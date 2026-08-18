#include "decoder/AudioDecoderNative.h"

#include <hilog/log.h>
#include <cstring>
#include <algorithm>
#include <thread>
#include <chrono>
#include <ohaudio/native_audiostreambuilder.h>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "AudioDecoderNative"
#define LOG_DOMAIN 0x3200

struct InputBufferInfo {
    uint32_t index;
    OH_AVBuffer* buffer;
};

struct AudioDecoderContext {
    AudioDecoderNative* decoder = nullptr;
    moodycamel::BlockingConcurrentQueue<InputBufferInfo> inputQueue;
    // std::mutex inputMutex;
    // std::condition_variable inputCv;
};

AudioDecoderNative::AudioDecoderNative()
    : decoder_(nullptr), renderer_(nullptr), builder_(nullptr),
      isStarted_(false), isRaw_(false),
      sampleRate_(48000), channelCount_(2),
      codecType_("opus"), context_(nullptr), currentFrame_(nullptr) {
    
    // Fill pool with initial frames
    for (size_t i = 0; i < PCM_POOL_SIZE; ++i) {
        freePcmFrames_.enqueue(new PcmFrame());
    }
}

AudioDecoderNative::~AudioDecoderNative() {
    Release();
}

void AudioDecoderNative::OnError(OH_AVCodec* codec, int32_t errorCode, void* userData) {
    OH_LOG_ERROR(LOG_APP, "[AudioNative] Decoder error: %{public}d", errorCode);
}

void AudioDecoderNative::OnStreamChanged(OH_AVCodec* codec, OH_AVFormat* format, void* userData) {
    OH_LOG_INFO(LOG_APP, "[AudioNative] Stream format changed");
}

void AudioDecoderNative::OnNeedInputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    AudioDecoderContext* ctx = static_cast<AudioDecoderContext*>(userData);
    if (buffer != nullptr && ctx != nullptr) {
        ctx->inputQueue.enqueue({index, buffer});
    }
}

void AudioDecoderNative::OnNewOutputBuffer(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void* userData) {
    AudioDecoderContext* ctx = static_cast<AudioDecoderContext*>(userData);
    if (buffer == nullptr) return;

    OH_AVCodecBufferAttr attr;
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && attr.size > 0) {
        uint8_t* data = OH_AVBuffer_GetAddr(buffer);

        // Simple size check to avoid unlimited growth
        if (ctx->decoder->pcmQueue_.size_approx() < PCM_POOL_SIZE) {
            // Decoding mode: we still need to copy from AVBuffer to PcmFrame
            // Get a free frame
            PcmFrame* frame = nullptr;
            if (!ctx->decoder->freePcmFrames_.try_dequeue(frame)) {
                 frame = new PcmFrame();
            }
            
            size_t copySize = std::min(static_cast<size_t>(attr.size), sizeof(frame->data));
            std::memcpy(frame->data.data(), data, copySize);
            frame->size = copySize;
            frame->offset = 0;
            
            ctx->decoder->pcmQueue_.enqueue(frame);
        } else {
             // Drop frame if queue full, but we must recycle logic?
             // Actually if decoder is fast but renderer slow, we drop.
             // But we don't have a frame to recycle unless we dequeued it.
             // Just do nothing -> frame dropped.
        }
    }

    OH_AudioCodec_FreeOutputBuffer(codec, index);
}

int32_t AudioDecoderNative::OnAudioRendererWriteData(OH_AudioRenderer* renderer,
                                                      void* userData,
                                                      void* buffer,
                                                      int32_t length) {
    AudioDecoderNative* self = static_cast<AudioDecoderNative*>(userData);
    // No lock needed for pcmQueue_ (thread-safe)
    // But currentFrame_ is accessed only by this thread (renderer callback), so it's safe.

    int32_t written = 0;
    uint8_t* outBuffer = static_cast<uint8_t*>(buffer);

    while (written < length) {
        // If current frame empty/exhausted, get next one
        if (self->currentFrame_ == nullptr || self->currentFrame_->remaining() == 0) {
             // Recycle used frame
             if (self->currentFrame_ != nullptr) {
                 self->freePcmFrames_.enqueue(self->currentFrame_);
                 self->currentFrame_ = nullptr;
             }
             
             if (!self->pcmQueue_.try_dequeue(self->currentFrame_)) {
                 break; // No more data
             }
        }

        size_t offset = self->currentFrame_->offset;
        size_t remaining = self->currentFrame_->remaining();
        int32_t toCopy = std::min(static_cast<int32_t>(remaining), length - written);
        
        std::memcpy(outBuffer + written, self->currentFrame_->data.data() + offset, toCopy);
        written += toCopy;
        self->currentFrame_->offset += toCopy;
    }

    if (written < length) {
        std::memset(outBuffer + written, 0, length - written);
    }

    return length;
}

int32_t AudioDecoderNative::OnAudioRendererInterruptEvent(OH_AudioRenderer* renderer,
                                                           void* userData,
                                                           OH_AudioInterrupt_ForceType type,
                                                           OH_AudioInterrupt_Hint hint) {
    OH_LOG_INFO(LOG_APP, "[AudioNative] OnInterruptEvent: type=%{public}d, hint=%{public}d",
                static_cast<int32_t>(type), static_cast<int32_t>(hint));
    return 0;
}

int32_t AudioDecoderNative::OnAudioRendererStreamEvent(OH_AudioRenderer* renderer,
                                                        void* userData,
                                                        OH_AudioStream_Event event) {
    OH_LOG_INFO(LOG_APP, "[AudioNative] OnStreamEvent: event=%{public}d", static_cast<int32_t>(event));
    return 0;
}

int32_t AudioDecoderNative::OnAudioRendererError(OH_AudioRenderer* renderer,
                                                  void* userData,
                                                  OH_AudioStream_Result error) {
    OH_LOG_ERROR(LOG_APP, "[AudioNative] OnRendererError: error=%{public}d", static_cast<int32_t>(error));
    return 0;
}

int32_t AudioDecoderNative::InitAudioRenderer() {
    // 创建音频流构建器
    OH_AudioStream_Result result = OH_AudioStreamBuilder_Create(&builder_, AUDIOSTREAM_TYPE_RENDERER);
    if (result != AUDIOSTREAM_SUCCESS || builder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Create AudioStreamBuilder failed: %{public}d", result);
        return -1;
    }

    // 设置采样率
    OH_AudioStreamBuilder_SetSamplingRate(builder_, sampleRate_);

    // 设置声道数
    OH_AudioStreamBuilder_SetChannelCount(builder_, channelCount_);

    // 设置采样格式为S16LE
    OH_AudioStreamBuilder_SetSampleFormat(builder_, AUDIOSTREAM_SAMPLE_S16LE);

    // 设置编码类型为PCM
    OH_AudioStreamBuilder_SetEncodingType(builder_, AUDIOSTREAM_ENCODING_TYPE_RAW);

    // 设置渲染信息
    OH_AudioStreamBuilder_SetRendererInfo(builder_, AUDIOSTREAM_USAGE_MUSIC);

    // 设置回调
    OH_AudioRenderer_Callbacks callbacks;
    callbacks.OH_AudioRenderer_OnWriteData = OnAudioRendererWriteData;
    callbacks.OH_AudioRenderer_OnInterruptEvent = OnAudioRendererInterruptEvent;
    callbacks.OH_AudioRenderer_OnStreamEvent = OnAudioRendererStreamEvent;
    callbacks.OH_AudioRenderer_OnError = OnAudioRendererError;
    OH_AudioStreamBuilder_SetRendererCallback(builder_, callbacks, this);

    // 创建渲染器
    result = OH_AudioStreamBuilder_GenerateRenderer(builder_, &renderer_);
    if (result != AUDIOSTREAM_SUCCESS || renderer_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Create AudioRenderer failed: %{public}d", result);
        return -1;
    }

    return 0;
}

int32_t AudioDecoderNative::Init(const char* codecType, int32_t sampleRate, int32_t channelCount) {
    OH_LOG_DEBUG(LOG_APP, "[AudioNative] Init: codec=%{public}s, sampleRate=%{public}d, channels=%{public}d",
                codecType, sampleRate, channelCount);

    sampleRate_ = sampleRate;
    channelCount_ = channelCount;
    codecType_ = codecType ? codecType : "opus";

    // RAW格式不需要解码器，直接播放PCM
    if (strcmp(codecType_.c_str(), "raw") == 0) {
        isRaw_ = true;

        // 只初始化音频渲染器
        int32_t ret = InitAudioRenderer();
        if (ret != 0) {
            return ret;
        }

        return 0;
    }

    isRaw_ = false;

    // 根据codecType选择对应的MIME类型
    const char* mimeType = nullptr;
    if (strcmp(codecType_.c_str(), "opus") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_OPUS;
    } else if (strcmp(codecType_.c_str(), "aac") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_AAC;
    } else if (strcmp(codecType_.c_str(), "flac") == 0) {
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_FLAC;
    } else {
        OH_LOG_WARN(LOG_APP, "[AudioNative] Unknown codec type: %{public}s, fallback to OPUS", codecType);
        mimeType = OH_AVCODEC_MIMETYPE_AUDIO_OPUS;
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] Creating decoder with MIME: %{public}s", mimeType);

    // 创建解码器
    decoder_ = OH_AudioCodec_CreateByMime(mimeType, false);
    if (decoder_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Create decoder failed, codec=%{public}s", mimeType);
        return -1;
    }

    // 配置解码器
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, sampleRate);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, channelCount);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, 1);  // SAMPLE_S16LE
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_CHANNEL_LAYOUT,
                             channelCount == 2 ? 3 : 4);  // STEREO or MONO

    int32_t ret = OH_AudioCodec_Configure(decoder_, format);
    OH_AVFormat_Destroy(format);

    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Configure failed: %{public}d", ret);
        return ret;
    }

    // 设置回调
    context_ = new AudioDecoderContext();
    context_->decoder = this;

    OH_AVCodecCallback callback;
    callback.onError = OnError;
    callback.onStreamChanged = OnStreamChanged;
    callback.onNeedInputBuffer = OnNeedInputBuffer;
    callback.onNewOutputBuffer = OnNewOutputBuffer;

    ret = OH_AudioCodec_RegisterCallback(decoder_, callback, context_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] RegisterCallback failed: %{public}d", ret);
        delete context_;
        context_ = nullptr;
        return ret;
    }

    // 准备解码器
    ret = OH_AudioCodec_Prepare(decoder_);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] Prepare failed: %{public}d", ret);
        return ret;
    }

    // 初始化音频渲染器
    ret = InitAudioRenderer();
    if (ret != 0) {
        return ret;
    }

    OH_LOG_INFO(LOG_APP, "[AudioNative] Init success with codec %{public}s", codecType);
    return 0;
}

int32_t AudioDecoderNative::Start() {
    // 启动音频渲染器
    if (renderer_ != nullptr) {
        OH_AudioStream_Result result = OH_AudioRenderer_Start(renderer_);
        if (result != AUDIOSTREAM_SUCCESS) {
            OH_LOG_ERROR(LOG_APP, "[AudioNative] Start renderer failed: %{public}d", result);
            return -1;
        }
    }

    // 如果不是RAW模式，启动解码器
    if (!isRaw_ && decoder_ != nullptr) {
        int32_t ret = OH_AudioCodec_Start(decoder_);
        if (ret != AV_ERR_OK) {
            OH_LOG_ERROR(LOG_APP, "[AudioNative] Start decoder failed: %{public}d", ret);
            return ret;
        }

        int waitCount = 0;
        constexpr int MAX_WAIT_COUNT = 200;  // 200 * 10ms = 2000ms
        while (waitCount < MAX_WAIT_COUNT) {
            if (context_->inputQueue.size_approx() > 0) {
                 OH_LOG_INFO(LOG_APP, "[AudioNative] Initial input buffer available after %{public}dx10ms", waitCount);
                 break;
            }
            // 使用nanosleep替代sleep_for
            struct timespec ts = {0, 10000000};  // 10ms
            nanosleep(&ts, nullptr);
            waitCount++;
        }
        if (waitCount >= MAX_WAIT_COUNT) {
                OH_LOG_WARN(LOG_APP, "[AudioNative] Timeout waiting for initial input buffers (queue still empty after %{public}dms)",
                       waitCount * 10);
        }
    }

    isStarted_ = true;
    return 0;
}

int32_t AudioDecoderNative::GetInputBuffer(uint32_t* outIndex, uint8_t** outData, int32_t* outCapacity, void** outHandle, int32_t timeoutMs) {
    if (!isStarted_) return -1;

    // RAW 模式特殊处理：伪造一个 buffer
    if (isRaw_) {
        // Raw mode: Get frame from pool
        PcmFrame* frame = nullptr;
        if (!freePcmFrames_.try_dequeue(frame)) {
             frame = new PcmFrame();
        }

        *outIndex = 0; // Dummy
        // We use the frame pointer as the handle
        *outHandle = frame; 
        
        *outData = frame->data.data();
        *outCapacity = static_cast<int32_t>(frame->data.size());
        
        return 0;
    }

    if (decoder_ == nullptr || context_ == nullptr) return -1;

    InputBufferInfo bufInfo;
    bool success;
    if (timeoutMs < 0) {
        context_->inputQueue.wait_dequeue(bufInfo);
        success = true;
    } else {
        success = context_->inputQueue.wait_dequeue_timed(bufInfo, std::chrono::milliseconds(timeoutMs));
    }

    if (!success) return -2; // Timeout

    *outIndex = bufInfo.index;
    *outHandle = bufInfo.buffer;
    *outData = OH_AVBuffer_GetAddr(bufInfo.buffer);
    *outCapacity = OH_AVBuffer_GetCapacity(bufInfo.buffer);

    return 0;
}

int32_t AudioDecoderNative::SubmitInputBuffer(uint32_t index, void* handle, int64_t pts, int32_t size, uint32_t flags) {
    if (!isStarted_) {
        // 如果停止了，Raw模式需要释放内存
        if (isRaw_ && handle) {
            delete[] static_cast<uint8_t*>(handle);
        }
        return -1;
    }

    if (isRaw_) {
        // Raw Mode: handle is PcmFrame*
        PcmFrame* frame = static_cast<PcmFrame*>(handle);
        if (frame) {
            frame->size = size;
            frame->offset = 0;
            pcmQueue_.enqueue(frame);
        }
        return 0;
    }

    if (decoder_ == nullptr) return -1;

    OH_AVBuffer* buffer = static_cast<OH_AVBuffer*>(handle);

    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = flags;

    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    int32_t ret = OH_AudioCodec_PushInputBuffer(decoder_, index);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] SubmitInputBuffer failed: %{public}d", ret);
        return -1;
    }

    return 0;
}

int32_t AudioDecoderNative::PushData(uint8_t* data, int32_t size, int64_t pts) {
    if (!isStarted_) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushData: not started");
        return -1;
    }

    // RAW模式直接放入PCM队列
    if (isRaw_) {
        PcmFrame* frame = nullptr;
        if (!freePcmFrames_.try_dequeue(frame)) {
             frame = new PcmFrame();
        }

        size_t copySize = std::min(static_cast<size_t>(size), sizeof(frame->data));
        std::memcpy(frame->data.data(), data, copySize);
        frame->size = copySize;
        frame->offset = 0;
        
        pcmQueue_.enqueue(frame);
        return 0;
    }

    // 解码模式
    if (decoder_ == nullptr || context_ == nullptr) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushData: decoder not ready");
        return -1;
    }

    InputBufferInfo bufInfo;
    if (!context_->inputQueue.try_dequeue(bufInfo)) {
        return -2;
    }
    
    OH_AVBuffer* buffer = bufInfo.buffer;
    uint32_t bufferIndex = bufInfo.index;

    // 复制数据
    uint8_t* bufferAddr = OH_AVBuffer_GetAddr(buffer);
    int32_t bufferSize = OH_AVBuffer_GetCapacity(buffer);

    if (bufferSize < size) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushData: buffer too small (size=%{public}d, capacity=%{public}d), dropping frame", size, bufferSize);
        // 归还buffer，避免泄漏
        OH_AVCodecBufferAttr attr = {0, 0, 0, 0};
        OH_AVBuffer_SetBufferAttr(buffer, &attr);
        OH_AudioCodec_PushInputBuffer(decoder_, bufferIndex);
        return -1;
    }

    memcpy(bufferAddr, data, size);

    // 设置属性
    OH_AVCodecBufferAttr attr;
    attr.pts = pts;
    attr.size = size;
    attr.offset = 0;
    attr.flags = 0;

    OH_AVBuffer_SetBufferAttr(buffer, &attr);

    // 提交
    int32_t ret = OH_AudioCodec_PushInputBuffer(decoder_, bufferIndex);
    if (ret != AV_ERR_OK) {
        OH_LOG_ERROR(LOG_APP, "[AudioNative] PushInputBuffer failed: %{public}d", ret);
        return -1;
    }

    return 0;
}



int32_t AudioDecoderNative::Stop() {
    if (!isStarted_) {
        return 0;
    }

    isStarted_ = false;

    // 停止渲染器
    if (renderer_ != nullptr) {
        OH_AudioRenderer_Stop(renderer_);
    }

    // 停止解码器
    if (!isRaw_ && decoder_ != nullptr) {
        OH_AudioCodec_Stop(decoder_);
    }

    return 0;
}

int32_t AudioDecoderNative::Release() {
    if (decoder_ == nullptr && renderer_ == nullptr && context_ == nullptr) return 0;
    
    Stop();

    if (decoder_ != nullptr) {
        OH_AudioCodec_Destroy(decoder_);
        decoder_ = nullptr;
    }

    if (renderer_ != nullptr) {
        OH_AudioRenderer_Release(renderer_);
        renderer_ = nullptr;
    }

    if (builder_ != nullptr) {
        OH_AudioStreamBuilder_Destroy(builder_);
        builder_ = nullptr;
    }

    if (context_ != nullptr) {
        delete context_;
        context_ = nullptr;
    }

    // 清空buffer池
    PcmFrame* frame;
    while (pcmQueue_.try_dequeue(frame)) { delete frame; }
    while (freePcmFrames_.try_dequeue(frame)) { delete frame; }
    if (currentFrame_) {
        delete currentFrame_;
        currentFrame_ = nullptr;
    }

    return 0;
}

bool AudioDecoderNative::HasAvailableBuffer() const {
    if (context_ == nullptr) return false;
    return context_->inputQueue.size_approx() > 0;
}
