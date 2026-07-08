#include "ScrcpyStreamManager.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <hilog/log.h>
#include <sstream>
#include <stdexcept>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

namespace {
constexpr size_t VIDEO_STARTUP_PREBUFFER_FRAMES = 10;
constexpr size_t VIDEO_REBUFFER_LOW_WATERMARK = 2;
constexpr int32_t VIDEO_REBUFFER_TRIGGER_MS = 90;
constexpr int32_t VIDEO_REBUFFER_MAX_WAIT_MS = 120;
constexpr int32_t VIDEO_HANDSHAKE_TIMEOUT_MS = 10000;

double elapsedMs(const std::chrono::steady_clock::time_point& start,
                 const std::chrono::steady_clock::time_point& end) {
    return std::chrono::duration<double, std::milli>(end - start).count();
}
}

void ScrcpyStreamManager::videoThreadFunc() {
    try {
        auto source = ::createByteStream(adb_, videoChannel_, videoStream_, "video");
        if (!source) {
            throw std::runtime_error("video source not found");
        }

        auto readToBuffer = [this, &source](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            readExactToBuffer(source.get(), dest, size, timeoutMs);
        };

        auto readBytes = [this, &source](size_t size, int32_t timeoutMs = -1) {
            return readExact(source.get(), size, timeoutMs);
        };

        if (config_.sendDummyByte) {
            auto dummy = readBytes(1, VIDEO_HANDSHAKE_TIMEOUT_MS);
            (void)dummy;
        }

        auto deviceNameData = readBytes(64, VIDEO_HANDSHAKE_TIMEOUT_MS);
        std::string deviceName(reinterpret_cast<char*>(deviceNameData.data()), 64);
        deviceName = deviceName.c_str();

        auto codecMeta = readBytes(12, VIDEO_HANDSHAKE_TIMEOUT_MS);
        int32_t codecId = readInt32BEValue(codecMeta.data());
        int32_t width = readInt32BEValue(codecMeta.data() + 4);
        int32_t height = readInt32BEValue(codecMeta.data() + 8);
        videoWidth_.store(width);
        videoHeight_.store(height);

        std::string codecType = "h264";
        if (codecId == 1 || codecId == 1748121141) codecType = "h265";
        if (codecId == 2 || codecId == 1635135537) codecType = "av1";
        OH_LOG_INFO(LOG_APP, "[VideoThread] Config codecId=%{public}d codec=%{public}s width=%{public}d height=%{public}d",
                    codecId, codecType.c_str(), width, height);

        {
            std::ostringstream oss;
            oss << "{\"codecId\":" << codecId
                << ",\"width\":" << width
                << ",\"height\":" << height
                << ",\"codecType\":\"" << codecType << "\""
                << ",\"deviceName\":\"" << deviceName << "\"}";
            emitEvent("video_config", oss.str());
        }

        videoDecoder_ = new VideoDecoderNative();
        videoDecoder_->SetSizeChangeCallback([this, codecId, codecType, deviceName](int32_t w, int32_t h) {
            this->videoWidth_.store(w);
            this->videoHeight_.store(h);
            std::ostringstream oss;
            oss << "{\"codecId\":" << codecId
                << ",\"width\":" << w
                << ",\"height\":" << h
                << ",\"codecType\":\"" << codecType << "\""
                << ",\"deviceName\":\"" << deviceName << "\"}";
            this->emitEvent("video_size_changed", oss.str());
        });

        int32_t initRet = videoDecoder_->Init(codecType.c_str(), config_.surfaceId.c_str(), width, height);
        if (initRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Decoder init failed: %{public}d", initRet);
            emitEvent("error", "Video decoder init failed");
            videoReaderDone_.store(true);
            videoPackets_.notifyAll();
            return;
        }

        int32_t startRet = videoDecoder_->Start();
        if (startRet != 0) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Decoder start failed: %{public}d", startRet);
            emitEvent("error", "Video decoder start failed");
            videoReaderDone_.store(true);
            videoPackets_.notifyAll();
            return;
        }

        videoDecodeThread_ = std::thread(&ScrcpyStreamManager::videoDecodeThreadFunc, this);

        uint8_t ptsBuf[8];
        uint8_t sizeBuf[4];
        auto acquireVideoPacket = [this]() -> EncodedVideoPacket* {
            auto waitStart = std::chrono::steady_clock::now();
            int64_t lastLogBucket = -1;
            while (running_.load()) {
                EncodedVideoPacket* packet = videoPackets_.waitAcquireFreeForWrite(20, running_);
                if (packet) {
                    int64_t waitedMs = static_cast<int64_t>(elapsedMs(waitStart, std::chrono::steady_clock::now()));
                    if (waitedMs >= 100) {
                        OH_LOG_INFO(LOG_APP,
                            "[VideoThread] Free video packet resumed after %{public}lldms queued=%{public}zu dropped=%{public}llu",
                            static_cast<long long>(waitedMs), videoPackets_.queuedSize(),
                            static_cast<unsigned long long>(videoPackets_.droppedCount()));
                    }
                    return packet;
                }

                int64_t waitedMs = static_cast<int64_t>(elapsedMs(waitStart, std::chrono::steady_clock::now()));
                int64_t bucket = waitedMs / 1000;
                if (waitedMs >= 100 && bucket != lastLogBucket) {
                    lastLogBucket = bucket;
                    OH_LOG_WARN(LOG_APP,
                        "[VideoThread] Waiting for free video packet %{public}lldms queued=%{public}zu dropped=%{public}llu",
                        static_cast<long long>(waitedMs), videoPackets_.queuedSize(),
                        static_cast<unsigned long long>(videoPackets_.droppedCount()));
                }
            }
            return nullptr;
        };

        while (running_.load()) {
            ScrcpyPacketMeta meta = readScrcpyPacketMeta(readToBuffer, ptsBuf, sizeBuf, 20 * 1024 * 1024,
                                                         "VideoThread");
            EncodedVideoPacket* packet = readScrcpyPacketPayload<EncodedVideoPacket>(
                readToBuffer, acquireVideoPacket, meta,
                "VideoThread", "frame");
            if (!packet) {
                continue;
            }
            applyPacketMeta(packet, meta);

            if (meta.isConfig) {
                videoPackets_.cacheConfig(packet->data.data(), packet->data.size(), packet->submitFlags);
                videoPackets_.recycle(packet);
                continue;
            }

            videoPackets_.enqueue(packet);
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[VideoThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Video thread error: ") + e.what());
        }
    }

    videoReaderDone_.store(true);
    videoPackets_.notifyAll();

    if (running_.load()) {
        emitEvent("disconnected", "video");
    }
}

void ScrcpyStreamManager::videoDecodeThreadFunc() {
    uint64_t appliedConfigSerial = 0;
    bool firstFrameNotified = false;
    bool startupBuffered = false;
    bool rebuffering = false;
    bool starvationActive = false;
    auto rebufferStart = std::chrono::steady_clock::now();
    auto starvationStart = std::chrono::steady_clock::now();

    try {
        while (running_.load() || !videoReaderDone_.load()) {
            if ((!startupBuffered || rebuffering) && running_.load()) {
                size_t queuedFrames = videoPackets_.queuedSize();
                const size_t targetFrames = startupBuffered ? VIDEO_REBUFFER_LOW_WATERMARK
                                                            : VIDEO_STARTUP_PREBUFFER_FRAMES;
                if (!videoReaderDone_.load() && queuedFrames < targetFrames) {
                    if (rebuffering &&
                        elapsedMs(rebufferStart, std::chrono::steady_clock::now()) >= VIDEO_REBUFFER_MAX_WAIT_MS) {
                        rebuffering = false;
                    } else {
                        std::this_thread::sleep_for(std::chrono::milliseconds(2));
                        continue;
                    }
                }
                startupBuffered = true;
                rebuffering = false;
                starvationActive = false;
            }

            EncodedVideoPacket* packet = nullptr;
            if (!videoPackets_.waitDequeueTimed(packet, 10, running_, videoReaderDone_)) {
                if (videoReaderDone_.load() || !running_.load()) {
                    break;
                }
                auto now = std::chrono::steady_clock::now();
                if (!startupBuffered) {
                    continue;
                }
                if (!starvationActive) {
                    starvationActive = true;
                    starvationStart = now;
                    continue;
                }
                if (!rebuffering &&
                    elapsedMs(starvationStart, now) >= VIDEO_REBUFFER_TRIGGER_MS) {
                    rebuffering = true;
                    rebufferStart = now;
                }
                continue;
            }
            starvationActive = false;
            rebuffering = false;

            std::vector<uint8_t> configData;
            uint32_t configFlags = 0;
            uint64_t nextConfigSerial = appliedConfigSerial;
            if (videoPackets_.copyPendingConfig(configData, configFlags, nextConfigSerial, appliedConfigSerial)) {
                uint32_t cfgIndex = 0;
                uint8_t* cfgData = nullptr;
                int32_t cfgCapacity = 0;
                void* cfgHandle = nullptr;
                while (running_.load()) {
                    int32_t ret = videoDecoder_->GetInputBuffer(&cfgIndex, &cfgData, &cfgCapacity, &cfgHandle, 10);
                    if (ret == 0) {
                        if (cfgCapacity >= static_cast<int32_t>(configData.size())) {
                            std::memcpy(cfgData, configData.data(), configData.size());
                            videoDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0,
                                                             static_cast<int32_t>(configData.size()), configFlags);
                            appliedConfigSerial = nextConfigSerial;
                        } else {
                            OH_LOG_ERROR(LOG_APP,
                                "[VideoDecode] Config buffer too small: capacity=%{public}d size=%{public}zu",
                                cfgCapacity, configData.size());
                            videoDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0, 0, 0);
                        }
                        break;
                    }
                    if (ret != -2) {
                        OH_LOG_ERROR(LOG_APP, "[VideoDecode] GetInputBuffer for config failed: %{public}d", ret);
                        break;
                    }
                }
            }

            uint32_t bufIndex = 0;
            uint8_t* bufData = nullptr;
            int32_t bufCapacity = 0;
            void* bufHandle = nullptr;
            int32_t getBufRet = -1;
            while (running_.load()) {
                getBufRet = videoDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0 || getBufRet != -2) {
                    break;
                }
            }

            if (getBufRet != 0) {
                videoPackets_.recycle(packet);
                if (running_.load()) {
                    OH_LOG_ERROR(LOG_APP, "[VideoDecode] GetInputBuffer failed: %{public}d", getBufRet);
                    emitEvent("error", std::string("Video decode input buffer failed: ") + std::to_string(getBufRet));
                }
                break;
            }

            if (bufCapacity < static_cast<int32_t>(packet->data.size())) {
                OH_LOG_ERROR(LOG_APP, "[VideoDecode] Buffer too small: %{public}d < %{public}zu",
                             bufCapacity, packet->data.size());
                videoDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                videoPackets_.recycle(packet);
                continue;
            }

            std::memcpy(bufData, packet->data.data(), packet->data.size());
            size_t packetSize = packet->data.size();
            int64_t packetPts = packet->pts;
            uint32_t packetFlags = packet->submitFlags;
            int32_t submitRet = videoDecoder_->SubmitInputBuffer(
                bufIndex,
                bufHandle,
                packetPts,
                static_cast<int32_t>(packetSize),
                packetFlags);
            videoPackets_.recycle(packet);

            if (submitRet == 0) {
                if (!firstFrameNotified) {
                    firstFrameNotified = true;
                    emitEvent("first_frame", "");
                }
            } else {
                OH_LOG_ERROR(LOG_APP, "[VideoDecode] Submit failed: %{public}d", submitRet);
            }
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[VideoDecode] Error: %{public}s", e.what());
            emitEvent("error", std::string("Video decode thread error: ") + e.what());
        }
    }
}
