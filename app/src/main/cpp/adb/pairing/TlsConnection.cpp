#include "adb/pairing/TlsConnection.h"

#include <algorithm>
#include <climits>

#include <openssl/err.h>
#include <openssl/pem.h>

#include <hilog/log.h>

#ifndef LOG_TAG
#define LOG_TAG "AdbPairTls"
#endif

namespace scrcpy::pairing {
namespace {

constexpr char kExportedKeyLabel[] = "adb-label";

class TlsConnectionImpl : public TlsConnection {
public:
    TlsConnectionImpl(Role role, std::string_view cert, std::string_view privKey, int fd) : role_(role), fd_(fd) {
        cert_ = BufferFromPEM(cert);
        privKey_ = EvpPkeyFromPEM(privKey);
    }

    ~TlsConnectionImpl() override = default;

    void SetCertVerifyCallback(CertVerifyCb cb) override {
        certVerifyCb_ = std::move(cb);
    }

    std::vector<uint8_t> ExportKeyingMaterial(size_t length) override {
        if (!ssl_) {
            return {};
        }
        std::vector<uint8_t> out(length);
        if (SSL_export_keying_material(ssl_.get(), out.data(), out.size(), kExportedKeyLabel,
                                       sizeof(kExportedKeyLabel), nullptr, 0, false) == 0) {
            return {};
        }
        return out;
    }

    TlsError DoHandshake() override {
        if (!cert_ || !privKey_) {
            return TlsError::UnknownFailure;
        }

        sslCtx_.reset(SSL_CTX_new(TLS_method()));
        if (!sslCtx_ || !SSL_CTX_set_min_proto_version(sslCtx_.get(), TLS1_3_VERSION) ||
            !SSL_CTX_set_max_proto_version(sslCtx_.get(), TLS1_3_VERSION)) {
            return TlsError::UnknownFailure;
        }

        if (certVerifyCb_) {
            SSL_CTX_set_cert_verify_callback(sslCtx_.get(), SSLSetCertVerifyCb, this);
        }

        std::vector<CRYPTO_BUFFER*> certChain = {cert_.get()};
        if (!SSL_CTX_set_chain_and_key(sslCtx_.get(), certChain.data(), certChain.size(), privKey_.get(), nullptr)) {
            return TlsError::UnknownFailure;
        }

        SSL_CTX_set_verify(sslCtx_.get(), SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nullptr);

        ssl_.reset(SSL_new(sslCtx_.get()));
        if (!ssl_ || !SSL_set_fd(ssl_.get(), fd_)) {
            return TlsError::UnknownFailure;
        }

        if (role_ == Role::Server) {
            SSL_set_accept_state(ssl_.get());
        } else {
            SSL_set_connect_state(ssl_.get());
        }
        if (SSL_do_handshake(ssl_.get()) != 1) {
            auto sslErr = ERR_get_error();
            Invalidate();
            return GetFailureReason(sslErr);
        }

        return TlsError::Success;
    }

    std::vector<uint8_t> ReadFully(size_t size) override {
        std::vector<uint8_t> buffer(size);
        size_t offset = 0;
        while (offset < size) {
            int bytesRead = ReadSome(buffer.data() + offset, size - offset);
            if (bytesRead <= 0) {
                return {};
            }
            offset += static_cast<size_t>(bytesRead);
        }
        return buffer;
    }

    int ReadSome(uint8_t* buffer, size_t size) override {
        if (!ssl_ || !buffer || size == 0) {
            return -1;
        }
        return SSL_read(ssl_.get(), buffer, static_cast<int>(std::min<size_t>(INT_MAX, size)));
    }

    size_t PendingBytes() const override {
        if (!ssl_) {
            return 0;
        }
        return static_cast<size_t>(SSL_pending(ssl_.get()));
    }

    bool WriteFully(std::string_view data) override {
        while (!data.empty()) {
            int bytesOut = SSL_write(ssl_.get(), data.data(), static_cast<int>(std::min<size_t>(INT_MAX, data.size())));
            if (bytesOut <= 0) {
                return false;
            }
            data.remove_prefix(static_cast<size_t>(bytesOut));
        }
        return true;
    }

private:
    static bssl::UniquePtr<EVP_PKEY> EvpPkeyFromPEM(std::string_view pem) {
        bssl::UniquePtr<BIO> bio(BIO_new_mem_buf(pem.data(), static_cast<int>(pem.size())));
        return bssl::UniquePtr<EVP_PKEY>(PEM_read_bio_PrivateKey(bio.get(), nullptr, nullptr, nullptr));
    }

    static bssl::UniquePtr<CRYPTO_BUFFER> BufferFromPEM(std::string_view pem) {
        bssl::UniquePtr<BIO> bio(BIO_new_mem_buf(pem.data(), static_cast<int>(pem.size())));
        char* name = nullptr;
        char* header = nullptr;
        uint8_t* data = nullptr;
        long dataLen = 0;
        if (!PEM_read_bio(bio.get(), &name, &header, &data, &dataLen)) {
            return nullptr;
        }
        OPENSSL_free(name);
        OPENSSL_free(header);
        auto ret = bssl::UniquePtr<CRYPTO_BUFFER>(CRYPTO_BUFFER_new(data, dataLen, nullptr));
        OPENSSL_free(data);
        return ret;
    }

    static int SSLSetCertVerifyCb(X509_STORE_CTX* ctx, void* opaque) {
        auto* self = static_cast<TlsConnectionImpl*>(opaque);
        return self->certVerifyCb_ ? self->certVerifyCb_(ctx) : 0;
    }

    static TlsError GetFailureReason(unsigned long err) {
        switch (ERR_GET_REASON(err)) {
            case SSL_R_SSLV3_ALERT_BAD_CERTIFICATE:
            case SSL_R_SSLV3_ALERT_UNSUPPORTED_CERTIFICATE:
            case SSL_R_SSLV3_ALERT_CERTIFICATE_REVOKED:
            case SSL_R_SSLV3_ALERT_CERTIFICATE_EXPIRED:
            case SSL_R_SSLV3_ALERT_CERTIFICATE_UNKNOWN:
            case SSL_R_TLSV1_ALERT_ACCESS_DENIED:
            case SSL_R_TLSV1_ALERT_UNKNOWN_CA:
            case SSL_R_TLSV1_CERTIFICATE_REQUIRED:
                return TlsError::PeerRejectedCertificate;
            case SSL_R_CERTIFICATE_VERIFY_FAILED:
                return TlsError::CertificateRejected;
            default:
                return TlsError::UnknownFailure;
        }
    }

    void Invalidate() {
        ssl_.reset();
        sslCtx_.reset();
    }

    Role role_;
    int fd_;
    CertVerifyCb certVerifyCb_;
    bssl::UniquePtr<EVP_PKEY> privKey_;
    bssl::UniquePtr<CRYPTO_BUFFER> cert_;
    bssl::UniquePtr<SSL_CTX> sslCtx_;
    bssl::UniquePtr<SSL> ssl_;
};

}  // namespace

std::unique_ptr<TlsConnection> TlsConnection::Create(Role role, std::string_view cert, std::string_view privKey,
                                                     int fd) {
    if (cert.empty() || privKey.empty() || fd < 0) {
        return nullptr;
    }
    return std::make_unique<TlsConnectionImpl>(role, cert, privKey, fd);
}

}  // namespace scrcpy::pairing
