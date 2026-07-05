// AdbKeyPair - RSA密钥对管理
// 使用 CryptoArchitectureKit 进行RSA密钥生成和签名
#include "adb/crypto/AdbKeyPair.h"
#include "adb/crypto/AdbBase64.h"
#include <CryptoArchitectureKit/crypto_asym_cipher.h>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>
#include <algorithm>
#include <hilog/log.h>

#undef LOG_TAG
#define LOG_TAG "AdbKeyPair"

// SIGNATURE_PADDING - PKCS#1 v1.5 SHA-1 padding for RSA2048 (exactly 236 bytes)
// Structure: 0x00, 0x01, [218 x 0xFF], 0x00, [15-byte DigestInfo]
// Total: 2 + 218 + 1 + 15 = 236 bytes. Combined with 20-byte SHA1 token = 256 = RSA2048 key size
const uint8_t AdbKeyPair::SIGNATURE_PADDING[] = {
    0x00, 0x01,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 16
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 32
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 48
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 64
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 80
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 96
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 112
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 128
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 144
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 160
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 176
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 192
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, // 208
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,                                     // 218
    0x00,
    0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00, 0x04, 0x14
};
static_assert(sizeof(AdbKeyPair::SIGNATURE_PADDING) == AdbKeyPair::SIGNATURE_PADDING_LEN,
              "SIGNATURE_PADDING must be exactly 236 bytes for RSA2048");

AdbKeyPair::AdbKeyPair() {}

AdbKeyPair::~AdbKeyPair() {
    if (keyPair_) {
        OH_CryptoKeyPair_Destroy(keyPair_);
        keyPair_ = nullptr;
    }
}

// ==================== BigUint implementation ====================

AdbKeyPair::BigUint AdbKeyPair::BigUint::fromBytes(const uint8_t* data, size_t len) {
    BigUint result;
    // data is big-endian, convert to little-endian uint32_t words
    size_t wordCount = (len + 3) / 4;
    result.words.resize(wordCount, 0);

    for (size_t i = 0; i < len; i++) {
        size_t bytePos = len - 1 - i; // position from LSB
        size_t wordIdx = bytePos / 4;
        // 因为是大端输入，data[i]是最高位
        size_t srcIdx = len - 1 - i;
        wordIdx = i / 4;
        int shift = (i % 4) * 8;
        result.words[wordIdx] |= static_cast<uint32_t>(data[srcIdx]) << shift;
    }

    while (result.words.size() > 1 && result.words.back() == 0) result.words.pop_back();
    return result;
}

bool AdbKeyPair::BigUint::operator>(const BigUint& b) const {
    if (words.size() != b.words.size()) return words.size() > b.words.size();
    for (int i = static_cast<int>(words.size()) - 1; i >= 0; i--) {
        if (words[i] != b.words[i]) return words[i] > b.words[i];
    }
    return false;
}

bool AdbKeyPair::BigUint::operator==(const BigUint& b) const {
    if (words.size() != b.words.size()) return false;
    for (size_t i = 0; i < words.size(); i++) {
        if (words[i] != b.words[i]) return false;
    }
    return true;
}

bool AdbKeyPair::BigUint::operator>=(const BigUint& b) const {
    return (*this > b) || (*this == b);
}

AdbKeyPair::BigUint AdbKeyPair::BigUint::operator+(const BigUint& b) const {
    BigUint result;
    size_t maxLen = std::max(words.size(), b.words.size());
    result.words.resize(maxLen + 1, 0);
    uint64_t carry = 0;
    for (size_t i = 0; i < maxLen || carry; i++) {
        uint64_t sum = carry;
        if (i < words.size()) sum += words[i];
        if (i < b.words.size()) sum += b.words[i];
        if (i >= result.words.size()) result.words.push_back(0);
        result.words[i] = static_cast<uint32_t>(sum);
        carry = sum >> 32;
    }
    while (result.words.size() > 1 && result.words.back() == 0) result.words.pop_back();
    return result;
}

AdbKeyPair::BigUint AdbKeyPair::BigUint::operator-(const BigUint& b) const {
    BigUint result;
    result.words.resize(words.size(), 0);
    int64_t borrow = 0;
    for (size_t i = 0; i < words.size(); i++) {
        int64_t diff = static_cast<int64_t>(words[i]) - borrow;
        if (i < b.words.size()) diff -= static_cast<int64_t>(b.words[i]);
        if (diff < 0) {
            diff += (1LL << 32);
            borrow = 1;
        } else {
            borrow = 0;
        }
        result.words[i] = static_cast<uint32_t>(diff);
    }
    while (result.words.size() > 1 && result.words.back() == 0) result.words.pop_back();
    return result;
}

AdbKeyPair::BigUint AdbKeyPair::BigUint::operator*(const BigUint& b) const {
    BigUint result;
    result.words.resize(words.size() + b.words.size(), 0);
    for (size_t i = 0; i < words.size(); i++) {
        uint64_t carry = 0;
        for (size_t j = 0; j < b.words.size() || carry; j++) {
            uint64_t cur = static_cast<uint64_t>(result.words[i + j]) + carry;
            if (j < b.words.size()) cur += static_cast<uint64_t>(words[i]) * b.words[j];
            result.words[i + j] = static_cast<uint32_t>(cur);
            carry = cur >> 32;
        }
    }
    while (result.words.size() > 1 && result.words.back() == 0) result.words.pop_back();
    return result;
}

AdbKeyPair::BigUint AdbKeyPair::BigUint::operator/(const BigUint& b) const {
    if (b.words.size() == 1 && b.words[0] == 0) {
        throw std::runtime_error("Division by zero");
    }

    if (*this == b) return BigUint(1);
    if (b > *this) return BigUint(0);

    // Simple long division
    BigUint dividend = *this;
    BigUint quotient;
    quotient.words.resize(words.size(), 0);

    // bit-by-bit division
    BigUint current(0);
    int totalBits = static_cast<int>(words.size()) * 32;

    for (int i = totalBits - 1; i >= 0; i--) {
        // shift current left by 1
        // Add bit i of dividend
        uint64_t carry = 0;
        for (size_t j = 0; j < current.words.size(); j++) {
            uint64_t val = (static_cast<uint64_t>(current.words[j]) << 1) | carry;
            current.words[j] = static_cast<uint32_t>(val);
            carry = val >> 32;
        }
        if (carry) current.words.push_back(static_cast<uint32_t>(carry));

        // Add bit i from this
        int wordIdx = i / 32;
        int bitIdx = i % 32;
        if (wordIdx < static_cast<int>(words.size()) && (words[wordIdx] >> bitIdx) & 1) {
            uint64_t addCarry = 1;
            for (size_t j = 0; j < current.words.size() && addCarry; j++) {
                uint64_t val = static_cast<uint64_t>(current.words[j]) + addCarry;
                current.words[j] = static_cast<uint32_t>(val);
                addCarry = val >> 32;
            }
            if (addCarry) current.words.push_back(static_cast<uint32_t>(addCarry));
        }

        if (current >= b) {
            current = current - b;
            quotient.words[wordIdx] |= (1u << bitIdx);
        }
    }

    while (quotient.words.size() > 1 && quotient.words.back() == 0) quotient.words.pop_back();
    return quotient;
}

AdbKeyPair::BigUint AdbKeyPair::BigUint::operator%(const BigUint& b) const {
    if (b.words.size() == 1 && b.words[0] == 0) {
        throw std::runtime_error("Modulo by zero");
    }
    // a % b = a - (a/b)*b
    BigUint q = *this / b;
    BigUint product = q * b;
    return *this - product;
}

AdbKeyPair::BigUint AdbKeyPair::modInverse(const BigUint& a, const BigUint& m) {
    // Extended Euclidean algorithm using signed big integers
    // For simplicity, use the iterative approach with 64-bit
    // Since m is r32 (2^32), we can use simple 64-bit arithmetic
    uint64_t a64 = a.toU32();
    uint64_t m64 = static_cast<uint64_t>(1) << 32;

    int64_t x0 = 0, x1 = 1;
    uint64_t tempA = a64, tempM = m64;

    if (m64 == 1) return BigUint(0);

    while (tempA > 1) {
        int64_t q = static_cast<int64_t>(tempA / tempM);
        uint64_t t = tempM;
        tempM = tempA % tempM;
        tempA = t;
        int64_t tx = x0;
        x0 = x1 - q * x0;
        x1 = tx;
    }

    if (x1 < 0) x1 += static_cast<int64_t>(m64);
    return BigUint(static_cast<uint64_t>(x1));
}

// ==================== Key operations ====================

AdbKeyPair AdbKeyPair::read(const std::string& publicKeyPath, const std::string& privateKeyPath) {
    AdbKeyPair kp;

    // 读取公钥文件
    {
        std::ifstream f(publicKeyPath, std::ios::binary);
        if (!f) throw std::runtime_error("Cannot open public key file: " + publicKeyPath);
        std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        kp.publicKeyBytes_.assign(content.begin(), content.end());
    }

    // 读取私钥文件 (PEM格式PKCS#8)
    std::vector<uint8_t> priKeyDer;
    {
        std::ifstream f(privateKeyPath, std::ios::binary);
        if (!f) throw std::runtime_error("Cannot open private key file: " + privateKeyPath);
        std::string content((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        kp.privateKeyPem_ = content;

        // 解析PEM: 去掉header/footer，base64解码
        std::string data = content;
        auto pos1 = data.find("-----BEGIN PRIVATE KEY-----");
        if (pos1 != std::string::npos) data.erase(pos1, 27);
        auto pos2 = data.find("-----END PRIVATE KEY-----");
        if (pos2 != std::string::npos) data.erase(pos2, 25);
        // 去掉换行
        std::string cleaned;
        for (char c : data) {
            if (c != '\n' && c != '\r' && c != ' ') cleaned.push_back(c);
        }
        priKeyDer = AdbBase64::decode(cleaned);
    }

    // 使用CryptoArchitectureKit加载密钥对
    OH_CryptoAsymKeyGenerator* generator = nullptr;
    OH_Crypto_ErrCode err = OH_CryptoAsymKeyGenerator_Create("RSA2048", &generator);
    if (err != CRYPTO_SUCCESS) {
        throw std::runtime_error("Failed to create RSA key generator: " + std::to_string(err));
    }

    Crypto_DataBlob priKeyBlob = { priKeyDer.data(), priKeyDer.size() };
    err = OH_CryptoAsymKeyGenerator_Convert(generator, CRYPTO_DER, nullptr, &priKeyBlob, &kp.keyPair_);
    OH_CryptoAsymKeyGenerator_Destroy(generator);

    if (err != CRYPTO_SUCCESS) {
        throw std::runtime_error("Failed to convert private key: " + std::to_string(err));
    }

    OH_LOG_INFO(LOG_APP, "AdbKeyPair: loaded key pair from files");
    return kp;
}

void AdbKeyPair::generate(const std::string& publicKeyPath, const std::string& privateKeyPath) {
    // 生成RSA 2048密钥对
    OH_CryptoAsymKeyGenerator* generator = nullptr;
    OH_Crypto_ErrCode err = OH_CryptoAsymKeyGenerator_Create("RSA2048", &generator);
    if (err != CRYPTO_SUCCESS) {
        throw std::runtime_error("Failed to create RSA key generator: " + std::to_string(err));
    }

    OH_CryptoKeyPair* keyPair = nullptr;
    err = OH_CryptoAsymKeyGenerator_Generate(generator, &keyPair);
    OH_CryptoAsymKeyGenerator_Destroy(generator);

    if (err != CRYPTO_SUCCESS) {
        throw std::runtime_error("Failed to generate RSA key pair: " + std::to_string(err));
    }

    // 转换公钥为ADB格式
    OH_CryptoPubKey* pubKey = OH_CryptoKeyPair_GetPubKey(keyPair);
    std::vector<uint8_t> adbPubKey = convertRsaPublicKeyToAdbFormat(pubKey);

    // Base64编码公钥
    std::string pubKeyBase64 = AdbBase64::encodeToString(adbPubKey.data(), adbPubKey.size());

    // 写入公钥文件 (去掉换行 + 追加 comment)
    {
        std::string cleaned;
        for (char c : pubKeyBase64) {
            if (c != '\n') cleaned.push_back(c);
        }
        cleaned += " scrcpyHmos@HarmonyOS";

        std::ofstream f(publicKeyPath, std::ios::binary | std::ios::trunc);
        if (!f) throw std::runtime_error("Cannot write public key file");
        f.write(cleaned.data(), cleaned.size());
    }

    // 获取私钥DER编码
    OH_CryptoPrivKey* privKey = OH_CryptoKeyPair_GetPrivKey(keyPair);
    Crypto_DataBlob priKeyDerBlob = {};
    err = OH_CryptoPrivKey_Encode(privKey, CRYPTO_DER, "PKCS8", nullptr, &priKeyDerBlob);
    if (err != CRYPTO_SUCCESS) {
        OH_CryptoKeyPair_Destroy(keyPair);
        throw std::runtime_error("Failed to encode private key: " + std::to_string(err));
    }

    // 写入PEM格式私钥文件
    {
        std::string priKeyBase64 = AdbBase64::encodeToString(priKeyDerBlob.data, priKeyDerBlob.len);
        // 去掉换行
        std::string cleaned;
        for (char c : priKeyBase64) {
            if (c != '\n') cleaned.push_back(c);
        }
        std::string pem = "-----BEGIN PRIVATE KEY-----\n" + cleaned + "\n-----END PRIVATE KEY-----";

        std::ofstream f(privateKeyPath, std::ios::binary | std::ios::trunc);
        if (!f) {
            OH_Crypto_FreeDataBlob(&priKeyDerBlob);
            OH_CryptoKeyPair_Destroy(keyPair);
            throw std::runtime_error("Cannot write private key file");
        }
        f.write(pem.data(), pem.size());
    }

    OH_Crypto_FreeDataBlob(&priKeyDerBlob);
    OH_CryptoKeyPair_Destroy(keyPair);

    OH_LOG_INFO(LOG_APP, "AdbKeyPair: generated and saved new key pair");
}

std::vector<uint8_t> AdbKeyPair::signPayload(const uint8_t* payload, size_t payloadLen) {
    if (!payload || payloadLen == 0) {
        return std::vector<uint8_t>(1, 0);
    }

    if (!keyPair_) {
        OH_LOG_ERROR(LOG_APP, "AdbKeyPair: no key pair available for signing");
        return std::vector<uint8_t>(256, 0);
    }

    // 合并padding和payload - must be exactly 256 bytes for RSA2048
    size_t combinedLen = SIGNATURE_PADDING_LEN + payloadLen;
    OH_LOG_INFO(LOG_APP, "AdbKeyPair: signPayload paddingLen=%{public}d payloadLen=%{public}zu combinedLen=%{public}zu",
                SIGNATURE_PADDING_LEN, payloadLen, combinedLen);
    std::vector<uint8_t> combined(combinedLen);
    std::memcpy(combined.data(), SIGNATURE_PADDING, SIGNATURE_PADDING_LEN);
    std::memcpy(combined.data() + SIGNATURE_PADDING_LEN, payload, payloadLen);

    // ADB uses RSA2048/NoPadding (raw RSA with DECRYPT_MODE = private key operation)
    // Must match the ArkTS version: 'RSA2048|NoPadding'
    OH_CryptoAsymCipher* cipher = nullptr;
    OH_Crypto_ErrCode err = OH_CryptoAsymCipher_Create("RSA2048|NoPadding", &cipher);
    if (err != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "AdbKeyPair: create cipher failed: %{public}d", err);
        return std::vector<uint8_t>(256, 0);
    }

    // DECRYPT_MODE with keyPair uses the private key for signing
    err = OH_CryptoAsymCipher_Init(cipher, CRYPTO_DECRYPT_MODE, keyPair_);
    if (err != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "AdbKeyPair: init cipher failed: %{public}d", err);
        OH_CryptoAsymCipher_Destroy(cipher);
        return std::vector<uint8_t>(256, 0);
    }

    Crypto_DataBlob inputBlob = { combined.data(), combined.size() };
    Crypto_DataBlob outputBlob = {};
    err = OH_CryptoAsymCipher_Final(cipher, &inputBlob, &outputBlob);
    OH_CryptoAsymCipher_Destroy(cipher);

    if (err != CRYPTO_SUCCESS) {
        OH_LOG_ERROR(LOG_APP, "AdbKeyPair: cipher final failed: %{public}d, inputSize=%{public}zu", err, combined.size());
        return std::vector<uint8_t>(256, 0);
    }

    OH_LOG_INFO(LOG_APP, "AdbKeyPair: signature OK, outputLen=%{public}zu", outputBlob.len);
    std::vector<uint8_t> result(outputBlob.data, outputBlob.data + outputBlob.len);
    OH_Crypto_FreeDataBlob(&outputBlob);
    return result;
}

std::vector<uint8_t> AdbKeyPair::convertRsaPublicKeyToAdbFormat(OH_CryptoPubKey* pubKey) {
    // 从公钥中获取modulus (N) 和 exponent (E)
    Crypto_DataBlob nBlob = {};
    Crypto_DataBlob eBlob = {};

    OH_Crypto_ErrCode err = OH_CryptoPubKey_GetParam(pubKey, CRYPTO_RSA_N_DATABLOB, &nBlob);
    if (err != CRYPTO_SUCCESS) {
        throw std::runtime_error("Failed to get RSA N: " + std::to_string(err));
    }

    err = OH_CryptoPubKey_GetParam(pubKey, CRYPTO_RSA_E_DATABLOB, &eBlob);
    if (err != CRYPTO_SUCCESS) {
        OH_Crypto_FreeDataBlob(&nBlob);
        throw std::runtime_error("Failed to get RSA E: " + std::to_string(err));
    }

    // N的big-endian字节, 可能有前导0
    const uint8_t* nData = nBlob.data;
    size_t nLen = nBlob.len;
    if (nLen > 0 && nData[0] == 0x00) {
        nData++;
        nLen--;
    }

    // E: 从字节解析为uint32
    uint32_t e = 0;
    for (size_t i = 0; i < eBlob.len; i++) {
        e = (e << 8) | eBlob.data[i];
    }

    // 按照原版Java代码，使用大整数计算
    BigUint n = BigUint::fromBytes(nData, nLen);
    BigUint r32(static_cast<uint64_t>(1) << 32);

    // r = 2^(KEY_LENGTH_WORDS * 32)
    // r*r mod n
    // 先计算 r mod n, 再平方
    // r 是一个 1 后跟 KEY_LENGTH_WORDS*32 个 0 的数
    BigUint r;
    r.words.resize(KEY_LENGTH_WORDS + 1, 0);
    r.words[KEY_LENGTH_WORDS] = 1;

    BigUint rModN = r % n;
    BigUint rr = (rModN * rModN) % n;

    BigUint nModR32 = n % r32;
    BigUint n0inv = modInverse(nModR32, r32);

    // 提取每个word
    std::vector<uint32_t> myN(KEY_LENGTH_WORDS, 0);
    std::vector<uint32_t> myRr(KEY_LENGTH_WORDS, 0);

    // n的小端words
    for (int i = 0; i < KEY_LENGTH_WORDS && i < static_cast<int>(n.words.size()); i++) {
        myN[i] = n.words[i];
    }
    for (int i = 0; i < KEY_LENGTH_WORDS && i < static_cast<int>(rr.words.size()); i++) {
        myRr[i] = rr.words[i];
    }

    // 构建524字节的buffer
    std::vector<uint8_t> buf(524, 0);
    size_t offset = 0;

    auto writeU32LE = [&](uint32_t val) {
        buf[offset]     = static_cast<uint8_t>(val & 0xFF);
        buf[offset + 1] = static_cast<uint8_t>((val >> 8) & 0xFF);
        buf[offset + 2] = static_cast<uint8_t>((val >> 16) & 0xFF);
        buf[offset + 3] = static_cast<uint8_t>((val >> 24) & 0xFF);
        offset += 4;
    };

    writeU32LE(KEY_LENGTH_WORDS);

    uint32_t n0invVal = n0inv.toU32();
    uint32_t negated = static_cast<uint32_t>(-static_cast<int32_t>(n0invVal));
    writeU32LE(negated);

    for (int i = 0; i < KEY_LENGTH_WORDS; i++) {
        writeU32LE(myN[i]);
    }
    for (int i = 0; i < KEY_LENGTH_WORDS; i++) {
        writeU32LE(myRr[i]);
    }

    writeU32LE(e);

    OH_Crypto_FreeDataBlob(&nBlob);
    OH_Crypto_FreeDataBlob(&eBlob);

    return buf;
}
