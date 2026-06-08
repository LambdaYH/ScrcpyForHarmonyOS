// TcpChannel - 基于文件描述符的通道实现
// 参考 TcpChannel.ets 实现
// 不实现网络连接逻辑，fd由ArkTS传入
#include "adb/channel/TcpChannel.h"
#include <cerrno>
#include <cstring>
#include <unistd.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <netinet/tcp.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netdb.h> // for getaddrinfo
#include <poll.h>
#include <stdexcept>
#include <chrono>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "TcpChannel"

namespace {
void tuneTcpDisconnectDetection(int fd) {
    int keepAlive = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, reinterpret_cast<const char*>(&keepAlive),
                   sizeof(keepAlive)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set SO_KEEPALIVE on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }

#ifdef TCP_KEEPIDLE
    int keepIdleSeconds = 3;
    if (setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, reinterpret_cast<const char*>(&keepIdleSeconds),
                   sizeof(keepIdleSeconds)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_KEEPIDLE on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif

#ifdef TCP_KEEPINTVL
    int keepIntervalSeconds = 1;
    if (setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, reinterpret_cast<const char*>(&keepIntervalSeconds),
                   sizeof(keepIntervalSeconds)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_KEEPINTVL on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif

#ifdef TCP_KEEPCNT
    int keepCount = 3;
    if (setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, reinterpret_cast<const char*>(&keepCount),
                   sizeof(keepCount)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_KEEPCNT on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif

#ifdef TCP_USER_TIMEOUT
    int userTimeoutMs = 3000;
    if (setsockopt(fd, IPPROTO_TCP, TCP_USER_TIMEOUT, reinterpret_cast<const char*>(&userTimeoutMs),
                   sizeof(userTimeoutMs)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_USER_TIMEOUT on fd=%{public}d errno=%{public}d",
                    fd, errno);
    }
#endif
}

int pollRetryOnEintr(struct pollfd* pfd, nfds_t nfds, int timeoutMs) {
    if (timeoutMs < 0) {
        while (true) {
            int ret = poll(pfd, nfds, -1);
            if (ret < 0 && errno == EINTR) {
                continue;
            }
            return ret;
        }
    }

    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs);
    while (true) {
        auto now = std::chrono::steady_clock::now();
        if (now >= deadline) {
            return 0;
        }
        int remainingMs = static_cast<int>(
            std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count()
        );

        int ret = poll(pfd, nfds, remainingMs);
        if (ret < 0 && errno == EINTR) {
            continue;
        }
        return ret;
    }
}
}

TcpChannel::TcpChannel(int fd) : fd_(fd) {
    if (fd_ < 0) {
        throw std::invalid_argument("Invalid fd");
    }
    // ArkTS TCPSocket sets the fd to non-blocking mode for its event loop.
    // We need blocking I/O for synchronous read()/write(), so clear O_NONBLOCK.
    int flags = fcntl(fd_, F_GETFL, 0);
    if (flags >= 0) {
        fcntl(fd_, F_SETFL, flags & ~O_NONBLOCK);
        OH_LOG_INFO(LOG_APP, "TcpChannel: set fd=%{public}d to blocking mode (was flags=0x%{public}x)", fd_, flags);
    }
    int nodelay = 1;
    if (setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay),
                   sizeof(nodelay)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_NODELAY on fd=%{public}d errno=%{public}d",
                    fd_, errno);
    }
    tuneTcpDisconnectDetection(fd_);
    buffer_.resize(BUFFER_SIZE);
    OH_LOG_INFO(LOG_APP, "TcpChannel: created with fd=%{public}d", fd_);
}

TcpChannel::TcpChannel(const std::string& host, int port) {
    fd_ = -1;
    buffer_.resize(BUFFER_SIZE);

    struct addrinfo hints, *res, *p;
    std::memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC; // IPv4 or IPv6
    hints.ai_socktype = SOCK_STREAM;

    std::string portStr = std::to_string(port);
    
    OH_LOG_INFO(LOG_APP, "TcpChannel: Resolving %{public}s:%{public}s...", host.c_str(), portStr.c_str());

    int status = getaddrinfo(host.c_str(), portStr.c_str(), &hints, &res);
    if (status != 0) {
        throw std::runtime_error("getaddrinfo failed: " + std::string(gai_strerror(status)));
    }

    // Iterate through results and try to connect
    for (p = res; p != nullptr; p = p->ai_next) {
        fd_ = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd_ < 0) {
            continue;
        }

        // Set non-blocking
        int flags = fcntl(fd_, F_GETFL, 0);
        fcntl(fd_, F_SETFL, flags | O_NONBLOCK);

//        OH_LOG_INFO(LOG_APP, "TcpChannel: Connecting (non-blocking)...");
        int res = connect(fd_, p->ai_addr, p->ai_addrlen);
        
        if (res == 0) {
            // Success immediately
             fcntl(fd_, F_SETFL, flags); // Restore blocking
             break;
        } else if (res < 0 && errno == EINPROGRESS) {
            // Waiting for connection
            struct pollfd pfd;
            pfd.fd = fd_;
            pfd.events = POLLOUT;
            
            // Timeout: 30 seconds (30000 ms)
            int pollRes = pollRetryOnEintr(&pfd, 1, 30000);
            
            if (pollRes > 0) {
                if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                    OH_LOG_ERROR(LOG_APP, "TcpChannel: Connect poll error revents=0x%{public}x", pfd.revents);
                    ::close(fd_);
                    fd_ = -1;
                    continue;
                }
                int error = 0;
                socklen_t len = sizeof(error);
                if (getsockopt(fd_, SOL_SOCKET, SO_ERROR, &error, &len) < 0 || error != 0) {
                     // Connection failed
                     OH_LOG_ERROR(LOG_APP, "TcpChannel: Connect failed with error: %{public}d", error);
                     ::close(fd_);
                     fd_ = -1;
                     continue;
                }
                // Success
                OH_LOG_INFO(LOG_APP, "TcpChannel: Connected via poll");
                fcntl(fd_, F_SETFL, flags); // Restore blocking
                break;
            } else if (pollRes == 0) {
                 OH_LOG_ERROR(LOG_APP, "TcpChannel: Connect TIMEOUT (30s)");
                 ::close(fd_);
                 fd_ = -1;
                 continue; // Try next address?
            } else {
                 OH_LOG_ERROR(LOG_APP, "TcpChannel: Poll error errno=%{public}d", errno);
                 ::close(fd_);
                 fd_ = -1;
                 continue;
            }
        } else {
             // Immediate failure
             OH_LOG_ERROR(LOG_APP, "TcpChannel: Connect immediate fail: %{public}s", strerror(errno));
             ::close(fd_);
             fd_ = -1;
             continue;
        }

        ::close(fd_);
        fd_ = -1;
    }

    freeaddrinfo(res);

    if (fd_ < 0) {
        throw std::runtime_error("Failed to connect to " + host + ":" + portStr);
    }

    int nodelay = 1;
    if (setsockopt(fd_, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&nodelay),
                   sizeof(nodelay)) != 0) {
        OH_LOG_WARN(LOG_APP, "TcpChannel: failed to set TCP_NODELAY on fd=%{public}d errno=%{public}d",
                    fd_, errno);
    }
    tuneTcpDisconnectDetection(fd_);

    OH_LOG_INFO(LOG_APP, "TcpChannel: connected fd=%{public}d", fd_);
}

TcpChannel::~TcpChannel() {
    close();
}

void TcpChannel::write(const uint8_t* data, size_t len) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: write on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        // Use send with MSG_NOSIGNAL to avoid SIGPIPE if the socket is closed by peer
        ssize_t n = ::send(fd_, data + offset, len - offset, MSG_NOSIGNAL);
        if (n <= 0) {
            // If error is EPIPE, it means connection closed, handled as runtime_error
            throw std::runtime_error("TcpChannel: write failed (broken pipe or closed)");
        }
        offset += static_cast<size_t>(n);
    }
}

void TcpChannel::read(uint8_t* buf, size_t len) {
    readWithTimeout(buf, len, -1);
}

void TcpChannel::readWithTimeout(uint8_t* buf, size_t len, int timeoutMs) {
    if (closed_.load()) {
        throw std::runtime_error("TcpChannel: read on closed channel");
    }

    size_t offset = 0;
    while (offset < len) {
        // 1. Try reading from buffer
        size_t available = bufferTail_ - bufferHead_;
        if (available > 0) {
            size_t toCopy = std::min(available, len - offset);
            std::memcpy(buf + offset, buffer_.data() + bufferHead_, toCopy);
            bufferHead_ += toCopy;
            offset += toCopy;
            if (offset == len) break;
        }

        // 2. Buffer empty. Needs more data.
        size_t needed = len - offset;
        
        // Optimization: if needed size >= BUFFER_SIZE, read directly to user buffer
        if (needed >= BUFFER_SIZE) {
             if (timeoutMs >= 0) {
                 struct pollfd pfd;
                 pfd.fd = fd_;
                 pfd.events = POLLIN;
                 int ret = pollRetryOnEintr(&pfd, 1, timeoutMs);
                 if (ret <= 0) {
                     if (ret == 0) throw std::runtime_error("TcpChannel: read timeout");
                     OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed errno=%{public}d", errno);
                     throw std::runtime_error("TcpChannel: poll failed");
                 }
                 if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
                     OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed revents=0x%{public}x", pfd.revents);
                     throw std::runtime_error("TcpChannel: poll failed");
                 }
             }
             ssize_t n = ::read(fd_, buf + offset, needed);
             if (n <= 0) {
                 OH_LOG_ERROR(LOG_APP, "TcpChannel: read failed n=%{public}zd errno=%{public}d", n, errno);
                 throw std::runtime_error("TcpChannel: read failed or connection closed");
             }
             offset += static_cast<size_t>(n);
        } else {
             // Fill buffer
             fillBuffer(timeoutMs);
        }
    }
}

void TcpChannel::fillBuffer(int timeoutMs) {
    bufferHead_ = 0;
    bufferTail_ = 0;
    
    if (timeoutMs >= 0) {
         struct pollfd pfd;
         pfd.fd = fd_;
         pfd.events = POLLIN;
         int ret = pollRetryOnEintr(&pfd, 1, timeoutMs);
         if (ret <= 0) {
             if (ret == 0) throw std::runtime_error("TcpChannel: read timeout");
             OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed errno=%{public}d", errno);
             throw std::runtime_error("TcpChannel: poll failed");
         }
         if ((pfd.revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
             OH_LOG_ERROR(LOG_APP, "TcpChannel: poll failed revents=0x%{public}x", pfd.revents);
             throw std::runtime_error("TcpChannel: poll failed");
         }
    }
    
    ssize_t n = ::read(fd_, buffer_.data(), BUFFER_SIZE);
    if (n <= 0) {
        OH_LOG_ERROR(LOG_APP, "TcpChannel: fillBuffer failed n=%{public}zd errno=%{public}d", n, errno);
        throw std::runtime_error("TcpChannel: read failed or connection closed");
    }
    bufferTail_ = static_cast<size_t>(n);
}

void TcpChannel::close() {
    bool expected = false;
    if (closed_.compare_exchange_strong(expected, true)) {
        OH_LOG_INFO(LOG_APP, "TcpChannel: closing fd=%{public}d", fd_);
        if (fd_ >= 0) {
            // Shutdown both read and write to force unblock any pending read/write operations
            ::shutdown(fd_, SHUT_RDWR);
            ::close(fd_);
            fd_ = -1;
        }
    }
}

bool TcpChannel::isClosed() const {
    return closed_.load();
}

int TcpChannel::releaseFd() {
    int fd = fd_;
    fd_ = -1;
    closed_.store(true);
    bufferHead_ = 0;
    bufferTail_ = 0;
    return fd;
}
