// TcpChannel - 基于文件描述符的通道实现
// 不实现网络连接逻辑，fd由ArkTS传入
#ifndef TCP_CHANNEL_H
#define TCP_CHANNEL_H

#include "adb/core/AdbChannel.h"
#include <atomic>
#include <mutex>

class TcpChannel : public AdbChannel {
public:
    // 构造函数接受ArkTS传入的文件描述符
    explicit TcpChannel(int fd);
    // 构造函数:直接连接指定IP和端口
    TcpChannel(const std::string& ip, int port);
    ~TcpChannel() override;

    void read(uint8_t* buf, size_t len) override;
    void readWithTimeout(uint8_t* buf, size_t len, int timeoutMs = -1) override;
    void write(const uint8_t* data, size_t len) override;
    void close() override;
    bool isClosed() const override;
    int releaseFd();

private:
    int fd_;
    std::atomic<bool> closed_{false};

    // Buffered I/O
    static const size_t BUFFER_SIZE = 65536; // 64KB
    std::vector<uint8_t> buffer_;
    size_t bufferHead_ = 0;
    size_t bufferTail_ = 0;
    
    // Internal helper
    ssize_t readFromBuffer(uint8_t* buf, size_t len);
    void fillBuffer(int timeoutMs);
};

#endif // TCP_CHANNEL_H
