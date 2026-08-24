#include "ScrcpyStreamManager.h"

#include <cstring>
#include <hilog/log.h>
#include <stdexcept>
#include <string>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

namespace {
constexpr int32_t AUDIO_HANDSHAKE_TIMEOUT_MS = 10000;
}

int32_t ScrcpyStreamManager::createAudioDecoderLocked() {
    if (audioCodecType_.empty()) {
        return -1;
    }
    releaseAudioDecoderLocked();
    audioDecoder_ = new AudioDecoderNative();
    int32_t ret = audioDecoder_->Init(audioCodecType_.c_str(), config_.audioSampleRate,
                                      config_.audioChannelCount);
    if (ret == 0) {
        ret = audioDecoder_->Start();
    }
    if (ret != 0) {
        releaseAudioDecoderLocked();
        return ret;
    }
    audioDecoderGeneration_.fetch_add(1);
    return 0;
}

void ScrcpyStreamManager::releaseAudioDecoderLocked() {
    if (!audioDecoder_) {
        return;
    }
    audioDecoder_->Release();
    delete audioDecoder_;
    audioDecoder_ = nullptr;
}

void ScrcpyStreamManager::audioThreadFunc() {
    try {
        auto source = ::createByteStream(adb_, audioChannel_, audioStream_, "audio");
        if (!source) {
            throw std::runtime_error("audio source not found");
        }

        auto readToBuffer = [this, &source](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            readExactToBuffer(source.get(), dest, size, timeoutMs);
        };

        uint8_t codecBytes[4];
        readToBuffer(codecBytes, 4, AUDIO_HANDSHAKE_TIMEOUT_MS);
        int32_t codecId = readInt32BEValue(codecBytes);

        if (codecId == 0) {
            OH_LOG_INFO(LOG_APP, "[AudioThread] Audio disabled by server");
            emitEvent("audio_disabled", "");
            audioReaderDone_.store(true);
            audioPackets_.notifyAll();
            return;
        }
        if (codecId == 1) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Audio config error from server");
            audioReaderDone_.store(true);
            audioPackets_.notifyAll();
            return;
        }

        std::string codecName;
        switch (codecId) {
            case 0x6F707573: codecName = "opus"; break;
            case 0x00616163: codecName = "aac"; break;
            case 0x666C6163: codecName = "flac"; break;
            case 0x00726177: codecName = "raw"; break;
            default:
                OH_LOG_WARN(LOG_APP, "[AudioThread] Unknown codec 0x%{public}x, fallback to opus", codecId);
                codecName = "opus";
                break;
        }

        OH_LOG_INFO(LOG_APP, "[AudioThread] Using codec: %{public}s", codecName.c_str());
        audioCodecType_ = codecName;

        if (audioOutputEnabled_.load()) {
            int32_t decoderRet = 0;
            {
                std::lock_guard<std::mutex> lock(decoderMutex_);
                decoderRet = createAudioDecoderLocked();
            }
            if (decoderRet != 0) {
                OH_LOG_ERROR(LOG_APP, "[AudioThread] Decoder init failed: %{public}d", decoderRet);
                emitEvent("error", "Audio decoder init failed");
                audioReaderDone_.store(true);
                audioPackets_.notifyAll();
                return;
            }
        } else {
            OH_LOG_INFO(LOG_APP, "[AudioThread] Decoder init deferred while minimized");
        }

        audioDecodeThread_ = std::thread(&ScrcpyStreamManager::audioDecodeThreadFunc, this);

        uint8_t ptsBuf[8];
        uint8_t sizeBuf[4];
        while (running_.load()) {
            ScrcpyPacketMeta meta = readScrcpyPacketMeta(readToBuffer, ptsBuf, sizeBuf, 1024 * 1024,
                                                         "AudioThread");
            EncodedAudioPacket* packet = readScrcpyPacketPayload<EncodedAudioPacket>(
                readToBuffer, [this]() { return audioPackets_.acquireForWrite(); }, meta,
                "AudioThread", "packet");
            if (!packet) {
                continue;
            }
            applyPacketMeta(packet, meta);

            if (meta.isConfig) {
                audioPackets_.cacheConfig(packet->data.data(), packet->data.size(), packet->submitFlags);
                audioPackets_.recycle(packet);
                continue;
            }

            if (!audioOutputEnabled_.load()) {
                audioPackets_.recycle(packet);
                continue;
            }

            audioPackets_.enqueue(packet);
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[AudioThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Audio thread error: ") + e.what());
        }
    }

    audioReaderDone_.store(true);
    audioPackets_.notifyAll();
}

void ScrcpyStreamManager::audioDecodeThreadFunc() {
    uint64_t appliedConfigSerial = 0;
    uint64_t observedDecoderGeneration = 0;

    try {
        while (running_.load() || !audioReaderDone_.load()) {
            EncodedAudioPacket* packet = nullptr;
            if (!audioPackets_.waitDequeue(packet, running_, audioReaderDone_)) {
                if (audioReaderDone_.load() || !running_.load()) {
                    break;
                }
                continue;
            }

            if (!audioOutputEnabled_.load()) {
                audioPackets_.recycle(packet);
                continue;
            }

            std::unique_lock<std::mutex> decoderLock(decoderMutex_);
            if (!audioOutputEnabled_.load() || !audioDecoder_) {
                decoderLock.unlock();
                audioPackets_.recycle(packet);
                continue;
            }
            const uint64_t decoderGeneration = audioDecoderGeneration_.load();
            if (decoderGeneration != observedDecoderGeneration) {
                observedDecoderGeneration = decoderGeneration;
                appliedConfigSerial = 0;
            }

            std::vector<uint8_t> configData;
            uint32_t configFlags = 0;
            uint64_t nextConfigSerial = appliedConfigSerial;
            if (audioPackets_.copyPendingConfig(configData, configFlags, nextConfigSerial, appliedConfigSerial)) {
                uint32_t cfgIndex = 0;
                uint8_t* cfgData = nullptr;
                int32_t cfgCapacity = 0;
                void* cfgHandle = nullptr;
                while (running_.load()) {
                    int32_t ret = audioDecoder_->GetInputBuffer(&cfgIndex, &cfgData, &cfgCapacity, &cfgHandle, 10);
                    if (ret == 0) {
                        if (cfgCapacity >= static_cast<int32_t>(configData.size())) {
                            std::memcpy(cfgData, configData.data(), configData.size());
                            audioDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0,
                                                             static_cast<int32_t>(configData.size()), configFlags);
                            appliedConfigSerial = nextConfigSerial;
                        } else {
                            audioDecoder_->SubmitInputBuffer(cfgIndex, cfgHandle, 0, 0, 0);
                        }
                        break;
                    }
                    if (ret != -2) {
                        OH_LOG_ERROR(LOG_APP, "[AudioDecode] GetInputBuffer for config failed: %{public}d", ret);
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
                getBufRet = audioDecoder_->GetInputBuffer(&bufIndex, &bufData, &bufCapacity, &bufHandle, 10);
                if (getBufRet == 0 || getBufRet != -2) {
                    break;
                }
            }

            if (getBufRet != 0) {
                audioPackets_.recycle(packet);
                if (running_.load()) {
                    OH_LOG_ERROR(LOG_APP, "[AudioDecode] GetInputBuffer failed: %{public}d", getBufRet);
                    emitEvent("error", std::string("Audio decode input buffer failed: ") + std::to_string(getBufRet));
                }
                break;
            }

            if (bufCapacity < static_cast<int32_t>(packet->data.size())) {
                OH_LOG_ERROR(LOG_APP, "[AudioDecode] Buffer too small: %{public}d < %{public}zu",
                             bufCapacity, packet->data.size());
                audioDecoder_->SubmitInputBuffer(bufIndex, bufHandle, 0, 0, 0);
                audioPackets_.recycle(packet);
                continue;
            }

            std::memcpy(bufData, packet->data.data(), packet->data.size());
            int32_t submitRet = audioDecoder_->SubmitInputBuffer(
                bufIndex,
                bufHandle,
                packet->pts,
                static_cast<int32_t>(packet->data.size()),
                packet->submitFlags);
            audioPackets_.recycle(packet);
            if (submitRet != 0) {
                OH_LOG_WARN(LOG_APP, "[AudioDecode] Submit failed: %{public}d", submitRet);
            }
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[AudioDecode] Error: %{public}s", e.what());
            emitEvent("error", std::string("Audio decode thread error: ") + e.what());
        }
    }
}
