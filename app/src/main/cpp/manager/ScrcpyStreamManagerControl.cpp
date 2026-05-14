#include "ScrcpyStreamManager.h"

#include <chrono>
#include <hilog/log.h>
#include <iomanip>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#undef LOG_TAG
#undef LOG_DOMAIN
#define LOG_TAG "StreamManager"
#define LOG_DOMAIN 0x3200

namespace {
constexpr size_t CONTROL_MSG_QUEUE_MAX = 128;
}

bool ScrcpyStreamManager::sendControl(const uint8_t* data, size_t len) {
    if (!running_.load() || len == 0) {
        return false;
    }

    if (controlReliableQueue_.size_approx() >= CONTROL_MSG_QUEUE_MAX) {
        return false;
    }

    controlReliableQueue_.enqueue(std::vector<uint8_t>(data, data + len));
    return true;
}

void ScrcpyStreamManager::controlSendThreadFunc() {
    auto sink = ::createByteSink(adb_, controlChannel_, controlStream_, "control");
    if (!sink) {
        OH_LOG_WARN(LOG_APP, "[ControlSend] No sink available, thread exits");
        return;
    }

    while (true) {
        std::vector<uint8_t> packet;
        if (!controlReliableQueue_.wait_dequeue_timed(packet, std::chrono::milliseconds(1))) {
            if (!running_.load()) {
                break;
            }
            continue;
        }

        try {
            if (sink->isClosed()) {
                if (!running_.load()) {
                    break;
                }
                throw std::runtime_error("control sink closed");
            }
            sink->write(packet.data(), packet.size());
        } catch (const std::exception& e) {
            if (!running_.load()) {
                break;
            }
            OH_LOG_ERROR(LOG_APP, "[StreamManager] control send error: %{public}s", e.what());
        }
    }
}

void ScrcpyStreamManager::controlThreadFunc() {
    try {
        auto source = ::createByteStream(adb_, controlChannel_, controlStream_, "control");
        if (!source) {
            throw std::runtime_error("control source not found");
        }

        auto readToBuffer = [this, &source](uint8_t* dest, size_t size, int32_t timeoutMs = -1) {
            readExactToBuffer(source.get(), dest, size, timeoutMs);
        };

        auto readBytes = [this, &source](size_t size, int32_t timeoutMs = -1) {
            return readExact(source.get(), size, timeoutMs);
        };

        uint8_t typeByte[1];
        uint8_t lenData[4];
        uint8_t ackData[8];
        uint8_t uhidHeader[4];
        while (running_.load()) {
            readToBuffer(typeByte, 1);
            const uint8_t eventType = typeByte[0];

            if (!running_.load()) {
                break;
            }

            switch (eventType) {
                case 0: {
                    readToBuffer(lenData, 4);
                    int32_t clipLen = readInt32BEValue(lenData);
                    if (clipLen > 0 && clipLen <= 100000) {
                        auto clipTextData = readBytes(static_cast<size_t>(clipLen));
                        std::string text(reinterpret_cast<char*>(clipTextData.data()), clipTextData.size());
                        OH_LOG_DEBUG(LOG_APP, "[ControlThread] Clipboard received: %{public}zu bytes", text.size());
                        emitEvent("clipboard", text);
                    }
                    break;
                }
                case 1: {
                    readToBuffer(ackData, sizeof(ackData));
                    break;
                }
                case 2: {
                    readToBuffer(uhidHeader, sizeof(uhidHeader));
                    int32_t id = (static_cast<int32_t>(uhidHeader[0]) << 8) |
                                 static_cast<int32_t>(uhidHeader[1]);
                    int32_t size = (static_cast<int32_t>(uhidHeader[2]) << 8) |
                                   static_cast<int32_t>(uhidHeader[3]);
                    if (size > 0) {
                        auto data = readBytes(static_cast<size_t>(size));
                        std::ostringstream oss;
                        oss << "{\"id\":" << id << ",\"data\":\"";
                        oss << std::hex << std::setfill('0');
                        for (uint8_t byte : data) {
                            oss << std::setw(2) << static_cast<int>(byte);
                        }
                        oss << "\"}";
                        emitEvent("uhid_output", oss.str());
                    }
                    break;
                }
                default:
                    OH_LOG_DEBUG(LOG_APP, "[ControlThread] Unknown event type: %{public}d", eventType);
                    break;
            }
        }
    } catch (const std::exception& e) {
        if (running_.load()) {
            OH_LOG_ERROR(LOG_APP, "[ControlThread] Error: %{public}s", e.what());
            emitEvent("error", std::string("Control thread error: ") + e.what());
        }
    }
}
