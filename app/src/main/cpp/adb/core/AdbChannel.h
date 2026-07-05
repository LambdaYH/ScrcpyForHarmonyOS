// AdbChannel - ADB通道接口
#ifndef ADB_CHANNEL_H
#define ADB_CHANNEL_H

#include <cstdint>
#include <cstddef>

// ADB通道抽象接口
class AdbChannel {
public:
    virtual ~AdbChannel() = default;

    // 写入数据
    virtual void write(const uint8_t* data, size_t len) = 0;

    // 精确读取指定字节数（阻塞直到读满）
    virtual void read(uint8_t* buf, size_t len) = 0;

    // 精确读取指定字节数，带超时（阻塞直到读满或超时）
    virtual void readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) = 0;

    // 刷新（TCP无需实现）
    virtual void flush() {}

    // 关闭通道
    virtual void close() = 0;

    // 是否已关闭
    virtual bool isClosed() const = 0;
};

#endif // ADB_CHANNEL_H
