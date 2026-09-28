#include "stream/adapters/ReverseStreamAdapter.h"

#include <stdexcept>

namespace {
class ReverseByteStreamAdapter final : public IByteStream {
public:
    ReverseByteStreamAdapter(AdbChannel* channel, const char* debugName) : channel_(channel), debugName_(debugName) {}

    void readExact(uint8_t* dest, size_t size, int32_t timeoutMs) override {
        if (!channel_) {
            throw std::runtime_error("byte stream channel unavailable");
        }
        channel_->readWithTimeout(dest, size, timeoutMs);
    }

    bool isClosed() const override {
        return channel_ == nullptr || channel_->isClosed();
    }

    const char* debugName() const override {
        return debugName_;
    }

private:
    AdbChannel* channel_;
    const char* debugName_;
};

class ReverseByteSinkAdapter final : public IByteSink {
public:
    ReverseByteSinkAdapter(AdbChannel* channel, const char* debugName) : channel_(channel), debugName_(debugName) {}

    void write(const uint8_t* data, size_t len) override {
        if (!channel_) {
            throw std::runtime_error("byte sink channel unavailable");
        }
        channel_->write(data, len);
    }

    bool isClosed() const override {
        return channel_ == nullptr || channel_->isClosed();
    }

    const char* debugName() const override {
        return debugName_;
    }

private:
    AdbChannel* channel_;
    const char* debugName_;
};
}

namespace reverse_stream {

std::unique_ptr<IByteStream> makeByteStream(AdbChannel* channel, const char* debugName) {
    if (!channel) {
        return std::unique_ptr<IByteStream>();
    }
    return std::make_unique<ReverseByteStreamAdapter>(channel, debugName);
}

std::unique_ptr<IByteSink> makeByteSink(AdbChannel* channel, const char* debugName) {
    if (!channel) {
        return std::unique_ptr<IByteSink>();
    }
    return std::make_unique<ReverseByteSinkAdapter>(channel, debugName);
}

}
