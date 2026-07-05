// AdbBase64 - Base64编解码
// 使用查表法实现，无外部依赖
#include "adb/crypto/AdbBase64.h"

static const char BASE64_CHARS[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

static const int BASE64_DECODE_TABLE[] = {
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,
    -1,-1,-1,-1,-1,-1,-1,-1,-1,-1,-1,62,-1,-1,-1,63,
    52,53,54,55,56,57,58,59,60,61,-1,-1,-1,-1,-1,-1,
    -1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9,10,11,12,13,14,
    15,16,17,18,19,20,21,22,23,24,25,-1,-1,-1,-1,-1,
    -1,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,
    41,42,43,44,45,46,47,48,49,50,51,-1,-1,-1,-1,-1
};

std::string AdbBase64::encodeToString(const uint8_t* data, size_t len) {
    std::string result;
    result.reserve(((len + 2) / 3) * 4);

    for (size_t i = 0; i < len; i += 3) {
        uint32_t b = (static_cast<uint32_t>(data[i]) << 16);
        if (i + 1 < len) b |= (static_cast<uint32_t>(data[i + 1]) << 8);
        if (i + 2 < len) b |= static_cast<uint32_t>(data[i + 2]);

        result.push_back(BASE64_CHARS[(b >> 18) & 0x3F]);
        result.push_back(BASE64_CHARS[(b >> 12) & 0x3F]);

        if (i + 1 < len) {
            result.push_back(BASE64_CHARS[(b >> 6) & 0x3F]);
        } else {
            result.push_back('=');
        }

        if (i + 2 < len) {
            result.push_back(BASE64_CHARS[b & 0x3F]);
        } else {
            result.push_back('=');
        }
    }

    return result;
}

std::vector<uint8_t> AdbBase64::decode(const std::string& encoded) {
    std::vector<uint8_t> result;
    result.reserve((encoded.size() / 4) * 3);

    uint32_t buf = 0;
    int bits = 0;

    for (char c : encoded) {
        if (c == '=' || c == '\n' || c == '\r' || c == ' ') continue;
        if (c < 0 || static_cast<unsigned char>(c) >= 128) continue;

        int val = BASE64_DECODE_TABLE[static_cast<unsigned char>(c)];
        if (val < 0) continue;

        buf = (buf << 6) | static_cast<uint32_t>(val);
        bits += 6;

        if (bits >= 8) {
            bits -= 8;
            result.push_back(static_cast<uint8_t>((buf >> bits) & 0xFF));
        }
    }

    return result;
}
