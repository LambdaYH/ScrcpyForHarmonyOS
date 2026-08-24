#include "ScrcpyStreamManager.h"

#include <chrono>
#include <hilog/log.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

namespace {
template <typename Queue>
void drainQueue(Queue& queue) {
    std::vector<uint8_t> packet;
    while (queue.try_dequeue(packet)) {
    }
}

void joinThread(std::thread& thread) {
    if (!thread.joinable()) {
        return;
    }
    if (thread.get_id() == std::this_thread::get_id()) {
        thread.detach();
        return;
    }
    thread.join();
}
}

ScrcpyStreamManager::ScrcpyStreamManager() {}

ScrcpyStreamManager::~ScrcpyStreamManager() {
    stop();
}

int32_t ScrcpyStreamManager::start(Adb* adb, const Config& config, StreamEventCallback callback) {
    if (running_.load()) {
        OH_LOG_WARN(LOG_APP, "[StreamManager] Already running, stop first");
        stop();
    }

    adb_ = adb;
    config_ = config;
    eventCallback_ = callback;
    videoStream_ = (config_.videoStreamId >= 0 && adb_) ? adb_->getStreamHandle(config_.videoStreamId) : nullptr;
    audioStream_ = (config_.audioStreamId >= 0 && adb_) ? adb_->getStreamHandle(config_.audioStreamId) : nullptr;
    controlStream_ = (config_.controlStreamId >= 0 && adb_) ? adb_->getStreamHandle(config_.controlStreamId) : nullptr;

    if (config_.videoStreamId >= 0 && !videoStream_) return -3;
    if (config_.audioStreamId >= 0 && !audioStream_) return -4;
    if (config_.controlStreamId >= 0 && !controlStream_) return -5;

    running_.store(true);
    renderEnabled_.store(true);
    restoringCachedVideoFrame_.store(false);
    audioOutputEnabled_.store(true);
    videoReaderDone_.store(false);
    audioReaderDone_.store(false);
    drainQueue(controlReliableQueue_);
    {
        std::lock_guard<std::mutex> lock(videoKeyframeMutex_);
        latestVideoKeyframe_.clear();
        latestVideoKeyframePts_ = 0;
        latestVideoKeyframeFlags_ = 0;
    }
    initPacketPools();

    if (videoStream_) {
        videoThread_ = std::thread(&ScrcpyStreamManager::videoThreadFunc, this);
    }

    if (audioStream_) {
        audioThread_ = std::thread(&ScrcpyStreamManager::audioThreadFunc, this);
    }

    if (controlStream_) {
        controlThread_ = std::thread(&ScrcpyStreamManager::controlThreadFunc, this);
        controlSendThread_ = std::thread(&ScrcpyStreamManager::controlSendThreadFunc, this);
    }

    return 0;
}

int32_t ScrcpyStreamManager::startReverse(Adb* adb, const Config& config, StreamEventCallback callback) {
    if (running_.load()) {
        OH_LOG_WARN(LOG_APP, "[StreamManager] Already running, stop first");
        stop();
    }

    adb_ = adb;
    config_ = config;
    eventCallback_ = callback;
    videoStream_ = nullptr;
    audioStream_ = nullptr;
    controlStream_ = nullptr;

    uint16_t port = 0;
    int32_t listenerRet = createTcpListener(port);
    if (listenerRet != 0) {
        closeLocalTunnels();
        closeListener();
        adb_ = nullptr;
        return listenerRet;
    }

    running_.store(true);
    renderEnabled_.store(true);
    restoringCachedVideoFrame_.store(false);
    audioOutputEnabled_.store(true);
    videoReaderDone_.store(false);
    audioReaderDone_.store(false);
    drainQueue(controlReliableQueue_);
    {
        std::lock_guard<std::mutex> lock(videoKeyframeMutex_);
        latestVideoKeyframe_.clear();
        latestVideoKeyframePts_ = 0;
        latestVideoKeyframeFlags_ = 0;
    }
    initPacketPools();
    acceptThread_ = std::thread(&ScrcpyStreamManager::acceptThreadFunc, this);

    return static_cast<int32_t>(port);
}

int32_t ScrcpyStreamManager::minimize() {
    if (!running_.load()) {
        return -1;
    }
    renderEnabled_.store(false);
    audioOutputEnabled_.store(false);
    videoPackets_.discardQueued();
    audioPackets_.discardQueued();
    {
        std::lock_guard<std::mutex> lock(decoderMutex_);
        releaseVideoDecoderLocked();
        releaseAudioDecoderLocked();
    }
    renderStateCv_.notify_all();
    return 0;
}

int32_t ScrcpyStreamManager::attachSurface(const std::string& surfaceId) {
    if (!running_.load() || surfaceId.empty()) {
        return -1;
    }
    config_.surfaceId = surfaceId;
    restoringCachedVideoFrame_.store(true);
    std::lock_guard<std::mutex> lock(decoderMutex_);
    int32_t videoRet = videoCodecType_.empty() ? 0 : createVideoDecoderLocked();
    int32_t audioRet = 0;
    if ((config_.audioStreamId >= 0 || config_.expectAudio) && !audioCodecType_.empty()) {
        audioRet = createAudioDecoderLocked();
    }
    if (videoRet != 0) {
        renderEnabled_.store(false);
        audioOutputEnabled_.store(false);
        restoringCachedVideoFrame_.store(false);
        return videoRet;
    }

    EncodedVideoPacket* cachedKeyframe = nullptr;
    {
        std::lock_guard<std::mutex> keyframeLock(videoKeyframeMutex_);
        if (!latestVideoKeyframe_.empty()) {
            cachedKeyframe = videoPackets_.acquireForWrite();
            if (cachedKeyframe) {
                cachedKeyframe->data = latestVideoKeyframe_;
                cachedKeyframe->pts = latestVideoKeyframePts_;
                cachedKeyframe->submitFlags = latestVideoKeyframeFlags_;
                cachedKeyframe->isKeyFrame = true;
            }
        }
    }
    renderEnabled_.store(true);
    audioOutputEnabled_.store(audioRet == 0);
    if (cachedKeyframe) {
        videoPackets_.enqueueFront(cachedKeyframe);
    }
    restoringCachedVideoFrame_.store(false);
    videoPackets_.notifyAll();
    renderStateCv_.notify_all();
    return 0;
}

void ScrcpyStreamManager::stop() {
    bool wasRunning = running_.exchange(false);
    if (!wasRunning && !videoThread_.joinable() && !videoDecodeThread_.joinable() &&
        !audioThread_.joinable() && !audioDecodeThread_.joinable() &&
        !controlThread_.joinable() && !controlSendThread_.joinable() &&
        !acceptThread_.joinable()) {
        return;
    }

    closeLocalTunnels();
    closeListener();
    videoReaderDone_.store(true);
    audioReaderDone_.store(true);
    videoPackets_.notifyAll();
    audioPackets_.notifyAll();
    renderStateCv_.notify_all();

    if (adb_) {
        if (config_.videoStreamId >= 0) {
            adb_->streamClose(config_.videoStreamId);
        }
        if (config_.audioStreamId >= 0) {
            adb_->streamClose(config_.audioStreamId);
        }
        if (config_.controlStreamId >= 0) {
            adb_->streamClose(config_.controlStreamId);
        }
    }

    joinThread(videoThread_);
    joinThread(videoDecodeThread_);
    joinThread(audioThread_);
    joinThread(audioDecodeThread_);
    joinThread(controlThread_);
    joinThread(controlSendThread_);
    joinThread(acceptThread_);
    drainQueue(controlReliableQueue_);
    releaseLocalTunnels();
    resetPacketPools();

    {
        std::lock_guard<std::mutex> lock(decoderMutex_);
        releaseVideoDecoderLocked();
        releaseAudioDecoderLocked();
    }

    videoStream_ = nullptr;
    audioStream_ = nullptr;
    controlStream_ = nullptr;
    adb_ = nullptr;
    restoringCachedVideoFrame_.store(false);
    {
        std::lock_guard<std::mutex> lock(videoKeyframeMutex_);
        latestVideoKeyframe_.clear();
        latestVideoKeyframePts_ = 0;
        latestVideoKeyframeFlags_ = 0;
    }
}
