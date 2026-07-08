#ifndef VIDEO_DECODER_NATIVE_H
#define VIDEO_DECODER_NATIVE_H

#include <string>
#include <queue>
#include <mutex>
#include <functional>
#include <atomic>
#include <thread>
#include "concurrentqueue/blockingconcurrentqueue.h"
#include "multimedia/player_framework/native_avcodec_videodecoder.h"
#include "multimedia/player_framework/native_avbuffer.h"
#include "native_window/external_window.h"

struct VideoInputBufferInfo {
    uint32_t index;
    OH_AVBuffer* buffer;
};

struct VideoOutputBufferInfo {
    uint32_t index;
    int64_t pts;
    int32_t size;
    uint32_t flags;
};

class VideoDecoderNative {
public:
    VideoDecoderNative();
    ~VideoDecoderNative();

    // codecType: "h264", "h265", "av1"
    int32_t Init(const char* codecType, const char* surfaceId, int32_t width, int32_t height);
    int32_t Start();
    int32_t PushData(uint8_t* data, int32_t size, int64_t pts, uint32_t flags);

    // Zero-Copy API
    // Get a free input buffer. Blocks up to timeoutMs.
    // returns 0 on success.
    int32_t GetInputBuffer(uint32_t* outIndex, uint8_t** outData, int32_t* outCapacity, void** outHandle, int32_t timeoutMs = 10);
    
    // Submit the filled input buffer.
    int32_t SubmitInputBuffer(uint32_t index, void* handle, int64_t pts, int32_t size, uint32_t flags);

    int32_t Stop();
    int32_t Release();
    bool HasAvailableBuffer() const;

    using VideoSizeChangeCallback = std::function<void(int32_t width, int32_t height)>;
    void SetSizeChangeCallback(VideoSizeChangeCallback callback);
    VideoSizeChangeCallback sizeChangeCallback_;

private:
    static void OnError(OH_AVCodec* codec, int32_t errorCode, void* userData);
    static void OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData);
    static void OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    static void OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData);
    void RenderOutputLoop();

    OH_AVCodec* decoder_;
    OHNativeWindow* window_;
    bool isStarted_;
    std::atomic<bool> renderRunning_ {false};
    std::thread renderThread_;
    int32_t width_;
    int32_t height_;
    std::string codecType_;
    struct DecoderContext* context_;
};

#endif // VIDEO_DECODER_NATIVE_H
