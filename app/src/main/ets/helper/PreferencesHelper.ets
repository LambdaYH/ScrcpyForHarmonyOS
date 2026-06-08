import preferences from '@ohos.data.preferences';
import { Device } from '../entity/Device';
import { LoggerPreferences } from './Logger';

// 数据持久化管理
export class PreferencesHelper {
  private static instance: PreferencesHelper;
  private preferences?: preferences.Preferences;
  private devicesList: Device[] = [];

  private constructor() {}

  static getInstance(): PreferencesHelper {
    if (!PreferencesHelper.instance) {
      PreferencesHelper.instance = new PreferencesHelper();
    }
    return PreferencesHelper.instance;
  }

  async init(context: Context): Promise<void> {
    try {
      this.preferences = await preferences.getPreferences(context, 'device_prefs');
      await this.loadDevices();
    } catch (err) {
      LoggerPreferences.error('PreferencesHelper init failed:', err);
    }
  }

  private async loadDevices(): Promise<void> {
    try {
      if (!this.preferences) return;

      const devicesStr = await this.preferences.get('devices', '[]') as string;
      const devicesData: Device[] = this.parseDevices(devicesStr);

      this.devicesList = devicesData.map((data: Device) => {
        const device = new Device(data.uuid, data.type);
        this.assignDeviceData(device, data);
        return device;
      });
    } catch (err) {
      LoggerPreferences.error('Load devices failed:', err);
      this.devicesList = [];
    }
  }

  private parseDevices(jsonStr: string): Device[] {
    try {
      return JSON.parse(jsonStr) as Device[];
    } catch (e) {
      return [];
    }
  }

  private assignDeviceData(target: Device, source: Device): void {
    target.uuid = source.uuid;
    target.name = source.name;
    target.address = source.address;
    target.adbPort = source.adbPort ?? 5555;
    target.type = source.type ?? Device.TYPE_NETWORK;

    // 视频参数
    target.videoCodec = source.videoCodec ?? 'h264';
    target.maxSize = source.maxSize ?? 1920;
    target.maxFps = source.maxFps ?? 60;
    target.maxVideoBit = source.maxVideoBit ?? 8000000;
    target.crop = source.crop ?? '';
    target.displayId = source.displayId ?? 0;

    // 显示设置
    target.showBottomNavBar = source.showBottomNavBar ?? false;
    target.autoSwitchOrientation = source.autoSwitchOrientation ?? true;
    target.fileReceivePath = source.fileReceivePath ?? '/sdcard/Download/';

    // 音频参数
    target.isAudio = source.isAudio ?? true;
    target.audioCodec = source.audioCodec ?? 'opus';
    target.maxAudioBit = source.maxAudioBit ?? 128000;

    // 连接时操作
    target.wakeOnConnect = source.wakeOnConnect ?? true;
    target.lightOffOnConnect = source.lightOffOnConnect ?? false;
    target.keepScreenOnWhileConnected = source.keepScreenOnWhileConnected ?? true;

    // 运行时操作
    // 兼容旧数据：keepAwake -> stayAwake
    target.stayAwake = source.stayAwake ?? true;
    target.showTouches = source.showTouches ?? false;
    // 兼容旧数据：listenClipOnRunning -> clipboardAutosync
    target.clipboardAutosync = source.clipboardAutosync ?? true;

    // 断开时操作
    target.powerOffScreenOnClose = source.powerOffScreenOnClose ?? false;
    target.autoReconnect = source.autoReconnect ?? true;

    // 高级选项
    target.downsizeOnError = source.downsizeOnError ?? true;
    target.forceAdbForward = source.forceAdbForward ?? false;
    target.forcePhysicalKeyboard = source.forcePhysicalKeyboard ?? false;
    target.connectOnStart = source.connectOnStart ?? false;
    target.logLevel = source.logLevel ?? 'info';
    
    // 额外参数
    target.extraParams = source.extraParams ?? [];
  }

  async saveDevices(): Promise<void> {
    try {
      if (!this.preferences) return;

      const devicesStr = JSON.stringify(this.devicesList);
      await this.preferences.put('devices', devicesStr);
      await this.preferences.flush();
    } catch (err) {
      LoggerPreferences.error('Save devices failed:', err);
    }
  }

  getDevicesList(): Device[] {
    return this.devicesList;
  }

  async insert(device: Device): Promise<void> {
    this.devicesList.push(device);
    await this.saveDevices();
  }

  async update(device: Device): Promise<void> {
    const index = this.devicesList.findIndex(d => d.uuid === device.uuid);
    if (index !== -1) {
      this.devicesList[index] = device;
      await this.saveDevices();
    }
  }

  async delete(uuid: string): Promise<void> {
    this.devicesList = this.devicesList.filter(d => d.uuid !== uuid);
    await this.saveDevices();
  }

  getByUUID(uuid: string): Device | null {
    return this.devicesList.find(d => d.uuid === uuid) || null;
  }

  async saveThemeMode(mode: string): Promise<void> {
    try {
      if (!this.preferences) return;
      await this.preferences.put('theme_mode', mode);
      await this.preferences.flush();
    } catch (err) {
      LoggerPreferences.error('Save theme mode failed:', err);
    }
  }

  async getThemeMode(): Promise<string> {
    try {
      if (!this.preferences) return 'system';
      const val = await this.preferences.get('theme_mode', 'system');
      return val as string;
    } catch (err) {
      LoggerPreferences.error('Get theme mode failed:', err);
      return 'system';
    }
  }

  async saveLanguage(lan: string): Promise<void> {
    try {
      if (!this.preferences) return;
      await this.preferences.put('language', lan);
      await this.preferences.flush();
    } catch (err) {
      LoggerPreferences.error('Save language failed:', err);
    }
  }

  async getLanguage(): Promise<string> {
    try {
      if (!this.preferences) return 'system';
      const val = await this.preferences.get('language', 'system');
      return val as string;
    } catch (err) {
      LoggerPreferences.error('Get language failed:', err);
      return 'system';
    }
  }
}
