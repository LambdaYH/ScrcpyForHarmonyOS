// AdbKeyPair - RSA密钥对管理
// 使用 CryptoArchitectureKit 进行RSA密钥生成和签名
#ifndef ADB_KEY_PAIR_H
#define ADB_KEY_PAIR_H

#include <cstdint>
#include <string>
#include <vector>
#include <CryptoArchitectureKit/crypto_common.h>
#include <CryptoArchitectureKit/crypto_asym_key.h>

class AdbKeyPair {
public:
    static constexpr int KEY_LENGTH_BITS = 2048;
    static constexpr int KEY_LENGTH_BYTES = KEY_LENGTH_BITS / 8;
    static constexpr int KEY_LENGTH_WORDS = KEY_LENGTH_BYTES / 4;

    // SIGNATURE_PADDING - 完全按照原版的PKCS1 v1.5 SHA1 padding
    static const uint8_t SIGNATURE_PADDING[];
    static constexpr int SIGNATURE_PADDING_LEN = 236; // 256 - 20(SHA1 token) = 236 for RSA2048

    AdbKeyPair();
    ~AdbKeyPair();

    // 从文件读取密钥对
    static AdbKeyPair read(const std::string& publicKeyPath, const std::string& privateKeyPath);

    // 生成新密钥对并保存到文件
    static void generate(const std::string& publicKeyPath, const std::string& privateKeyPath);

    // 使用私钥签名payload（ADB认证用）
    std::vector<uint8_t> signPayload(const uint8_t* payload, size_t payloadLen);

    // 获取公钥字节（用于ADB AUTH_TYPE_RSA_PUBLIC）
    const std::vector<uint8_t>& getPublicKeyBytes() const { return publicKeyBytes_; }
    const std::string& getPrivateKeyPem() const { return privateKeyPem_; }

private:
    std::vector<uint8_t> publicKeyBytes_;  // ADB格式的公钥字符串
    std::string privateKeyPem_;
    OH_CryptoKeyPair* keyPair_ = nullptr;  // CryptoArchitectureKit密钥对

    // 将RSA公钥转换为ADB格式（524字节）
    static std::vector<uint8_t> convertRsaPublicKeyToAdbFormat(OH_CryptoPubKey* pubKey);

    // 大整数模逆运算 (用于ADB格式转换)
    // 使用向量表示大整数，小端序uint32_t数组
    struct BigUint {
        std::vector<uint32_t> words;
        BigUint() {}
        BigUint(uint64_t val) : words({static_cast<uint32_t>(val), static_cast<uint32_t>(val >> 32)}) {
            while (words.size() > 1 && words.back() == 0) words.pop_back();
        }
        static BigUint fromBytes(const uint8_t* data, size_t len); // big-endian bytes
        BigUint operator%(const BigUint& m) const;
        BigUint operator*(const BigUint& b) const;
        BigUint operator/(const BigUint& b) const;
        BigUint operator-(const BigUint& b) const;
        BigUint operator+(const BigUint& b) const;
        bool operator>(const BigUint& b) const;
        bool operator==(const BigUint& b) const;
        bool operator>=(const BigUint& b) const;
        uint32_t toU32() const { return words.empty() ? 0 : words[0]; }
    };
    static BigUint modInverse(const BigUint& a, const BigUint& m);
};

#endif // ADB_KEY_PAIR_H
