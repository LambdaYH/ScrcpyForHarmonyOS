#pragma once

#include <atomic>
#include <string>
#include <vector>

namespace scrcpy::pairing {

struct QrPairingSessionInfo {
    int64_t sessionId;
    std::string pairingCode;
    std::string serviceName;
};

struct QrPairingResult {
    std::string guid;
    std::string pairedHost;
    std::string hostPort;
};

std::string AdbPair(const std::string& hostPort, const std::string& pairingCode, const std::string& publicKeyPath,
                    const std::string& privateKeyPath, const std::atomic_bool* canceled = nullptr);
QrPairingSessionInfo StartQrPairingSession(const std::string& publicKeyPath, const std::string& privateKeyPath,
                                           const std::string& localIp);
QrPairingResult WaitQrPairingSession(int64_t sessionId);
std::vector<std::string> DiscoverConnectHostPorts(const std::string& localIp, const std::string& preferredHost);
std::string DiscoverConnectHostPort(const std::string& localIp, const std::string& preferredHost);
void StopQrPairingSession(int64_t sessionId);

}  // namespace scrcpy::pairing
