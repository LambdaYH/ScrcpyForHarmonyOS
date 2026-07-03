#include "adb/pairing/PairingAuth.h"

#include <cstring>
#include <memory>
#include <vector>

#include <openssl/aead.h>
#include <openssl/curve25519.h>
#include <openssl/evp.h>
#include <openssl/hkdf.h>
#include <openssl/mem.h>

#include <hilog/log.h>

#ifndef LOG_TAG
#define LOG_TAG "AdbPairingAuth"
#endif

namespace {
constexpr uint8_t kClientName[] = "adb pair client";
constexpr uint8_t kServerName[] = "adb pair server";
constexpr size_t kHkdfKeyLength = 16;

class Aes128Gcm {
public:
    Aes128Gcm(const uint8_t* keyMaterial, size_t keyMaterialLen) {
        uint8_t key[kHkdfKeyLength];
        uint8_t info[] = "adb pairing_auth aes-128-gcm key";
        if (HKDF(key, sizeof(key), EVP_sha256(), keyMaterial, keyMaterialLen, nullptr, 0, info,
                 sizeof(info) - 1) != 1) {
            OH_LOG_ERROR(LOG_APP, "HKDF failed");
            return;
        }

        if (!EVP_AEAD_CTX_init(context_.get(), EVP_aead_aes_128_gcm(), key, sizeof(key),
                               EVP_AEAD_DEFAULT_TAG_LENGTH, nullptr)) {
            OH_LOG_ERROR(LOG_APP, "EVP_AEAD_CTX_init failed");
        }
    }

    bool Encrypt(const uint8_t* in, size_t inLen, uint8_t* out, size_t outLen, size_t& written) {
        std::vector<uint8_t> nonce(EVP_AEAD_nonce_length(EVP_AEAD_CTX_aead(context_.get())), 0);
        std::memcpy(nonce.data(), &encSequence_, sizeof(encSequence_));
        written = 0;
        if (!EVP_AEAD_CTX_seal(context_.get(), out, &written, outLen, nonce.data(), nonce.size(), in, inLen,
                               nullptr, 0)) {
            return false;
        }
        ++encSequence_;
        return true;
    }

    bool Decrypt(const uint8_t* in, size_t inLen, uint8_t* out, size_t outLen, size_t& written) {
        std::vector<uint8_t> nonce(EVP_AEAD_nonce_length(EVP_AEAD_CTX_aead(context_.get())), 0);
        std::memcpy(nonce.data(), &decSequence_, sizeof(decSequence_));
        written = 0;
        if (!EVP_AEAD_CTX_open(context_.get(), out, &written, outLen, nonce.data(), nonce.size(), in, inLen,
                               nullptr, 0)) {
            return false;
        }
        ++decSequence_;
        return true;
    }

    size_t EncryptedSize(size_t size) const {
        return size + EVP_AEAD_max_overhead(EVP_AEAD_CTX_aead(context_.get()));
    }

    size_t DecryptedSize(size_t size) const {
        return size;
    }

private:
    bssl::ScopedEVP_AEAD_CTX context_;
    uint64_t decSequence_ = 0;
    uint64_t encSequence_ = 0;
};
}  // namespace

struct PairingAuthCtx {
    explicit PairingAuthCtx(const std::vector<uint8_t>& password) {
        spake2Ctx.reset(SPAKE2_CTX_new(spake2_role_alice, kClientName, sizeof(kClientName),
                                       kServerName, sizeof(kServerName)));
        if (!spake2Ctx) {
            OH_LOG_ERROR(LOG_APP, "Unable to create SPAKE2 context");
            return;
        }

        size_t keySize = 0;
        uint8_t key[SPAKE2_MAX_MSG_SIZE];
        if (SPAKE2_generate_msg(spake2Ctx.get(), key, &keySize, SPAKE2_MAX_MSG_SIZE, password.data(), password.size()) !=
                1 ||
            keySize == 0) {
            OH_LOG_ERROR(LOG_APP, "Unable to generate SPAKE2 message");
            return;
        }

        msg.assign(key, key + keySize);
    }

    bool InitCipher(const std::vector<uint8_t>& peerMsg) {
        if (peerMsg.empty() || cipher) {
            return false;
        }
        if (peerMsg.size() > SPAKE2_MAX_MSG_SIZE) {
            return false;
        }

        size_t keyMaterialLen = 0;
        uint8_t keyMaterial[SPAKE2_MAX_KEY_SIZE];
        if (SPAKE2_process_msg(spake2Ctx.get(), keyMaterial, &keyMaterialLen, sizeof(keyMaterial), peerMsg.data(),
                               peerMsg.size()) != 1) {
            return false;
        }

        cipher = std::make_unique<Aes128Gcm>(keyMaterial, keyMaterialLen);
        return true;
    }

    std::vector<uint8_t> Encrypt(const std::vector<uint8_t>& data) {
        if (!cipher || data.empty()) {
            return {};
        }
        std::vector<uint8_t> encrypted(cipher->EncryptedSize(data.size()));
        size_t outSize = 0;
        if (!cipher->Encrypt(data.data(), data.size(), encrypted.data(), encrypted.size(), outSize) || outSize == 0) {
            return {};
        }
        encrypted.resize(outSize);
        return encrypted;
    }

    std::vector<uint8_t> Decrypt(const std::vector<uint8_t>& data) {
        if (!cipher || data.empty()) {
            return {};
        }
        std::vector<uint8_t> decrypted(cipher->DecryptedSize(data.size()));
        size_t outSize = 0;
        if (!cipher->Decrypt(data.data(), data.size(), decrypted.data(), decrypted.size(), outSize) || outSize == 0) {
            return {};
        }
        decrypted.resize(outSize);
        return decrypted;
    }

    size_t SafeEncryptedSize(size_t len) const {
        return cipher ? cipher->EncryptedSize(len) : 0;
    }

    size_t SafeDecryptedSize(size_t len) const {
        return cipher ? cipher->DecryptedSize(len) : 0;
    }

    std::vector<uint8_t> msg;
    bssl::UniquePtr<SPAKE2_CTX> spake2Ctx;
    std::unique_ptr<Aes128Gcm> cipher;
};

PairingAuthCtx* pairing_auth_client_new(const uint8_t* pswd, size_t len) {
    if (!pswd || len == 0) {
        return nullptr;
    }
    std::vector<uint8_t> password(pswd, pswd + len);
    auto* ctx = new PairingAuthCtx(password);
    if (ctx->msg.empty()) {
        delete ctx;
        return nullptr;
    }
    return ctx;
}

void pairing_auth_destroy(PairingAuthCtx* ctx) {
    delete ctx;
}

size_t pairing_auth_msg_size(PairingAuthCtx* ctx) {
    return ctx ? ctx->msg.size() : 0;
}

void pairing_auth_get_spake2_msg(PairingAuthCtx* ctx, uint8_t* out_buf) {
    if (!ctx || !out_buf || ctx->msg.empty()) {
        return;
    }
    std::memcpy(out_buf, ctx->msg.data(), ctx->msg.size());
}

bool pairing_auth_init_cipher(PairingAuthCtx* ctx, const uint8_t* their_msg, size_t msg_len) {
    if (!ctx || !their_msg || msg_len == 0) {
        return false;
    }
    std::vector<uint8_t> peerMsg(their_msg, their_msg + msg_len);
    return ctx->InitCipher(peerMsg);
}

size_t pairing_auth_safe_encrypted_size(PairingAuthCtx* ctx, size_t len) {
    return ctx ? ctx->SafeEncryptedSize(len) : 0;
}

bool pairing_auth_encrypt(PairingAuthCtx* ctx, const uint8_t* inbuf, size_t inlen, uint8_t* outbuf, size_t* outlen) {
    if (!ctx || !inbuf || inlen == 0 || !outbuf || !outlen) {
        return false;
    }
    std::vector<uint8_t> in(inbuf, inbuf + inlen);
    std::vector<uint8_t> out = ctx->Encrypt(in);
    if (out.empty()) {
        return false;
    }
    std::memcpy(outbuf, out.data(), out.size());
    *outlen = out.size();
    return true;
}

size_t pairing_auth_safe_decrypted_size(PairingAuthCtx* ctx, const uint8_t* buf, size_t len) {
    if (!ctx || !buf || len == 0) {
        return 0;
    }
    return ctx->SafeDecryptedSize(len);
}

bool pairing_auth_decrypt(PairingAuthCtx* ctx, const uint8_t* inbuf, size_t inlen, uint8_t* outbuf, size_t* outlen) {
    if (!ctx || !inbuf || inlen == 0 || !outbuf || !outlen) {
        return false;
    }
    std::vector<uint8_t> in(inbuf, inbuf + inlen);
    std::vector<uint8_t> out = ctx->Decrypt(in);
    if (out.empty()) {
        return false;
    }
    std::memcpy(outbuf, out.data(), out.size());
    *outlen = out.size();
    return true;
}
