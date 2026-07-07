#include "decoder/VideoDecoderNative.h"
#include <hilog/log.h>
#include <algorithm>
#include <queue>
#include <mutex>
#include <cstring>
#include <chrono>
#include <thread>
#include <map>
#include "multimedia/player_framework/native_avbuffer.h"

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "VideoDecoderNative"
#define LOG_DOMAIN 0x3200

// DecoderContext - 使用 BlockingConcurrentQueue
struct DecoderContext {
    VideoDecoderNative* decoder = nullptr;
    moodycamel::BlockingConcurrentQueue<VideoInputBufferInfo> inputQueue;
    // std::mutex queueMutex; // Removed
    // std::condition_variable queueCv; // Removed
    bool isDecFirstFrame = true;
    int32_t outputWidth = 0;
    int32_t outputHeight = 0;
};

VideoDecoderNative::VideoDecoderNative()
    : decoder_(nullptr), window_(nullptr), isStarted_(false),
      width_(0), height_(0), codecType_("h264"), context_(nullptr) {
}

VideoDecoderNative::~VideoDecoderNative() {
    Release();
}

void VideoDecoderNative::SetSizeChangeCallback(VideoSizeChangeCallback callback) {
    sizeChangeCallback_ = callback;
}

void VideoDecoderNative::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "[Native] Decoder error: %{public}d", errorCode);
}

void VideoDecoderNative::OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    if (format == nullptr) {
        OH_LOG_WARN(LOG_APP, "[Native] Stream format changed but format is null");
        return;
    }
    int32_t width = 0;
    int32_t height = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_WIDTH, &width);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_HEIGHT, &height);
    
    // Also try video specific keys if generic ones fail or different
    int32_t videoWidth = 0;
    int32_t videoHeight = 0;
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &videoWidth);
    OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &videoHeight);

    DecoderContext* ctx = static_cast<DecoderContext*>(userData);
    if (ctx != nullptr && ctx->decoder != nullptr && ctx->decoder->sizeChangeCallback_) {
        // Use video dimensions if available, otherwise fallback to container dimensions
        int32_t finalW = (videoWidth > 0) ? videoWidth : width;
        int32_t finalH = (videoHeight > 0) ? videoHeight : height;
        if (finalW > 0 && finalH > 0 && (finalW != ctx->decoder->width_ || finalH != ctx->decoder->height_)) {
            ctx->decoder->width_ = finalW;
            ctx->decoder->height_ = finalH;
            ctx->decoder->sizeChangeCallback_(finalW, finalH);
        }
    }
}

void VideoDecoderNative::OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    DecoderContext* ctx = static_cast<DecoderContext*>(userData);
    if (ctx == nullptr || buffer == nullptr) return;

    ctx->inputQueue.enqueue({index, buffer});
    ctx->isDecFirstFrame = false;
}

void VideoDecoderNative::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    DecoderContext* ctx = static_cast<DecoderContext*>(userData);
    if (ctx == nullptr) return;

    if (ctx->isDecFirstFrame) {
        OH_AVFormat* format = OH_VideoDecoder_GetOutputDescription(codec);
        if (format != nullptr) {
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_WIDTH, &ctx->outputWidth);
            OH_AVFormat_GetIntValue(format, OH_MD_KEY_VIDEO_PIC_HEIGHT, &ctx->outputHeight);
            OH_AVFormat_Destroy(format);
        }
        ctx->isDecFirstFrame = false;
    }

    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK) {
        OH_VideoDecoder_RenderOutputBuffer(codec, index);
    } else {
        OH_VideoDecoder_FreeOutputBuffer(codec, index);
    }
}

int32_t VideoDecoderNative::Init(const char* codecType, const char* surfaceId, int32_t width, int32_t height) {
    width_ = width;
    height_ = height;
    codecType_ = codecType ? codecType : "h264";

    const char* mimeType = OH_AVCODEC_MIMETYPE_VIDEO_AVC;
    if (strcmp(codecType_.c_str(), "h265") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_VIDEO_HEVC;
    } else if (strcmp(codecType_.c_str(), "av1") == 0) {
        mimeType = "video/av01";
    }

    decoder_ = OH_VideoDecoder_CreateByMime(mimeType);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create decoder failed");
        return -1;
    }

    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, width);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, height);
//    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_NV12);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_FRAME_RATE, 120);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_MAX_INPUT_SIZE, 10 * 1024 * 1024); // 10MB (Safe for 4K 120fps high bitrate)

    int32_t ret = OH_VideoDecoder_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Configure failed: %{public}d", ret);
        return ret;
    }

    uint64_t surfaceIdNum = std::stoull(surfaceId);
    int32_t windowRet = OH_NativeWindow_CreateNativeWindowFromSurfaceId(surfaceIdNum, &window_);
    if (windowRet != 0 || window_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[Native] Create NativeWindow failed");
        return -1;
    }

    ret = OH_VideoDecoder_SetSurface(decoder_, window_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] SetSurface failed");
        return ret;
    }

    context_ = new DecoderContext();
    context_->decoder = this;

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;

    ret = OH_VideoDecoder_RegisterCallback(decoder_, callback, context_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] RegisterCallback failed");
        delete context_;
        context_ = nullptr;
        return ret;
    }

    ret = OH_VideoDecoder_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] Prepare failed");
        return ret;
    }

    return 0;
}

int32_t VideoDecoderNative::Start() {
    if (decoder_ == nullptr) return -1;

    int32_t ret = OH_VideoDecoder_Start(decoder_);
    if (ret == AV_ERR_OK) {
        isStarted_ = true;
        int waitCount = 0;
        while (waitCount < 200) {
            if (context_->inputQueue.size_approx() > 0) {
                return ret;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            waitCount++;
        }
        OH_LOG_WARN(LOG_APP, "[Native] Timeout waiting for buffers");
    }
    return ret;
}

int32_t VideoDecoderNative::PushData(uint8_t* data, int32_t size, int64_t pts, uint32_t flags) {
    if (!isStarted_ || decoder_ == nullptr || context_ == nullptr) {
        return -1;
    }

    VideoInputBufferInfo bufInfo;
    if (!context_->inputQueue.try_dequeue(bufInfo)) {
         return -2;
    }

    OH_AVBuffer* buffer = bufInfo.buffer;
    if (buffer == nullptr) return -2; // Should not happen

    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_ERROR(LOG_APP, "[Native] Buffer too small: %{public}d < %{public}d, dropping frame", bufferSize, size);
        // 归还buffer，避免泄漏
        OH_AVCodecBufferAttr attr;
        attr.pts = 0;
        attr.size = 0;
        attr.offset = 0;
        attr.flags = 0;
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        OH_VideoDecoder_PushInputBuffer(decoder_, bufInfo.index);
        return -1;
    }

    memcpy(bufferAddr, data, size);

    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = flags;

    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, bufInfo.index);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] PushInputBuffer failed: %{public}d", ret);
        return -1;
    }

    return 0;
}

int32_t VideoDecoderNative::GetInputBuffer(uint32_t* outIndex, uint8_t** outData, int32_t* outCapacity, void** outHandle, int32_t timeoutMs) {
    if (!isStarted_ || decoder_ == nullptr || context_ == nullptr) return -1;

    VideoInputBufferInfo bufInfo;
    bool success;
    
    if (timeoutMs < 0) {
         context_->inputQueue.wait_dequeue(bufInfo);
         success = true;
    } else {
         success = context_->inputQueue.wait_dequeue_timed(bufInfo, std::chrono::milliseconds(timeoutMs));
    }

    if (!success) {
        return -2; // Timeout/Empty
    }

    *outIndex = bufInfo.index;
    *outHandle = bufInfo.buffer;
    *outData = OH_AVBuffer_GetAddr(bufInfo.buffer);
    *outCapacity = OH_AVBuffer_GetCapacity(bufInfo.buffer);
    
    return 0;
}

int32_t VideoDecoderNative::SubmitInputBuffer(uint32_t index, void* handle, int64_t pts, int32_t size, uint32_t flags) {
    if (!isStarted_ || decoder_ == nullptr) return -1;
    
    OH_AVBuffer* buffer = static_cast<OH_AVBuffer*>(handle);
    
    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = flags;
    
    OH_AVBuffer_SetBufferAttr(buffer, &attr);
    
    int32_t ret = OH_VideoDecoder_PushInputBuffer(decoder_, index);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[Native] SubmitInputBuffer failed: %{public}d", ret);
        return -1;
    }
    
    return 0;
}

int32_t VideoDecoderNative::Stop() {
    if (decoder_ != nullptr && isStarted_) {
        OH_VideoDecoder_Stop(decoder_);
        isStarted_ = false;
    }
    return 0;
}

int32_t VideoDecoderNative::Release() {
    if (decoder_ == nullptr && window_ == nullptr && context_ == nullptr) return 0;

    Stop();

    if (decoder_ != nullptr) {
        OH_VideoDecoder_Destroy(decoder_);
        decoder_ = nullptr;
    }

    if (window_ != nullptr) {
        OH_NativeWindow_DestroyNativeWindow(window_);
        window_ = nullptr;
    }

    if (context_ != nullptr) {
        delete context_;
        context_ = nullptr;
    }

    return 0;
}

bool VideoDecoderNative::HasAvailableBuffer() const {
    if (context_ == nullptr) return false;
    return context_->inputQueue.size_approx() > 0;
}
