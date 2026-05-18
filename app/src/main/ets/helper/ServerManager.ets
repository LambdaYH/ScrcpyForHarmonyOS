// ServerManager - 服务端管理器
// Scrcpy官方服务端启动逻辑 - Refactored for Native ADB
import { Device } from '../entity/Device';
import { LoggerServerManager } from './Logger';



export class ServerManager {
  // Scrcpy版本号 - 必须与rawfile中的服务端版本匹配
  private static readonly SCRCPY_VERSION = '3.3.4';
  // 服务端文件名包含版本号，确保版本更新后不混淆
  // Made public for ClientStream usage
  public static readonly SERVER_PATH = `/data/local/tmp/scrcpy-server-${ServerManager.SCRCPY_VERSION}`;
  
  // 最后生成的SCID
  private static lastScid: string = '';

  // 获取当前Scrcpy版本
  static getVersion(): string {
    return ServerManager.SCRCPY_VERSION;
  }

  // 从rawfile加载server
  static async loadServerFromRawfile(context: Context): Promise<ArrayBuffer | null> {
    try {
      const resMgr = context.resourceManager;
      const fileName = `scrcpy-server-v${ServerManager.SCRCPY_VERSION}`;
      LoggerServerManager.debug(`Loading server from rawfile: ${fileName}`);
      const rawFileData = await resMgr.getRawFileContent(fileName);
      return rawFileData.buffer;
    } catch (err) {
      LoggerServerManager.error('Load rawfile failed:', err);
      return null;
    }
  }

  // 生成随机scid（31位非负整数的十六进制表示，避免Java端NumberFormatException）
  private static generateScid(): string {
    // Generate a random integer between 0 and 0x7FFFFFFF (31-bit positive integer)
    const scid = Math.floor(Math.random() * 0x80000000);
    const scidHex = scid.toString(16).padStart(8, '0');
    ServerManager.lastScid = scidHex;
    return scidHex;
  }
  
  // 获取最后生成的SCID（用于连接socket）
  static getLastScid(): string {
    return ServerManager.lastScid;
  }
  
  // 获取socket名称
  static getSocketName(): string {
    return `scrcpy_${ServerManager.lastScid}`;
  }

  // 构建scrcpy启动参数
  static buildServerArgs(device: Device, tunnelForward: boolean = true): string {
    const args: string[] = [];
    // 记录已添加的参数键，用于过滤 extraParams 中的重复项
    const reservedKeys = new Set<string>();

    // 辅助函数：添加参数并记录键名
    const addArg = (key: string, value: string | number | boolean): void => {
      reservedKeys.add(key);
      args.push(`${key}=${value}`);
    };

    // 必需参数
    addArg('scid', ServerManager.generateScid());

    // 视频参数
    addArg('video_codec', device.videoCodec);
    // max_size 为 0 时不传递，使用原始分辨率
    if (device.maxSize) {
      addArg('max_size', device.maxSize);
    }
    // max_fps 为 0 时不传递，使用原始帧率
    if (device.maxFps) {
      addArg('max_fps', device.maxFps);
    }
    // video_bit_rate 为 0 时不传递，使用服务端默认值
    if (device.maxVideoBit) {
      addArg('video_bit_rate', device.maxVideoBit);
    }
    if (device.crop) {
      addArg('crop', device.crop);
    }
    if (device.displayId !== 0) {
      addArg('display_id', device.displayId);
    }
    if (device.captureOrientation !== undefined && device.captureOrientation >= 0) {
      addArg('capture_orientation', `${device.captureOrientation}`);
    }

    // 音频参数
    // audio=true is default, remove. Only send if false.
    if (!device.isAudio) {
      addArg('audio', false);
    } else {
      addArg('audio_codec', device.audioCodec);
      // audio_bit_rate 为 0 时不传递，使用服务端默认值
      if (device.maxAudioBit) {
        addArg('audio_bit_rate', device.maxAudioBit);
      }
    }

    // 控制和行为参数
    addArg('control', true);

    // Always reserve this key so legacy extraParams cannot silently override
    // the selected tunnel mode.
    reservedKeys.add('tunnel_forward');
    if (tunnelForward) {
      addArg('tunnel_forward', true);
    }

    addArg('show_touches', device.showTouches);
    addArg('stay_awake', device.stayAwake);
    if (!device.wakeOnConnect) {
      addArg('power_on', false);
    }
    addArg('power_off_on_close', device.powerOffScreenOnClose);
    addArg('clipboard_autosync', device.clipboardAutosync);
    addArg('downsize_on_error', device.downsizeOnError);
    
    addArg('cleanup', device.cleanup);

    if (device.logLevel !== 'info') {
      addArg('log_level', device.logLevel);
    }
    
    // 额外参数（用户自定义）
    // 自动过滤掉已存在的参数键，避免冲突
    if (device.extraParams && device.extraParams.length > 0) {
      for (const param of device.extraParams) {
        if (param.key && param.key.trim()) {
          // 自动将中划线转换为下划线（与官方scrcpy CLI行为一致）
          const key = param.key.trim().replace(/-/g, '_');
          
          // 如果参数键已存在于 reservedKeys 中，则跳过
          if (reservedKeys.has(key)) {
            continue;
          }
          
          args.push(`${key}=${param.value || ''}`);
        }
      }
    }

    return args.join(' ');
  }
}
