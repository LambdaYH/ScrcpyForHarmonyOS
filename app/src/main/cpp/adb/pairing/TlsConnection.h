#pragma once

#include <cstddef>
#include <cstdint>

#include <functional>
#include <memory>
#include <string_view>
#include <vector>

#include <openssl/ssl.h>
#include <openssl/x509.h>

namespace scrcpy::pairing {

class TlsConnection {
public:
    enum class Role {
        Client,
        Server,
    };

    enum class TlsError : uint8_t {
        Success = 0,
        CertificateRejected,
        PeerRejectedCertificate,
        UnknownFailure,
    };

    using CertVerifyCb = std::function<int(X509_STORE_CTX*)>;

    virtual ~TlsConnection() = default;

    virtual void SetCertVerifyCallback(CertVerifyCb cb) = 0;
    virtual std::vector<uint8_t> ExportKeyingMaterial(size_t length) = 0;
    virtual TlsError DoHandshake() = 0;
    virtual std::vector<uint8_t> ReadFully(size_t size) = 0;
    virtual int ReadSome(uint8_t* buffer, size_t size) = 0;
    virtual size_t PendingBytes() const = 0;
    virtual bool WriteFully(std::string_view data) = 0;

    static std::unique_ptr<TlsConnection> Create(Role role, std::string_view cert, std::string_view privKey, int fd);
};

}  // namespace scrcpy::pairing
