// ScrcpyStreamManager - C++ 层流管理器
// 接管 ADB 流的读取，使用独立线程解析 Scrcpy V2 协议并推送至解码器
#ifndef SCRCPY_STREAM_MANAGER_H
#define SCRCPY_STREAM_MANAGER_H

#include "adb/core/Adb.h"
#include "adb/core/AdbChannel.h"
#include "concurrentqueue/blockingconcurrentqueue.h"
#include "stream/EncodedPacket.h"
#include "stream/MediaPacketStore.h"
#include "stream/StreamIO.h"
#include "decoder/VideoDecoderNative.h"
#include "decoder/AudioDecoderNative.h"

#include <cstdint>
#include <string>
#include <thread>
#include <atomic>
#include <functional>
#include <mutex>
#include <vector>
#include <deque>
#include <condition_variable>
#include <memory>

// 事件回调: type, data (JSON string)
using StreamEventCallback = std::function<void(const std::string& type, const std::string& data)>;

class ScrcpyStreamManager {
public:
    struct Config {
        int32_t videoStreamId = -1;
        int32_t audioStreamId = -1;    // -1 if no audio
        int32_t controlStreamId = -1;
        std::string surfaceId;
        int32_t audioSampleRate = 48000;
        int32_t audioChannelCount = 2;
        bool reverse = false;
        bool expectVideo = true;
        bool expectAudio = false;
        bool expectControl = true;
        bool sendDummyByte = true;
    };

    ScrcpyStreamManager();
    ~ScrcpyStreamManager();

    // 启动流处理，adb 必须已连接且 stream 已打开
    int32_t start(Adb* adb, const Config& config, StreamEventCallback callback);
    int32_t startReverse(Adb* adb, const Config& config, StreamEventCallback callback);

    // 向控制流发送数据
    bool sendControl(const uint8_t* data, size_t len);

    // 保留传输线程但释放解码/渲染资源，用于热最小化。
    int32_t minimize();

    // 在现有传输流上重新创建解码器并绑定新的 Surface。
    int32_t attachSurface(const std::string& surfaceId);

    int32_t getVideoWidth() const { return videoWidth_.load(); }
    int32_t getVideoHeight() const { return videoHeight_.load(); }

    // 停止所有线程并释放资源
    void stop();

    bool isRunning() const { return running_.load(); }

private:
    // 线程函数
    void videoThreadFunc();
    void videoDecodeThreadFunc();
    void audioThreadFunc();
    void audioDecodeThreadFunc();
    void controlThreadFunc();
    void controlSendThreadFunc();
    void acceptThreadFunc();

    // 精确读取 N 字节（阻塞），抛出异常表示流关闭或超时
    std::vector<uint8_t> readExact(IByteStream* source, size_t size, int32_t timeoutMs = -1);
    void readExactToBuffer(IByteStream* source, uint8_t* dest, size_t size, int32_t timeoutMs = -1);
    int32_t createTcpListener(uint16_t& port);
    void closeLocalTunnels();
    void releaseLocalTunnels();
    void closeListener();
    static void closeFd(int& fd);
    void initPacketPools();
    void resetPacketPools();
    int32_t createVideoDecoderLocked();
    int32_t createAudioDecoderLocked();
    void releaseVideoDecoderLocked();
    void releaseAudioDecoderLocked();

    // 发送事件到 ArkTS
    void emitEvent(const std::string& type, const std::string& data = "");

    Adb* adb_ = nullptr;
    Config config_;
    StreamEventCallback eventCallback_;

    VideoDecoderNative* videoDecoder_ = nullptr;
    AudioDecoderNative* audioDecoder_ = nullptr;
    AdbStream* videoStream_ = nullptr;
    AdbStream* audioStream_ = nullptr;
    AdbStream* controlStream_ = nullptr;
    AdbChannel* videoChannel_ = nullptr;
    AdbChannel* audioChannel_ = nullptr;
    AdbChannel* controlChannel_ = nullptr;

    int listenFd_ = -1;

    std::thread videoThread_;
    std::thread videoDecodeThread_;
    std::thread audioThread_;
    std::thread audioDecodeThread_;
    std::thread controlThread_;
    std::thread acceptThread_;
    std::thread controlSendThread_;
    std::atomic<bool> running_{false};
    std::atomic<bool> videoReaderDone_{false};
    std::atomic<bool> audioReaderDone_{false};
    std::atomic<int32_t> videoWidth_{0};
    std::atomic<int32_t> videoHeight_{0};
    std::atomic<bool> renderEnabled_{true};
    std::atomic<bool> restoringCachedVideoFrame_{false};
    std::atomic<bool> audioOutputEnabled_{true};
    std::atomic<uint64_t> videoDecoderGeneration_{0};
    std::atomic<uint64_t> audioDecoderGeneration_{0};
    std::string videoCodecType_;
    std::string audioCodecType_;
    std::string deviceName_;
    int32_t videoCodecId_ = 0;
    std::mutex decoderMutex_;
    std::mutex renderStateMutex_;
    std::condition_variable renderStateCv_;
    std::mutex videoKeyframeMutex_;
    std::vector<uint8_t> latestVideoKeyframe_;
    int64_t latestVideoKeyframePts_ = 0;
    uint32_t latestVideoKeyframeFlags_ = 0;
    std::mutex eventMutex_;
    moodycamel::BlockingConcurrentQueue<std::vector<uint8_t>> controlReliableQueue_;
    MediaPacketStore<EncodedVideoPacket> videoPackets_;
    MediaPacketStore<EncodedAudioPacket> audioPackets_;
};

#endif // SCRCPY_STREAM_MANAGER_H
