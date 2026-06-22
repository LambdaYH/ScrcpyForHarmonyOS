// 额外参数接口
export interface ExtraParam {
  key: string;
  value: string;
}

// 设备实体类
export class Device {
  uuid: string = '';
  name: string = '';
  address: string = '';
  adbPort: number = 5555;
  type: number = Device.TYPE_NETWORK;

  // 视频参数
  videoCodec: string = 'h265'; // 'h264', 'h265'
  maxSize: number = 0;
  maxFps: number = 0;
  maxVideoBit: number = 0; // bps
  crop: string = ''; // 格式: "width:height:x:y"
  displayId: number = 0;
  captureOrientation: number = -1; // -1 for auto/default, or 0, 90, 180, 270

  // 显示设置
  showBottomNavBar: boolean = true; // 底部显示导航栏
  autoSwitchOrientation: boolean = true; // 根据目标设备画面自动切换控制页横竖屏
  fileReceivePath: string = '/sdcard/Download/'; // 文件收发默认路径

  // 音频参数
  isAudio: boolean = true;
  audioCodec: string = 'opus'; // 'opus', 'aac', 'raw', 'flac'
  maxAudioBit: number = 0; // bps

  // 连接时操作
  wakeOnConnect: boolean = true;
  lightOffOnConnect: boolean = false;
  keepScreenOnWhileConnected: boolean = true;

  // 运行时操作
  stayAwake: boolean = true; // 原 keepAwake
  showTouches: boolean = false;
  clipboardAutosync: boolean = true; // 原 listenClipOnRunning
  cleanup: boolean = true;

  // 断开时操作
  powerOffScreenOnClose: boolean = false;
  autoReconnect: boolean = true;

  // 高级选项
  downsizeOnError: boolean = true;
  forceAdbForward: boolean = false;
  forcePhysicalKeyboard: boolean = false;
  connectOnStart: boolean = false;
  logLevel: string = 'info'; // 'verbose', 'debug', 'info', 'warn', 'error'
  
  // 额外参数 (key-value pairs for custom server arguments)
  extraParams: ExtraParam[] = [];

  static readonly TYPE_NETWORK: number = 0;

  constructor(uuid?: string, type?: number) {
    if (uuid) {
      this.uuid = uuid;
    }
    if (type !== undefined) {
      this.type = type;
    }
  }

  isNetworkDevice(): boolean {
    return this.type === Device.TYPE_NETWORK;
  }
}
