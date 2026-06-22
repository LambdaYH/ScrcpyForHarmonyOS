// Adb
#include "adb/core/Adb.h"
#include "adb/channel/TcpChannel.h"
#include "adb/channel/TlsAdbChannel.h"
#include "adb/pairing/TlsConnection.h"
#include <cstring>
#include <stdexcept>
#include <algorithm>
#include <utility>
#include <cerrno>
#include <cinttypes>
#include <chrono>
#include <functional>
#include <memory>
#include <netdb.h>
#include <netinet/tcp.h>
#include <thread>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>
#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "Adb"

namespace {
constexpr size_t MAX_PENDING_WRITE_BYTES = 256 * 1024;
constexpr size_t CONTROL_STALE_MOVE_COMPACT_THRESHOLD_BYTES = 512;
constexpr uint8_t CONTROL_MSG_TYPE_TOUCH_EVENT = 2;
constexpr size_t CONTROL_TOUCH_PACKET_SIZE = 32;
constexpr size_t CONTROL_TOUCH_ACTION_OFFSET = 1;
constexpr size_t CONTROL_TOUCH_POINTER_ID_OFFSET = 2;
constexpr uint8_t CONTROL_TOUCH_ACTION_MOVE = 2;
constexpr uint8_t CONTROL_TOUCH_ACTION_CANCEL = 3;
constexpr int kCertLifetimeSeconds = 10 * 365 * 24 * 60 * 60;
const char kBasicConstraints[] = "critical,CA:TRUE";
const char kKeyUsage[] = "critical,keyCertSign,cRLSign,digitalSignature";
const char kSubjectKeyIdentifier[] = "hash";

uint32_t readU32LE(const uint8_t* data) {
    return static_cast<uint32_t>(data[0])
         | (static_cast<uint32_t>(data[1]) << 8)
         | (static_cast<uint32_t>(data[2]) << 16)
         | (static_cast<uint32_t>(data[3]) << 24);
}

int32_t readInt32BE(const uint8_t* data) {
    return (static_cast<int32_t>(data[0]) << 24) |
           (static_cast<int32_t>(data[1]) << 16) |
           (static_cast<int32_t>(data[2]) << 8) |
           static_cast<int32_t>(data[3]);
}

int64_t readInt64BE(const uint8_t* data) {
    return (static_cast<int64_t>(data[0]) << 56) |
           (static_cast<int64_t>(data[1]) << 48) |
           (static_cast<int64_t>(data[2]) << 40) |
           (static_cast<int64_t>(data[3]) << 32) |
           (static_cast<int64_t>(data[4]) << 24) |
           (static_cast<int64_t>(data[5]) << 16) |
           (static_cast<int64_t>(data[6]) << 8) |
           static_cast<int64_t>(data[7]);
}

struct TouchPacketTrace {
    bool isTouch = false;
    uint8_t action = 0;
    int64_t pointerId = 0;
    int32_t x = 0;
    int32_t y = 0;
};

bool isSupportedControlTouchAction(uint8_t action) {
    return action <= CONTROL_TOUCH_ACTION_CANCEL;
}

TouchPacketTrace parseControlTouchPayload(const uint8_t* data, size_t len) {
    TouchPacketTrace trace;
    if (!data || len != CONTROL_TOUCH_PACKET_SIZE || data[0] != CONTROL_MSG_TYPE_TOUCH_EVENT) {
        return trace;
    }

    trace.action = data[CONTROL_TOUCH_ACTION_OFFSET];
    if (!isSupportedControlTouchAction(trace.action)) {
        return trace;
    }

    trace.pointerId = readInt64BE(data + CONTROL_TOUCH_POINTER_ID_OFFSET);
    if (trace.pointerId < 0) {
        return trace;
    }

    trace.isTouch = true;
    trace.x = readInt32BE(data + 10);
    trace.y = readInt32BE(data + 14);
    return trace;
}

struct DeferredControlMove {
    int64_t pointerId = 0;
    std::vector<uint8_t> packet;
};

void rememberDeferredMove(std::vector<DeferredControlMove>& moves,
                          const uint8_t* packet,
                          const TouchPacketTrace& trace) {
    for (auto& move : moves) {
        if (move.pointerId == trace.pointerId) {
            move.packet.assign(packet, packet + CONTROL_TOUCH_PACKET_SIZE);
            return;
        }
    }

    DeferredControlMove move;
    move.pointerId = trace.pointerId;
    move.packet.assign(packet, packet + CONTROL_TOUCH_PACKET_SIZE);
    moves.push_back(std::move(move));
}

void appendDeferredMoves(std::vector<uint8_t>& output,
                         std::vector<DeferredControlMove>& moves,
                         bool excludePointer,
                         int64_t excludedPointerId) {
    for (const auto& move : moves) {
        if (excludePointer && move.pointerId == excludedPointerId) {
            continue;
        }
        output.insert(output.end(), move.packet.begin(), move.packet.end());
    }
    moves.clear();
}

void compactControlPendingMovesForCurrentMove(AdbStream* stream, const TouchPacketTrace& currentTrace) {
    if (!stream || !currentTrace.isTouch || currentTrace.action != CONTROL_TOUCH_ACTION_MOVE) {
        return;
    }

    if (stream->pendingWriteOffset > 0) {
        stream->pendingWriteBuffer.erase(stream->pendingWriteBuffer.begin(),
                                         stream->pendingWriteBuffer.begin() + stream->pendingWriteOffset);
        stream->pendingWriteOffset = 0;
    }

    const size_t pendingBytes = stream->pendingWriteBuffer.size();
    if (pendingBytes < CONTROL_STALE_MOVE_COMPACT_THRESHOLD_BYTES ||
        pendingBytes % CONTROL_TOUCH_PACKET_SIZE != 0) {
        return;
    }

    std::vector<uint8_t> compacted;
    compacted.reserve(pendingBytes);
    std::vector<DeferredControlMove> deferredMoves;

    for (size_t offset = 0; offset < pendingBytes; offset += CONTROL_TOUCH_PACKET_SIZE) {
        const uint8_t* packet = stream->pendingWriteBuffer.data() + offset;
        TouchPacketTrace trace = parseControlTouchPayload(packet, CONTROL_TOUCH_PACKET_SIZE);
        if (trace.isTouch && trace.action == CONTROL_TOUCH_ACTION_MOVE) {
            rememberDeferredMove(deferredMoves, packet, trace);
            continue;
        }

        appendDeferredMoves(compacted, deferredMoves, false, 0);
        compacted.insert(compacted.end(), packet, packet + CONTROL_TOUCH_PACKET_SIZE);
    }

    appendDeferredMoves(compacted, deferredMoves, true, currentTrace.pointerId);

    if (compacted.size() >= pendingBytes) {
        return;
    }

    stream->pendingWriteBuffer.swap(compacted);
    stream->pendingWriteOffset = 0;
}

std::string shellSingleQuote(const std::string& text) {
    std::string escaped;
    escaped.reserve(text.size() + 8);
    escaped.push_back('\'');
    for (char ch : text) {
        if (ch == '\'') {
            escaped += "'\\''";
        } else {
            escaped.push_back(ch);
        }
    }
    escaped.push_back('\'');
    return escaped;
}

std::string trimTrailingNewlines(std::string text) {
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) {
        text.pop_back();
    }
    return text;
}

enum class ShellProtocolId : uint8_t {
    Stdin = 0,
    Stdout = 1,
    Stderr = 2,
    Exit = 3,
    CloseStdin = 4,
    WindowSizeChange = 5,
};

AdbShellCommandResult parseShellProtocolPayload(const std::vector<uint8_t>& raw) {
    AdbShellCommandResult result;
    size_t offset = 0;

    while (offset < raw.size()) {
        if (raw.size() - offset < 5) {
            throw std::runtime_error("shell protocol parse failed: incomplete packet header");
        }

        const uint8_t id = raw[offset];
        const uint32_t payloadLength = readU32LE(raw.data() + offset + 1);
        offset += 5;

        if (raw.size() - offset < payloadLength) {
            throw std::runtime_error("shell protocol parse failed: truncated packet payload");
        }

        const char* payload = reinterpret_cast<const char*>(raw.data() + offset);
        switch (static_cast<ShellProtocolId>(id)) {
            case ShellProtocolId::Stdout:
                result.stdoutText.append(payload, payloadLength);
                break;
            case ShellProtocolId::Stderr:
                result.stderrText.append(payload, payloadLength);
                break;
            case ShellProtocolId::Exit:
                if (payloadLength < 1) {
                    throw std::runtime_error("shell protocol parse failed: missing exit code payload");
                }
                result.exitCode = static_cast<uint8_t>(raw[offset]);
                result.exitCodeReliable = true;
                break;
            case ShellProtocolId::Stdin:
            case ShellProtocolId::CloseStdin:
            case ShellProtocolId::WindowSizeChange:
                break;
            default:
                throw std::runtime_error("shell protocol parse failed: unknown packet id " + std::to_string(id));
        }

        offset += payloadLength;
    }

    result.stdoutText = trimTrailingNewlines(result.stdoutText);
    result.stderrText = trimTrailingNewlines(result.stderrText);
    return result;
}

AdbShellCommandResult parseLegacyShellPayload(const std::string& raw,
                                             const std::string& rcMarker,
                                             const std::string& stdoutMarker,
                                             const std::string& stderrMarker) {
    AdbShellCommandResult result;

    const size_t rcPos = raw.find(rcMarker);
    const size_t stdoutPos = raw.find(stdoutMarker);
    const size_t stderrPos = raw.find(stderrMarker);
    if (rcPos == std::string::npos || stdoutPos == std::string::npos || stderrPos == std::string::npos ||
        !(rcPos <= stdoutPos && stdoutPos <= stderrPos)) {
        throw std::runtime_error("legacy shell parse failed: markers missing");
    }

    const size_t rcValueStart = rcPos + rcMarker.size();
    const size_t rcValueEnd = raw.find('\n', rcValueStart);
    std::string rcText = rcValueEnd == std::string::npos
        ? raw.substr(rcValueStart)
        : raw.substr(rcValueStart, rcValueEnd - rcValueStart);
    rcText = trimTrailingNewlines(rcText);

    try {
        result.exitCode = std::stoi(rcText);
        result.exitCodeReliable = true;
    } catch (...) {
        throw std::runtime_error("legacy shell parse failed: invalid exit code");
    }

    const size_t stdoutDataStart = stdoutPos + stdoutMarker.size();
    const size_t stdoutContentStart = (stdoutDataStart < raw.size() && raw[stdoutDataStart] == '\n')
        ? stdoutDataStart + 1
        : stdoutDataStart;
    size_t stdoutContentEnd = stderrPos;
    if (stdoutContentEnd > stdoutContentStart && raw[stdoutContentEnd - 1] == '\n') {
        --stdoutContentEnd;
    }
    result.stdoutText = raw.substr(stdoutContentStart, stdoutContentEnd - stdoutContentStart);

    const size_t stderrDataStart = stderrPos + stderrMarker.size();
    const size_t stderrContentStart = (stderrDataStart < raw.size() && raw[stderrDataStart] == '\n')
        ? stderrDataStart + 1
        : stderrDataStart;
    result.stderrText = trimTrailingNewlines(raw.substr(stderrContentStart));

    return result;
}

AdbShellCommandResult execShellCommandLegacy(Adb* adb, const std::string& cmd) {
    const auto now = std::chrono::steady_clock::now().time_since_epoch().count();
    const std::string rcMarker = "__SCRCPY_SHELL_RC_" + std::to_string(now) + "__";
    const std::string stdoutMarker = "__SCRCPY_SHELL_STDOUT_" + std::to_string(now + 1) + "__";
    const std::string stderrMarker = "__SCRCPY_SHELL_STDERR_" + std::to_string(now + 2) + "__";

    const std::string script =
        "OUT=/data/local/tmp/scrcpy-shell-out-$$; "
        "ERR=/data/local/tmp/scrcpy-shell-err-$$; "
        "(" + cmd + ") >\"$OUT\" 2>\"$ERR\"; "
        "RC=$?; "
        "printf " + shellSingleQuote(rcMarker) + "; "
        "printf " + shellSingleQuote("%s\n") + " \"$RC\"; "
        "printf " + shellSingleQuote(stdoutMarker + "\n") + "; "
        "cat \"$OUT\" 2>/dev/null; "
        "printf " + shellSingleQuote("\n" + stderrMarker + "\n") + "; "
        "cat \"$ERR\" 2>/dev/null; "
        "rm -f \"$OUT\" \"$ERR\"";

    const std::string raw = adb->runAdbCmd(script);
    return parseLegacyShellPayload(raw, rcMarker, stdoutMarker, stderrMarker);
}

int32_t remainingTimeoutMs(const std::chrono::steady_clock::time_point& deadline) {
    auto now = std::chrono::steady_clock::now();
    if (now >= deadline) {
        return 0;
    }
    return static_cast<int32_t>(
        std::chrono::duration_cast<std::chrono::milliseconds>(deadline - now).count());
}

void closeFdIfNeeded(int& fd) {
    if (fd < 0) {
        return;
    }
    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
    fd = -1;
}

void joinThreadIfNeeded(std::thread& thread) {
    if (!thread.joinable()) {
        return;
    }
    if (thread.get_id() == std::this_thread::get_id()) {
        thread.detach();
        return;
    }
    thread.join();
}

void writeAllToFd(int fd, const uint8_t* data, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        ssize_t n = ::send(fd, data + offset, len - offset, MSG_NOSIGNAL);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n <= 0) {
            throw std::runtime_error("reverse bridge write failed");
        }
        offset += static_cast<size_t>(n);
    }
}

bssl::UniquePtr<EVP_PKEY> LoadPrivateKey(std::string_view pem) {
    bssl::UniquePtr<BIO> bio(BIO_new_mem_buf(pem.data(), static_cast<int>(pem.size())));
    if (!bio) {
        return nullptr;
    }
    return bssl::UniquePtr<EVP_PKEY>(PEM_read_bio_PrivateKey(bio.get(), nullptr, nullptr, nullptr));
}

bool AddExtension(X509* cert, int nid, const char* value) {
    size_t len = std::strlen(value) + 1;
    std::vector<char> mutableValue(value, value + len);
    X509V3_CTX context;

    X509V3_set_ctx_nodb(&context);
    X509V3_set_ctx(&context, cert, cert, nullptr, nullptr, 0);
    X509_EXTENSION* ext = X509V3_EXT_nconf_nid(nullptr, &context, nid, mutableValue.data());
    if (!ext) {
        return false;
    }

    X509_add_ext(cert, ext, -1);
    X509_EXTENSION_free(ext);
    return true;
}

std::string PrivateKeyToPem(EVP_PKEY* pkey) {
    bssl::UniquePtr<BIO> bio(BIO_new(BIO_s_mem()));
    if (!bio) {
        throw std::runtime_error("Failed to allocate PEM BIO");
    }
    if (PEM_write_bio_PKCS8PrivateKey(bio.get(), pkey, nullptr, nullptr, 0, nullptr, nullptr) != 1) {
        throw std::runtime_error("PEM_write_bio_PKCS8PrivateKey failed");
    }
    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio.get(), &mem);
    if (!mem || !mem->data || mem->length == 0) {
        throw std::runtime_error("BIO_get_mem_ptr failed");
    }
    return std::string(mem->data, mem->length);
}

std::string GenerateCertificatePem(EVP_PKEY* pkey) {
    bssl::UniquePtr<X509> x509(X509_new());
    if (!x509) {
        throw std::runtime_error("Unable to allocate X509");
    }
    X509_set_version(x509.get(), 2);
    ASN1_INTEGER_set(X509_get_serialNumber(x509.get()), 1);
    X509_gmtime_adj(X509_get_notBefore(x509.get()), 0);
    X509_gmtime_adj(X509_get_notAfter(x509.get()), kCertLifetimeSeconds);
    if (!X509_set_pubkey(x509.get(), pkey)) {
        throw std::runtime_error("Unable to set X509 public key");
    }
    X509_NAME* name = X509_get_subject_name(x509.get());
    if (!name) {
        throw std::runtime_error("Unable to get X509 subject name");
    }
    X509_NAME_add_entry_by_txt(name, "C", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("US"), -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "O", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("Android"), -1, -1, 0);
    X509_NAME_add_entry_by_txt(name, "CN", MBSTRING_ASC, reinterpret_cast<const unsigned char*>("Adb"), -1, -1, 0);
    if (!X509_set_issuer_name(x509.get(), name)) {
        throw std::runtime_error("Unable to set X509 issuer name");
    }
    if (!AddExtension(x509.get(), NID_basic_constraints, kBasicConstraints) ||
        !AddExtension(x509.get(), NID_key_usage, kKeyUsage) ||
        !AddExtension(x509.get(), NID_subject_key_identifier, kSubjectKeyIdentifier)) {
        throw std::runtime_error("Unable to create X509 extensions");
    }
    if (X509_sign(x509.get(), pkey, EVP_sha256()) <= 0) {
        throw std::runtime_error("Unable to sign X509 certificate");
    }

    bssl::UniquePtr<BIO> bio(BIO_new(BIO_s_mem()));
    if (!bio) {
        throw std::runtime_error("Failed to allocate X509 PEM BIO");
    }
    if (PEM_write_bio_X509(bio.get(), x509.get()) != 1) {
        throw std::runtime_error("PEM_write_bio_X509 failed");
    }
    BUF_MEM* mem = nullptr;
    BIO_get_mem_ptr(bio.get(), &mem);
    if (!mem || !mem->data || mem->length == 0) {
        throw std::runtime_error("BIO_get_mem_ptr failed");
    }
    return std::string(mem->data, mem->length);
}
}

Adb::Adb(AdbChannel* channel) : channel_(channel) {
    sendRunning_.store(true);
    sendThread_ = std::thread(&Adb::sendLoop, this);
}

std::string Adb::normalizeStreamKind(const std::string& streamKind) {
    if (streamKind == "video" || streamKind == "audio" || streamKind == "control") {
        return streamKind;
    }
    return "other";
}

size_t Adb::getReadBufferCapacityForKind(const std::string& streamKind) {
    const std::string normalizedKind = normalizeStreamKind(streamKind);
    if (normalizedKind == "video") {
        return 64 * 1024 * 1024;
    }
    if (normalizedKind == "audio") {
        return 16 * 1024 * 1024;
    }
    return 10 * 1024 * 1024;
}

Adb::~Adb() {
    close();

    // Destroy stream objects only when the ADB instance is destroyed.
    // close() may be triggered by handleIn thread on disconnect, while
    // reader threads are still unwinding from waitForData().
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        for (auto& pair : openStreams_) {
            delete pair.second;
        }
        openStreams_.clear();
        connectionStreams_.clear();
        pendingOpenStreamKinds_.clear();
        pendingIncomingStreamKinds_.clear();
        lastStream_ = nullptr;
    }
    delete channel_;
}



// 通过channel读取一个ADB消息
static AdbMessage readMessageFromChannel(AdbChannel* channel, int timeoutMs = -1) {
    uint8_t header[AdbProtocol::ADB_HEADER_LENGTH];
    channel->readWithTimeout(header, AdbProtocol::ADB_HEADER_LENGTH, timeoutMs);

    auto readU32LE = [&](int off) -> uint32_t {
        return static_cast<uint32_t>(header[off])
             | (static_cast<uint32_t>(header[off + 1]) << 8)
             | (static_cast<uint32_t>(header[off + 2]) << 16)
             | (static_cast<uint32_t>(header[off + 3]) << 24);
    };

    AdbMessage msg(readU32LE(0), readU32LE(4), readU32LE(8), readU32LE(12));
    if (msg.payloadLength > 0) {
        msg.payload.resize(msg.payloadLength);
        channel->readWithTimeout(msg.payload.data(), msg.payloadLength, timeoutMs);
    }
    return msg;
}

int Adb::connect(AdbKeyPair& keyPair, AuthCallback onWaitAuth) {
    clearLastConnectError();
    // 发送CONNECT消息
    OH_LOG_INFO(LOG_APP, "ADB: Sending CONNECT message...");
    auto connectMsg = AdbProtocol::generateConnect();
    channel_->write(connectMsg.data(), connectMsg.size());
    OH_LOG_INFO(LOG_APP, "ADB: CONNECT sent, waiting for response (timeout 10s)...");

    AdbMessage message;
    try {
        message = readMessageFromChannel(channel_, 10000);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "ADB: CONNECT response timeout or error: %{public}s", e.what());
        setLastConnectError(std::string("connect response failed: ") + e.what());
        channel_->close();
        return -4; // Connect Timeout/Error
    }

    OH_LOG_INFO(LOG_APP, "ADB: Received response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u payloadLen=%{public}u",
                message.command, message.arg0, message.arg1, message.payloadLength);
    int authResult = 0; // 0=已授权/无需授权, 1=需要用户确认, -1=失败

    if (message.command == AdbProtocol::CMD_STLS) {
        OH_LOG_INFO(LOG_APP, "ADB: Received STLS, upgrading transport to TLS...");
        int fd = -1;
        try {
            auto tlsRequest = AdbProtocol::generateTlsRequest();
            channel_->write(tlsRequest.data(), tlsRequest.size());

            auto* tcpChannel = dynamic_cast<TcpChannel*>(channel_);
            if (!tcpChannel) {
                throw std::runtime_error("STLS requires TcpChannel");
            }

            fd = tcpChannel->releaseFd();
            delete channel_;
            channel_ = nullptr;

            const std::string& privateKeyPem = keyPair.getPrivateKeyPem();
            bssl::UniquePtr<EVP_PKEY> privateKey = LoadPrivateKey(privateKeyPem);
            if (!privateKey) {
                throw std::runtime_error("Failed to load ADB private key for TLS");
            }
            const std::string certPem = GenerateCertificatePem(privateKey.get());
            const std::string normalizedPrivateKeyPem = PrivateKeyToPem(privateKey.get());

            auto tlsConnection = scrcpy::pairing::TlsConnection::Create(
                scrcpy::pairing::TlsConnection::Role::Client,
                certPem,
                normalizedPrivateKeyPem,
                fd
            );
            if (!tlsConnection) {
                throw std::runtime_error("Failed to create TLS connection");
            }
            tlsConnection->SetCertVerifyCallback([](X509_STORE_CTX*) { return 1; });
            if (tlsConnection->DoHandshake() != scrcpy::pairing::TlsConnection::TlsError::Success) {
                throw std::runtime_error("TLS handshake failed");
            }

            channel_ = new TlsAdbChannel(std::move(tlsConnection), fd);
            message = readMessageFromChannel(channel_, 10000);
            OH_LOG_INFO(LOG_APP,
                        "ADB: Post-TLS response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u payloadLen=%{public}u",
                        message.command, message.arg0, message.arg1, message.payloadLength);
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "ADB: STLS upgrade failed: %{public}s", e.what());
            setLastConnectError(std::string("stls upgrade failed: ") + e.what());
            if (fd >= 0) {
                ::shutdown(fd, SHUT_RDWR);
                ::close(fd);
            }
            if (channel_) {
                channel_->close();
            }
            return -1;
        }
    }

    if (message.command == AdbProtocol::CMD_AUTH) {
        OH_LOG_INFO(LOG_APP, "ADB: Got AUTH challenge, signing payload...");
        // 发送签名
        auto signature = keyPair.signPayload(message.payload.data(), message.payload.size());
        OH_LOG_INFO(LOG_APP, "ADB: Signature generated, size=%{public}zu, sending AUTH_SIGNATURE...", signature.size());
        auto authMsg = AdbProtocol::generateAuth(AdbProtocol::AUTH_TYPE_SIGNATURE,
                                                  signature.data(), signature.size());
        channel_->write(authMsg.data(), authMsg.size());

        OH_LOG_INFO(LOG_APP, "ADB: AUTH_SIGNATURE sent, waiting for response (timeout 5s)...");
        
        bool authFailedOrTimeout = false;
        try {
            message = readMessageFromChannel(channel_, 5000);
            OH_LOG_INFO(LOG_APP, "ADB: Received response cmd=0x%{public}x arg0=%{public}u arg1=%{public}u payloadLen=%{public}u",
                        message.command, message.arg0, message.arg1, message.payloadLength);
            
            if (message.command == AdbProtocol::CMD_AUTH) {
                authFailedOrTimeout = true;
            }
        } catch (const std::exception& e) {
            OH_LOG_WARN(LOG_APP, "ADB: Wait for AUTH response timeout or error: %{public}s. Proceeding to send Public Key.", e.what());
            authFailedOrTimeout = true;
        }

        if (authFailedOrTimeout) {
            // 需要发送公钥
            OH_LOG_INFO(LOG_APP, "ADB: Still AUTH or Timeout, sending public key, size: %{public}zu",
                         keyPair.getPublicKeyBytes().size());

            authResult = 1; // 需要用户在设备上确认授权

            auto pubKeyMsg = AdbProtocol::generateAuth(AdbProtocol::AUTH_TYPE_RSA_PUBLIC,
                                                        keyPair.getPublicKeyBytes().data(),
                                                        keyPair.getPublicKeyBytes().size());
            channel_->write(pubKeyMsg.data(), pubKeyMsg.size());
            OH_LOG_INFO(LOG_APP, "ADB: Public key sent, waiting for CNXN...");
            
            if (onWaitAuth) {
                OH_LOG_INFO(LOG_APP, "ADB: Invoking onWaitAuth callback");
                onWaitAuth();
            }

            // Wait longer for user confirmation (e.g. 30s)
            // But if user cancels, TcpChannel::close() will unblock read() via shutdown().
            try {
                message = readMessageFromChannel(channel_, 30000); 
            } catch (const std::exception& e) {
                 if (channel_->isClosed()) {
                     OH_LOG_INFO(LOG_APP, "ADB: Connect/Auth cancelled (channel closed)");
                     return -6; // Cancelled
                 }
                 std::string err = e.what();
                 if (err.find("timeout") != std::string::npos) {
                     OH_LOG_ERROR(LOG_APP, "ADB: Wait for CNXN timeout: %{public}s", err.c_str());
                     setLastConnectError(std::string("wait for cnxn timeout: ") + err);
                     channel_->close();
                     return -5; // Timeout
                 }
                 OH_LOG_ERROR(LOG_APP, "ADB: Wait for CNXN error (disconnect?): %{public}s", err.c_str());
                 setLastConnectError(std::string("wait for cnxn failed: ") + err);
                 channel_->close();
                 return -7; // Connection Closed / Error
            }
            
            // If we are here, we got a message. Check if it is CNXN.
            if (message.command != AdbProtocol::CMD_CNXN) {
                OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN but got 0x%{public}x", message.command);
                setLastConnectError("auth flow failed: expected CNXN");
                channel_->close();
                return -3;
            }
        }
    } else if (message.command != AdbProtocol::CMD_CNXN) {
         OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN or AUTH but got 0x%{public}x", message.command);
         setLastConnectError("unexpected initial ADB response");
         channel_->close();
         return -1;
    }
    
    // At this point, `message` should be CNXN.
    if (message.command != AdbProtocol::CMD_CNXN) {
        OH_LOG_ERROR(LOG_APP, "ADB: Expected CNXN (0x%{public}x) but got 0x%{public}x",
                     AdbProtocol::CMD_CNXN, message.command);
        setLastConnectError("expected CNXN after connect");
        channel_->close();
        return -1;
    }


    clearLastConnectError();
    maxData_ = std::min<uint32_t>(message.arg1, AdbProtocol::CONNECT_MAXDATA);
    OH_LOG_INFO(LOG_APP,
                "ADB: connected, peerMaxData=%{public}u, localMaxData=%{public}u, effectiveMaxData=%{public}u",
                message.arg1,
                AdbProtocol::CONNECT_MAXDATA,
                maxData_);

    // 启动后台消息处理
    handleInRunning_.store(true);
    handleInThread_ = std::thread(&Adb::handleInLoop, this);

    return 0;
}

void Adb::handleInLoop() {
    try {
        const size_t HEADER_SIZE = 24;
        uint8_t headerBuf[24];
        std::vector<uint8_t> tempPayload;
        while (handleInRunning_.load() && !isClosed_.load()) {
            // 1. Read Header (24 bytes)
            try {
                channel_->readWithTimeout(headerBuf, HEADER_SIZE, -1);
            } catch (...) {
                if (isClosed_.load()) break;
                throw; // Re-throw to exit loop
            }

            if (isClosed_.load() || !handleInRunning_.load()) break;

            // 2. Parse Header
            auto readU32LE = [&](int off) -> uint32_t {
                return static_cast<uint32_t>(headerBuf[off])
                     | (static_cast<uint32_t>(headerBuf[off + 1]) << 8)
                     | (static_cast<uint32_t>(headerBuf[off + 2]) << 16)
                     | (static_cast<uint32_t>(headerBuf[off + 3]) << 24);
            };
            
            uint32_t cmd = readU32LE(0);
            uint32_t arg0 = readU32LE(4);
            uint32_t arg1 = readU32LE(8);
            uint32_t payloadLen = readU32LE(12);
            // checksum (16) and magic (20) ignored for now

            // OH_LOG_INFO(LOG_APP, "[ADB] Recv Header: cmd=0x%{public}x len=%{public}u", cmd, payloadLen);

            if (cmd == AdbProtocol::CMD_OPEN) {
                if (payloadLen > 0) {
                    if (tempPayload.size() < payloadLen) tempPayload.resize(payloadLen);
                    channel_->readWithTimeout(tempPayload.data(), payloadLen, -1);
                    tempPayload.resize(payloadLen);
                } else {
                    tempPayload.clear();
                }

                if (arg0 != 0 && arg1 == 0) {
                    if (!handleIncomingOpen(arg0, tempPayload)) {
                        auto closeMsg = AdbProtocol::generateClose(0, static_cast<int32_t>(arg0));
                        writeToChannel(std::move(closeMsg));
                    }
                }
                continue;
            }

            // 3. Handle Payload
            AdbStream* stream = nullptr;
            if (lastStream_ != nullptr && lastStream_->localId == static_cast<int32_t>(arg1) && !lastStream_->closed) {
                 stream = lastStream_;
            } else {
                std::lock_guard<std::mutex> lock(streamsMutex_);
                auto it = connectionStreams_.find(static_cast<int32_t>(arg1));
                if (it != connectionStreams_.end()) {
                    stream = it->second;
                    lastStream_ = stream; // Update cache
                } else {
                    // connectionStreams_ may no longer contain closed streams (streamClose removes them),
                    // but openStreams_ keeps ownership for lifecycle safety. Reuse it first to avoid
                    // creating phantom streams on late CLSE/OKAY packets during shutdown.
                    auto openIt = openStreams_.find(static_cast<int32_t>(arg1));
                    if (openIt != openStreams_.end() && !openIt->second->closed.load()) {
                        stream = openIt->second;
                        lastStream_ = stream;
                    } else if (openIt != openStreams_.end()) {
                        // Known stream already closed; ignore late packets without recreating it.
                        stream = nullptr;
                    } else {
                        std::string streamKind = "other";
                        auto pendingKindIt = pendingOpenStreamKinds_.find(static_cast<int32_t>(arg1));
                        if (pendingKindIt != pendingOpenStreamKinds_.end()) {
                            streamKind = pendingKindIt->second;
                        }
                        OH_LOG_DEBUG(LOG_APP, "[ADB] New connection: localId=%{public}u, remoteId=%{public}u",
                                     arg1, arg0);
                        stream = createNewStream(static_cast<int32_t>(arg1),
                                                 static_cast<int32_t>(arg0),
                                                 static_cast<int32_t>(arg1) > 0,
                                                 streamKind);
                        lastStream_ = stream; // Update cache
                        // notifyAll(); // Moved to after command processing to avoid race condition (e.g. notify before CLSE handled)
                    }
                }
            }

            if (cmd == AdbProtocol::CMD_WRTE && stream && payloadLen > 0) {
                // *** ZERO-COPY PATH ***
                // Read directly into Stream's RingBuffer.
                // Do not drop bytes here: ADB must remain a reliable byte stream.
                // Overload is handled later at the decoded-packet queue layer.
                size_t remaining = payloadLen;
                while (remaining > 0) {
                    auto writeInfo = stream->readBuffer.getWritePtr();
                    if (writeInfo.second == 0) {
                        bool hasSpace = stream->readBuffer.waitForSpace(1, -1);
                        if (!hasSpace) {
                            // The stream is closing while this payload is already in-flight.
                            // Drain the remaining bytes to keep the ADB connection framed correctly.
                            size_t toDrain = std::min(remaining, static_cast<size_t>(4096));
                            if (tempPayload.size() < toDrain) tempPayload.resize(toDrain);
                            channel_->readWithTimeout(tempPayload.data(), toDrain, -1);
                            remaining -= toDrain;
                            continue;
                        }
                        continue;
                    }

                    size_t toRead = std::min(remaining, writeInfo.second);
                    channel_->readWithTimeout(writeInfo.first, toRead, -1);
                    stream->readBuffer.commitWrite(toRead);
                    remaining -= toRead;
                }

                if (!stream->closed.load() && !isClosed_.load()) {
                    auto okayMsg = AdbProtocol::generateOkay(static_cast<int32_t>(arg1),
                                                             static_cast<int32_t>(arg0));
                    writeToChannel(std::move(okayMsg));
                }

            } else {
                // *** NORMAL PATH ***
                // Read payload to temp buffer (if any)
                if (payloadLen > 0) {
                     if (tempPayload.size() < payloadLen) tempPayload.resize(payloadLen);
                     channel_->readWithTimeout(tempPayload.data(), payloadLen, -1);
                }
                
                // Process non-WRTE or new-stream messages
                if (!stream && cmd == AdbProtocol::CMD_WRTE) {
                     // Maybe new stream (OPEN? No, Device never sends OPEN usually, it sends WRTE to localId)
                     // If stream not found, we ignore data (already read to temp)
                     // Respond with CLSE?
                     // Verify if it is a new connection request?
                     // Device initiates connection via OPEN?
                     if (arg0 == 0) { // Should check command, but OPEN is 0x4e45504f
                        // Logic for new stream...
                     }
                }

                // Handle other commands
                if (cmd == AdbProtocol::CMD_OKAY) {
                    if (stream) {
                         {
                             std::lock_guard<std::mutex> streamWriteLock(stream->writeMutex);
                             stream->canWrite.store(true);
                             flushPendingWritesLocked(stream);
                         }
                         notifyAll(); // Notify open() or any waiters that stream is ready
                    }
                } else if (cmd == AdbProtocol::CMD_CLSE) {
                    bool firstClose = true;
                    bool shouldLog = false;
                    if (stream) {
                        firstClose = !stream->closed.exchange(true);
                        stream->readBuffer.close();
                        {
                            std::lock_guard<std::mutex> streamWriteLock(stream->writeMutex);
                            stream->pendingWriteBuffer.clear();
                            stream->pendingWriteOffset = 0;
                        }
                        notifyAll();

                        if (firstClose) {
                            std::lock_guard<std::mutex> lock(streamsMutex_);
                            auto it = connectionStreams_.find(static_cast<int32_t>(arg1));
                            if (it != connectionStreams_.end() && it->second == stream) {
                                connectionStreams_.erase(it);
                            }
                            if (lastStream_ == stream) {
                                lastStream_ = nullptr;
                            }
                            shouldLog = true;
                        }
                    }

                    if (shouldLog) {
                        OH_LOG_DEBUG(LOG_APP, "[ADB] Connection closed: localId=%{public}u", arg1);
                    }
                    notifyAll(); // Notify open() or read() that stream is closed
                } else if (cmd == AdbProtocol::CMD_WRTE && !stream) {
                     // ...
                }
            }
        }
        OH_LOG_INFO(LOG_APP, "[ADB] handleIn loop exited normally");
    } catch (const std::exception& e) {
        if (!isClosed_.load()) {
            OH_LOG_ERROR(LOG_APP, "ADB handleIn error: %{public}s", e.what());
        } else {
            OH_LOG_INFO(LOG_APP, "[ADB] handleIn exited due to close");
        }
        close();
    }
}

int32_t Adb::open(const std::string& destination, bool canMultipleSend, bool allowImmediateClose,
                  const std::string& streamKind) {
    int32_t localId = localIdPool_++;
    if (!canMultipleSend) localId = -localId;

    {
        std::lock_guard<std::mutex> slock(streamsMutex_);
        pendingOpenStreamKinds_[localId] = normalizeStreamKind(streamKind);
    }

    auto openMsg = AdbProtocol::generateOpen(localId, destination);
    writeToChannel(std::move(openMsg));
    OH_LOG_INFO(LOG_APP, "[ADB] OPEN sent: localId=%{public}d dest=%{public}s kind=%{public}s",
                localId, destination.c_str(), normalizeStreamKind(streamKind).c_str());

    // 等待流建立
    AdbStream* stream = nullptr;
    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isClosed_.load()) {
            {
                std::lock_guard<std::mutex> slock(streamsMutex_);
                auto it = openStreams_.find(localId);
                if (it != openStreams_.end()) {
                    stream = it->second;
                    break;
                }
            }
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    if (!stream) {
        std::lock_guard<std::mutex> slock(streamsMutex_);
        pendingOpenStreamKinds_.erase(localId);
        throw std::runtime_error("Failed to open stream");
    }

    // Service commands like "reverse:*" may legitimately open, send a reply,
    // and close before open() returns. Normal data streams should still be
    // rejected if they are already closed here.
    {
        const bool refused = stream->remoteId == 0;
        const bool closedTooEarly = stream->closed.load() && !allowImmediateClose;
        if (refused || closedTooEarly) {
            OH_LOG_ERROR(LOG_APP,
                         "[ADB] Stream opened but closed/refused (remoteId=%{public}d closed=%{public}d): localId=%{public}d",
                         stream->remoteId, stream->closed.load(), localId);
            // Cleanup
            {
                std::lock_guard<std::mutex> slock(streamsMutex_);
                pendingOpenStreamKinds_.erase(localId);
                auto it = connectionStreams_.find(localId);
                if (it != connectionStreams_.end()) {
                    connectionStreams_.erase(it);
                }
                auto openIt = openStreams_.find(localId);
                if (openIt != openStreams_.end()) {
                    openStreams_.erase(openIt);
                }
                if (lastStream_ == stream) {
                    lastStream_ = nullptr;
                }
            }
            delete stream;
            throw std::runtime_error(refused ? "Stream connection refused" : "Stream closed before ready");
        }
    }

    return localId;
}

std::string Adb::restartOnTcpip(int port) {
    int32_t streamId = open("tcpip:" + std::to_string(port), false);

    // 等待流关闭
    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isStreamClosed(streamId) && !isClosed_.load()) {
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    auto data = streamReadAllBeforeClose(streamId);
    return std::string(data.begin(), data.end());
}

std::string Adb::runServiceCommand(const std::string& destination) {
    int32_t streamId = open(destination, true, true);

    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isStreamClosed(streamId) && !isClosed_.load()) {
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    auto data = streamReadAllBeforeClose(streamId);
    std::string reply(data.begin(), data.end());
    OH_LOG_INFO(LOG_APP, "[ADB] Service reply: dest=%{public}s reply=%{public}s",
                destination.c_str(), reply.c_str());
    return reply;
}

bool Adb::reverseForward(const std::string& remote, const std::string& local) {
    const std::string reply = runServiceCommand("reverse:forward:" + remote + ";" + local);
    if (reply.empty() || reply.rfind("OKAY", 0) == 0) {
        return true;
    }
    OH_LOG_ERROR(LOG_APP, "[ADB] reverse forward failed: %{public}s", reply.c_str());
    return false;
}

bool Adb::reverseRemove(const std::string& remote) {
    const std::string reply = runServiceCommand("reverse:killforward:" + remote);
    if (reply.empty() || reply.rfind("OKAY", 0) == 0) {
        return true;
    }
    OH_LOG_WARN(LOG_APP, "[ADB] reverse remove failed: %{public}s", reply.c_str());
    return false;
}

void Adb::pushFile(const uint8_t* fileData, size_t fileLen,
                   const std::string& remotePath, ProcessCallback callback) {
    int32_t streamId = startPushFile(remotePath);
    try {
        constexpr size_t chunkSize = 64 * 1024;
        size_t hasSendLen = 0;
        int lastProcess = 0;

        size_t offset = 0;
        while (offset < fileLen) {
            size_t len = std::min(chunkSize, fileLen - offset);
            writePushFileChunk(streamId, fileData + offset, len);

            hasSendLen += len;
            int newProcess = static_cast<int>((hasSendLen * 100) / fileLen);
            if (newProcess != lastProcess) {
                lastProcess = newProcess;
                if (callback) callback(lastProcess);
            }
            offset += len;
        }
        finishPushFile(streamId);
    } catch (...) {
        abortPushFile(streamId);
        throw;
    }
}

void Adb::pushFileFromFd(int fd, uint64_t fileLen,
                         const std::string& remotePath, ProcessCallback callback) {
    if (fd < 0) {
        throw std::runtime_error("Invalid source fd");
    }

    constexpr size_t kChunkSize = 64 * 1024;
    constexpr int32_t kDefaultFileMode = 0644;

    int32_t streamId = open("sync:", true);
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) {
        throw std::runtime_error("Failed to open sync stream");
    }

    const std::string sendString = remotePath + "," + std::to_string(kDefaultFileMode);
    auto sendHeader = AdbProtocol::generateSyncHeader("SEND", static_cast<int32_t>(sendString.size()));

    auto readExact = [fd](uint8_t* dest, size_t len) {
        size_t offset = 0;
        while (offset < len) {
            ssize_t bytesRead = read(fd, dest + offset, len - offset);
            if (bytesRead < 0) {
                if (errno == EINTR) {
                    continue;
                }
                throw std::runtime_error(std::string("Failed to read local file: ") + std::strerror(errno));
            }
            if (bytesRead == 0) {
                throw std::runtime_error("Unexpected EOF while reading local file");
            }
            offset += static_cast<size_t>(bytesRead);
        }
    };

    try {
        if (fileLen < kChunkSize) {
            std::vector<uint8_t> fileData(static_cast<size_t>(fileLen));
            if (!fileData.empty()) {
                readExact(fileData.data(), fileData.size());
            }

            const int64_t nowSeconds = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            const uint32_t mtime = nowSeconds > 0 ? static_cast<uint32_t>(nowSeconds) : 0;
            auto dataHeader = AdbProtocol::generateSyncHeader("DATA", static_cast<int32_t>(fileData.size()));
            auto doneHeader = AdbProtocol::generateSyncHeader("DONE", static_cast<int32_t>(mtime));

            std::vector<uint8_t> packet;
            packet.reserve(sendHeader.size() + sendString.size() + dataHeader.size() + fileData.size() + doneHeader.size());
            packet.insert(packet.end(), sendHeader.begin(), sendHeader.end());
            packet.insert(packet.end(), sendString.begin(), sendString.end());
            packet.insert(packet.end(), dataHeader.begin(), dataHeader.end());
            packet.insert(packet.end(), fileData.begin(), fileData.end());
            packet.insert(packet.end(), doneHeader.begin(), doneHeader.end());
            streamWriteRaw(stream, packet.data(), packet.size());
            if (callback) {
                callback(100);
            }
        } else {
            std::vector<uint8_t> sendPacket;
            sendPacket.reserve(sendHeader.size() + sendString.size());
            sendPacket.insert(sendPacket.end(), sendHeader.begin(), sendHeader.end());
            sendPacket.insert(sendPacket.end(), sendString.begin(), sendString.end());
            streamWriteRaw(stream, sendPacket.data(), sendPacket.size());

            std::vector<uint8_t> chunkBuffer(kChunkSize);
            uint64_t uploaded = 0;
            int lastProgress = -1;
            while (uploaded < fileLen) {
                size_t toRead = static_cast<size_t>(std::min<uint64_t>(kChunkSize, fileLen - uploaded));
                readExact(chunkBuffer.data(), toRead);

                auto dataHeader = AdbProtocol::generateSyncHeader("DATA", static_cast<int32_t>(toRead));
                std::vector<uint8_t> packet;
                packet.reserve(dataHeader.size() + toRead);
                packet.insert(packet.end(), dataHeader.begin(), dataHeader.end());
                packet.insert(packet.end(), chunkBuffer.begin(), chunkBuffer.begin() + static_cast<std::ptrdiff_t>(toRead));
                streamWriteRaw(stream, packet.data(), packet.size());

                uploaded += toRead;
                if (callback && fileLen > 0) {
                    int currentProgress = static_cast<int>((uploaded * 100) / fileLen);
                    if (currentProgress != lastProgress) {
                        lastProgress = currentProgress;
                        callback(currentProgress);
                    }
                }
            }

            const int64_t nowSeconds = std::chrono::duration_cast<std::chrono::seconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            const uint32_t mtime = nowSeconds > 0 ? static_cast<uint32_t>(nowSeconds) : 0;
            auto doneHeader = AdbProtocol::generateSyncHeader("DONE", static_cast<int32_t>(mtime));
            streamWriteRaw(stream, doneHeader.data(), doneHeader.size());
        }

        const auto responseHeader = streamRead(streamId, 8, 30000, true);
        if (responseHeader.size() != 8) {
            abortPushFile(streamId);
            throw std::runtime_error("sync push failed: invalid response");
        }

        const std::string responseId(reinterpret_cast<const char*>(responseHeader.data()), 4);
        const uint32_t responseArg = readU32LE(responseHeader.data() + 4);
        if (responseId == "FAIL") {
            std::string errorMessage = "sync push failed";
            if (responseArg > 0) {
                const auto errorData = streamRead(streamId, responseArg, 30000, true);
                errorMessage = "sync push failed: " + std::string(errorData.begin(), errorData.end());
            }
            abortPushFile(streamId);
            throw std::runtime_error(errorMessage);
        }
        if (responseId != "OKAY") {
            abortPushFile(streamId);
            throw std::runtime_error("sync push failed: unexpected response " + responseId);
        }

        auto quitHeader = AdbProtocol::generateSyncHeader("QUIT", 0);
        streamWriteRaw(stream, quitHeader.data(), quitHeader.size());
        streamClose(streamId);
    } catch (...) {
        abortPushFile(streamId);
        throw;
    }
}

std::vector<RemoteFileEntry> Adb::listDirectory(const std::string& remotePath) {
    if (remotePath.empty()) {
        throw std::runtime_error("Remote directory path is empty");
    }

    constexpr int32_t kSyncTimeoutMs = 30000;
    constexpr uint32_t kMaxNameLength = 1024 * 1024;
    int32_t streamId = open("sync:", true);
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) {
        throw std::runtime_error("Failed to open sync stream");
    }

    auto readFailure = [this, streamId](const std::string& prefix) {
        const auto lengthData = streamRead(streamId, 4, 30000, true);
        const uint32_t length = readU32LE(lengthData.data());
        if (length > 1024 * 1024) {
            throw std::runtime_error(prefix + ": invalid error length");
        }
        const auto messageData = length > 0 ? streamRead(streamId, length, 30000, true)
                                            : std::vector<uint8_t>();
        throw std::runtime_error(prefix + ": " + std::string(messageData.begin(), messageData.end()));
    };
    auto resolveSymlinkTargetTypes = [this](const std::vector<std::string>& paths) -> std::unordered_map<std::string, char> {
        std::unordered_map<std::string, char> resultMap;
        if (paths.empty()) {
            return resultMap;
        }

        std::string command = "for p in";
        for (const auto& path : paths) {
            command += " ";
            command += shellSingleQuote(path);
        }
        command += "; do ";
        command += "if [ -d \"$p\" ]; then t=d; ";
        command += "elif [ -f \"$p\" ]; then t=f; ";
        command += "else t=o; fi; ";
        command += "printf '%s\\t%s\\n' \"$t\" \"$p\"; ";
        command += "done";

        const AdbShellCommandResult result = execShellCommand(command);
        if (result.exitCodeReliable && result.exitCode != 0) {
            throw std::runtime_error("shell type probe failed: exit code " + std::to_string(result.exitCode));
        }

        const std::string output = trimTrailingNewlines(result.stdoutText);
        size_t start = 0;
        while (start < output.size()) {
            size_t end = output.find('\n', start);
            if (end == std::string::npos) {
                end = output.size();
            }
            if (end > start) {
                const std::string line = output.substr(start, end - start);
                if (line.size() >= 3 && line[1] == '\t') {
                    resultMap[line.substr(2)] = line[0];
                }
            }
            start = end + 1;
        }

        return resultMap;
    };

    try {
        auto listHeader = AdbProtocol::generateSyncHeader("LIST", static_cast<int32_t>(remotePath.size()));
        streamWriteRaw(stream, listHeader.data(), listHeader.size());
        streamWriteRaw(stream, reinterpret_cast<const uint8_t*>(remotePath.data()), remotePath.size());

        std::vector<RemoteFileEntry> entries;
        std::vector<size_t> symlinkEntryIndexes;
        std::vector<std::string> symlinkPaths;
        while (true) {
            const auto idData = streamRead(streamId, 4, kSyncTimeoutMs, true);
            const std::string id(reinterpret_cast<const char*>(idData.data()), 4);
            if (id == "DONE") {
                // LIST v1 terminates with the remaining zeroed DENT fields.
                streamRead(streamId, 16, kSyncTimeoutMs, true);
                break;
            }
            if (id == "FAIL") {
                readFailure("sync list failed");
            }
            if (id != "DENT") {
                throw std::runtime_error("sync list failed: unexpected response " + id);
            }

            const auto metadata = streamRead(streamId, 16, kSyncTimeoutMs, true);
            const uint32_t mode = readU32LE(metadata.data());
            const uint32_t size = readU32LE(metadata.data() + 4);
            const uint32_t mtime = readU32LE(metadata.data() + 8);
            const uint32_t nameLength = readU32LE(metadata.data() + 12);
            if (nameLength == 0 || nameLength > kMaxNameLength) {
                throw std::runtime_error("sync list failed: invalid entry name length");
            }

            const auto nameData = streamRead(streamId, nameLength, kSyncTimeoutMs, true);
            std::string name(nameData.begin(), nameData.end());
            if (name == "." || name == "..") {
                continue;
            }

            std::string path = remotePath;
            if (path.size() > 1 && path.back() == '/') {
                path.pop_back();
            }
            if (path != "/") {
                path.push_back('/');
            }
            path += name;

            RemoteFileEntry entry;
            entry.name = std::move(name);
            entry.path = std::move(path);
            entry.mode = mode;
            entry.size = size;
            entry.mtime = mtime;
            bool isDirectory = S_ISDIR(mode);
            bool isRegularFile = S_ISREG(mode);
            if (S_ISLNK(mode)) {
                symlinkEntryIndexes.push_back(entries.size());
                symlinkPaths.push_back(entry.path);
            }
            entry.isDirectory = isDirectory;
            entry.isRegularFile = isRegularFile;
            entries.push_back(std::move(entry));
        }

        if (!symlinkPaths.empty()) {
            try {
                const auto resolvedTypes = resolveSymlinkTargetTypes(symlinkPaths);
                for (size_t i = 0; i < symlinkEntryIndexes.size(); ++i) {
                    RemoteFileEntry& entry = entries[symlinkEntryIndexes[i]];
                    const auto found = resolvedTypes.find(entry.path);
                    if (found == resolvedTypes.end()) {
                        entry.isRegularFile = true;
                        continue;
                    }
                    entry.isDirectory = found->second == 'd';
                    entry.isRegularFile = found->second == 'f';
                }
            } catch (...) {
                for (const size_t index : symlinkEntryIndexes) {
                    entries[index].isRegularFile = true;
                }
            }
        }

        auto quitHeader = AdbProtocol::generateSyncHeader("QUIT", 0);
        streamWriteRaw(stream, quitHeader.data(), quitHeader.size());
        streamClose(streamId);
        return entries;
    } catch (...) {
        streamClose(streamId);
        throw;
    }
}

uint64_t Adb::pullFileToFd(int fd, const std::string& remotePath, ProcessCallback callback) {
    if (fd < 0) {
        throw std::runtime_error("Invalid destination fd");
    }
    if (remotePath.empty()) {
        throw std::runtime_error("Remote file path is empty");
    }
    if (ftruncate(fd, 0) != 0 || lseek(fd, 0, SEEK_SET) < 0) {
        throw std::runtime_error(std::string("Failed to prepare local file: ") + std::strerror(errno));
    }

    constexpr int32_t kSyncTimeoutMs = 30000;
    constexpr uint32_t kMaxChunkSize = 1024 * 1024;
    int32_t streamId = open("sync:", true);
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) {
        throw std::runtime_error("Failed to open sync stream");
    }

    auto sendRequest = [this, stream](const char id[4], const std::string& path) {
        auto header = AdbProtocol::generateSyncHeader(id, static_cast<int32_t>(path.size()));
        streamWriteRaw(stream, header.data(), header.size());
        streamWriteRaw(stream, reinterpret_cast<const uint8_t*>(path.data()), path.size());
    };
    auto readFailure = [this, streamId](const std::string& prefix) {
        const auto lengthData = streamRead(streamId, 4, 30000, true);
        const uint32_t length = readU32LE(lengthData.data());
        if (length > 1024 * 1024) {
            throw std::runtime_error(prefix + ": invalid error length");
        }
        const auto messageData = length > 0 ? streamRead(streamId, length, 30000, true)
                                            : std::vector<uint8_t>();
        throw std::runtime_error(prefix + ": " + std::string(messageData.begin(), messageData.end()));
    };

    try {
        sendRequest("STAT", remotePath);
        const auto statIdData = streamRead(streamId, 4, kSyncTimeoutMs, true);
        const std::string statId(reinterpret_cast<const char*>(statIdData.data()), 4);
        if (statId == "FAIL") {
            readFailure("sync stat failed");
        }
        if (statId != "STAT") {
            throw std::runtime_error("sync stat failed: unexpected response " + statId);
        }
        const auto statData = streamRead(streamId, 12, kSyncTimeoutMs, true);
        const uint32_t mode = readU32LE(statData.data());
        const uint64_t expectedSize = readU32LE(statData.data() + 4);
        if (!S_ISREG(mode) && !S_ISLNK(mode)) {
            throw std::runtime_error("Remote path is not a regular file");
        }

        sendRequest("RECV", remotePath);
        uint64_t downloaded = 0;
        int lastProgress = -1;
        std::vector<uint8_t> buffer;

        while (true) {
            const auto idData = streamRead(streamId, 4, kSyncTimeoutMs, true);
            const std::string id(reinterpret_cast<const char*>(idData.data()), 4);
            if (id == "DONE") {
                break;
            }
            if (id == "FAIL") {
                readFailure("sync pull failed");
            }
            if (id != "DATA") {
                throw std::runtime_error("sync pull failed: unexpected response " + id);
            }

            const auto lengthData = streamRead(streamId, 4, kSyncTimeoutMs, true);
            const uint32_t length = readU32LE(lengthData.data());
            if (length == 0 || length > kMaxChunkSize) {
                throw std::runtime_error("sync pull failed: invalid data length");
            }
            if (buffer.size() < length) {
                buffer.resize(length);
            }
            streamReadToBuffer(streamId, buffer.data(), length, kSyncTimeoutMs, true);

            size_t written = 0;
            while (written < length) {
                ssize_t result = write(fd, buffer.data() + written, length - written);
                if (result < 0 && errno == EINTR) {
                    continue;
                }
                if (result <= 0) {
                    throw std::runtime_error(std::string("Failed to write local file: ") + std::strerror(errno));
                }
                written += static_cast<size_t>(result);
            }

            downloaded += length;
            if (callback && expectedSize > 0) {
                int progress = static_cast<int>(std::min<uint64_t>((downloaded * 100) / expectedSize, 99));
                if (progress != lastProgress) {
                    lastProgress = progress;
                    callback(progress);
                }
            }
        }

        if (callback) {
            callback(100);
        }
        auto quitHeader = AdbProtocol::generateSyncHeader("QUIT", 0);
        streamWriteRaw(stream, quitHeader.data(), quitHeader.size());
        streamClose(streamId);
        return downloaded;
    } catch (...) {
        ftruncate(fd, 0);
        streamClose(streamId);
        throw;
    }
}

int32_t Adb::startPushFile(const std::string& remotePath) {
    int32_t streamId = open("sync:", true);
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) {
            stream = it->second;
        }
    }
    if (!stream) {
        throw std::runtime_error("Failed to open sync stream");
    }

    constexpr int32_t kDefaultFileMode = 0644;
    const std::string sendString = remotePath + "," + std::to_string(kDefaultFileMode);
    auto sendHeader = AdbProtocol::generateSyncHeader("SEND", static_cast<int32_t>(sendString.size()));
    streamWriteRaw(stream, sendHeader.data(), sendHeader.size());
    streamWriteRaw(stream, reinterpret_cast<const uint8_t*>(sendString.data()), sendString.size());
    return streamId;
}

void Adb::writePushFileChunk(int32_t streamId, const uint8_t* chunkData, size_t chunkLen) {
    if (chunkLen == 0) {
        return;
    }
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) {
        throw std::runtime_error("Sync push stream not found");
    }
    auto dataHeader = AdbProtocol::generateSyncHeader("DATA", static_cast<int32_t>(chunkLen));
    streamWriteRaw(stream, dataHeader.data(), dataHeader.size());
    streamWriteRaw(stream, chunkData, chunkLen);
}

void Adb::finishPushFile(int32_t streamId) {
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) {
        throw std::runtime_error("Sync push stream not found");
    }

    const int64_t nowSeconds = std::chrono::duration_cast<std::chrono::seconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    const uint32_t mtime = nowSeconds > 0 ? static_cast<uint32_t>(nowSeconds) : 0;
    auto doneHeader = AdbProtocol::generateSyncHeader("DONE", static_cast<int32_t>(mtime));
    streamWriteRaw(stream, doneHeader.data(), doneHeader.size());

    const auto responseHeader = streamRead(streamId, 8, 30000, true);
    if (responseHeader.size() != 8) {
        abortPushFile(streamId);
        throw std::runtime_error("sync push failed: invalid response");
    }

    const std::string responseId(reinterpret_cast<const char*>(responseHeader.data()), 4);
    const uint32_t responseArg = readU32LE(responseHeader.data() + 4);
    if (responseId == "FAIL") {
        std::string errorMessage = "sync push failed";
        if (responseArg > 0) {
            const auto errorData = streamRead(streamId, responseArg, 30000, true);
            errorMessage = "sync push failed: " + std::string(errorData.begin(), errorData.end());
        }
        abortPushFile(streamId);
        throw std::runtime_error(errorMessage);
    }
    if (responseId != "OKAY") {
        abortPushFile(streamId);
        throw std::runtime_error("sync push failed: unexpected response " + responseId);
    }

    auto quitHeader = AdbProtocol::generateSyncHeader("QUIT", 0);
    streamWriteRaw(stream, quitHeader.data(), quitHeader.size());
    streamClose(streamId);
}

void Adb::abortPushFile(int32_t streamId) {
    if (streamId >= 0 && !isStreamClosed(streamId)) {
        streamClose(streamId);
    }
}

std::string Adb::runAdbCmd(const std::string& cmd) {
    int32_t streamId = open("shell:" + cmd, true, true);

    {
        std::unique_lock<std::mutex> lock(waitMutex_);
        while (!isStreamClosed(streamId) && !isClosed_.load()) {
            waitCv_.wait_for(lock, std::chrono::milliseconds(100));
        }
    }

    auto data = streamReadAllBeforeClose(streamId);
    return std::string(data.begin(), data.end());
}

AdbShellCommandResult Adb::execShellCommand(const std::string& cmd) {
    try {
        int32_t streamId = open("shell,v2,raw:" + cmd, true, true);

        {
            std::unique_lock<std::mutex> lock(waitMutex_);
            while (!isStreamClosed(streamId) && !isClosed_.load()) {
                waitCv_.wait_for(lock, std::chrono::milliseconds(100));
            }
        }

        const auto raw = streamReadAllBeforeClose(streamId);
        if (raw.empty()) {
            throw std::runtime_error("shell protocol failed: empty response");
        }

        return parseShellProtocolPayload(raw);
    } catch (const std::exception& e) {
        OH_LOG_WARN(LOG_APP, "[ADB] shell,v2,raw failed, fallback to legacy shell: %{public}s", e.what());
        return execShellCommandLegacy(this, cmd);
    }
}

int32_t Adb::getShell() {
    return open("shell:", true);
}

int32_t Adb::tcpForward(int port) {
    int32_t streamId = open("tcp:" + std::to_string(port), true);
    if (isStreamClosed(streamId)) {
        throw std::runtime_error("error forward");
    }
    return streamId;
}

int32_t Adb::localSocketForward(const std::string& socketName, const std::string& streamKind) {
    int32_t streamId = open("localabstract:" + socketName, true, false, streamKind);
    if (isStreamClosed(streamId)) {
        throw std::runtime_error("error forward");
    }
    return streamId;
}

AdbStream* Adb::getStreamHandle(int32_t streamId) {
    std::lock_guard<std::mutex> lock(streamsMutex_);
    auto it = connectionStreams_.find(streamId);
    if (it != connectionStreams_.end()) {
        AdbStream* stream = it->second;
        if (stream && !stream->closed.load()) return stream;
        return nullptr;
    }

    auto openIt = openStreams_.find(streamId);
    if (openIt != openStreams_.end()) {
        AdbStream* stream = openIt->second;
        if (stream && !stream->closed.load()) return stream;
    }

    return nullptr;
}

std::vector<uint8_t> Adb::streamRead(int32_t streamId, size_t size, int32_t timeoutMs, bool exact) {
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) throw std::runtime_error("Stream not found");

    std::vector<uint8_t> result(size);
    size_t totalRead = 0;
    
    // RingBuffer handles waiting and copying
    // My RingBuffer implementation: waitForData, copyTo
    
    const bool hasDeadline = timeoutMs > 0;
    const auto deadline = hasDeadline ? std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs)
                                      : std::chrono::steady_clock::time_point{};

    while (totalRead < size) {
        size_t needed = size - totalRead;
        size_t waitTarget = exact ? std::min(needed, static_cast<size_t>(maxData_)) : 1;
        int32_t waitTimeout = timeoutMs;
        if (hasDeadline) {
            waitTimeout = remainingTimeoutMs(deadline);
        }
        
        // Wait for data
        // If timeoutMs < 0, wait indefinitely.
        // If timeoutMs == 0, check immediately (non-blocking).
        // If timeoutMs > 0, wait for given duration.
        bool hasData = stream->readBuffer.waitForData(waitTarget, waitTimeout);
        
        if (!hasData) {
             if (stream->readBuffer.isClosed()) {
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream closed");
             }
             if (waitTimeout == 0) { // Non-blocking read returned nothing
                  if (!exact && totalRead > 0) break;
                  // If explicit non-blocking read and no data, we could just return partial/empty result
                  // usually expected to return whatever is available.
                  // But streamRead(..., exact) logic implies we throw if not satisfied?
                  // ArkTS adbStreamRead usually expects partial/empty if not blocking.
                  // Legacy behavior: 
                  /*
                    if (timeoutMs == 0) {
                         if (!exact) break;
                         throw std::runtime_error("Stream read timeout");
                    }
                  */
                  if (!exact) break;
                  throw std::runtime_error("Stream read timeout (no data)");
             }
             if (hasDeadline || timeoutMs > 0) { // Specific timeout occurred
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream read timeout");
             }
        }
        
        // Copy available
        size_t n = stream->readBuffer.copyTo(result.data() + totalRead, needed);
        if (n == 0) {
            if (stream->readBuffer.isClosed()) {
                 if (!exact && totalRead > 0) break;
                 throw std::runtime_error("Stream closed");
            }
        }
        
        totalRead += n;
        
        if (!exact && n > 0) break; // Return what we have if not exact
        
        // Timeout check for next iteration
        if (hasDeadline && totalRead < size && remainingTimeoutMs(deadline) == 0) {
             if (!exact) break;
             throw std::runtime_error("Stream read timeout");
        }
    }

    result.resize(totalRead);
    return result;
}

size_t Adb::streamReadToBuffer(int32_t streamId, uint8_t* dest, size_t destSize, int32_t timeoutMs, bool exact) {
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) throw std::runtime_error("Stream not found");
    return streamReadToBuffer(stream, dest, destSize, timeoutMs, exact);
}

size_t Adb::streamReadToBuffer(AdbStream* stream, uint8_t* dest, size_t destSize, int32_t timeoutMs, bool exact) {
    if (!stream) throw std::runtime_error("Stream not found");
    if (stream->closed.load()) throw std::runtime_error("Stream closed");

    auto callStart = std::chrono::steady_clock::now();
    size_t totalRead = 0;
    const bool hasDeadline = timeoutMs > 0;
    const auto deadline = hasDeadline ? std::chrono::steady_clock::now() + std::chrono::milliseconds(timeoutMs)
                                      : std::chrono::steady_clock::time_point{};

    while (totalRead < destSize) {
        size_t needed = destSize - totalRead;
        size_t waitTarget = exact ? std::min(needed, static_cast<size_t>(maxData_)) : 1;
        int32_t waitTimeout = timeoutMs;
        if (hasDeadline) {
            waitTimeout = remainingTimeoutMs(deadline);
        }
        
        bool hasData = stream->readBuffer.waitForData(waitTarget, waitTimeout);
        
        if (!hasData) {
             if (stream->readBuffer.isClosed()) {
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream closed");
             }
             if (waitTimeout == 0) {
                  if (!exact) break;
                  throw std::runtime_error("Stream read timeout (no data)");
             }
             if (hasDeadline || timeoutMs > 0) {
                  if (!exact && totalRead > 0) break;
                  throw std::runtime_error("Stream read timeout");
             }
        }
        
        size_t n = stream->readBuffer.copyTo(dest + totalRead, needed);
        if (n == 0) {
            if (stream->readBuffer.isClosed()) {
                 if (!exact && totalRead > 0) break;
                 throw std::runtime_error("Stream closed");
            }
        }
        
        totalRead += n;
        
        if (!exact && n > 0) break; // Return what we have if not exact
        
        if (hasDeadline && totalRead < destSize && remainingTimeoutMs(deadline) == 0) {
             if (!exact) break;
             throw std::runtime_error("Stream read timeout");
        }
    }

    return totalRead;
}

void Adb::streamWrite(int32_t streamId, const uint8_t* data, size_t len) {
    AdbStream* stream = getStreamHandle(streamId);
    if (!stream) throw std::runtime_error("Stream not found");
    streamWrite(stream, data, len);
}

void Adb::streamWrite(AdbStream* stream, const uint8_t* data, size_t len) {
    if (!stream) throw std::runtime_error("Stream not found");
    if (stream->closed.load()) throw std::runtime_error("Stream closed");
    if (!data && len > 0) throw std::runtime_error("Invalid write buffer");
    if (len == 0) return;

    const bool isControlStream = stream->streamKind == "control";
    const TouchPacketTrace currentControlTrace = isControlStream
        ? parseControlTouchPayload(data, len)
        : TouchPacketTrace();

    std::unique_lock<std::mutex> streamWriteLock(stream->writeMutex);
    if (stream->closed.load()) throw std::runtime_error("Stream closed");

    size_t offset = 0;
    while (offset < len) {
        while (!isClosed_.load() && !stream->closed.load()) {
            compactPendingWritesLocked(stream);
            flushPendingWritesLocked(stream);

            if (pendingWriteBytesLocked(stream) < MAX_PENDING_WRITE_BYTES) {
                break;
            }

            streamWriteLock.unlock();
            {
                std::unique_lock<std::mutex> waitLock(waitMutex_);
                waitCv_.wait_for(waitLock, std::chrono::milliseconds(100), [this, stream]() {
                    if (isClosed_.load() || stream->closed.load()) {
                        return true;
                    }
                    std::lock_guard<std::mutex> streamLock(stream->writeMutex);
                    return pendingWriteBytesLocked(stream) < MAX_PENDING_WRITE_BYTES ||
                           stream->canWrite.load();
                });
            }
            streamWriteLock.lock();
        }

        if (isClosed_.load()) throw std::runtime_error("ADB closed");
        if (stream->closed.load()) throw std::runtime_error("Stream closed");

        compactPendingWritesLocked(stream);
        if (isControlStream && currentControlTrace.isTouch &&
            currentControlTrace.action == CONTROL_TOUCH_ACTION_MOVE &&
            len - offset == CONTROL_TOUCH_PACKET_SIZE) {
            compactControlPendingMovesForCurrentMove(stream, currentControlTrace);
        }

        const size_t pendingBytes = pendingWriteBytesLocked(stream);
        if (pendingBytes >= MAX_PENDING_WRITE_BYTES) {
            continue;
        }

        const size_t availableBytes = MAX_PENDING_WRITE_BYTES - pendingBytes;
        const size_t chunkSize = std::min(availableBytes, len - offset);
        stream->pendingWriteBuffer.insert(stream->pendingWriteBuffer.end(),
                                          data + offset,
                                          data + offset + chunkSize);
        offset += chunkSize;
        flushPendingWritesLocked(stream);
    }
}

void Adb::flushPendingWritesLocked(AdbStream* stream) {
    if (!stream) {
        return;
    }
    while (!isClosed_.load() && !stream->closed.load() && stream->canWrite.load()) {
        const size_t pendingSize = stream->pendingWriteBuffer.size();
        if (stream->pendingWriteOffset >= pendingSize) {
            if (stream->pendingWriteOffset > 0) {
                stream->pendingWriteBuffer.clear();
                stream->pendingWriteOffset = 0;
            }
            break;
        }

        size_t available = pendingSize - stream->pendingWriteOffset;
        size_t chunkLimit = maxData_ > 128 ? static_cast<size_t>(maxData_ - 128) : 1;
        size_t chunkSize = std::min(chunkLimit, available);
        stream->canWrite.store(false);
        auto writeMsg = AdbProtocol::generateWrite(
            stream->localId,
            stream->remoteId,
            stream->pendingWriteBuffer.data() + stream->pendingWriteOffset,
            chunkSize);
        writeToChannel(std::move(writeMsg));
        stream->pendingWriteOffset += chunkSize;
        compactPendingWritesLocked(stream);

        if (stream->pendingWriteOffset >= stream->pendingWriteBuffer.size()) {
            stream->pendingWriteBuffer.clear();
            stream->pendingWriteOffset = 0;
            break;
        }
    }
}

void Adb::streamWriteRaw(AdbStream* stream, const uint8_t* data, size_t len) {
    size_t offset = 0;
    while (offset < len) {
        {
            std::unique_lock<std::mutex> lock(waitMutex_);
            waitCv_.wait(lock, [this, stream]() {
                return isClosed_.load() || stream->closed.load() || stream->canWrite.load();
            });
        }

        if (isClosed_.load()) {
            throw std::runtime_error("ADB closed");
        }
        if (stream->closed.load()) {
            throw std::runtime_error("Stream closed");
        }

        size_t chunkSize = std::min(static_cast<size_t>(maxData_ - 128), len - offset);
        {
            std::lock_guard<std::mutex> streamWriteLock(stream->writeMutex);
            if (stream->closed.load()) {
                throw std::runtime_error("Stream closed");
            }
            if (!stream->canWrite.load()) {
                continue;
            }
            stream->canWrite.store(false);
            auto writeMsg = AdbProtocol::generateWrite(stream->localId, stream->remoteId,
                                                       data + offset, chunkSize);
            writeToChannel(std::move(writeMsg));
            offset += chunkSize;
        }
    }
}

void Adb::streamClose(int32_t streamId) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) {
            stream = it->second;
            connectionStreams_.erase(it);
        }
    }
    if (stream) {
        auto closeMsg = AdbProtocol::generateClose(stream->localId, stream->remoteId);
        writeToChannel(std::move(closeMsg));

        stream->closed = true;
        stream->readBuffer.close();
        {
            std::lock_guard<std::mutex> streamWriteLock(stream->writeMutex);
            stream->pendingWriteBuffer.clear();
            stream->pendingWriteOffset = 0;
        }
        notifyAll();
    }
}

bool Adb::isStreamClosed(int32_t streamId) {
    std::lock_guard<std::mutex> lock(streamsMutex_);
    auto it = connectionStreams_.find(streamId);
    if (it == connectionStreams_.end()) return true;
    return it->second->closed;
}

std::vector<uint8_t> Adb::streamReadAllBeforeClose(int32_t streamId) {
    AdbStream* stream = nullptr;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        auto it = connectionStreams_.find(streamId);
        if (it != connectionStreams_.end()) {
            stream = it->second;
        } else {
            auto openIt = openStreams_.find(streamId);
            if (openIt != openStreams_.end()) {
                stream = openIt->second;
            }
        }
    }
    if (!stream) return {};

    std::vector<uint8_t> result(stream->readBuffer.size()); // Approximate size
    size_t actual = stream->readBuffer.copyTo(result.data(), result.size());
    result.resize(actual);
    return result;
}

void Adb::close() {
    bool expected = false;
    if (!isClosed_.compare_exchange_strong(expected, true)) {
        return;
    }

    handleInRunning_.store(false);

    sendRunning_.store(false);
    if (channel_) {
        // Close the socket before joining worker threads so any blocking read/write
        // returns immediately during shutdown.
        channel_->close();
    }
    // Send poison pill (empty vector) to wake up thread
    sendQueue_.enqueue(std::vector<uint8_t>());
    if (sendThread_.joinable()) {
        if (std::this_thread::get_id() != sendThread_.get_id()) {
            sendThread_.join();
        } else {
             sendThread_.detach();
        }
    }

    std::vector<std::shared_ptr<ReverseBridge>> reverseBridges;
    {
        std::lock_guard<std::mutex> lock(reverseBridgesMutex_);
        reverseBridges = reverseBridges_;
    }
    for (const auto& bridge : reverseBridges) {
        if (!bridge) {
            continue;
        }
        bridge->closed.store(true);
        closeFdIfNeeded(bridge->fd);
    }

    // Mark all streams closed and wake blocking readers.
    // Stream objects are not deleted here to avoid use-after-free while
    // external consumer threads are still unwinding.
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        for (auto& pair : openStreams_) {
            if (pair.second) {
                pair.second->closed = true;
                pair.second->readBuffer.close();
            }
        }
        for (auto& pair : connectionStreams_) {
            if (pair.second) {
                pair.second->closed = true;
                pair.second->readBuffer.close();
            }
        }
        lastStream_ = nullptr;
    }

    notifyAll();

    if (handleInThread_.joinable()) {
        if (std::this_thread::get_id() != handleInThread_.get_id()) {
            handleInThread_.join();
        } else {
             OH_LOG_INFO(LOG_APP, "Adb::close called from handleInLoop, detaching thread");
             handleInThread_.detach();
        }
    }

    for (const auto& bridge : reverseBridges) {
        if (!bridge) {
            continue;
        }
        joinThreadIfNeeded(bridge->socketToAdbThread);
        joinThreadIfNeeded(bridge->adbToSocketThread);
    }
    {
        std::lock_guard<std::mutex> lock(reverseBridgesMutex_);
        reverseBridges_.clear();
    }

    // 清理流
    // Stream objects are released in ~Adb().
}

std::string Adb::getLastConnectError() const {
    std::lock_guard<std::mutex> lock(lastConnectErrorMutex_);
    return lastConnectError_;
}

void Adb::setLastConnectError(std::string error) {
    std::lock_guard<std::mutex> lock(lastConnectErrorMutex_);
    lastConnectError_ = std::move(error);
}

void Adb::clearLastConnectError() {
    std::lock_guard<std::mutex> lock(lastConnectErrorMutex_);
    lastConnectError_.clear();
}

void Adb::writeToChannel(const std::vector<uint8_t>& data) {
    if (isClosed_.load()) return;

    // Use approx size check for queue limit (BlockingConcurrentQueue size_approx is fast)
    size_t sendQueueApprox = sendQueue_.size_approx();
    if (sendQueueApprox > 5000) {
         OH_LOG_WARN(LOG_APP, "[ADB] Send queue full, dropping packet");
         return;
    }
    sendQueue_.enqueue(data);
}

void Adb::writeToChannel(std::vector<uint8_t>&& data) {
    if (isClosed_.load()) return;

    size_t sendQueueApprox = sendQueue_.size_approx();
    if (sendQueueApprox > 5000) {
         OH_LOG_WARN(LOG_APP, "[ADB] Send queue full, dropping packet");
         return;
    }
    sendQueue_.enqueue(std::move(data));
}

void Adb::sendLoop() {
    OH_LOG_INFO(LOG_APP, "[ADB] Send thread started");
    while (sendRunning_.load()) {
        std::vector<uint8_t> data;
        
        // Blocking wait for data
        // Uses internal semaphore for efficient sleep/wake
        sendQueue_.wait_dequeue(data);

        // Check for Poison Pill (empty data) or stopped flag
        if (!sendRunning_.load()) break;
        if (data.empty()) continue; // Should not happen usually unless used as wake-up signal

        try {
            // Blocking Write
            channel_->write(data.data(), data.size());
        } catch (const std::exception& e) {
            OH_LOG_ERROR(LOG_APP, "[ADB] Send error: %{public}s", e.what());
            close();
            break;
        }
    }
    OH_LOG_INFO(LOG_APP, "[ADB] Send thread exited");
}

Adb* Adb::create(int fd) {
    try {
        AdbChannel* channel = new TcpChannel(fd);
        return new Adb(channel);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "Adb::create(fd) failed: %{public}s", e.what());
        return nullptr;
    }
}

Adb* Adb::create(const std::string& ip, int port) {
    try {
        AdbChannel* channel = new TcpChannel(ip, port);
        return new Adb(channel);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "Adb::create(ip, port) failed: %{public}s", e.what());
        return nullptr;
    }
}

AdbStream* Adb::createNewStream(int32_t localId, int32_t remoteId, bool canMultipleSend,
                                const std::string& streamKind) {
    const std::string normalizedKind = normalizeStreamKind(streamKind);
    auto* stream = new AdbStream(getReadBufferCapacityForKind(normalizedKind), normalizedKind);
    stream->localId = localId;
    stream->remoteId = remoteId;
    stream->canMultipleSend = canMultipleSend;
    pendingOpenStreamKinds_.erase(localId);

    connectionStreams_[localId] = stream;
    openStreams_[localId] = stream;

    return stream;
}

void Adb::prepareIncomingStreamKinds(const std::vector<std::string>& streamKinds) {
    std::lock_guard<std::mutex> lock(streamsMutex_);
    pendingIncomingStreamKinds_.clear();
    for (const auto& streamKind : streamKinds) {
        pendingIncomingStreamKinds_.push_back(normalizeStreamKind(streamKind));
    }
}

void Adb::notifyAll() {
    waitCv_.notify_all();
}

size_t Adb::pendingWriteBytesLocked(const AdbStream* stream) const {
    if (!stream || stream->pendingWriteOffset >= stream->pendingWriteBuffer.size()) {
        return 0;
    }
    return stream->pendingWriteBuffer.size() - stream->pendingWriteOffset;
}

void Adb::compactPendingWritesLocked(AdbStream* stream) {
    if (!stream || stream->pendingWriteOffset == 0) {
        return;
    }
    if (stream->pendingWriteOffset >= stream->pendingWriteBuffer.size()) {
        stream->pendingWriteBuffer.clear();
        stream->pendingWriteOffset = 0;
        return;
    }
    if (stream->pendingWriteOffset >= stream->pendingWriteBuffer.size() / 2 ||
        stream->pendingWriteBuffer.size() > MAX_PENDING_WRITE_BYTES) {
        stream->pendingWriteBuffer.erase(stream->pendingWriteBuffer.begin(),
                                         stream->pendingWriteBuffer.begin() + stream->pendingWriteOffset);
        stream->pendingWriteOffset = 0;
    }
}

std::string Adb::stripTrailingNulls(const std::vector<uint8_t>& payload) {
    size_t end = payload.size();
    while (end > 0 && payload[end - 1] == '\0') {
        --end;
    }
    return std::string(reinterpret_cast<const char*>(payload.data()), end);
}

int Adb::connectLocalTcpPort(uint16_t port) {
    struct addrinfo hints {};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;

    struct addrinfo* res = nullptr;
    const std::string portStr = std::to_string(port);
    int status = getaddrinfo("127.0.0.1", portStr.c_str(), &hints, &res);
    if (status != 0) {
        throw std::runtime_error("reverse bridge getaddrinfo failed");
    }

    int fd = -1;
    for (struct addrinfo* p = res; p != nullptr; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd < 0) {
            continue;
        }

        int flag = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&flag), sizeof(flag));

        if (::connect(fd, p->ai_addr, p->ai_addrlen) == 0) {
            break;
        }

        closeFdIfNeeded(fd);
    }

    freeaddrinfo(res);

    if (fd < 0) {
        throw std::runtime_error("reverse bridge connect failed");
    }
    return fd;
}

void Adb::startReverseBridge(AdbStream* stream, int fd) {
    auto bridge = std::make_shared<ReverseBridge>();
    bridge->fd = fd;
    bridge->stream = stream;

    auto closeBridge = [bridge]() {
        bool expected = false;
        if (!bridge->closed.compare_exchange_strong(expected, true)) {
            return;
        }
        closeFdIfNeeded(bridge->fd);
    };

    bridge->socketToAdbThread = std::thread([this, stream, bridge, closeBridge]() {
        std::vector<uint8_t> buffer(64 * 1024);
        try {
            while (!bridge->closed.load() && !isClosed_.load()) {
                ssize_t n = ::recv(bridge->fd, buffer.data(), buffer.size(), 0);
                if (n < 0 && errno == EINTR) {
                    continue;
                }
                if (n <= 0) {
                    break;
                }
                streamWrite(stream, buffer.data(), static_cast<size_t>(n));
            }
        } catch (const std::exception& e) {
            if (!isClosed_.load() && !bridge->closed.load()) {
                OH_LOG_WARN(LOG_APP, "[ADB] reverse socket->adb exit: %{public}s", e.what());
            }
        }

        closeBridge();
        if (stream && !stream->closed.load()) {
            streamClose(stream->localId);
        }
    });

    bridge->adbToSocketThread = std::thread([this, stream, bridge, closeBridge]() {
        std::vector<uint8_t> buffer(64 * 1024);
        try {
            while (!bridge->closed.load() && !isClosed_.load()) {
                size_t n = streamReadToBuffer(stream, buffer.data(), buffer.size(), -1, false);
                if (n == 0) {
                    if (stream->closed.load()) {
                        break;
                    }
                    continue;
                }
                writeAllToFd(bridge->fd, buffer.data(), n);
            }
        } catch (const std::exception& e) {
            if (!isClosed_.load() && !bridge->closed.load()) {
                OH_LOG_WARN(LOG_APP, "[ADB] reverse adb->socket exit: %{public}s", e.what());
            }
        }

        closeBridge();
        if (stream && !stream->closed.load()) {
            streamClose(stream->localId);
        }
    });

    std::lock_guard<std::mutex> lock(reverseBridgesMutex_);
    reverseBridges_.push_back(std::move(bridge));
}

bool Adb::handleIncomingOpen(uint32_t remoteId, const std::vector<uint8_t>& payload) {
    const std::string destination = stripTrailingNulls(payload);
    if (destination.rfind("tcp:", 0) != 0) {
        OH_LOG_WARN(LOG_APP, "[ADB] Unsupported incoming OPEN destination: %{public}s", destination.c_str());
        return false;
    }

    const std::string portString = destination.substr(4);
    if (portString.empty()) {
        OH_LOG_WARN(LOG_APP, "[ADB] Invalid incoming OPEN destination: %{public}s", destination.c_str());
        return false;
    }

    int port = 0;
    try {
        port = std::stoi(portString);
    } catch (...) {
        OH_LOG_WARN(LOG_APP, "[ADB] Invalid incoming OPEN tcp spec: %{public}s", destination.c_str());
        return false;
    }

    if (port <= 0 || port > 65535) {
        OH_LOG_WARN(LOG_APP, "[ADB] Incoming OPEN port out of range: %{public}d", port);
        return false;
    }

    int fd = -1;
    try {
        fd = connectLocalTcpPort(static_cast<uint16_t>(port));
    } catch (const std::exception& e) {
        OH_LOG_WARN(LOG_APP, "[ADB] Incoming OPEN connect failed: %{public}s", e.what());
        return false;
    }

    AdbStream* stream = nullptr;
    int32_t localId = localIdPool_++;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        std::string streamKind = "other";
        if (!pendingIncomingStreamKinds_.empty()) {
            streamKind = pendingIncomingStreamKinds_.front();
            pendingIncomingStreamKinds_.pop_front();
        }
        stream = createNewStream(localId, static_cast<int32_t>(remoteId), true, streamKind);
        stream->canWrite.store(true);
        lastStream_ = stream;
    }

    auto okayMsg = AdbProtocol::generateOkay(localId, static_cast<int32_t>(remoteId));
    writeToChannel(std::move(okayMsg));
    startReverseBridge(stream, fd);
    return true;
}
