// Adb - 完整的ADB实现
// 参考 Adb.ets 实现
// 核心ADB协议处理类，使用fd进行I/O
#ifndef ADB_H
#define ADB_H

#include "adb/core/AdbChannel.h"
#include "adb/core/AdbProtocol.h"
#include "adb/crypto/AdbKeyPair.h"
#include "adb/util/RingBuffer.h"

#include <cstdint>
#include <string>
#include <vector>
#include <map>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <thread>
#include <atomic>
#include <functional>
#include <queue> 
#include <deque>
#include "concurrentqueue/blockingconcurrentqueue.h"

// 进度回调函数类型
    // 进度回调函数类型
    using ProcessCallback = std::function<void(int progress)>;
    using AuthCallback = std::function<void()>;

// 内部流数据结构 (替代ArkTS的BufferStream)
struct AdbStream {
    int32_t localId = 0;
    int32_t remoteId = 0;
    bool canMultipleSend = false;
    std::string streamKind = "other";
    std::atomic<bool> closed{false};
    std::atomic<bool> canWrite{false};
    std::mutex writeMutex;
    std::vector<uint8_t> pendingWriteBuffer;
    size_t pendingWriteOffset = 0;

    // 读缓冲区 - 使用 RingBuffer 实现零拷贝。
    // 容量按流类型区分：
    // video=64 MiB, audio=16 MiB, other=10 MiB
    RingBuffer readBuffer;
    
    explicit AdbStream(size_t readBufferCapacity, std::string kind = "other")
        : streamKind(std::move(kind)), readBuffer(readBufferCapacity) {}
};

struct AdbShellCommandResult {
    int32_t exitCode = 0;
    bool exitCodeReliable = false;
    std::string stdoutText;
    std::string stderrText;
};

struct RemoteFileEntry {
    std::string name;
    std::string path;
    uint32_t mode = 0;
    uint64_t size = 0;
    uint64_t mtime = 0;
    bool isDirectory = false;
    bool isRegularFile = false;
};

// ADB主类 - 完全参考Adb.ets
class Adb {
public:
    ~Adb();

    // 通过fd创建并连接ADB实例
    // fd由ArkTS传入，不在C++中创建网络连接
    static Adb* create(int fd);

    // 通过IP和端口创建并连接ADB实例 (C++直接创建Socket)
    static Adb* create(const std::string& ip, int port);    // ADB认证连接
    // 如果需要认证，needAuth会被设置为true，此时需要ArkTS弹出授权对话框
    // 返回值: 0=成功, 1=需要用户授权(已发送公钥), -1=失败
    int connect(AdbKeyPair& keyPair, AuthCallback onWaitAuth = nullptr);

    // 执行ADB命令
    std::string runAdbCmd(const std::string& cmd);

    // 执行 shell 命令并返回结构化结果
    AdbShellCommandResult execShellCommand(const std::string& cmd);

    // 推送文件
    void pushFile(const uint8_t* fileData, size_t fileLen,
                  const std::string& remotePath, ProcessCallback callback = nullptr);
    void pushFileFromFd(int fd, uint64_t fileLen,
                        const std::string& remotePath, ProcessCallback callback = nullptr);
    std::vector<RemoteFileEntry> listDirectory(const std::string& remotePath);
    uint64_t pullFileToFd(int fd, const std::string& remotePath, ProcessCallback callback = nullptr);
    int32_t startPushFile(const std::string& remotePath);
    void writePushFileChunk(int32_t streamId, const uint8_t* chunkData, size_t chunkLen);
    void finishPushFile(int32_t streamId);
    void abortPushFile(int32_t streamId);

    // 执行非 shell 的 ADB service 命令
    std::string runServiceCommand(const std::string& destination);

    // 切换到TCP模式
    std::string restartOnTcpip(int port);

    // 配置 adb reverse
    bool reverseForward(const std::string& remote, const std::string& local);
    bool reverseRemove(const std::string& remote);

    // TCP端口转发 - 返回stream id
    int32_t tcpForward(int port);

    // 本地Socket转发 - 返回stream id
    int32_t localSocketForward(const std::string& socketName, const std::string& streamKind = "other");

    // 获取Shell流 - 返回stream id
    int32_t getShell();

    // 从流中读取数据
    // timeoutMs: 超时时间(毫秒), <=0 表示无限等待
    std::vector<uint8_t> streamRead(int32_t streamId, size_t size, int32_t timeoutMs = -1, bool exact = true);

    // 从流中读取数据到指定缓冲区 (Zero-Copy)
    // dest: 目标缓冲区指针
    // destSize: 目标缓冲区大小
    // 返回实际读取的字节数
    size_t streamReadToBuffer(int32_t streamId, uint8_t* dest, size_t destSize, int32_t timeoutMs = -1, bool exact = true);

    // 向流中写入数据
    void streamWrite(int32_t streamId, const uint8_t* data, size_t len);
    void streamWrite(AdbStream* stream, const uint8_t* data, size_t len);

    // 关闭流
    void streamClose(int32_t streamId);

    // 流是否已关闭
    bool isStreamClosed(int32_t streamId);

    // 读取流关闭前的全部数据
    std::vector<uint8_t> streamReadAllBeforeClose(int32_t streamId);

    // 获取流句柄（用于高频读写路径，避免重复查表）
    AdbStream* getStreamHandle(int32_t streamId);

    // 从流句柄读取数据到指定缓冲区
    size_t streamReadToBuffer(AdbStream* stream, uint8_t* dest, size_t destSize, int32_t timeoutMs = -1, bool exact = true);

    // 关闭ADB连接
    void close();

    // 是否已关闭
    bool isAdbClosed() const { return isClosed_.load(); }

    // 获取最大数据大小
    uint32_t getMaxData() const { return maxData_; }

    std::string getLastConnectError() const;
    void prepareIncomingStreamKinds(const std::vector<std::string>& streamKinds);

private:
    Adb(AdbChannel* channel);
    void setLastConnectError(std::string error);
    void clearLastConnectError();

    struct ReverseBridge {
        int fd = -1;
        AdbStream* stream = nullptr;
        std::thread socketToAdbThread;
        std::thread adbToSocketThread;
        std::atomic<bool> closed{false};
    };

    // 后台消息处理线程
    void handleInLoop();

    // 打开一个流
    int32_t open(const std::string& destination, bool canMultipleSend,
                 bool allowImmediateClose = false, const std::string& streamKind = "other");

    // 通知机制
    void notifyAll();

    // 写入channel
    void writeToChannel(const std::vector<uint8_t>& data);
    void writeToChannel(std::vector<uint8_t>&& data);

    // 创建新的流
    AdbStream* createNewStream(int32_t localId, int32_t remoteId, bool canMultipleSend,
                               const std::string& streamKind = "other");

    bool handleIncomingOpen(uint32_t remoteId, const std::vector<uint8_t>& payload);
    int connectLocalTcpPort(uint16_t port);
    void startReverseBridge(AdbStream* stream, int fd);
    static std::string stripTrailingNulls(const std::vector<uint8_t>& payload);
    static std::string normalizeStreamKind(const std::string& streamKind);
    static size_t getReadBufferCapacityForKind(const std::string& streamKind);

    // 向流的底层channel写入数据（分块）
    void compactPendingWritesLocked(AdbStream* stream);
    size_t pendingWriteBytesLocked(const AdbStream* stream) const;
    void flushPendingWritesLocked(AdbStream* stream);
    void streamWriteRaw(AdbStream* stream, const uint8_t* data, size_t len);

    AdbChannel* channel_ = nullptr;
    std::atomic<bool> isClosed_{false};
    std::atomic<bool> handleInRunning_{false};
    std::atomic<int32_t> localIdPool_{1};
    uint32_t maxData_ = AdbProtocol::CONNECT_MAXDATA;

    // 流管理
    std::mutex streamsMutex_;
    std::unordered_map<int32_t, AdbStream*> connectionStreams_;
    std::unordered_map<int32_t, AdbStream*> openStreams_; // Owner of AdbStream*
    std::unordered_map<int32_t, std::string> pendingOpenStreamKinds_;
    std::deque<std::string> pendingIncomingStreamKinds_;

    // 后台处理线程
    std::thread handleInThread_;
    
    // Asynchronous Send
    std::thread sendThread_;
    std::atomic<bool> sendRunning_{false};
    moodycamel::BlockingConcurrentQueue<std::vector<uint8_t>> sendQueue_;

    // 等待通知
    std::mutex waitMutex_;
    std::condition_variable waitCv_;

    // Optimization cache for handleInLoop
    AdbStream* lastStream_ = nullptr;

    std::mutex reverseBridgesMutex_;
    std::vector<std::shared_ptr<ReverseBridge>> reverseBridges_;

    mutable std::mutex lastConnectErrorMutex_;
    std::string lastConnectError_;

    // channel写入锁 (由sendLoop管理)
    // std::mutex channelWriteMutex_; // Removed, managed by sendLoop

    void sendLoop();
};

#endif // ADB_H
