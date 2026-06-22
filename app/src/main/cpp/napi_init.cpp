#include "napi/native_api.h"
#include "decoder/VideoDecoderNative.h"
#include "decoder/AudioDecoderNative.h"
#include "adb/core/Adb.h"
#include "adb/pairing/AdbPair.h"
#include "concurrentqueue/concurrentqueue.h"


#include <hilog/log.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <string>
#include <map>
#include <memory>
#include <unordered_map>
#include <vector>
#include <cerrno>
#include <unistd.h>

static napi_value CreateShellCommandResult(napi_env env, const AdbShellCommandResult& result) {
    napi_value obj;
    napi_create_object(env, &obj);

    napi_value exitCode;
    napi_create_int32(env, result.exitCode, &exitCode);
    napi_set_named_property(env, obj, "exitCode", exitCode);

    napi_value exitCodeReliable;
    napi_get_boolean(env, result.exitCodeReliable, &exitCodeReliable);
    napi_set_named_property(env, obj, "exitCodeReliable", exitCodeReliable);

    napi_value stdoutValue;
    napi_create_string_utf8(env, result.stdoutText.c_str(), result.stdoutText.size(), &stdoutValue);
    napi_set_named_property(env, obj, "stdout", stdoutValue);

    napi_value stderrValue;
    napi_create_string_utf8(env, result.stderrText.c_str(), result.stderrText.size(), &stderrValue);
    napi_set_named_property(env, obj, "stderr", stderrValue);

    return obj;
}

static napi_value CreateInstallPackageResult(
    napi_env env,
    bool success,
    const std::string& remotePath,
    const AdbShellCommandResult& result) {
    napi_value obj = CreateShellCommandResult(env, result);

    napi_value successValue;
    napi_get_boolean(env, success, &successValue);
    napi_set_named_property(env, obj, "success", successValue);

    napi_value remotePathValue;
    napi_create_string_utf8(env, remotePath.c_str(), remotePath.size(), &remotePathValue);
    napi_set_named_property(env, obj, "remotePath", remotePathValue);

    return obj;
}

static std::string BuildErrnoMessage(const std::string& prefix) {
    return prefix + ": " + std::strerror(errno);
}

static void ReportProgress(napi_threadsafe_function tsfn, int progress) {
    if (!tsfn) {
        return;
    }
    auto* value = new int(progress);
    napi_status status = napi_call_threadsafe_function(tsfn, value, napi_tsfn_nonblocking);
    if (status != napi_ok) {
        delete value;
    }
}

static bool LooksLikeInstallSuccess(const AdbShellCommandResult& result) {
    const std::string combinedOutput = result.stdoutText + "\n" + result.stderrText;
    return combinedOutput.find("Success") != std::string::npos &&
        combinedOutput.find("Failure") == std::string::npos &&
        combinedOutput.find("INSTALL_FAILED") == std::string::npos;
}

static std::string ShellQuote(const std::string& text) {
    std::string escaped;
    escaped.reserve(text.size() + 8);
    escaped.push_back('\'');
    for (char ch : text) {
        if (ch == '\'') {
            escaped += "'\\''";
        } else {
            escaped.push_back(ch);
        }
    }
    escaped.push_back('\'');
    return escaped;
}

static napi_threadsafe_function CreateProgressTsfn(
    napi_env env,
    napi_value callback,
    napi_value resourceName) {
    napi_threadsafe_function tsfn = nullptr;
    napi_create_threadsafe_function(
        env,
        callback,
        nullptr,
        resourceName,
        0,
        1,
        nullptr,
        nullptr,
        nullptr,
        [](napi_env env, napi_value jsCb, void*, void* data) {
            int* progress = static_cast<int*>(data);
            if (!env || !jsCb || !progress) {
                delete progress;
                return;
            }
            napi_value argv[1];
            napi_create_int32(env, *progress, &argv[0]);
            napi_value global;
            napi_get_global(env, &global);
            napi_call_function(env, global, jsCb, 1, argv, nullptr);
            delete progress;
        },
        &tsfn
    );
    return tsfn;
}

// ============== Video Decoder ==============

static std::unordered_map<int64_t, VideoDecoderNative*> g_videoDecoders;
static int64_t g_nextVideoId = 1;

// 创建视频解码器
static napi_value CreateVideoDecoder(napi_env env, napi_callback_info info) {
    VideoDecoderNative* decoder = new VideoDecoderNative();
    int64_t decoderId = g_nextVideoId++;
    g_videoDecoders[decoderId] = decoder;

    napi_value result;
    napi_create_int64(env, decoderId, &result);
    return result;
}

// 初始化视频解码器 - 现在接受codecType字符串而不是useH265布尔值
static napi_value InitVideoDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    // 获取参数
    int64_t decoderId;
    char codecType[32];
    size_t codecTypeLen;
    char surfaceId[128];
    size_t surfaceIdLen;
    int32_t width, height;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_string_utf8(env, args[1], codecType, sizeof(codecType), &codecTypeLen);
    napi_get_value_string_utf8(env, args[2], surfaceId, sizeof(surfaceId), &surfaceIdLen);
    napi_get_value_int32(env, args[3], &width);
    napi_get_value_int32(env, args[4], &height);

    // 调用Native方法
    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        int32_t ret = it->second->Init(codecType, surfaceId, width, height);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 启动视频解码器
static napi_value StartVideoDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送视频数据
static napi_value PushVideoData(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    void* data;
    size_t dataSize;
    int64_t pts;
    uint32_t flags = 0;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);

    // Fast path: assume Number type (common case)
    napi_valuetype valueType;
    napi_typeof(env, args[2], &valueType);

    if (valueType == napi_bigint) {
        bool lossless;
        napi_get_value_bigint_int64(env, args[2], &pts, &lossless);
    } else {
        napi_get_value_int64(env, args[2], &pts);
    }

    // Get flags if provided
    if (argc > 3) {
        napi_typeof(env, args[3], &valueType);
        if (valueType == napi_number) {
            napi_get_value_uint32(env, args[3], &flags);
        }
    }

    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data), static_cast<int32_t>(dataSize), pts, flags);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放视频解码器
static napi_value ReleaseVideoDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_videoDecoders.find(decoderId);
    if (it != g_videoDecoders.end()) {
        it->second->Release();
        delete it->second;
        g_videoDecoders.erase(it);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// ============== Audio Decoder ==============

static std::unordered_map<int64_t, AudioDecoderNative*> g_audioDecoders;
static int64_t g_nextAudioId = 1;

// 创建音频解码器
static napi_value CreateAudioDecoder(napi_env env, napi_callback_info info) {
    AudioDecoderNative* decoder = new AudioDecoderNative();
    int64_t decoderId = g_nextAudioId++;
    g_audioDecoders[decoderId] = decoder;

    napi_value result;
    napi_create_int64(env, decoderId, &result);
    return result;
}

// 初始化音频解码器
static napi_value InitAudioDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    char codecType[32];
    size_t codecTypeLen;
    int32_t sampleRate, channelCount;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_value_string_utf8(env, args[1], codecType, sizeof(codecType), &codecTypeLen);
    napi_get_value_int32(env, args[2], &sampleRate);
    napi_get_value_int32(env, args[3], &channelCount);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        int32_t ret = it->second->Init(codecType, sampleRate, channelCount);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 启动音频解码器
static napi_value StartAudioDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        int32_t ret = it->second->Start();
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 推送音频数据
static napi_value PushAudioData(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    void* data;
    size_t dataSize;
    int64_t pts;

    napi_get_value_int64(env, args[0], &decoderId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);
    napi_get_value_int64(env, args[2], &pts);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        int32_t ret = it->second->PushData(static_cast<uint8_t*>(data), static_cast<int32_t>(dataSize), pts);
        napi_value result;
        napi_create_int32(env, ret, &result);
        return result;
    }

    napi_value result;
    napi_create_int32(env, -1, &result);
    return result;
}

// 释放音频解码器
static napi_value ReleaseAudioDecoder(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t decoderId;
    napi_get_value_int64(env, args[0], &decoderId);

    auto it = g_audioDecoders.find(decoderId);
    if (it != g_audioDecoders.end()) {
        it->second->Release();
        delete it->second;
        g_audioDecoders.erase(it);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}





// ============== ADB Module ==============

#include "adb/crypto/AdbKeyPair.h"

static std::unordered_map<int64_t, std::shared_ptr<Adb>> g_adbInstances;
static int64_t g_nextAdbId = 1;

// 创建ADB实例 - adbCreate(ip, port) => adbId
// 异步任务上下文
struct AdbCreateContext {
    napi_async_work work;
    napi_deferred deferred;
    napi_ref callbackRef = nullptr;
    
    std::string ip;
    int32_t port;
    int64_t resultAdbId = -1;
    bool success = false;
    std::string errorMsg;
};

// 异步执行函数 (后台线程)
static void ExecuteAdbCreate(napi_env env, void* data) {
    AdbCreateContext* context = static_cast<AdbCreateContext*>(data);
    try {
        Adb* adb = Adb::create(context->ip, context->port);
        if (adb) {
            // 注意: 这里不能直接操作 g_adbInstances，因为它是全局的且非线程安全的
            // 我们只在 Execute 中创建对象，Id 分配和 Map 插入放到 Complete (主线程) 中
            // 但我们需要把 adb 指针传回去。
            // 实际上 g_nextAdbId 也应该在主线程访问。
            // 所以这里只负责 new Adb
            // 为了传递指针，我们将 Adb* 类型转换存入 resultAdbId (虽然 hacky，但这里我们用一个临时成员变量吧)
            // wait, context struct is ours to define. Let's add Adb* adbInstance to it.
            // But I cannot change the struct definition easily in this replace block without seeing it.
            // So I will just cast the pointer to int64_t for storage if needed, OR better:
            // I defined the struct above. I can add members!
            context->success = true;
            // Hack: Store pointer in resultAdbId temporarily? No, resultAdbId is int64.
            // Let's redefine struct properly.
        } else {
            context->success = false;
            context->errorMsg = "Adb::create returned nullptr";
        }
        // Wait, I need to store the `adb` pointer.
        // I will re-declare the struct with `Adb* adbInstance` below.
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

// 重新定义 Context 包含 Adb指针
struct AdbCreateContextFull {
    napi_async_work work;
    napi_deferred deferred;
    napi_ref callbackRef = nullptr;
    
    std::string ip;
    int32_t port;
    
    std::shared_ptr<Adb> adbInstance; // Created in BG
    int64_t resultAdbId = -1;
    bool success = false;
    std::string errorMsg;
};

static void ExecuteAdbCreateFull(napi_env env, void* data) {
    AdbCreateContextFull* context = static_cast<AdbCreateContextFull*>(data);
    try {
        context->adbInstance = std::shared_ptr<Adb>(Adb::create(context->ip, context->port));
        if (context->adbInstance) {
            context->success = true;
        } else {
            context->success = false;
            context->errorMsg = "Adb::create returned nullptr";
        }
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

// 异步完成函数 (主线程)
static void CompleteAdbCreateFull(napi_env env, napi_status status, void* data) {
    AdbCreateContextFull* context = static_cast<AdbCreateContextFull*>(data);
    napi_value result;

    if (context->success && context->adbInstance) {
        int64_t adbId = g_nextAdbId++;
        g_adbInstances[adbId] = context->adbInstance;
        napi_create_int64(env, adbId, &result);
        napi_resolve_deferred(env, context->deferred, result);
    } else {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbCreate failed: %{public}s", context->errorMsg.c_str());
        napi_create_int64(env, -1, &result);
        // Resolve with -1 instead of reject to maintain simpler logic on TS side (or reject?)
        // The original sync code returned -1. Let's resolve with -1.
        napi_resolve_deferred(env, context->deferred, result);
    }

    napi_delete_async_work(env, context->work);
    delete context;
}

// 创建ADB实例 - adbCreate(ip, port) => Promise<number>
static napi_value AdbCreate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char ip[256];
    size_t ipLen;
    int32_t port;

    napi_get_value_string_utf8(env, args[0], ip, sizeof(ip), &ipLen);
    napi_get_value_int32(env, args[1], &port);

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbCreate", NAPI_AUTO_LENGTH, &resourceName);

    AdbCreateContextFull* context = new AdbCreateContextFull();
    context->ip = ip;
    context->port = port;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        ExecuteAdbCreateFull,
        CompleteAdbCreateFull,
        (void*)context,
        &context->work
    );

    napi_queue_async_work(env, context->work);

    return promise;
}

// 异步连接上下文
// 异步连接上下文
struct AdbConnectContext {
    napi_async_work work;
    napi_deferred deferred;
    
    int64_t adbId;
    std::string pubKeyPath;
    std::string priKeyPath;
    
    std::shared_ptr<Adb> adbInstance;

    int32_t result = -1;
    bool success = false;
    std::string errorMsg;
    
    napi_threadsafe_function tsfn = nullptr;
};

static void ExecuteAdbConnect(napi_env env, void* data) {
    AdbConnectContext* context = static_cast<AdbConnectContext*>(data);
    if (!context->adbInstance) {
        context->success = false;
        context->errorMsg = "Adb instance not found or invalid";
        return;
    }

    try {
        AdbKeyPair keyPair = AdbKeyPair::read(context->pubKeyPath, context->priKeyPath);
        
        auto onWaitAuth = [context]() {
            if (context->tsfn) {
                // 回调到主线程
                napi_call_threadsafe_function(context->tsfn, nullptr, napi_tsfn_blocking);
            }
        };

        context->result = context->adbInstance->connect(keyPair, onWaitAuth);
        context->success = true;
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

static void CompleteAdbConnect(napi_env env, napi_status status, void* data) {
    AdbConnectContext* context = static_cast<AdbConnectContext*>(data);
    napi_value result;

    if (context->success) {
        napi_create_int32(env, context->result, &result);
        napi_resolve_deferred(env, context->deferred, result);
    } else {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbConnect failed: %{public}s", context->errorMsg.c_str());
        napi_create_int32(env, -1, &result);
        napi_resolve_deferred(env, context->deferred, result);
    }

    if (context->tsfn) {
        napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
        context->tsfn = nullptr;
    }

    napi_delete_async_work(env, context->work);
    delete context;
}

// ADB连接认证 - adbConnect(adbId, pubKeyPath, priKeyPath, onWaitAuthCallback?) => Promise<number>
static napi_value AdbConnect(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char pubKeyPath[512];
    char priKeyPath[512];
    size_t pubLen;
    size_t priLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], pubKeyPath, sizeof(pubKeyPath), &pubLen);
    napi_get_value_string_utf8(env, args[2], priKeyPath, sizeof(priKeyPath), &priLen);

    // 查找 ADB 实例 (在主线程进行)
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbConnect", NAPI_AUTO_LENGTH, &resourceName);

    AdbConnectContext* context = new AdbConnectContext();
    context->adbId = adbId;
    context->pubKeyPath = pubKeyPath;
    context->priKeyPath = priKeyPath;
    context->adbInstance = it->second;

    // Check for optional callback
    if (argc >= 4) {
        napi_valuetype type;
        napi_typeof(env, args[3], &type);
        if (type == napi_function) {
            napi_create_threadsafe_function(env, args[3], nullptr, resourceName, 0, 1, nullptr, nullptr, nullptr, nullptr, &context->tsfn);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        ExecuteAdbConnect,
        CompleteAdbConnect,
        (void*)context,
        &context->work
    );

    napi_queue_async_work(env, context->work);

    return promise;
}

// 执行ADB命令 - adbRunCmd(adbId, cmd) => string
static napi_value AdbRunCmd(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char cmd[4096];
    size_t cmdLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], cmd, sizeof(cmd), &cmdLen);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_string_utf8(env, "", 0, &result);
        return result;
    }

    try {
        std::string output = it->second->runAdbCmd(cmd);
        napi_create_string_utf8(env, output.c_str(), output.size(), &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbRunCmd failed: %{public}s", e.what());
        napi_create_string_utf8(env, "", 0, &result);
    }
    return result;
}

// 执行ADB shell命令并返回结构化结果 - adbExecShell(adbId, cmd) => Promise<{exitCode, exitCodeReliable, stdout, stderr}>
static napi_value AdbExecShell(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char cmd[4096];
    size_t cmdLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], cmd, sizeof(cmd), &cmdLen);

    struct AdbExecShellContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        std::string command;
        AdbShellCommandResult result;
        bool success = false;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    auto* context = new AdbExecShellContext();
    context->adbInstance = it->second;
    context->command = cmd;

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbExecShell", NAPI_AUTO_LENGTH, &resourceName);

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbExecShellContext*>(rawData);
            if (!context->adbInstance) {
                context->errorMsg = "Adb instance not found or invalid";
                return;
            }
            try {
                context->result = context->adbInstance->execShellCommand(context->command);
                context->success = true;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbExecShellContext*>(rawData);
            if (context->success) {
                napi_value result = CreateShellCommandResult(env, context->result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbExecShell failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMsg;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
                napi_value error;
                napi_create_error(env, nullptr, errorMsg, &error);
                napi_reject_deferred(env, context->deferred, error);
            }

            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// 安装APK - adbInstallPackage(adbId, data, remoteName, installArgs?) => Promise<{success, remotePath, exitCode, exitCodeReliable, stdout, stderr}>
static napi_value AdbInstallPackage(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    void* data;
    size_t dataSize;
    char remoteName[256];
    size_t remoteNameLen;
    char installArgs[1024] = {0};
    size_t installArgsLen = 0;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);
    napi_get_value_string_utf8(env, args[2], remoteName, sizeof(remoteName), &remoteNameLen);
    if (argc >= 4) {
        napi_get_value_string_utf8(env, args[3], installArgs, sizeof(installArgs), &installArgsLen);
    }

    struct AdbInstallPackageContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        napi_ref dataRef = nullptr;
        napi_threadsafe_function tsfn = nullptr;
        std::shared_ptr<Adb> adbInstance;
        void* fileData = nullptr;
        size_t fileSize = 0;
        std::string remoteName;
        std::string installArgs;
        std::string remotePath;
        AdbShellCommandResult shellResult;
        bool commandSuccess = false;
        bool completed = false;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    auto* context = new AdbInstallPackageContext();
    context->adbInstance = it->second;
    context->fileData = data;
    context->fileSize = dataSize;
    context->remoteName = remoteName;
    context->installArgs = installArgs;
    napi_create_reference(env, args[1], 1, &context->dataRef);

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbInstallPackage", NAPI_AUTO_LENGTH, &resourceName);

    if (argc >= 5) {
        napi_valuetype type;
        napi_typeof(env, args[4], &type);
        if (type == napi_function) {
            context->tsfn = CreateProgressTsfn(env, args[4], resourceName);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbInstallPackageContext*>(rawData);
            if (!context->adbInstance) {
                context->errorMsg = "Adb instance not found or invalid";
                return;
            }
            if (context->remoteName.empty()) {
                context->errorMsg = "remoteName is required";
                return;
            }

            auto shellQuote = [](const std::string& text) -> std::string {
                std::string escaped;
                escaped.reserve(text.size() + 8);
                escaped.push_back('\'');
                for (char ch : text) {
                    if (ch == '\'') {
                        escaped += "'\\''";
                    } else {
                        escaped.push_back(ch);
                    }
                }
                escaped.push_back('\'');
                return escaped;
            };

            context->remotePath = "/data/local/tmp/" + context->remoteName;
            try {
                context->adbInstance->pushFile(
                    static_cast<uint8_t*>(context->fileData),
                    context->fileSize,
                    context->remotePath,
                    [context](int progress) {
                        if (!context->tsfn) {
                            return;
                        }
                        auto* mappedProgress = new int(std::min((progress * 90) / 100, 90));
                        napi_status status = napi_call_threadsafe_function(
                            context->tsfn, mappedProgress, napi_tsfn_nonblocking);
                        if (status != napi_ok) {
                            delete mappedProgress;
                        }
                    }
                );

                if (context->tsfn) {
                    auto* installProgress = new int(95);
                    napi_status status = napi_call_threadsafe_function(
                        context->tsfn, installProgress, napi_tsfn_nonblocking);
                    if (status != napi_ok) {
                        delete installProgress;
                    }
                }

                std::string installCommand = "pm install";
                if (!context->installArgs.empty()) {
                    installCommand += " " + context->installArgs;
                }
                installCommand += " " + shellQuote(context->remotePath);

                context->shellResult = context->adbInstance->execShellCommand(installCommand);
                const std::string combinedOutput =
                    context->shellResult.stdoutText + "\n" + context->shellResult.stderrText;
                const bool looksSuccessful =
                    combinedOutput.find("Success") != std::string::npos &&
                    combinedOutput.find("Failure") == std::string::npos &&
                    combinedOutput.find("INSTALL_FAILED") == std::string::npos;
                const bool shellSucceeded = !context->shellResult.exitCodeReliable ||
                    context->shellResult.exitCode == 0;
                context->commandSuccess = shellSucceeded && looksSuccessful;
                if (context->tsfn) {
                    auto* completedProgress = new int(100);
                    napi_status status = napi_call_threadsafe_function(
                        context->tsfn, completedProgress, napi_tsfn_nonblocking);
                    if (status != napi_ok) {
                        delete completedProgress;
                    }
                }
                context->completed = true;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }

            if (!context->remotePath.empty()) {
                try {
                    context->adbInstance->execShellCommand("rm -f " + shellQuote(context->remotePath));
                } catch (const std::exception&) {
                }
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbInstallPackageContext*>(rawData);
            if (context->completed) {
                napi_value result = CreateInstallPackageResult(
                    env,
                    context->commandSuccess,
                    context->remotePath,
                    context->shellResult);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbInstallPackage failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMsg;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
                napi_value error;
                napi_create_error(env, nullptr, errorMsg, &error);
                napi_reject_deferred(env, context->deferred, error);
            }

            napi_delete_async_work(env, context->work);
            if (context->dataRef) {
                napi_delete_reference(env, context->dataRef);
            }
            if (context->tsfn) {
                napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
            }
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// 推送文件 - adbPushFile(adbId, data, remotePath, onProgress?) => void
static napi_value AdbPushFileFromFd(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t sourceFd;
    int64_t fileSize;
    char remotePath[1024];
    size_t pathLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &sourceFd);
    napi_get_value_int64(env, args[2], &fileSize);
    napi_get_value_string_utf8(env, args[3], remotePath, sizeof(remotePath), &pathLen);

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }
    if (fileSize <= 0) {
        napi_throw_error(env, nullptr, "Invalid file size");
        return nullptr;
    }

    struct AdbPushFileFromFdContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        napi_threadsafe_function tsfn = nullptr;
        std::shared_ptr<Adb> adbInstance;
        int fd = -1;
        int64_t fileSize = 0;
        std::string remotePath;
        bool success = false;
        std::string errorMsg;
    };

    auto* context = new AdbPushFileFromFdContext();
    context->adbInstance = it->second;
    context->fd = dup(sourceFd);
    context->fileSize = fileSize;
    context->remotePath = remotePath;
    if (context->fd < 0) {
        const std::string errorMsg = BuildErrnoMessage("Failed to duplicate source fd");
        delete context;
        napi_throw_error(env, nullptr, errorMsg.c_str());
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbPushFileFromFd", NAPI_AUTO_LENGTH, &resourceName);

    if (argc >= 5) {
        napi_valuetype type;
        napi_typeof(env, args[4], &type);
        if (type == napi_function) {
            context->tsfn = CreateProgressTsfn(env, args[4], resourceName);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbPushFileFromFdContext*>(rawData);
            if (!context->adbInstance) {
                context->errorMsg = "Adb instance not found or invalid";
                return;
            }

            try {
                if (lseek(context->fd, 0, SEEK_SET) < 0) {
                    throw std::runtime_error(BuildErrnoMessage("Failed to seek source file"));
                }
                context->adbInstance->pushFileFromFd(
                    context->fd,
                    static_cast<uint64_t>(context->fileSize),
                    context->remotePath,
                    [context](int progress) {
                        ReportProgress(context->tsfn, progress);
                    }
                );
                context->success = true;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbPushFileFromFdContext*>(rawData);
            if (context->success) {
                napi_value result;
                napi_get_undefined(env, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbPushFileFromFd failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMsg;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
                napi_value error;
                napi_create_error(env, nullptr, errorMsg, &error);
                napi_reject_deferred(env, context->deferred, error);
            }

            napi_delete_async_work(env, context->work);
            if (context->fd >= 0) {
                close(context->fd);
            }
            if (context->tsfn) {
                napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
            }
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value AdbListDirectory(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId = -1;
    char remotePath[4096] = {0};
    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], remotePath, sizeof(remotePath), nullptr);

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    struct AdbListDirectoryContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        std::string remotePath;
        std::vector<RemoteFileEntry> entries;
        std::string errorMsg;
    };

    auto* context = new AdbListDirectoryContext();
    context->adbInstance = it->second;
    context->remotePath = remotePath;

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbListDirectory", NAPI_AUTO_LENGTH, &resourceName);
    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbListDirectoryContext*>(rawData);
            try {
                context->entries = context->adbInstance->listDirectory(context->remotePath);
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbListDirectoryContext*>(rawData);
            if (context->errorMsg.empty()) {
                napi_value result;
                napi_create_array_with_length(env, context->entries.size(), &result);
                for (size_t index = 0; index < context->entries.size(); ++index) {
                    const auto& entry = context->entries[index];
                    napi_value item;
                    napi_create_object(env, &item);

                    napi_value value;
                    napi_create_string_utf8(env, entry.name.c_str(), entry.name.size(), &value);
                    napi_set_named_property(env, item, "name", value);
                    napi_create_string_utf8(env, entry.path.c_str(), entry.path.size(), &value);
                    napi_set_named_property(env, item, "path", value);
                    napi_create_uint32(env, entry.mode, &value);
                    napi_set_named_property(env, item, "mode", value);
                    napi_create_double(env, static_cast<double>(entry.size), &value);
                    napi_set_named_property(env, item, "size", value);
                    napi_create_double(env, static_cast<double>(entry.mtime), &value);
                    napi_set_named_property(env, item, "mtime", value);
                    napi_get_boolean(env, entry.isDirectory, &value);
                    napi_set_named_property(env, item, "isDirectory", value);
                    napi_get_boolean(env, entry.isRegularFile, &value);
                    napi_set_named_property(env, item, "isRegularFile", value);
                    napi_set_element(env, result, index, item);
                }
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                napi_value errorMessage;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMessage);
                napi_value error;
                napi_create_error(env, nullptr, errorMessage, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value AdbPullFileToFd(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId = -1;
    int32_t destinationFd = -1;
    char remotePath[4096] = {0};
    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &destinationFd);
    napi_get_value_string_utf8(env, args[2], remotePath, sizeof(remotePath), nullptr);

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    struct AdbPullFileToFdContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        napi_threadsafe_function tsfn = nullptr;
        std::shared_ptr<Adb> adbInstance;
        int fd = -1;
        std::string remotePath;
        uint64_t bytesWritten = 0;
        std::string errorMsg;
    };

    auto* context = new AdbPullFileToFdContext();
    context->adbInstance = it->second;
    context->fd = dup(destinationFd);
    context->remotePath = remotePath;
    if (context->fd < 0) {
        const std::string errorMsg = BuildErrnoMessage("Failed to duplicate destination fd");
        delete context;
        napi_throw_error(env, nullptr, errorMsg.c_str());
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbPullFileToFd", NAPI_AUTO_LENGTH, &resourceName);
    if (argc >= 4) {
        napi_valuetype type;
        napi_typeof(env, args[3], &type);
        if (type == napi_function) {
            context->tsfn = CreateProgressTsfn(env, args[3], resourceName);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);
    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbPullFileToFdContext*>(rawData);
            try {
                context->bytesWritten = context->adbInstance->pullFileToFd(
                    context->fd,
                    context->remotePath,
                    [context](int progress) {
                        ReportProgress(context->tsfn, progress);
                    }
                );
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbPullFileToFdContext*>(rawData);
            if (context->errorMsg.empty()) {
                napi_value result;
                napi_create_double(env, static_cast<double>(context->bytesWritten), &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbPullFileToFd failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMessage;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMessage);
                napi_value error;
                napi_create_error(env, nullptr, errorMessage, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            if (context->fd >= 0) {
                close(context->fd);
            }
            if (context->tsfn) {
                napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
            }
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value AdbInstallPackageFromFd(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t sourceFd;
    int64_t fileSize;
    char remoteName[256];
    size_t remoteNameLen;
    char installArgs[1024] = {0};

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &sourceFd);
    napi_get_value_int64(env, args[2], &fileSize);
    napi_get_value_string_utf8(env, args[3], remoteName, sizeof(remoteName), &remoteNameLen);
    if (argc >= 5) {
        napi_get_value_string_utf8(env, args[4], installArgs, sizeof(installArgs), nullptr);
    }

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }
    if (fileSize <= 0) {
        napi_throw_error(env, nullptr, "Invalid file size");
        return nullptr;
    }

    struct AdbInstallPackageFromFdContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        napi_threadsafe_function tsfn = nullptr;
        std::shared_ptr<Adb> adbInstance;
        int fd = -1;
        int64_t fileSize = 0;
        std::string remoteName;
        std::string installArgs;
        std::string remotePath;
        AdbShellCommandResult shellResult;
        bool commandSuccess = false;
        bool completed = false;
        std::string errorMsg;
    };

    auto* context = new AdbInstallPackageFromFdContext();
    context->adbInstance = it->second;
    context->fd = dup(sourceFd);
    context->fileSize = fileSize;
    context->remoteName = remoteName;
    context->installArgs = installArgs;
    if (context->fd < 0) {
        const std::string errorMsg = BuildErrnoMessage("Failed to duplicate source fd");
        delete context;
        napi_throw_error(env, nullptr, errorMsg.c_str());
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbInstallPackageFromFd", NAPI_AUTO_LENGTH, &resourceName);

    if (argc >= 6) {
        napi_valuetype type;
        napi_typeof(env, args[5], &type);
        if (type == napi_function) {
            context->tsfn = CreateProgressTsfn(env, args[5], resourceName);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbInstallPackageFromFdContext*>(rawData);
            if (!context->adbInstance) {
                context->errorMsg = "Adb instance not found or invalid";
                return;
            }
            if (context->remoteName.empty()) {
                context->errorMsg = "remoteName is required";
                return;
            }

            context->remotePath = "/data/local/tmp/" + context->remoteName;

            try {
                if (lseek(context->fd, 0, SEEK_SET) < 0) {
                    throw std::runtime_error(BuildErrnoMessage("Failed to seek source file"));
                }

                context->adbInstance->pushFileFromFd(
                    context->fd,
                    static_cast<uint64_t>(context->fileSize),
                    context->remotePath,
                    [context](int progress) {
                        const int mappedProgress = std::min((progress * 90) / 100, 90);
                        ReportProgress(context->tsfn, mappedProgress);
                    }
                );

                ReportProgress(context->tsfn, 95);
                std::string installCommand = "pm install";
                if (!context->installArgs.empty()) {
                    installCommand += " " + context->installArgs;
                }
                installCommand += " " + ShellQuote(context->remotePath);

                context->shellResult = context->adbInstance->execShellCommand(installCommand);
                const bool shellSucceeded = !context->shellResult.exitCodeReliable ||
                    context->shellResult.exitCode == 0;
                context->commandSuccess = shellSucceeded && LooksLikeInstallSuccess(context->shellResult);
                ReportProgress(context->tsfn, 100);
                context->completed = true;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }

            if (!context->remotePath.empty()) {
                try {
                    context->adbInstance->execShellCommand("rm -f " + ShellQuote(context->remotePath));
                } catch (const std::exception&) {
                }
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbInstallPackageFromFdContext*>(rawData);
            if (context->completed) {
                napi_value result = CreateInstallPackageResult(
                    env,
                    context->commandSuccess,
                    context->remotePath,
                    context->shellResult);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbInstallPackageFromFd failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMsg;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
                napi_value error;
                napi_create_error(env, nullptr, errorMsg, &error);
                napi_reject_deferred(env, context->deferred, error);
            }

            napi_delete_async_work(env, context->work);
            if (context->fd >= 0) {
                close(context->fd);
            }
            if (context->tsfn) {
                napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
            }
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// 推送文件 - adbPushFile(adbId, data, remotePath, onProgress?) => void
static napi_value AdbPushFile(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    void* data;
    size_t dataSize;
    char remotePath[1024];
    size_t pathLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_arraybuffer_info(env, args[1], &data, &dataSize);
    napi_get_value_string_utf8(env, args[2], remotePath, sizeof(remotePath), &pathLen);

    struct AdbPushFileContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        napi_ref dataRef = nullptr;
        napi_threadsafe_function tsfn = nullptr;
        std::shared_ptr<Adb> adbInstance;
        void* fileData = nullptr;
        size_t fileSize = 0;
        std::string remotePath;
        bool success = false;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbPushFile", NAPI_AUTO_LENGTH, &resourceName);

    AdbPushFileContext* context = new AdbPushFileContext();
    context->adbInstance = it->second;
    context->remotePath = remotePath;
    context->fileData = data;
    context->fileSize = dataSize;
    napi_create_reference(env, args[1], 1, &context->dataRef);

    if (argc >= 4) {
        napi_valuetype type;
        napi_typeof(env, args[3], &type);
        if (type == napi_function) {
            context->tsfn = CreateProgressTsfn(env, args[3], resourceName);
        }
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbPushFileContext*>(rawData);
            if (!context->adbInstance) {
                context->errorMsg = "Adb instance not found or invalid";
                return;
            }
            try {
                context->adbInstance->pushFile(
                    static_cast<uint8_t*>(context->fileData),
                    context->fileSize,
                    context->remotePath,
                    [context](int progress) {
                        if (!context->tsfn) {
                            return;
                        }
                        auto* progressValue = new int(progress);
                        napi_status status = napi_call_threadsafe_function(
                            context->tsfn, progressValue, napi_tsfn_nonblocking);
                        if (status != napi_ok) {
                            delete progressValue;
                        }
                    }
                );
                context->success = true;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbPushFileContext*>(rawData);
            if (context->success) {
                napi_value result;
                napi_get_undefined(env, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbPushFile failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMsg;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
                napi_value error;
                napi_create_error(env, nullptr, errorMsg, &error);
                napi_reject_deferred(env, context->deferred, error);
            }

            napi_delete_async_work(env, context->work);
            if (context->dataRef) {
                napi_delete_reference(env, context->dataRef);
            }
            if (context->tsfn) {
                napi_release_threadsafe_function(context->tsfn, napi_tsfn_release);
            }
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value AdbGetLastConnectError(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_string_utf8(env, "", 0, &result);
        return result;
    }

    const std::string error = it->second->getLastConnectError();
    napi_create_string_utf8(env, error.c_str(), error.size(), &result);
    return result;
}

struct AdbPairContext {
    napi_async_work work;
    napi_deferred deferred;
    std::string hostPort;
    std::string pairingCode;
    std::string pubKeyPath;
    std::string priKeyPath;
    std::string result;
    std::string errorMsg;
    bool success = false;
};

static void ExecuteAdbPair(napi_env env, void* data) {
    AdbPairContext* context = static_cast<AdbPairContext*>(data);
    try {
        context->result = scrcpy::pairing::AdbPair(context->hostPort, context->pairingCode, context->pubKeyPath,
                                                   context->priKeyPath);
        context->success = true;
    } catch (const std::exception& e) {
        context->success = false;
        context->errorMsg = e.what();
    }
}

static void CompleteAdbPair(napi_env env, napi_status status, void* data) {
    AdbPairContext* context = static_cast<AdbPairContext*>(data);
    if (context->success) {
        napi_value result;
        napi_create_string_utf8(env, context->result.c_str(), NAPI_AUTO_LENGTH, &result);
        napi_resolve_deferred(env, context->deferred, result);
    } else {
        napi_value errorMsg;
        napi_value error;
        napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
        napi_create_error(env, nullptr, errorMsg, &error);
        napi_reject_deferred(env, context->deferred, error);
    }

    napi_delete_async_work(env, context->work);
    delete context;
}

// adbPair(hostPort, pairingCode, pubKeyPath, priKeyPath) => Promise<string>
static napi_value AdbPair(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 4) {
        napi_throw_error(env, nullptr, "adbPair requires hostPort, pairingCode, pubKeyPath and priKeyPath");
        return nullptr;
    }

    char hostPort[256];
    char pairingCode[128];
    char pubKeyPath[512];
    char priKeyPath[512];
    size_t hostPortLen = 0;
    size_t pairingCodeLen = 0;
    size_t pubKeyLen = 0;
    size_t priKeyLen = 0;

    napi_get_value_string_utf8(env, args[0], hostPort, sizeof(hostPort), &hostPortLen);
    napi_get_value_string_utf8(env, args[1], pairingCode, sizeof(pairingCode), &pairingCodeLen);
    napi_get_value_string_utf8(env, args[2], pubKeyPath, sizeof(pubKeyPath), &pubKeyLen);
    napi_get_value_string_utf8(env, args[3], priKeyPath, sizeof(priKeyPath), &priKeyLen);

    auto* context = new AdbPairContext();
    context->hostPort = hostPort;
    context->pairingCode = pairingCode;
    context->pubKeyPath = pubKeyPath;
    context->priKeyPath = priKeyPath;

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbPair", NAPI_AUTO_LENGTH, &resourceName);

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);
    napi_create_async_work(env, nullptr, resourceName, ExecuteAdbPair, CompleteAdbPair, context, &context->work);
    napi_queue_async_work(env, context->work);
    return promise;
}

// TCP端口转发 - adbTcpForward(adbId, port) => streamId
static napi_value AdbTcpForward(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t port;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &port);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_int32(env, -1, &result);
        return result;
    }

    try {
        int32_t streamId = it->second->tcpForward(port);
        napi_create_int32(env, streamId, &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbTcpForward failed: %{public}s", e.what());
        napi_create_int32(env, -1, &result);
    }
    return result;
}

// 本地Socket转发 - adbLocalSocketForward(adbId, socketName, streamKind?) => streamId
static napi_value AdbLocalSocketForward(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char socketName[256];
    char streamKind[32] = "other";
    size_t nameLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], socketName, sizeof(socketName), &nameLen);
    if (argc >= 3) {
        size_t kindLen = 0;
        napi_get_value_string_utf8(env, args[2], streamKind, sizeof(streamKind), &kindLen);
    }

    struct AdbLocalSocketForwardContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        std::string socketName;
        std::string streamKind;
        int32_t streamId = -1;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbLocalSocketForward", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new AdbLocalSocketForwardContext();
    context->adbInstance = it->second;
    context->socketName = socketName;
    context->streamKind = streamKind;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbLocalSocketForwardContext*>(rawData);
            try {
                context->streamId = context->adbInstance->localSocketForward(context->socketName, context->streamKind);
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbLocalSocketForwardContext*>(rawData);
            napi_value result;
            if (context->errorMsg.empty()) {
                napi_create_int32(env, context->streamId, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbLocalSocketForward failed: %{public}s", context->errorMsg.c_str());
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &result);
                napi_value error;
                napi_create_error(env, nullptr, result, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value AdbReverse(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char socketName[256];
    size_t nameLen;
    int32_t port;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], socketName, sizeof(socketName), &nameLen);
    napi_get_value_int32(env, args[2], &port);

    struct AdbReverseContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        std::string socketName;
        int32_t port = 0;
        int32_t resultCode = -1;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbReverse", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new AdbReverseContext();
    context->adbInstance = it->second;
    context->socketName = socketName;
    context->port = port;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbReverseContext*>(rawData);
            try {
                const std::string remote = "localabstract:" + context->socketName;
                const std::string local = "tcp:" + std::to_string(context->port);
                context->resultCode = context->adbInstance->reverseForward(remote, local) ? 0 : -1;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbReverseContext*>(rawData);
            napi_value result;
            if (context->errorMsg.empty()) {
                napi_create_int32(env, context->resultCode, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbReverse failed: %{public}s", context->errorMsg.c_str());
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &result);
                napi_value error;
                napi_create_error(env, nullptr, result, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value AdbReverseRemove(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    char socketName[256];
    size_t nameLen;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_string_utf8(env, args[1], socketName, sizeof(socketName), &nameLen);

    struct AdbReverseRemoveContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        std::string socketName;
        int32_t resultCode = -1;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbReverseRemove", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new AdbReverseRemoveContext();
    context->adbInstance = it->second;
    context->socketName = socketName;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbReverseRemoveContext*>(rawData);
            try {
                const std::string remote = "localabstract:" + context->socketName;
                context->resultCode = context->adbInstance->reverseRemove(remote) ? 0 : -1;
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbReverseRemoveContext*>(rawData);
            napi_value result;
            if (context->errorMsg.empty()) {
                napi_create_int32(env, context->resultCode, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbReverseRemove failed: %{public}s", context->errorMsg.c_str());
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &result);
                napi_value error;
                napi_create_error(env, nullptr, result, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// 从流读取 - adbStreamRead(adbId, streamId, size) => ArrayBuffer
static napi_value AdbStreamRead(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId, size;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);
    napi_get_value_int32(env, args[2], &size);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        void* buf;
        napi_create_arraybuffer(env, 0, &buf, &result);
        return result;
    }

    try {
        // Use non-blocking read (timeout=0, exact=false) to avoid freezing UI
        auto data = it->second->streamRead(streamId, static_cast<size_t>(size), 0, false);

        void* buf;
        napi_create_arraybuffer(env, data.size(), &buf, &result);
        if (!data.empty()) {
            std::memcpy(buf, data.data(), data.size());
        }
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbStreamRead failed: %{public}s", e.what());
        void* buf;
        napi_create_arraybuffer(env, 0, &buf, &result);
    }
    return result;
}

// 向流写入 - adbStreamWrite(adbId, streamId, data)
static napi_value AdbStreamWrite(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId;
    void* data;
    size_t dataSize;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);
    napi_get_arraybuffer_info(env, args[2], &data, &dataSize);

    struct AdbStreamWriteContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        int32_t streamId = -1;
        std::vector<uint8_t> data;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbStreamWrite", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new AdbStreamWriteContext();
    context->adbInstance = it->second;
    context->streamId = streamId;
    context->data.resize(dataSize);
    if (dataSize > 0) {
        std::memcpy(context->data.data(), data, dataSize);
    }

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbStreamWriteContext*>(rawData);
            try {
                context->adbInstance->streamWrite(
                    context->streamId,
                    context->data.empty() ? nullptr : context->data.data(),
                    context->data.size()
                );
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbStreamWriteContext*>(rawData);
            if (context->errorMsg.empty()) {
                napi_value result;
                napi_get_undefined(env, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbStreamWrite failed: %{public}s", context->errorMsg.c_str());
                napi_value errorMsg;
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &errorMsg);
                napi_value error;
                napi_create_error(env, nullptr, errorMsg, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// 关闭流 - adbStreamClose(adbId, streamId)
static napi_value AdbStreamClose(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);

    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        it->second->streamClose(streamId);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 关闭ADB - adbClose(adbId)
static napi_value AdbClose(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        it->second->close();
        g_adbInstances.erase(it);
    }

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// 生成密钥对 - adbGenerateKeyPair(pubKeyPath, priKeyPath)
static napi_value AdbGenerateKeyPair(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    char pubKeyPath[512], priKeyPath[512];
    size_t pubLen, priLen;

    napi_get_value_string_utf8(env, args[0], pubKeyPath, sizeof(pubKeyPath), &pubLen);
    napi_get_value_string_utf8(env, args[1], priKeyPath, sizeof(priKeyPath), &priLen);

    napi_value result;
    try {
        AdbKeyPair::generate(pubKeyPath, priKeyPath);
        napi_create_int32(env, 0, &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbGenerateKeyPair failed: %{public}s", e.what());
        napi_create_int32(env, -1, &result);
    }
    return result;
}

// 检查ADB是否已连接 - adbIsConnected(adbId) => bool
static napi_value AdbIsConnected(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    bool connected = false;
    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        connected = !it->second->isAdbClosed();
    }

    napi_value result;
    napi_get_boolean(env, connected, &result);
    return result;
}

// 获取Shell - adbGetShell(adbId) => streamId
static napi_value AdbGetShell(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    napi_get_value_int64(env, args[0], &adbId);

    struct AdbGetShellContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        int32_t streamId = -1;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "AdbGetShell", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new AdbGetShellContext();
    context->adbInstance = it->second;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<AdbGetShellContext*>(rawData);
            try {
                context->streamId = context->adbInstance->getShell();
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<AdbGetShellContext*>(rawData);
            napi_value result;
            if (context->errorMsg.empty()) {
                napi_create_int32(env, context->streamId, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] AdbGetShell failed: %{public}s", context->errorMsg.c_str());
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &result);
                napi_value error;
                napi_create_error(env, nullptr, result, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// 切换TCP模式 - adbRestartOnTcpip(adbId, port) => string
static napi_value AdbRestartOnTcpip(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t port;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &port);

    napi_value result;
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_create_string_utf8(env, "", 0, &result);
        return result;
    }

    try {
        std::string output = it->second->restartOnTcpip(port);
        napi_create_string_utf8(env, output.c_str(), output.size(), &result);
    } catch (const std::exception& e) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] AdbRestartOnTcpip failed: %{public}s", e.what());
        napi_create_string_utf8(env, "", 0, &result);
    }
    return result;
}

// 流是否已关闭 - adbIsStreamClosed(adbId, streamId) => bool
static napi_value AdbIsStreamClosed(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t streamId;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &streamId);

    bool closed = true;
    auto it = g_adbInstances.find(adbId);
    if (it != g_adbInstances.end()) {
        closed = it->second->isStreamClosed(streamId);
    }

    napi_value result;
    napi_get_boolean(env, closed, &result);
    return result;
}

// ============== ScrcpyStreamManager Module ==============

#include "ScrcpyStreamManager.h"
#include <ace/xcomponent/native_interface_xcomponent.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>

static ScrcpyStreamManager* g_streamManager = nullptr;
static OH_NativeXComponent_Callback g_xComponentCallback;
static std::atomic<bool> g_nativeXComponentCallbacksRegistered{false};

namespace {
constexpr uint8_t CONTROL_MSG_TYPE_TOUCH_EVENT = 2;
constexpr uint8_t CONTROL_TOUCH_ACTION_DOWN = 0;
constexpr uint8_t CONTROL_TOUCH_ACTION_UP = 1;
constexpr uint8_t CONTROL_TOUCH_ACTION_MOVE = 2;
constexpr uint8_t CONTROL_TOUCH_ACTION_CANCEL = 3;

void WriteInt32BE(uint8_t* dest, int32_t value) {
    dest[0] = static_cast<uint8_t>((value >> 24) & 0xFF);
    dest[1] = static_cast<uint8_t>((value >> 16) & 0xFF);
    dest[2] = static_cast<uint8_t>((value >> 8) & 0xFF);
    dest[3] = static_cast<uint8_t>(value & 0xFF);
}

void WriteInt64BE(uint8_t* dest, int64_t value) {
    dest[0] = static_cast<uint8_t>((value >> 56) & 0xFF);
    dest[1] = static_cast<uint8_t>((value >> 48) & 0xFF);
    dest[2] = static_cast<uint8_t>((value >> 40) & 0xFF);
    dest[3] = static_cast<uint8_t>((value >> 32) & 0xFF);
    dest[4] = static_cast<uint8_t>((value >> 24) & 0xFF);
    dest[5] = static_cast<uint8_t>((value >> 16) & 0xFF);
    dest[6] = static_cast<uint8_t>((value >> 8) & 0xFF);
    dest[7] = static_cast<uint8_t>(value & 0xFF);
}

void WriteUint16BE(uint8_t* dest, uint16_t value) {
    dest[0] = static_cast<uint8_t>((value >> 8) & 0xFF);
    dest[1] = static_cast<uint8_t>(value & 0xFF);
}

uint8_t ConvertNativeTouchAction(OH_NativeXComponent_TouchEventType type) {
    switch (type) {
        case OH_NATIVEXCOMPONENT_DOWN:
            return CONTROL_TOUCH_ACTION_DOWN;
        case OH_NATIVEXCOMPONENT_UP:
            return CONTROL_TOUCH_ACTION_UP;
        case OH_NATIVEXCOMPONENT_MOVE:
            return CONTROL_TOUCH_ACTION_MOVE;
        case OH_NATIVEXCOMPONENT_CANCEL:
        default:
            return CONTROL_TOUCH_ACTION_CANCEL;
    }
}

float NormalizePressure(uint8_t action, float force) {
    if (action == CONTROL_TOUCH_ACTION_UP || action == CONTROL_TOUCH_ACTION_CANCEL) {
        return 0.0f;
    }
    return force > 0.0f ? std::min(force, 1.0f) : 1.0f;
}

void SendNativeTouchSample(int32_t pointerId, float localX, float localY, OH_NativeXComponent_TouchEventType type,
                           float force, uint64_t componentWidthVp, uint64_t componentHeightVp) {
    ScrcpyStreamManager* streamManager = g_streamManager;
    if (!streamManager || !streamManager->isRunning()) {
        return;
    }

    int32_t videoWidth = streamManager->getVideoWidth();
    int32_t videoHeight = streamManager->getVideoHeight();
    if (videoWidth <= 0 || videoHeight <= 0 || componentWidthVp == 0 || componentHeightVp == 0) {
        return;
    }

    float clampedX = std::max(0.0f, std::min(localX, static_cast<float>(componentWidthVp)));
    float clampedY = std::max(0.0f, std::min(localY, static_cast<float>(componentHeightVp)));
    int32_t x = static_cast<int32_t>(std::lround((clampedX / static_cast<float>(componentWidthVp)) * videoWidth));
    int32_t y = static_cast<int32_t>(std::lround((clampedY / static_cast<float>(componentHeightVp)) * videoHeight));
    x = std::max(0, std::min(x, videoWidth - 1));
    y = std::max(0, std::min(y, videoHeight - 1));

    uint8_t action = ConvertNativeTouchAction(type);
    float pressure = NormalizePressure(action, force);
    uint16_t pressureU16 = static_cast<uint16_t>(std::lround(std::min(std::max(pressure, 0.0f), 1.0f) * 65535.0f));

    std::array<uint8_t, 32> packet{};
    packet[0] = CONTROL_MSG_TYPE_TOUCH_EVENT;
    packet[1] = action;
    WriteInt64BE(packet.data() + 2, static_cast<int64_t>(pointerId));
    WriteInt32BE(packet.data() + 10, x);
    WriteInt32BE(packet.data() + 14, y);
    WriteUint16BE(packet.data() + 18, static_cast<uint16_t>(videoWidth));
    WriteUint16BE(packet.data() + 20, static_cast<uint16_t>(videoHeight));
    WriteUint16BE(packet.data() + 22, pressureU16);
    WriteInt32BE(packet.data() + 24, 0);
    WriteInt32BE(packet.data() + 28, 0);
    streamManager->sendControl(packet.data(), packet.size());
}

void SendNativeTouchEvent(const OH_NativeXComponent_TouchEvent& event, uint64_t componentWidthVp, uint64_t componentHeightVp) {
    SendNativeTouchSample(event.id, event.x, event.y, event.type, event.force, componentWidthVp, componentHeightVp);
}

void OnSurfaceCreated(OH_NativeXComponent*, void*) {}

void OnSurfaceChanged(OH_NativeXComponent*, void*) {}

void OnSurfaceDestroyed(OH_NativeXComponent*, void*) {}

void DispatchTouchEvent(OH_NativeXComponent* component, void* window) {
    OH_NativeXComponent_TouchEvent touchEvent;
    std::memset(&touchEvent, 0, sizeof(touchEvent));
    if (OH_NativeXComponent_GetTouchEvent(component, window, &touchEvent) != OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        return;
    }

    uint64_t componentWidth = 0;
    uint64_t componentHeight = 0;
    if (OH_NativeXComponent_GetXComponentSize(component, window, &componentWidth, &componentHeight) != OH_NATIVEXCOMPONENT_RESULT_SUCCESS) {
        return;
    }

//    if (touchEvent.type == OH_NATIVEXCOMPONENT_MOVE) {
//        int32_t historicalSize = 0;
//        OH_NativeXComponent_HistoricalPoint* historicalPoints = nullptr;
//        if (OH_NativeXComponent_GetHistoricalPoints(component, window, &historicalSize, &historicalPoints) ==
//            OH_NATIVEXCOMPONENT_RESULT_SUCCESS && historicalPoints && historicalSize > 0) {
//            for (int32_t i = 0; i < historicalSize; ++i) {
//                const OH_NativeXComponent_HistoricalPoint& point = historicalPoints[i];
//                if (point.id != touchEvent.id || point.type != OH_NATIVEXCOMPONENT_MOVE) {
//                    continue;
//                }
//                SendNativeTouchSample(point.id, point.x, point.y, point.type, point.force, componentWidth, componentHeight);
//            }
//        }
//    }

    SendNativeTouchEvent(touchEvent, componentWidth, componentHeight);
}

bool RegisterNativeXComponentCallbacks(napi_env env, napi_value exports) {
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) != napi_ok) {
        return false;
    }

    OH_NativeXComponent* nativeXComponent = nullptr;
    if (napi_unwrap(env, exportInstance, reinterpret_cast<void**>(&nativeXComponent)) != napi_ok || !nativeXComponent) {
        return false;
    }

    std::memset(&g_xComponentCallback, 0, sizeof(g_xComponentCallback));
    g_xComponentCallback.OnSurfaceCreated = OnSurfaceCreated;
    g_xComponentCallback.OnSurfaceChanged = OnSurfaceChanged;
    g_xComponentCallback.OnSurfaceDestroyed = OnSurfaceDestroyed;
    g_xComponentCallback.DispatchTouchEvent = DispatchTouchEvent;

    int32_t ret = OH_NativeXComponent_RegisterCallback(nativeXComponent, &g_xComponentCallback);
    bool registered = ret == OH_NATIVEXCOMPONENT_RESULT_SUCCESS;
    g_nativeXComponentCallbacksRegistered.store(registered, std::memory_order_release);
    return registered;
}
}
static napi_threadsafe_function g_streamCallback = nullptr;

// 事件数据结构（传给 threadsafe function）
struct StreamEventData {
    std::string type;
    std::string data;
};

static moodycamel::ConcurrentQueue<StreamEventData*> g_streamEventPool;
static std::atomic<size_t> g_streamEventPoolSize{0};
static constexpr size_t STREAM_EVENT_POOL_MAX = 256;

static StreamEventData* AcquireStreamEventData()
{
    StreamEventData* item = nullptr;
    if (g_streamEventPool.try_dequeue(item) && item != nullptr) {
        g_streamEventPoolSize.fetch_sub(1, std::memory_order_relaxed);
        return item;
    }
    return new StreamEventData();
}

static void ReleaseStreamEventData(StreamEventData* eventData)
{
    if (!eventData) return;
    eventData->type.clear();
    eventData->data.clear();
    size_t current = g_streamEventPoolSize.load(std::memory_order_relaxed);
    while (current < STREAM_EVENT_POOL_MAX &&
           !g_streamEventPoolSize.compare_exchange_weak(
               current, current + 1, std::memory_order_relaxed, std::memory_order_relaxed)) {
    }
    if (current >= STREAM_EVENT_POOL_MAX) {
        delete eventData;
        return;
    }
    if (!g_streamEventPool.enqueue(eventData)) {
        g_streamEventPoolSize.fetch_sub(1, std::memory_order_relaxed);
        delete eventData;
    }
}

static void ClearStreamEventPool()
{
    StreamEventData* item = nullptr;
    while (g_streamEventPool.try_dequeue(item)) {
        delete item;
    }
    g_streamEventPoolSize.store(0, std::memory_order_relaxed);
}

// JS 侧执行的回调函数
static void StreamEventCallToJS(napi_env env, napi_value jsCb, void* context, void* data) {
    StreamEventData* eventData = static_cast<StreamEventData*>(data);
    if (!eventData || !env || !jsCb) {
        ReleaseStreamEventData(eventData);
        return;
    }

    napi_value argv[2];
    napi_create_string_utf8(env, eventData->type.c_str(), eventData->type.size(), &argv[0]);
    napi_create_string_utf8(env, eventData->data.c_str(), eventData->data.size(), &argv[1]);

    napi_value global;
    napi_get_global(env, &global);
    napi_call_function(env, global, jsCb, 2, argv, nullptr);

    ReleaseStreamEventData(eventData);
}

static bool PrepareStreamCallback(napi_env env, napi_value callback) {
    napi_value callbackName;
    napi_create_string_utf8(env, "streamCallback", NAPI_AUTO_LENGTH, &callbackName);

    if (g_streamCallback) {
        napi_release_threadsafe_function(g_streamCallback, napi_tsfn_abort);
        g_streamCallback = nullptr;
    }

    napi_status status = napi_create_threadsafe_function(
        env, callback, nullptr, callbackName,
        64,
        1,
        nullptr, nullptr, nullptr,
        StreamEventCallToJS,
        &g_streamCallback
    );
    return status == napi_ok;
}

static StreamEventCallback CreateNativeStreamEventCallback() {
    napi_threadsafe_function tsfn = g_streamCallback;
    return [tsfn](const std::string& type, const std::string& data) {
        StreamEventData* eventData = AcquireStreamEventData();
        eventData->type = type;
        eventData->data = data;
        napi_status status = napi_call_threadsafe_function(tsfn, eventData, napi_tsfn_nonblocking);
        if (status != napi_ok) {
            ReleaseStreamEventData(eventData);
        }
    };
}

static napi_value NativeStartStreams(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    int32_t videoStreamId, audioStreamId, controlStreamId;
    char surfaceId[128];
    int32_t audioSampleRate, audioChannelCount;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_int32(env, args[1], &videoStreamId);
    napi_get_value_int32(env, args[2], &audioStreamId);
    napi_get_value_int32(env, args[3], &controlStreamId);
    napi_get_value_string_utf8(env, args[4], surfaceId, sizeof(surfaceId), nullptr);
    napi_get_value_int32(env, args[5], &audioSampleRate);
    napi_get_value_int32(env, args[6], &audioChannelCount);

    if (!g_nativeXComponentCallbacksRegistered.load(std::memory_order_acquire)) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] Native XComponent callbacks are not registered");
        napi_value result;
        napi_create_int32(env, -3, &result);
        return result;
    }

    if (!PrepareStreamCallback(env, args[7])) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] Failed to create threadsafe function");
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    struct NativeStartStreamsContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        ScrcpyStreamManager::Config config;
        bool reverse = false;
        int32_t result = -1;
        std::string errorMsg;
    };

    // 查找 ADB 实例
    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "NativeStartStreams", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new NativeStartStreamsContext();
    context->adbInstance = it->second;
    context->config.videoStreamId = videoStreamId;
    context->config.audioStreamId = audioStreamId;
    context->config.controlStreamId = controlStreamId;
    context->config.surfaceId = surfaceId;
    context->config.audioSampleRate = audioSampleRate;
    context->config.audioChannelCount = audioChannelCount;
    context->config.reverse = false;
    context->config.sendDummyByte = true;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<NativeStartStreamsContext*>(rawData);
            try {
                if (g_streamManager) {
                    g_streamManager->stop();
                    delete g_streamManager;
                    g_streamManager = nullptr;
                }
                g_streamManager = new ScrcpyStreamManager();
                auto eventCallback = CreateNativeStreamEventCallback();
                context->result = g_streamManager->start(context->adbInstance.get(), context->config, eventCallback);
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<NativeStartStreamsContext*>(rawData);
            napi_value result;
            if (context->errorMsg.empty()) {
                napi_create_int32(env, context->result, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] NativeStartStreams failed: %{public}s", context->errorMsg.c_str());
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &result);
                napi_value error;
                napi_create_error(env, nullptr, result, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

static napi_value NativeStartReverseStreams(napi_env env, napi_callback_info info) {
    size_t argc = 8;
    napi_value args[8];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int64_t adbId;
    bool expectVideo = true;
    bool expectAudio = false;
    bool expectControl = true;
    char surfaceId[128];
    int32_t audioSampleRate = 48000;
    int32_t audioChannelCount = 2;

    napi_get_value_int64(env, args[0], &adbId);
    napi_get_value_bool(env, args[1], &expectVideo);
    napi_get_value_bool(env, args[2], &expectAudio);
    napi_get_value_bool(env, args[3], &expectControl);
    napi_get_value_string_utf8(env, args[4], surfaceId, sizeof(surfaceId), nullptr);
    napi_get_value_int32(env, args[5], &audioSampleRate);
    napi_get_value_int32(env, args[6], &audioChannelCount);

    if (!g_nativeXComponentCallbacksRegistered.load(std::memory_order_acquire)) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] Native XComponent callbacks are not registered");
        napi_value result;
        napi_create_int32(env, -3, &result);
        return result;
    }

    if (!PrepareStreamCallback(env, args[7])) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] Failed to create reverse threadsafe function");
        napi_value result;
        napi_create_int32(env, -1, &result);
        return result;
    }

    struct NativeStartReverseStreamsContext {
        napi_async_work work = nullptr;
        napi_deferred deferred = nullptr;
        std::shared_ptr<Adb> adbInstance;
        ScrcpyStreamManager::Config config;
        int32_t result = -1;
        std::string errorMsg;
    };

    auto it = g_adbInstances.find(adbId);
    if (it == g_adbInstances.end()) {
        napi_throw_error(env, nullptr, "Adb instance not found");
        return nullptr;
    }

    napi_value resourceName;
    napi_create_string_utf8(env, "NativeStartReverseStreams", NAPI_AUTO_LENGTH, &resourceName);

    auto* context = new NativeStartReverseStreamsContext();
    context->adbInstance = it->second;
    context->config.videoStreamId = -1;
    context->config.audioStreamId = -1;
    context->config.controlStreamId = -1;
    context->config.surfaceId = surfaceId;
    context->config.audioSampleRate = audioSampleRate;
    context->config.audioChannelCount = audioChannelCount;
    context->config.reverse = true;
    context->config.expectVideo = expectVideo;
    context->config.expectAudio = expectAudio;
    context->config.expectControl = expectControl;
    context->config.sendDummyByte = false;

    napi_value promise;
    napi_create_promise(env, &context->deferred, &promise);

    napi_create_async_work(
        env, nullptr, resourceName,
        [](napi_env, void* rawData) {
            auto* context = static_cast<NativeStartReverseStreamsContext*>(rawData);
            try {
                if (g_streamManager) {
                    g_streamManager->stop();
                    delete g_streamManager;
                    g_streamManager = nullptr;
                }
                g_streamManager = new ScrcpyStreamManager();
                auto eventCallback = CreateNativeStreamEventCallback();
                std::vector<std::string> expectedStreamKinds;
                if (context->config.expectVideo) {
                    expectedStreamKinds.emplace_back("video");
                }
                if (context->config.expectAudio) {
                    expectedStreamKinds.emplace_back("audio");
                }
                if (context->config.expectControl) {
                    expectedStreamKinds.emplace_back("control");
                }
                context->adbInstance->prepareIncomingStreamKinds(expectedStreamKinds);
                context->result = g_streamManager->startReverse(context->adbInstance.get(), context->config, eventCallback);
            } catch (const std::exception& e) {
                context->errorMsg = e.what();
            }
        },
        [](napi_env env, napi_status, void* rawData) {
            auto* context = static_cast<NativeStartReverseStreamsContext*>(rawData);
            napi_value result;
            if (context->errorMsg.empty()) {
                napi_create_int32(env, context->result, &result);
                napi_resolve_deferred(env, context->deferred, result);
            } else {
                OH_LOG_ERROR(LOG_APP, "[NAPI] NativeStartReverseStreams failed: %{public}s", context->errorMsg.c_str());
                napi_create_string_utf8(env, context->errorMsg.c_str(), NAPI_AUTO_LENGTH, &result);
                napi_value error;
                napi_create_error(env, nullptr, result, &error);
                napi_reject_deferred(env, context->deferred, error);
            }
            napi_delete_async_work(env, context->work);
            delete context;
        },
        context,
        &context->work
    );

    napi_queue_async_work(env, context->work);
    return promise;
}

// nativeStopStreams()
static napi_value NativeStopStreams(napi_env env, napi_callback_info info) {
    if (g_streamManager) {
        g_streamManager->stop();
        delete g_streamManager;
        g_streamManager = nullptr;
    }

    if (g_streamCallback) {
        napi_release_threadsafe_function(g_streamCallback, napi_tsfn_release);
        g_streamCallback = nullptr;
    }
    ClearStreamEventPool();

    napi_value result;
    napi_get_undefined(env, &result);
    return result;
}

// nativeSendControl(data: ArrayBuffer) => boolean
static napi_value NativeSendControl(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    void* data;
    size_t dataSize;
    napi_get_arraybuffer_info(env, args[0], &data, &dataSize);

    bool accepted = false;
    if (g_streamManager && dataSize > 0) {
        accepted = g_streamManager->sendControl(static_cast<uint8_t*>(data), dataSize);
    }

    napi_value result;
    napi_get_boolean(env, accepted, &result);
    return result;
}

// ============== Module Registration ==============

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        // 视频API
        {"createVideoDecoder", nullptr, CreateVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initVideoDecoder", nullptr, InitVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startVideoDecoder", nullptr, StartVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushVideoData", nullptr, PushVideoData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseVideoDecoder", nullptr, ReleaseVideoDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        // 音频API
        {"createAudioDecoder", nullptr, CreateAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initAudioDecoder", nullptr, InitAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startAudioDecoder", nullptr, StartAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushAudioData", nullptr, PushAudioData, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseAudioDecoder", nullptr, ReleaseAudioDecoder, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Native Buffer

        // ADB API
        {"adbCreate", nullptr, AdbCreate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbConnect", nullptr, AdbConnect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbGetLastConnectError", nullptr, AdbGetLastConnectError, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbPair", nullptr, AdbPair, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbRunCmd", nullptr, AdbRunCmd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbExecShell", nullptr, AdbExecShell, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbInstallPackage", nullptr, AdbInstallPackage, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbInstallPackageFromFd", nullptr, AdbInstallPackageFromFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbPushFile", nullptr, AdbPushFile, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbPushFileFromFd", nullptr, AdbPushFileFromFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbListDirectory", nullptr, AdbListDirectory, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbPullFileToFd", nullptr, AdbPullFileToFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbTcpForward", nullptr, AdbTcpForward, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbLocalSocketForward", nullptr, AdbLocalSocketForward, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbReverse", nullptr, AdbReverse, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbReverseRemove", nullptr, AdbReverseRemove, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbGetShell", nullptr, AdbGetShell, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbRestartOnTcpip", nullptr, AdbRestartOnTcpip, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbStreamRead", nullptr, AdbStreamRead, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbStreamWrite", nullptr, AdbStreamWrite, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbStreamClose", nullptr, AdbStreamClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbIsStreamClosed", nullptr, AdbIsStreamClosed, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbClose", nullptr, AdbClose, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbGenerateKeyPair", nullptr, AdbGenerateKeyPair, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"adbIsConnected", nullptr, AdbIsConnected, nullptr, nullptr, nullptr, napi_default, nullptr},

        // Stream Manager API
        {"nativeStartStreams", nullptr, NativeStartStreams, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeStartReverseStreams", nullptr, NativeStartReverseStreams, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeStopStreams", nullptr, NativeStopStreams, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"nativeSendControl", nullptr, NativeSendControl, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    if (!RegisterNativeXComponentCallbacks(env, exports)) {
        OH_LOG_ERROR(LOG_APP, "[NAPI] Failed to register Native XComponent callbacks");
    }
    return exports;
}
EXTERN_C_END

static napi_module demoModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "scrcpy_native",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterModule(void) {
    napi_module_register(&demoModule);
}
