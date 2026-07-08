#ifndef SCRCPY_STREAM_IO_H
#define SCRCPY_STREAM_IO_H

#include "adb/core/Adb.h"
#include "adb/core/AdbChannel.h"
#include "stream/EncodedPacket.h"

#include "multimedia/player_framework/native_avbuffer_info.h"

#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

class IByteStream {
public:
    virtual ~IByteStream() = default;
    virtual void readExact(uint8_t* dest, size_t size, int32_t timeoutMs) = 0;
    virtual bool isClosed() const = 0;
    virtual const char* debugName() const = 0;
};

class IByteSink {
public:
    virtual ~IByteSink() = default;
    virtual void write(const uint8_t* data, size_t len) = 0;
    virtual bool isClosed() const = 0;
    virtual const char* debugName() const = 0;
};

struct ScrcpyPacketMeta {
    bool isConfig = false;
    bool isKeyFrame = false;
    int64_t pts = 0;
    uint32_t submitFlags = 0;
    int32_t frameSize = 0;
};

int32_t readInt32BEValue(const uint8_t* data);
int64_t readInt64BEValue(const uint8_t* data);
std::unique_ptr<IByteStream> createByteStream(Adb* adb, AdbChannel* channel, AdbStream* stream, const char* debugName);
std::unique_ptr<IByteSink> createByteSink(Adb* adb, AdbChannel* channel, AdbStream* stream, const char* debugName);
void applyPacketMeta(EncodedVideoPacket* packet, const ScrcpyPacketMeta& meta);
void applyPacketMeta(EncodedAudioPacket* packet, const ScrcpyPacketMeta& meta);

template <typename ReadFn>
ScrcpyPacketMeta readScrcpyPacketMeta(ReadFn&& readToBuffer,
                                      uint8_t* ptsBuf,
                                      uint8_t* sizeBuf,
                                      int32_t maxFrameSize,
                                      const char* threadTag) {
    readToBuffer(ptsBuf, 8);
    int64_t ptsRaw = readInt64BEValue(ptsBuf);

    readToBuffer(sizeBuf, 4);
    int32_t frameSize = readInt32BEValue(sizeBuf);
    if (frameSize <= 0 || frameSize > maxFrameSize) {
        throw std::runtime_error(std::string(threadTag) + " invalid frame size");
    }

    constexpr uint32_t packetFlagConfig = AVCODEC_BUFFER_FLAGS_CODEC_DATA;
    constexpr uint32_t packetFlagKeyFrame = AVCODEC_BUFFER_FLAGS_SYNC_FRAME;
    constexpr int64_t scrcpyPacketFlagConfig = 1LL << 63;
    constexpr int64_t scrcpyPacketFlagKeyFrame = 1LL << 62;
    constexpr int64_t scrcpyPacketPtsMask = scrcpyPacketFlagKeyFrame - 1;

    ScrcpyPacketMeta meta;
    meta.isConfig = (ptsRaw & scrcpyPacketFlagConfig) != 0;
    meta.isKeyFrame = (ptsRaw & scrcpyPacketFlagKeyFrame) != 0;
    meta.pts = ptsRaw & scrcpyPacketPtsMask;
    meta.submitFlags = (meta.isConfig ? packetFlagConfig : 0) |
                       (meta.isKeyFrame ? packetFlagKeyFrame : 0);
    meta.frameSize = frameSize;
    return meta;
}

template <typename PacketT, typename ReadFn, typename AcquireFn>
PacketT* readScrcpyPacketPayload(ReadFn&& readToBuffer,
                                 AcquireFn&& acquirePacket,
                                 const ScrcpyPacketMeta& meta,
                                 const char* threadTag,
                                 const char* dropLabel) {
    (void)threadTag;
    (void)dropLabel;
    PacketT* packet = acquirePacket();
    if (!packet) {
        constexpr size_t DROP_CHUNK_SIZE = 64 * 1024;
        std::vector<uint8_t> dropBuffer(std::min(static_cast<size_t>(meta.frameSize), DROP_CHUNK_SIZE));
        size_t remaining = static_cast<size_t>(meta.frameSize);
        while (remaining > 0) {
            size_t chunk = std::min(remaining, dropBuffer.size());
            readToBuffer(dropBuffer.data(), chunk);
            remaining -= chunk;
        }
        return nullptr;
    }

    packet->data.resize(static_cast<size_t>(meta.frameSize));
    readToBuffer(packet->data.data(), static_cast<size_t>(meta.frameSize));

    return packet;
}

#endif // SCRCPY_STREAM_IO_H
