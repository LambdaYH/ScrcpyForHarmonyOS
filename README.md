# scrcpy for HarmonyOS

`scrcpy mobile` 是一个运行在 HarmonyOS 上的第三方 scrcpy 客户端，用于通过 ADB TCP/IP 或 Android 无线调试连接并控制 Android 设备。项目使用 ArkTS 构建界面，使用 C++/NAPI 实现 ADB、媒体流、解码和控制通道。

<a href="https://appgallery.huawei.com/app/detail?id=com.lambdayh.scrcpyHmos&channelId=SHARE&source=appshare">
  <img src="Huawei_AppGallery_white_badge_EN.png" alt="Explore it on AppGallery" width="180">
</a>

> 本项目不是 Genymobile/scrcpy 官方客户端。内置的 `scrcpy-server` 来自官方 scrcpy，客户端代码遵循 GPL-3.0。

## 功能特性

- 通过网络 ADB 连接 Android 设备，支持传统 `adb tcpip` 和 Android 无线调试配对。
- 使用内置 `scrcpy-server-v3.3.4` 启动被控端服务。
- 支持视频镜像、触控控制、返回/Home/最近任务等快捷操作。
- 支持音频转发，音频能力依赖 Android 版本和设备编码支持。
- 支持 H.264、H.265、AV1 等视频编码配置，以及 OPUS、AAC、RAW、FLAC 等音频配置。
- 支持分辨率、帧率、码率、裁剪、显示器 ID、屏幕方向等 scrcpy 参数。
- 支持剪贴板同步、文件发送和 APK 安装。
- 支持 ADB 全局密钥管理、重新生成密钥和自定义密钥导入。
- 支持浅色/深色主题、中英文语言、应用日志查看。
- 默认优先尝试 ADB reverse 建链，失败后回退到 ADB forward；也可以在设备配置中强制使用 forward。

## 使用前准备

### 控制端

- HarmonyOS 手机或平板。
- 与被控 Android 设备处在可互通的网络环境。

### 被控端

- Android 设备。
- 已开启开发者选项。
- 已开启 USB 调试或无线调试。
- 首次连接时需要在 Android 设备上确认 `允许 USB 调试`。

## 连接方式

### 方式一：传统 ADB TCP/IP

1. 在 Android 设备上开启 `开发者选项` 和 `USB 调试`。
2. 将 Android 设备连接到电脑，确认 ADB 可用：

   ```bash
   adb devices
   ```

3. 切换到 TCP/IP 模式：

   ```bash
   adb tcpip 5555
   ```

4. 查看 Android 设备 IP 地址，确保 HarmonyOS 设备可以访问该地址。
5. 在本应用中添加设备：
   - 地址：Android 设备 IP，例如 `192.168.1.10`
   - ADB 端口：上一步设置的端口，例如 `5555`
6. 保存后点击连接。首次连接时，在 Android 设备上点击授权。

### 方式二：Android 无线调试配对

1. 在 Android 设备上进入 `开发者选项 > 无线调试` 并开启。
2. 点击 `使用配对码配对设备`，记录页面显示的配对地址、配对端口和 6 位配对码。
3. 在本应用进入 `更多 > 无线 ADB 配对`，输入 `IP:配对端口` 和配对码完成配对。
4. 配对成功后，回到 Android 的无线调试页面，记录用于连接的端口。
5. 在本应用添加或编辑设备：
   - 地址：Android 设备 IP
   - ADB 端口：无线调试页面显示的连接端口，不是配对端口
6. 保存后点击连接。

## 主要配置说明

### 视频

- `视频编码`：选择 H.264、H.265 或 AV1。实际可用性取决于 Android 设备和 HarmonyOS 端解码能力。
- `最大尺寸`：限制视频宽高最大值，`0` 表示使用原始分辨率。
- `最大帧率`：限制采集帧率，`0` 表示不限制。
- `比特率`：视频码率，`0` 表示使用服务端默认值。
- `裁剪区域`：格式为 `宽:高:X:Y`。
- `屏幕旋转`：指定采集方向，可选 0、90、180、270 度。

### 音频

- `启用音频`：开启 Android 设备音频转发。
- `音频编码`：支持 OPUS、AAC、RAW、FLAC，具体取决于设备能力。
- `音频比特率`：`0` 表示使用服务端默认值。

### 行为

- `显示触摸点`：在被控设备上显示触摸轨迹。
- `保持唤醒`：连接期间避免被控设备休眠。
- `剪贴板同步`：自动同步被控设备剪贴板，并支持手动发送本机剪贴板。
- `连接时亮屏/熄屏`、`断开时熄屏`：控制被控设备屏幕状态。
- `错误时降低分辨率`：编码失败时自动降级重试。
- `强制使用 ADB Forward`：关闭 reverse 优先策略，始终使用传统 forward 连接。
- `额外参数`：以 `key=value` 形式传递未在界面中暴露的 scrcpy-server 参数。已由界面管理的参数会被自动过滤，避免冲突。

## 开发与构建

建议使用 DevEco Studio 打开工程，并在 DevEco Studio 终端中执行构建命令。如果环境中存在 wrapper，优先使用 `hvigorw.bat` 或 `hvigorw`。

```bash
hvigor clean
hvigor assembleHap
```

显式构建 app 模块：

```bash
hvigor --mode module -p module=app@default -p product=default assembleHap
```

运行 ohosTest：

```bash
hvigor --mode module -p module=app@ohosTest test
```

## 项目结构

```text
app/src/main/ets/                 ArkTS 源码
app/src/main/ets/pages/           页面入口和 UI
app/src/main/ets/client/          流媒体和控制客户端逻辑
app/src/main/ets/helper/          日志、会话、ADB、服务端参数等辅助逻辑
app/src/main/ets/entity/          设备配置实体
app/src/main/cpp/                 C++ NAPI、ADB、解码和流处理
app/src/main/cpp/adb/             ADB 协议、通道、TLS 配对和密钥处理
app/src/main/cpp/decoder/         原生视频/音频解码封装
app/src/main/cpp/manager/         scrcpy 视频、音频、控制流生命周期管理
app/src/main/resources/           资源、国际化文本、图标和内置 scrcpy-server
app/src/test/                     本地单元测试
app/src/ohosTest/                 设备/Ability 测试
sample/                           外部示例，不属于核心应用代码
```

## Native 模块

原生库名为 `libscrcpy_native.so`，主要能力包括：

- ADB 创建、连接、认证、关闭。
- Android 无线调试配对。
- ADB shell、push 文件、安装 APK。其中 shell 能力主要供应用内部流程调用，不作为独立的用户入口。
- local socket forward、reverse forward。
- 视频/音频解码和渲染。
- scrcpy 控制包发送。
- reverse/forward 两种流处理模式。

## 常见问题

### 连接超时

- 确认 Android 设备已开启 USB 调试或无线调试。
- 首次连接时检查 Android 设备是否弹出授权框。
- 确认 HarmonyOS 设备和 Android 设备处在同一网络，且 IP 和端口填写正确。
- 使用无线调试时，注意配对端口和连接端口不同。

### 无线调试握手失败

- 重新打开 Android 无线调试页面。
- 重新执行无线 ADB 配对。
- 添加设备时使用无线调试页面显示的连接端口，而不是配对端口。

### 没有画面或编码失败

- 尝试降低最大尺寸、帧率或码率。
- 尝试切换视频编码，例如从 H.265 改为 H.264。
- 保持 `错误时降低分辨率` 开启。
- 查看应用日志和 Android 端 scrcpy-server 日志。

### 没有声音

- Android 音频转发通常要求 Android 11+。
- 尝试关闭音频后重新连接，确认视频控制链路是否正常。
- 尝试切换音频编码。

### APK 安装失败

- 在 Android 开发者选项中开启 `USB 安装` 或同类 ADB 安装授权。
- 检查系统是否限制未知来源或通过 ADB 安装应用。

## 相关项目

- [scrcpy](https://github.com/Genymobile/scrcpy)
- [Easycontrol](https://github.com/mingzhixian/Easycontrol)

## 开源协议

- 客户端：GPL-3.0，详见 [LICENSE](LICENSE)。
- 内置 `scrcpy-server`：来自 Genymobile/scrcpy，遵循其对应开源协议；本应用分发的服务端二进制未进行源码修改。
