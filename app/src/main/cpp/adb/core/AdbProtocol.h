// AdbProtocol - ADB协议实现
#ifndef ADB_PROTOCOL_H
#define ADB_PROTOCOL_H

#include <cstdint>
#include <string>
#include <vector>

// ADB消息
struct AdbMessage {
    uint32_t command;
    uint32_t arg0;
    uint32_t arg1;
    uint32_t payloadLength;
    std::vector<uint8_t> payload;

    AdbMessage() : command(0), arg0(0), arg1(0), payloadLength(0) {}
    AdbMessage(uint32_t cmd, uint32_t a0, uint32_t a1, uint32_t pLen)
        : command(cmd), arg0(a0), arg1(a1), payloadLength(pLen) {}

    // 从fd读取并解析ADB消息
    static AdbMessage parse(int fd);
};

class AdbProtocol {
public:
    static constexpr int ADB_HEADER_LENGTH = 24;

    static constexpr uint32_t AUTH_TYPE_TOKEN = 1;
    static constexpr uint32_t AUTH_TYPE_SIGNATURE = 2;
    static constexpr uint32_t AUTH_TYPE_RSA_PUBLIC = 3;

    static constexpr uint32_t CMD_AUTH = 0x48545541; // "AUTH"
    static constexpr uint32_t CMD_CNXN = 0x4e584e43; // "CNXN"
    static constexpr uint32_t CMD_OPEN = 0x4e45504f; // "OPEN"
    static constexpr uint32_t CMD_OKAY = 0x59414b4f; // "OKAY"
    static constexpr uint32_t CMD_CLSE = 0x45534c43; // "CLSE"
    static constexpr uint32_t CMD_WRTE = 0x45545257; // "WRTE"
    static constexpr uint32_t CMD_STLS = 0x534c5453; // "STLS"

    static constexpr uint32_t CONNECT_VERSION = 0x01000000;
    static constexpr uint32_t STLS_VERSION = 0x01000000;
    // 当前工程仅走 TCP/IP，主机侧接收窗口宣告为 1 MiB。
    static constexpr uint32_t CONNECT_MAXDATA = 1024 * 1024;

    static std::vector<uint8_t> generateConnect();
    static std::vector<uint8_t> generateTlsRequest();
    static std::vector<uint8_t> generateAuth(uint32_t type, const uint8_t* data, size_t len);
    static std::vector<uint8_t> generateOpen(int32_t localId, const std::string& dest);
    static std::vector<uint8_t> generateWrite(int32_t localId, int32_t remoteId, const uint8_t* data, size_t len);
    static std::vector<uint8_t> generateClose(int32_t localId, int32_t remoteId);
    static std::vector<uint8_t> generateOkay(int32_t localId, int32_t remoteId);

    // Sync协议头生成 - 用于文件传输
    static std::vector<uint8_t> generateSyncHeader(const char id[4], int32_t arg);

private:
    static std::vector<uint8_t> generateMessage(uint32_t cmd, uint32_t arg0, uint32_t arg1,
                                                  const uint8_t* payload, size_t payloadLen);
};

#endif // ADB_PROTOCOL_H
