// AdbBase64 - Base64编解码
#ifndef ADB_BASE64_H
#define ADB_BASE64_H

#include <cstdint>
#include <string>
#include <vector>

class AdbBase64 {
public:
    static std::string encodeToString(const uint8_t* data, size_t len);
    static std::vector<uint8_t> decode(const std::string& encoded);
};

#endif // ADB_BASE64_H
