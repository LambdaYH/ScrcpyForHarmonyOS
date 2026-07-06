#include "adb/pairing/AdbPair.h"

#include "adb/pairing/PairingAuth.h"
#include "adb/pairing/TlsConnection.h"

#include <arpa/inet.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <netdb.h>
#include <net/if.h>
#include <netinet/tcp.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <condition_variable>
#include <cctype>
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <mutex>
#include <memory>
#include <random>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <openssl/evp.h>
#include <openssl/pem.h>
#include <openssl/x509v3.h>

#include <hilog/log.h>

#ifndef LOG_TAG
#define LOG_TAG "AdbPair"
#endif

#ifndef IPV6_JOIN_GROUP
#define IPV6_JOIN_GROUP IPV6_ADD_MEMBERSHIP
#endif

namespace scrcpy::pairing {
namespace {

constexpr uint8_t kPacketTypeSpake2Msg = 0;
constexpr uint8_t kPacketTypePeerInfo = 1;
constexpr uint8_t kCurrentKeyHeaderVersion = 1;
constexpr uint32_t kMaxPeerInfoSize = 8192;
constexpr uint32_t kMaxPayloadSize = kMaxPeerInfoSize * 2;
constexpr int kConnectTimeoutSeconds = 10;
constexpr int kPairingAcceptTimeoutSeconds = 180;
constexpr size_t kExportedKeySize = 64;
constexpr char kAdbPairingServiceType[] = "_adb-tls-pairing._tcp.local";

enum PeerInfoType : uint8_t {
    ADB_RSA_PUB_KEY = 0,
    ADB_DEVICE_GUID = 1,
};

struct PeerInfo {
    uint8_t type;
    uint8_t data[kMaxPeerInfoSize - 1];
} __attribute__((packed));

struct PairingPacketHeader {
    uint8_t version;
    uint8_t type;
    uint32_t payload;
} __attribute__((packed));

class UniqueFd {
public:
    explicit UniqueFd(int fd = -1) : fd_(fd) {}
    ~UniqueFd() {
        reset();
    }

    UniqueFd(const UniqueFd&) = delete;
    UniqueFd& operator=(const UniqueFd&) = delete;

    UniqueFd(UniqueFd&& other) noexcept : fd_(other.fd_) {
        other.fd_ = -1;
    }

    UniqueFd& operator=(UniqueFd&& other) noexcept {
        if (this != &other) {
            reset();
            fd_ = other.fd_;
            other.fd_ = -1;
        }
        return *this;
    }

    int get() const {
        return fd_;
    }

    int release() {
        int fd = fd_;
        fd_ = -1;
        return fd;
    }

    void reset(int fd = -1) {
        if (fd_ >= 0) {
            ::close(fd_);
        }
        fd_ = fd;
    }

private:
    int fd_;
};

struct QrPairingSession {
    int64_t sessionId = 0;
    std::string pairingCode;
    std::string serviceName;
    std::string localIp;
    std::string publicKeyPath;
    std::string privateKeyPath;
    std::string resultGuid;
    std::string resultPairedHost;
    std::string resultHostPort;
    std::string error;
    bool completed = false;
    std::atomic_bool stopped {false};
    std::thread worker;
    std::mutex workerMutex;
    std::mutex mutex;
    std::condition_variable cv;
};

void LogQrSession(const QrPairingSession& session, const char* message) {
    OH_LOG_INFO(LOG_APP,
                "QRPairing: session=%{public}lld service=%{public}s ip=%{public}s %{public}s",
                static_cast<long long>(session.sessionId), session.serviceName.c_str(), session.localIp.c_str(),
                message);
}

std::mutex gQrPairingMutex;
std::unordered_map<int64_t, std::shared_ptr<QrPairingSession>> gQrPairingSessions;
int64_t gNextQrPairingSessionId = 1;

struct PairingAuthDeleter {
    void operator()(PairingAuthCtx* ctx) const {
        pairing_auth_destroy(ctx);
    }
};

using PairingAuthPtr = std::unique_ptr<PairingAuthCtx, PairingAuthDeleter>;
constexpr int kCertLifetimeSeconds = 10 * 365 * 24 * 60 * 60;
const char kBasicConstraints[] = "critical,CA:TRUE";
const char kKeyUsage[] = "critical,keyCertSign,cRLSign,digitalSignature";
const char kSubjectKeyIdentifier[] = "hash";

std::string ReadFileToString(const std::string& path) {
    std::ifstream file(path, std::ios::binary);
    if (!file) {
        throw std::runtime_error("Unable to open file: " + path);
    }
    return std::string((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
}

std::string ReadPublicKeyString(const std::string& path) {
    std::string raw = ReadFileToString(path);
    const size_t zeroPos = raw.find('\0');
    if (zeroPos != std::string::npos) {
        raw.resize(zeroPos);
    }
    while (!raw.empty() && (raw.back() == '\n' || raw.back() == '\r')) {
        raw.pop_back();
    }
    return raw;
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

std::string GeneratePairingCode() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<int> dist(0, 999999);
    int value = dist(gen);
    char buffer[7];
    std::snprintf(buffer, sizeof(buffer), "%06d", value);
    return std::string(buffer);
}

std::string GenerateServiceName() {
    std::random_device rd;
    std::mt19937 gen(rd());
    std::uniform_int_distribution<uint32_t> dist(0, 0xFFFFFFFF);
    char buffer[24];
    std::snprintf(buffer, sizeof(buffer), "adb-%08x", dist(gen));
    return std::string(buffer);
}

void PushU16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

void PushU32(std::vector<uint8_t>& out, uint32_t value) {
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

uint16_t ReadU16(const std::vector<uint8_t>& data, size_t offset) {
    if (offset + 2 > data.size()) {
        return 0;
    }
    return static_cast<uint16_t>((data[offset] << 8) | data[offset + 1]);
}

std::string NormalizeDnsName(std::string name) {
    if (!name.empty() && name.back() == '.') {
        name.pop_back();
    }
    for (char& ch : name) {
        ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
    }
    return name;
}

std::string NormalizeIpLiteral(std::string host) {
    if (host.size() >= 2 && host.front() == '[' && host.back() == ']') {
        host = host.substr(1, host.size() - 2);
    }
    const size_t scopeIndex = host.find('%');
    if (scopeIndex != std::string::npos) {
        host = host.substr(0, scopeIndex);
    }
    return NormalizeDnsName(host);
}

std::string ExtractIpv6Scope(std::string host) {
    if (host.size() >= 2 && host.front() == '[' && host.back() == ']') {
        host = host.substr(1, host.size() - 2);
    }
    const size_t scopeIndex = host.find('%');
    if (scopeIndex == std::string::npos || scopeIndex + 1 >= host.size()) {
        return "";
    }
    return host.substr(scopeIndex + 1);
}

uint32_t ParseInterfaceScope(const std::string& scope) {
    if (scope.empty()) {
        return 0;
    }
    char* end = nullptr;
    const unsigned long numericScope = std::strtoul(scope.c_str(), &end, 10);
    if (end != nullptr && *end == '\0' && numericScope > 0 && numericScope <= UINT32_MAX) {
        return static_cast<uint32_t>(numericScope);
    }
    return if_nametoindex(scope.c_str());
}

bool IsIpv6Literal(const std::string& host) {
    std::string normalizedHost = NormalizeIpLiteral(host);
    in6_addr addr {};
    return inet_pton(AF_INET6, normalizedHost.c_str(), &addr) == 1;
}

bool IsIpv6LinkLocalLiteral(const std::string& host) {
    std::string normalizedHost = NormalizeIpLiteral(host);
    in6_addr addr {};
    if (inet_pton(AF_INET6, normalizedHost.c_str(), &addr) != 1) {
        return false;
    }
    return addr.s6_addr[0] == 0xfe && (addr.s6_addr[1] & 0xc0) == 0x80;
}

std::string FormatHostPort(const std::string& host, uint16_t port) {
    if (host.find(':') != std::string::npos && !(host.size() >= 2 && host.front() == '[' && host.back() == ']')) {
        return "[" + host + "]:" + std::to_string(port);
    }
    return host + ":" + std::to_string(port);
}

std::string FormatScopedIpv6HostPort(const std::string& host, uint16_t port, uint32_t interfaceIndex) {
    if (interfaceIndex == 0 || host.find(':') == std::string::npos || host.find('%') != std::string::npos ||
        !IsIpv6LinkLocalLiteral(host)) {
        return FormatHostPort(host, port);
    }
    return FormatHostPort(host + "%" + std::to_string(interfaceIndex), port);
}

uint32_t FindInterfaceIndexForAddress(const std::string& localIp) {
    const uint32_t scopedInterfaceIndex = ParseInterfaceScope(ExtractIpv6Scope(localIp));
    if (scopedInterfaceIndex != 0) {
        return scopedInterfaceIndex;
    }

    ifaddrs* interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0 || interfaces == nullptr) {
        return 0;
    }

    const std::string normalizedLocalIp = NormalizeIpLiteral(localIp);
    uint32_t interfaceIndex = 0;
    for (ifaddrs* item = interfaces; item != nullptr; item = item->ifa_next) {
        if (item->ifa_addr == nullptr) {
            continue;
        }
        const int family = item->ifa_addr->sa_family;
        char address[INET6_ADDRSTRLEN] {};
        if (family == AF_INET6) {
            const auto* addr = reinterpret_cast<const sockaddr_in6*>(item->ifa_addr);
            if (inet_ntop(AF_INET6, &addr->sin6_addr, address, sizeof(address)) == nullptr) {
                continue;
            }
        } else if (family == AF_INET) {
            const auto* addr = reinterpret_cast<const sockaddr_in*>(item->ifa_addr);
            if (inet_ntop(AF_INET, &addr->sin_addr, address, sizeof(address)) == nullptr) {
                continue;
            }
        } else {
            continue;
        }
        if (NormalizeIpLiteral(address) == normalizedLocalIp) {
            interfaceIndex = if_nametoindex(item->ifa_name);
            break;
        }
    }
    freeifaddrs(interfaces);
    return interfaceIndex;
}

void PushDnsName(std::vector<uint8_t>& out, const std::string& name) {
    size_t start = 0;
    while (start < name.size()) {
        size_t end = name.find('.', start);
        if (end == std::string::npos) {
            end = name.size();
        }
        size_t len = end - start;
        if (len > 63) {
            throw std::runtime_error("mDNS label is too long");
        }
        out.push_back(static_cast<uint8_t>(len));
        out.insert(out.end(), name.begin() + static_cast<long>(start), name.begin() + static_cast<long>(end));
        start = end + 1;
    }
    out.push_back(0);
}

bool ReadDnsName(const std::vector<uint8_t>& data, size_t& offset, std::string& out, int depth = 0) {
    if (depth > 8) {
        return false;
    }

    std::string name;
    size_t cursor = offset;
    bool jumped = false;
    while (cursor < data.size()) {
        uint8_t len = data[cursor++];
        if (len == 0) {
            if (!jumped) {
                offset = cursor;
            }
            out = name;
            return true;
        }

        if ((len & 0xC0) == 0xC0) {
            if (cursor >= data.size()) {
                return false;
            }
            uint16_t pointer = static_cast<uint16_t>(((len & 0x3F) << 8) | data[cursor++]);
            size_t pointerOffset = pointer;
            std::string suffix;
            if (!ReadDnsName(data, pointerOffset, suffix, depth + 1)) {
                return false;
            }
            if (!name.empty() && !suffix.empty()) {
                name.push_back('.');
            }
            name += suffix;
            if (!jumped) {
                offset = cursor;
            }
            out = name;
            return true;
        }

        if ((len & 0xC0) != 0 || cursor + len > data.size()) {
            return false;
        }
        if (!name.empty()) {
            name.push_back('.');
        }
        name.append(reinterpret_cast<const char*>(data.data() + cursor), len);
        cursor += len;
    }
    return false;
}

void CompleteQrPairingSession(const std::shared_ptr<QrPairingSession>& session, const std::string& guid,
                              const std::string& pairedHost, const std::string& hostPort,
                              const std::string& error) {
    std::lock_guard<std::mutex> lock(session->mutex);
    if (session->completed) {
        return;
    }
    session->resultGuid = guid;
    session->resultPairedHost = pairedHost;
    session->resultHostPort = hostPort;
    session->error = error;
    session->completed = true;
    session->cv.notify_all();
}

void ParseHostPort(const std::string& hostPort, std::string& host, std::string& port) {
    if (hostPort.empty()) {
        throw std::runtime_error("Pairing address is empty");
    }

    if (hostPort.front() == '[') {
        const size_t close = hostPort.find(']');
        if (close == std::string::npos || close + 2 > hostPort.size() || hostPort[close + 1] != ':') {
            throw std::runtime_error("Invalid IPv6 pairing address");
        }
        host = hostPort.substr(1, close - 1);
        port = hostPort.substr(close + 2);
        return;
    }

    const size_t colon = hostPort.rfind(':');
    if (colon == std::string::npos || colon == 0 || colon + 1 >= hostPort.size()) {
        throw std::runtime_error("Pairing address must be host:port");
    }

    host = hostPort.substr(0, colon);
    port = hostPort.substr(colon + 1);
}

void ThrowIfCanceled(const std::atomic_bool* canceled) {
    if (canceled != nullptr && canceled->load()) {
        throw std::runtime_error("QR pairing canceled");
    }
}

UniqueFd ConnectTcp(const std::string& host, const std::string& port, const std::atomic_bool* canceled) {
    ThrowIfCanceled(canceled);
    addrinfo hints {};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    addrinfo* result = nullptr;
    const int gai = getaddrinfo(host.c_str(), port.c_str(), &hints, &result);
    if (gai != 0) {
        throw std::runtime_error("Failed to resolve pairing address");
    }

    std::unique_ptr<addrinfo, decltype(&freeaddrinfo)> addrResult(result, freeaddrinfo);
    std::string lastError = "connect failed";

    for (addrinfo* ai = addrResult.get(); ai != nullptr; ai = ai->ai_next) {
        ThrowIfCanceled(canceled);
        UniqueFd fd(::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol));
        if (fd.get() < 0) {
            continue;
        }

        const int flags = fcntl(fd.get(), F_GETFL, 0);
        if (flags >= 0) {
            fcntl(fd.get(), F_SETFL, flags | O_NONBLOCK);
        }

        int rc = ::connect(fd.get(), ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) {
            if (flags >= 0) {
                fcntl(fd.get(), F_SETFL, flags);
            }
            int off = 1;
            setsockopt(fd.get(), IPPROTO_TCP, TCP_NODELAY, &off, sizeof(off));
            return fd;
        }

        if (errno != EINPROGRESS) {
            lastError = std::strerror(errno);
            continue;
        }

        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(kConnectTimeoutSeconds);
        while (true) {
            ThrowIfCanceled(canceled);
            const auto now = std::chrono::steady_clock::now();
            if (now >= deadline) {
                rc = 0;
                break;
            }

            auto waitMicros = std::chrono::duration_cast<std::chrono::microseconds>(deadline - now);
            const auto maxWaitMicros = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::milliseconds(200));
            if (waitMicros > maxWaitMicros) {
                waitMicros = maxWaitMicros;
            }

            fd_set writeSet;
            FD_ZERO(&writeSet);
            FD_SET(fd.get(), &writeSet);
            timeval timeout {};
            timeout.tv_sec = static_cast<time_t>(waitMicros.count() / 1000000);
            timeout.tv_usec = static_cast<suseconds_t>(waitMicros.count() % 1000000);
            rc = select(fd.get() + 1, nullptr, &writeSet, nullptr, &timeout);
            if (rc < 0 && errno == EINTR) {
                continue;
            }
            if (rc != 0) {
                break;
            }
        }
        if (rc <= 0) {
            lastError = rc == 0 ? "connect timeout" : std::strerror(errno);
            continue;
        }

        int soError = 0;
        socklen_t soErrorLen = sizeof(soError);
        if (getsockopt(fd.get(), SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) != 0 || soError != 0) {
            lastError = std::strerror(soError == 0 ? errno : soError);
            continue;
        }

        if (flags >= 0) {
            fcntl(fd.get(), F_SETFL, flags);
        }
        int off = 1;
        setsockopt(fd.get(), IPPROTO_TCP, TCP_NODELAY, &off, sizeof(off));
        return fd;
    }

    throw std::runtime_error("Failed to connect pairing socket: " + lastError);
}

PairingAuthPtr CreatePairingAuth(const std::vector<uint8_t>& password) {
    PairingAuthPtr auth(pairing_auth_client_new(password.data(), password.size()));
    if (!auth) {
        throw std::runtime_error("Unable to create pairing auth context");
    }
    return auth;
}

void WriteHeader(TlsConnection& tls, uint8_t type, std::string_view payload) {
    PairingPacketHeader header {kCurrentKeyHeaderVersion, type, static_cast<uint32_t>(payload.size())};
    PairingPacketHeader networkHeader = header;
    networkHeader.payload = htonl(networkHeader.payload);
    if (!tls.WriteFully(std::string_view(reinterpret_cast<const char*>(&networkHeader), sizeof(networkHeader))) ||
        !tls.WriteFully(payload)) {
        throw std::runtime_error("Failed to write pairing packet");
    }
}

PairingPacketHeader ReadHeader(TlsConnection& tls) {
    std::vector<uint8_t> data = tls.ReadFully(sizeof(PairingPacketHeader));
    if (data.size() != sizeof(PairingPacketHeader)) {
        throw std::runtime_error("Failed to read pairing packet header");
    }

    PairingPacketHeader header {};
    const uint8_t* p = data.data();
    header.version = p[0];
    header.type = p[1];
    uint32_t payload = 0;
    std::memcpy(&payload, p + 2, sizeof(payload));
    header.payload = ntohl(payload);

    if (header.version != kCurrentKeyHeaderVersion) {
        throw std::runtime_error("Unsupported pairing packet version");
    }
    if (header.type != kPacketTypeSpake2Msg && header.type != kPacketTypePeerInfo) {
        throw std::runtime_error("Unsupported pairing packet type");
    }
    if (header.payload == 0 || header.payload > kMaxPayloadSize) {
        throw std::runtime_error("Invalid pairing packet payload");
    }
    return header;
}

std::string PeerInfoToString(const PeerInfo& info) {
    const size_t len = strnlen(reinterpret_cast<const char*>(info.data), sizeof(info.data));
    return std::string(reinterpret_cast<const char*>(info.data), len);
}

struct MdnsPairingService {
    std::string instanceName;
    std::string targetHost;
    std::string address;
    std::unordered_map<std::string, std::string> resolvedAddresses;
    uint16_t port = 0;
};

void RememberMdnsAddress(MdnsPairingService& service, const std::string& hostName, const std::string& address) {
    service.resolvedAddresses[NormalizeDnsName(hostName)] = address;
}

bool AddressMatchesFamily(const std::string& address, int preferredFamily) {
    if (preferredFamily == AF_INET) {
        in_addr addr {};
        return inet_pton(AF_INET, NormalizeIpLiteral(address).c_str(), &addr) == 1;
    }
    if (preferredFamily == AF_INET6) {
        in6_addr addr {};
        return inet_pton(AF_INET6, NormalizeIpLiteral(address).c_str(), &addr) == 1;
    }
    return false;
}

void ApplyTargetHostAddress(MdnsPairingService& service, int preferredFamily) {
    if (service.targetHost.empty()) {
        return;
    }
    const auto it = service.resolvedAddresses.find(service.targetHost);
    if (it != service.resolvedAddresses.end() && AddressMatchesFamily(it->second, preferredFamily)) {
        service.address = it->second;
    }
}

std::vector<uint8_t> BuildMdnsQuery(const std::vector<std::pair<std::string, uint16_t>>& questions) {
    std::vector<uint8_t> packet;
    PushU16(packet, 0);
    PushU16(packet, 0);
    PushU16(packet, static_cast<uint16_t>(questions.size()));
    PushU16(packet, 0);
    PushU16(packet, 0);
    PushU16(packet, 0);
    for (const auto& question : questions) {
        PushDnsName(packet, question.first);
        PushU16(packet, question.second);
        PushU16(packet, 1);
    }
    return packet;
}

void ParseMdnsAnswers(const std::vector<uint8_t>& packet, const std::string& wantedInstance,
                      const std::string& remoteAddress, int preferredFamily, MdnsPairingService& service) {
    constexpr uint16_t kDnsTypeA = 1;
    constexpr uint16_t kDnsTypePtr = 12;
    constexpr uint16_t kDnsTypeSrv = 33;
    constexpr uint16_t kDnsTypeAaaa = 28;

    if (packet.size() < 12 || (ReadU16(packet, 2) & 0x8000) == 0) {
        return;
    }

    const uint16_t qdCount = ReadU16(packet, 4);
    const uint16_t anCount = ReadU16(packet, 6);
    const uint16_t nsCount = ReadU16(packet, 8);
    const uint16_t arCount = ReadU16(packet, 10);
    size_t offset = 12;
    for (uint16_t i = 0; i < qdCount; ++i) {
        std::string ignored;
        if (!ReadDnsName(packet, offset, ignored) || offset + 4 > packet.size()) {
            return;
        }
        offset += 4;
    }

    const uint32_t rrCount = static_cast<uint32_t>(anCount) + nsCount + arCount;
    for (uint32_t i = 0; i < rrCount; ++i) {
        std::string name;
        if (!ReadDnsName(packet, offset, name) || offset + 10 > packet.size()) {
            return;
        }
        name = NormalizeDnsName(name);
        const uint16_t type = ReadU16(packet, offset);
        offset += 2;
        offset += 2; // class
        offset += 4; // ttl
        const uint16_t rdLength = ReadU16(packet, offset);
        offset += 2;
        if (offset + rdLength > packet.size()) {
            return;
        }

        const size_t rdataOffset = offset;
        if (type == kDnsTypePtr && name == NormalizeDnsName(kAdbPairingServiceType)) {
            size_t ptrOffset = rdataOffset;
            std::string ptrName;
            if (ReadDnsName(packet, ptrOffset, ptrName) && NormalizeDnsName(ptrName) == wantedInstance) {
                service.instanceName = wantedInstance;
            }
        } else if (type == kDnsTypeSrv && name == wantedInstance && rdLength >= 6) {
            service.instanceName = wantedInstance;
            service.port = ReadU16(packet, rdataOffset + 4);
            size_t targetOffset = rdataOffset + 6;
            std::string targetHost;
            if (ReadDnsName(packet, targetOffset, targetHost)) {
                service.targetHost = NormalizeDnsName(targetHost);
                ApplyTargetHostAddress(service, preferredFamily);
                if (service.address.empty() && service.targetHost.empty()) {
                    service.address = remoteAddress;
                }
            }
        } else if (type == kDnsTypeA && rdLength == 4) {
            const std::string normalizedName = NormalizeDnsName(name);
            char addr[INET_ADDRSTRLEN] {};
            if (inet_ntop(AF_INET, packet.data() + rdataOffset, addr, sizeof(addr)) != nullptr) {
                RememberMdnsAddress(service, normalizedName, addr);
                if (preferredFamily == AF_INET && !service.targetHost.empty() && normalizedName == service.targetHost) {
                    service.address = addr;
                }
            }
        } else if (type == kDnsTypeAaaa && rdLength == 16) {
            const std::string normalizedName = NormalizeDnsName(name);
            char addr[INET6_ADDRSTRLEN] {};
            if (inet_ntop(AF_INET6, packet.data() + rdataOffset, addr, sizeof(addr)) != nullptr) {
                RememberMdnsAddress(service, normalizedName, addr);
                if (preferredFamily == AF_INET6 && !service.targetHost.empty() && normalizedName == service.targetHost) {
                    service.address = addr;
                }
            }
        }
        offset = rdataOffset + rdLength;
    }
}

std::string DiscoverAndroidQrPairingHostPortIpv4(const std::shared_ptr<QrPairingSession>& session) {
    constexpr uint16_t kDnsTypeA = 1;
    constexpr uint16_t kDnsTypePtr = 12;
    constexpr uint16_t kDnsTypeSrv = 33;
    constexpr uint16_t kDnsTypeAaaa = 28;

    UniqueFd fd(::socket(AF_INET, SOCK_DGRAM, 0));
    if (fd.get() < 0) {
        throw std::runtime_error("Failed to create mDNS discovery socket");
    }

    int on = 1;
    setsockopt(fd.get(), SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
#ifdef SO_REUSEPORT
    setsockopt(fd.get(), SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
#endif

    sockaddr_in bindAddr {};
    bindAddr.sin_family = AF_INET;
    bindAddr.sin_port = htons(5353);
    bindAddr.sin_addr.s_addr = htonl(INADDR_ANY);
    if (bind(fd.get(), reinterpret_cast<sockaddr*>(&bindAddr), sizeof(bindAddr)) != 0) {
        throw std::runtime_error("Failed to bind mDNS discovery socket");
    }

    in_addr localAddr {};
    if (inet_pton(AF_INET, session->localIp.c_str(), &localAddr) == 1) {
        setsockopt(fd.get(), IPPROTO_IP, IP_MULTICAST_IF, &localAddr, sizeof(localAddr));
    }

    ip_mreq mreq {};
    inet_pton(AF_INET, "224.0.0.251", &mreq.imr_multiaddr);
    mreq.imr_interface = localAddr;
    if (setsockopt(fd.get(), IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, sizeof(mreq)) != 0) {
        OH_LOG_WARN(LOG_APP, "QRPairing: join mDNS multicast failed errno=%{public}d", errno);
    }

    uint8_t ttl = 255;
    setsockopt(fd.get(), IPPROTO_IP, IP_MULTICAST_TTL, &ttl, sizeof(ttl));

    sockaddr_in multicast {};
    multicast.sin_family = AF_INET;
    multicast.sin_port = htons(5353);
    inet_pton(AF_INET, "224.0.0.251", &multicast.sin_addr);

    const std::string instanceName = NormalizeDnsName(session->serviceName + "." + kAdbPairingServiceType);
    MdnsPairingService service;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(kPairingAcceptTimeoutSeconds);
    int queryCount = 0;
    while (!session->stopped.load() && std::chrono::steady_clock::now() < deadline) {
        std::vector<std::pair<std::string, uint16_t>> questions {
            {kAdbPairingServiceType, kDnsTypePtr},
            {instanceName, kDnsTypeSrv}
        };
        if (!service.targetHost.empty()) {
            questions.push_back({service.targetHost, kDnsTypeA});
            questions.push_back({service.targetHost, kDnsTypeAaaa});
        }
        std::vector<uint8_t> query = BuildMdnsQuery(questions);
        sendto(fd.get(), query.data(), query.size(), 0, reinterpret_cast<sockaddr*>(&multicast), sizeof(multicast));
        ++queryCount;

        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd.get(), &readSet);
        timeval timeout {};
        timeout.tv_sec = 0;
        timeout.tv_usec = 800000;
        const int ready = select(fd.get() + 1, &readSet, nullptr, nullptr, &timeout);
        if (ready > 0 && FD_ISSET(fd.get(), &readSet)) {
            std::vector<uint8_t> packet(1500);
            sockaddr_in remote {};
            socklen_t remoteLen = sizeof(remote);
            const ssize_t received = recvfrom(fd.get(), packet.data(), packet.size(), 0,
                                              reinterpret_cast<sockaddr*>(&remote), &remoteLen);
            if (received > 0) {
                packet.resize(static_cast<size_t>(received));
                char remoteAddr[INET_ADDRSTRLEN] {};
                inet_ntop(AF_INET, &remote.sin_addr, remoteAddr, sizeof(remoteAddr));
                ParseMdnsAnswers(packet, instanceName, remoteAddr, AF_INET, service);
                if (service.port != 0 && !service.address.empty()) {
                    return FormatHostPort(service.address, service.port);
                }
            }
        } else if (ready < 0 && errno != EINTR) {
            OH_LOG_WARN(LOG_APP, "QRPairing: select mDNS discovery failed errno=%{public}d", errno);
        }
    }

    if (session->stopped.load()) {
        throw std::runtime_error("QR pairing canceled");
    }
    throw std::runtime_error("QR pairing timed out waiting for Android pairing service");
}

std::string DiscoverAndroidQrPairingHostPortIpv6(const std::shared_ptr<QrPairingSession>& session) {
    constexpr uint16_t kDnsTypeA = 1;
    constexpr uint16_t kDnsTypePtr = 12;
    constexpr uint16_t kDnsTypeSrv = 33;
    constexpr uint16_t kDnsTypeAaaa = 28;

    const uint32_t interfaceIndex = FindInterfaceIndexForAddress(session->localIp);
    if (interfaceIndex == 0) {
        throw std::runtime_error("IPv6 mDNS interface not found");
    }

    UniqueFd fd(::socket(AF_INET6, SOCK_DGRAM, 0));
    if (fd.get() < 0) {
        throw std::runtime_error("Failed to create IPv6 mDNS discovery socket");
    }

    int on = 1;
    setsockopt(fd.get(), SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
#ifdef SO_REUSEPORT
    setsockopt(fd.get(), SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
#endif
    setsockopt(fd.get(), IPPROTO_IPV6, IPV6_V6ONLY, &on, sizeof(on));

    sockaddr_in6 bindAddr {};
    bindAddr.sin6_family = AF_INET6;
    bindAddr.sin6_port = htons(5353);
    bindAddr.sin6_addr = in6addr_any;
    bindAddr.sin6_scope_id = interfaceIndex;
    if (bind(fd.get(), reinterpret_cast<sockaddr*>(&bindAddr), sizeof(bindAddr)) != 0) {
        throw std::runtime_error("Failed to bind IPv6 mDNS discovery socket");
    }

    setsockopt(fd.get(), IPPROTO_IPV6, IPV6_MULTICAST_IF, &interfaceIndex, sizeof(interfaceIndex));

    ipv6_mreq mreq {};
    inet_pton(AF_INET6, "ff02::fb", &mreq.ipv6mr_multiaddr);
    mreq.ipv6mr_interface = interfaceIndex;
    if (setsockopt(fd.get(), IPPROTO_IPV6, IPV6_JOIN_GROUP, &mreq, sizeof(mreq)) != 0) {
        OH_LOG_WARN(LOG_APP, "QRPairing: join IPv6 mDNS multicast failed errno=%{public}d", errno);
    }

    int hops = 255;
    setsockopt(fd.get(), IPPROTO_IPV6, IPV6_MULTICAST_HOPS, &hops, sizeof(hops));

    sockaddr_in6 multicast {};
    multicast.sin6_family = AF_INET6;
    multicast.sin6_port = htons(5353);
    multicast.sin6_scope_id = interfaceIndex;
    inet_pton(AF_INET6, "ff02::fb", &multicast.sin6_addr);

    const std::string instanceName = NormalizeDnsName(session->serviceName + "." + kAdbPairingServiceType);
    MdnsPairingService service;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(kPairingAcceptTimeoutSeconds);
    while (!session->stopped.load() && std::chrono::steady_clock::now() < deadline) {
        std::vector<std::pair<std::string, uint16_t>> questions {
            {kAdbPairingServiceType, kDnsTypePtr},
            {instanceName, kDnsTypeSrv}
        };
        if (!service.targetHost.empty()) {
            questions.push_back({service.targetHost, kDnsTypeA});
            questions.push_back({service.targetHost, kDnsTypeAaaa});
        }
        std::vector<uint8_t> query = BuildMdnsQuery(questions);
        sendto(fd.get(), query.data(), query.size(), 0, reinterpret_cast<sockaddr*>(&multicast), sizeof(multicast));

        fd_set readSet;
        FD_ZERO(&readSet);
        FD_SET(fd.get(), &readSet);
        timeval timeout {};
        timeout.tv_sec = 0;
        timeout.tv_usec = 800000;
        const int ready = select(fd.get() + 1, &readSet, nullptr, nullptr, &timeout);
        if (ready > 0 && FD_ISSET(fd.get(), &readSet)) {
            std::vector<uint8_t> packet(1500);
            sockaddr_in6 remote {};
            socklen_t remoteLen = sizeof(remote);
            const ssize_t received = recvfrom(fd.get(), packet.data(), packet.size(), 0,
                                              reinterpret_cast<sockaddr*>(&remote), &remoteLen);
            if (received > 0) {
                packet.resize(static_cast<size_t>(received));
                char remoteAddr[INET6_ADDRSTRLEN] {};
                inet_ntop(AF_INET6, &remote.sin6_addr, remoteAddr, sizeof(remoteAddr));
                ParseMdnsAnswers(packet, instanceName, remoteAddr, AF_INET6, service);
                if (service.port != 0 && !service.address.empty()) {
                    return FormatScopedIpv6HostPort(service.address, service.port, interfaceIndex);
                }
            }
        } else if (ready < 0 && errno != EINTR) {
            OH_LOG_WARN(LOG_APP, "QRPairing: select IPv6 mDNS discovery failed errno=%{public}d", errno);
        }
    }

    if (session->stopped.load()) {
        throw std::runtime_error("QR pairing canceled");
    }
    throw std::runtime_error("QR pairing timed out waiting for Android pairing service");
}

std::string DiscoverAndroidQrPairingHostPort(const std::shared_ptr<QrPairingSession>& session) {
    if (IsIpv6Literal(session->localIp)) {
        return DiscoverAndroidQrPairingHostPortIpv6(session);
    }
    return DiscoverAndroidQrPairingHostPortIpv4(session);
}

void RunQrPairingSession(const std::shared_ptr<QrPairingSession>& session) {
    try {
        LogQrSession(*session, "QR discovery worker started");
        const std::string hostPort = DiscoverAndroidQrPairingHostPort(session);
        ThrowIfCanceled(&session->stopped);
        OH_LOG_INFO(LOG_APP,
                    "QRPairing: Android pairing service resolved session=%{public}lld hostPort=%{public}s",
                    static_cast<long long>(session->sessionId), hostPort.c_str());
        const std::string guid = AdbPair(hostPort, session->pairingCode, session->publicKeyPath,
                                         session->privateKeyPath, &session->stopped);
        ThrowIfCanceled(&session->stopped);
        std::string pairedHost;
        std::string pairingPort;
        ParseHostPort(hostPort, pairedHost, pairingPort);
        OH_LOG_INFO(LOG_APP,
                    "QRPairing: Android QR pairing succeeded session=%{public}lld guid=%{public}s pairedHost=%{public}s",
                    static_cast<long long>(session->sessionId), guid.c_str(), pairedHost.c_str());
        CompleteQrPairingSession(session, guid, pairedHost, "", "");
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "QRPairing: Android QR pairing failed session=%{public}lld error=%{public}s",
                     static_cast<long long>(session->sessionId), e.what());
        CompleteQrPairingSession(session, "", "", "", e.what());
    }
}

}  // namespace

std::string AdbPair(const std::string& hostPort, const std::string& pairingCode, const std::string& publicKeyPath,
                    const std::string& privateKeyPath, const std::atomic_bool* canceled) {
    ThrowIfCanceled(canceled);
    if (pairingCode.empty()) {
        throw std::runtime_error("Pairing code is empty");
    }

    std::string host;
    std::string port;
    ParseHostPort(hostPort, host, port);

    const std::string pubKey = ReadPublicKeyString(publicKeyPath);
    if (pubKey.empty()) {
        throw std::runtime_error("ADB public key is empty");
    }

    const std::string privateKeyPem = ReadFileToString(privateKeyPath);
    bssl::UniquePtr<EVP_PKEY> privateKey = LoadPrivateKey(privateKeyPem);
    if (!privateKey) {
        throw std::runtime_error("Failed to load ADB private key");
    }

    const std::string certPem = GenerateCertificatePem(privateKey.get());
    const std::string normalizedPrivateKeyPem = PrivateKeyToPem(privateKey.get());

    PeerInfo myInfo {};
    myInfo.type = ADB_RSA_PUB_KEY;
    if (pubKey.size() > sizeof(myInfo.data) - 1) {
        throw std::runtime_error("ADB public key is too large for pairing peer info");
    }
    std::memcpy(myInfo.data, pubKey.data(), pubKey.size());

    UniqueFd fd = ConnectTcp(host, port, canceled);
    ThrowIfCanceled(canceled);
    std::unique_ptr<TlsConnection> tls = TlsConnection::Create(TlsConnection::Role::Client, certPem,
                                                               normalizedPrivateKeyPem, fd.get());
    if (!tls) {
        throw std::runtime_error("Failed to create pairing TLS connection");
    }

    tls->SetCertVerifyCallback([](X509_STORE_CTX*) { return 1; });
    ThrowIfCanceled(canceled);
    if (tls->DoHandshake() != TlsConnection::TlsError::Success) {
        throw std::runtime_error("TLS handshake failed during pairing");
    }
    ThrowIfCanceled(canceled);

    std::vector<uint8_t> exported = tls->ExportKeyingMaterial(kExportedKeySize);
    if (exported.empty()) {
        throw std::runtime_error("Failed to export TLS key material");
    }

    std::vector<uint8_t> password(pairingCode.begin(), pairingCode.end());
    password.insert(password.end(), exported.begin(), exported.end());
    PairingAuthPtr auth = CreatePairingAuth(password);

    const uint32_t msgSize = static_cast<uint32_t>(pairing_auth_msg_size(auth.get()));
    std::vector<uint8_t> myMsg(msgSize);
    pairing_auth_get_spake2_msg(auth.get(), myMsg.data());
    WriteHeader(*tls, kPacketTypeSpake2Msg,
                std::string_view(reinterpret_cast<const char*>(myMsg.data()), myMsg.size()));

    PairingPacketHeader header = ReadHeader(*tls);
    if (header.type != kPacketTypeSpake2Msg) {
        throw std::runtime_error("Unexpected pairing packet type while waiting for SPAKE2 message");
    }

    std::vector<uint8_t> peerMsg = tls->ReadFully(header.payload);
    if (peerMsg.empty() || !pairing_auth_init_cipher(auth.get(), peerMsg.data(), peerMsg.size())) {
        throw std::runtime_error("Failed to initialize pairing cipher");
    }

    std::vector<uint8_t> peerInfoBytes(reinterpret_cast<const uint8_t*>(&myInfo),
                                       reinterpret_cast<const uint8_t*>(&myInfo) + sizeof(myInfo));
    std::vector<uint8_t> encrypted(pairing_auth_safe_encrypted_size(auth.get(), peerInfoBytes.size()));
    size_t encryptedSize = 0;
    if (!pairing_auth_encrypt(auth.get(), peerInfoBytes.data(), peerInfoBytes.size(), encrypted.data(), &encryptedSize)) {
        throw std::runtime_error("Failed to encrypt pairing peer info");
    }
    encrypted.resize(encryptedSize);
    WriteHeader(*tls, kPacketTypePeerInfo,
                std::string_view(reinterpret_cast<const char*>(encrypted.data()), encrypted.size()));

    header = ReadHeader(*tls);
    if (header.type != kPacketTypePeerInfo) {
        throw std::runtime_error("Unexpected pairing packet type while waiting for peer info");
    }

    std::vector<uint8_t> encryptedPeerInfo = tls->ReadFully(header.payload);
    if (encryptedPeerInfo.empty()) {
        throw std::runtime_error("Failed to read encrypted peer info");
    }

    std::vector<uint8_t> decrypted(pairing_auth_safe_decrypted_size(auth.get(), encryptedPeerInfo.data(),
                                                                    encryptedPeerInfo.size()));
    size_t decryptedSize = 0;
    if (decrypted.empty() ||
        !pairing_auth_decrypt(auth.get(), encryptedPeerInfo.data(), encryptedPeerInfo.size(), decrypted.data(),
                              &decryptedSize)) {
        throw std::runtime_error("Failed to decrypt peer info");
    }
    decrypted.resize(decryptedSize);

    if (decrypted.size() != sizeof(PeerInfo)) {
        throw std::runtime_error("Unexpected peer info size");
    }

    PeerInfo theirInfo {};
    std::memcpy(&theirInfo, decrypted.data(), sizeof(theirInfo));
    if (theirInfo.type != ADB_DEVICE_GUID) {
        throw std::runtime_error("Pairing succeeded but peer did not return a device guid");
    }

    const std::string guid = PeerInfoToString(theirInfo);
    if (guid.empty()) {
        throw std::runtime_error("Pairing succeeded but device guid is empty");
    }

    ThrowIfCanceled(canceled);
    return guid;
}

QrPairingSessionInfo StartQrPairingSession(const std::string& publicKeyPath, const std::string& privateKeyPath,
                                           const std::string& localIp) {
    if (publicKeyPath.empty() || privateKeyPath.empty()) {
        throw std::runtime_error("QR pairing key paths are empty");
    }
    if (localIp.empty()) {
        throw std::runtime_error("QR pairing local ip is empty");
    }

    auto session = std::make_shared<QrPairingSession>();
    session->publicKeyPath = publicKeyPath;
    session->privateKeyPath = privateKeyPath;
    session->pairingCode = GeneratePairingCode();
    session->serviceName = GenerateServiceName();
    session->localIp = localIp;
    {
        std::lock_guard<std::mutex> lock(gQrPairingMutex);
        session->sessionId = gNextQrPairingSessionId++;
        gQrPairingSessions[session->sessionId] = session;
    }

    LogQrSession(*session, "created");
    session->worker = std::thread([session]() {
        RunQrPairingSession(session);
    });

    return {
        session->sessionId,
        session->pairingCode,
        session->serviceName
    };
}

QrPairingResult WaitQrPairingSession(int64_t sessionId) {
    std::shared_ptr<QrPairingSession> session;
    {
        std::lock_guard<std::mutex> lock(gQrPairingMutex);
        auto it = gQrPairingSessions.find(sessionId);
        if (it == gQrPairingSessions.end()) {
            throw std::runtime_error("QR pairing session not found");
        }
        session = it->second;
    }

    LogQrSession(*session, "wait called");
    {
        std::unique_lock<std::mutex> lock(session->mutex);
        session->cv.wait(lock, [&session]() { return session->completed; });
    }
    LogQrSession(*session, "wait completed");

    {
        std::lock_guard<std::mutex> lock(session->workerMutex);
        if (session->worker.joinable()) {
            session->worker.join();
        }
    }

    {
        std::lock_guard<std::mutex> lock(gQrPairingMutex);
        gQrPairingSessions.erase(sessionId);
    }

    if (!session->error.empty()) {
        const bool expectedStop = session->error == "QR pairing canceled" ||
            session->error.find("timed out waiting for Android") != std::string::npos;
        if (expectedStop) {
            OH_LOG_WARN(LOG_APP, "QRPairing: wait returning non-success session=%{public}lld error=%{public}s",
                        static_cast<long long>(session->sessionId), session->error.c_str());
        } else {
            OH_LOG_ERROR(LOG_APP, "QRPairing: wait returning error session=%{public}lld error=%{public}s",
                         static_cast<long long>(session->sessionId), session->error.c_str());
        }
        throw std::runtime_error(session->error);
    }
    OH_LOG_INFO(LOG_APP,
                "QRPairing: wait returning success session=%{public}lld guid=%{public}s pairedHost=%{public}s hostPort=%{public}s",
                static_cast<long long>(session->sessionId), session->resultGuid.c_str(),
                session->resultPairedHost.c_str(), session->resultHostPort.c_str());
    return {session->resultGuid, session->resultPairedHost, session->resultHostPort};
}

void StopQrPairingSession(int64_t sessionId) {
    std::shared_ptr<QrPairingSession> session;
    {
        std::lock_guard<std::mutex> lock(gQrPairingMutex);
        auto it = gQrPairingSessions.find(sessionId);
        if (it == gQrPairingSessions.end()) {
            return;
        }
        session = it->second;
        gQrPairingSessions.erase(it);
    }

    LogQrSession(*session, "stop called");
    session->stopped.store(true);

    {
        std::lock_guard<std::mutex> lock(session->mutex);
        if (!session->completed) {
            session->completed = true;
            session->error = "QR pairing canceled";
        }
        session->cv.notify_all();
    }

    {
        std::unique_lock<std::mutex> lock(session->workerMutex);
        if (session->worker.joinable()) {
            session->worker.join();
        }
    }
    LogQrSession(*session, "stopped");
}

}  // namespace scrcpy::pairing
