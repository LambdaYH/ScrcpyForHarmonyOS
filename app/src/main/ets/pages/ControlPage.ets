import { Device } from '../entity/Device';
import { KeyCode, ControlPacket } from '../client/tools/ControlPacket';
import { KeyboardUhidController } from '../client/tools/KeyboardUhidController';
import { LoggerControlPage } from '../helper/Logger';
import { NativeStreamClient, NativeStreamListener } from '../client/tools/NativeStreamClient';
import { ServerManager } from '../helper/ServerManager';
import { ClientSessionManager } from '../helper/ClientSessionManager';
import { AdbTransferService } from '../helper/AdbTransferService';
import { TransferNotificationHelper } from '../helper/TransferNotificationHelper';
import window from '@ohos.window';

import { common } from '@kit.AbilityKit';
import { inputDevice } from '@kit.InputKit';
import { picker } from '@kit.CoreFileKit';
import fs from '@ohos.file.fs';
import pasteboard from '@ohos.pasteboard';
import * as libscrcpy from 'libscrcpy_native.so';

@Entry
@Component
struct ControlPage {
  @State device?: Device = undefined;
  @State surfaceId: string = '';
  @State videoWidth: number = 1920;
  @State videoHeight: number = 1080;
  @State containerWidth: number = 0;    // 容器宽度(vp)
  @State containerHeight: number = 0;   // 容器高度(vp)
  @State displayXComponentWidth: number = 0; // 计算后的显示宽度
  @State displayXComponentHeight: number = 0; // 计算后的显示高度

  // 手动横竖屏状态
  @State isLandscape: boolean = false;
  private appliedAutoOrientation: string = '';

  @State isConnected: boolean = false;
  @State connectionStatus: string = '';
  @State showLoading: boolean = true;

  // 悬浮按钮状态
  @State showControlPanel: boolean = false;  // 控制面板是否展开
  @State fabX: number = 0; // 悬浮按钮X位置
  @State fabY: number = 0; // 悬浮按钮Y位置
  @State checkFabPosition: boolean = false; // 是否需要初始化位置
  @State fabDockedLeft: boolean = false; // 悬浮按钮是否吸附在左侧

  // Native Client 实例
  private nativeClient?: NativeStreamClient;
  private serverJarData: ArrayBuffer | null = null;
  private isStarted: boolean = false;
  private isInitializingClient: boolean = false;
  private isStartingSession: boolean = false;
  private xComponentController: XComponentController = new XComponentController();
  private surfaceReady: boolean = false;
  private context?: common.UIAbilityContext;
  private autoHideTimer: number = -1;
  private readonly FAB_SIZE = 30; // 悬浮按钮大小
  private readonly BOTTOM_SAFE_AREA = 28; // 底部安全区域高度(系统导航条)
  private readonly KEYBOARD_FOCUS_ID: string = 'control_page_keyboard_root';
  // 临时存储拖动开始时的位置
  private dragStartX: number = 0;
  private dragStartY: number = 0;
  private hasReceivedFirstFrame: boolean = false;
  private isTransferBusy: boolean = false;
  private keyboardUhid?: KeyboardUhidController;
  private isKeyboardUhidInitializing: boolean = false;
  private inputDeviceChangeListener?: (data: inputDevice.DeviceListener) => void;
  private keyboardSyncToken: number = 0;
  private isKeyboardAvailabilitySyncing: boolean = false;
  private keyboardAvailabilityResyncRequested: boolean = false;
  @State sendFileTargetPath: string = '/sdcard/Download/';
  @State showSendFilePathDialog: boolean = false;
  private pendingSendFilePathResolve?: (value: string | undefined) => void;
  @State stepTime: number = 0;
  private stepTimer: number = -1;

  // Start the step timer (resets count)
  private startStepTimer() {
    this.stopStepTimer();

    this.stepTime = 0;
    this.stepTimer = setInterval(() => {
      this.stepTime++;
    }, 1000);
  }

  @Builder fabButtons() {
    // 返回上一页（Android返回键）
    Button() {
      SymbolGlyph($r('sys.symbol.arrow_left'))
        .fontSize(24)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .backgroundColor('#80000000')
    .borderRadius(22)
    .onClick(() => {
      this.sendKeyToWorker(KeyCode.KEYCODE_BACK);
    })

    // 主页（Android Home键）
    Button() {
      SymbolGlyph($r('sys.symbol.house'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .backgroundColor('#80000000')
    .borderRadius(22)
    .onClick(() => {
      this.sendKeyToWorker(KeyCode.KEYCODE_HOME);
    })

    // 多任务界面（Android Recent Apps键）
    Button() {
      SymbolGlyph($r('sys.symbol.square'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .backgroundColor('#80000000')
    .borderRadius(22)
    .onClick(() => {
      this.sendKeyToWorker(KeyCode.KEYCODE_APP_SWITCH);
    })

    // 旋转屏幕按钮
    Button() {
      SymbolGlyph($r('sys.symbol.rectangle_rotate'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .backgroundColor('#80000000')
    .borderRadius(22)
    .onClick(async () => {
      try {
        const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
        const windowClass = await window.getLastWindow(ctx);
        this.isLandscape = !this.isLandscape;
        if (this.isLandscape) {
          // 手动横屏
          await windowClass.setPreferredOrientation(window.Orientation.LANDSCAPE_INVERTED);
        } else {
          // 恢复自动（受限于系统锁定）
          await windowClass.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
        }
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.rotate_screen') });
      } catch (err) {
        LoggerControlPage.error('Save rotation failed', err);
      }
    })
    
    // 剪贴板同步按钮 - 使用安全控件
    PasteButton({ icon: PasteIconStyle.LINES, buttonType: ButtonType.Circle })
      .width(44)
      .height(44)
      .backgroundColor('#80000000')
      .onClick(async (_event: ClickEvent, result: PasteButtonOnClickResult) => {
        if (result === PasteButtonOnClickResult.SUCCESS) {
          try {
            const systemPasteboard = pasteboard.getSystemPasteboard();
            const hasData = await systemPasteboard.hasData();
            if (!hasData) {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_empty') });
              return;
            }
            const pasteData = await systemPasteboard.getData();
            const text = pasteData.getPrimaryText();
            if (text && this.nativeClient) {
              // 发送到 Native
              const packet = ControlPacket.createSetClipboard(text, 0n, true);
              this.nativeClient.sendControl(packet);
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_synced') });
            } else {
              this.getUIContext().getPromptAction().showToast({ message: $r('app.string.clipboard_no_text') });
            }
          } catch (err) {
            LoggerControlPage.error('Paste failed:', err);
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.paste_failed') });
          }
        }
      })

    // 发送文件
    Button() {
      SymbolGlyph($r('sys.symbol.arrow_right_folder_circle'))
        .fontSize(20)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .backgroundColor('#80000000')
    .borderRadius(22)
    .onClick(() => {
      void this.handleSendFile();
    })

    // 安装应用
    Button() {
      SymbolGlyph($r('sys.symbol.more'))
        .fontSize(20)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .backgroundColor('#80000000')
    .borderRadius(22)
    .onClick(() => {
      void this.handleInstallPackage();
    })
    
    // 断开连接并返回
    Button() {
      SymbolGlyph($r('sys.symbol.xmark'))
        .fontSize(22)
        .fontColor(['#FFFFFF'])
    }
    .width(44)
    .height(44)
    .borderRadius(22)
    .onClick(() => {
      this.exitPage();
    })
  }

  // Stop the step timer
  private stopStepTimer() {
    if (this.stepTimer !== -1) {
      clearInterval(this.stepTimer);
      this.stepTimer = -1;
    }
  }

  // Helper to update status and restart timer
  private updateConnectionStatus(status: string) {
    this.connectionStatus = status;
    this.startStepTimer();
  }

  private applyWaitingForFirstFrameStatus(): void {
    this.connectionStatus = this.getResString($r('app.string.waiting_first_frame_status'));
  }

  private applyConnectedStatus(): void {
    this.stopStepTimer();
    this.connectionStatus = this.getResString($r('app.string.control_connected'));
    this.startAutoHideTimer();
    this.showLoading = false;
  }

  // 辅助方法：将 Resource 引用解析为字符串
  private getResString(res: Resource): string {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      return ctx.resourceManager.getStringSync(res.id);
    } catch (e) {
      return '';
    }
  }

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private async showTransferNotification(
    type: 'send' | 'install',
    title: string,
    text: string,
    statusText: string
  ): Promise<void> {
    await TransferNotificationHelper.start(this.getAbilityContext(), type, title, text, statusText);
  }

  private async updateTransferNotification(
    type: 'send' | 'install',
    title: string,
    text: string,
    statusText: string,
    progress: number
  ): Promise<void> {
    await TransferNotificationHelper.updateProgress(
      this.getAbilityContext(),
      type,
      title,
      text,
      statusText,
      progress
    );
  }

  private async completeTransferNotification(
    type: 'send' | 'install',
    title: string,
    text: string,
    statusText: string
  ): Promise<void> {
    await TransferNotificationHelper.complete(this.getAbilityContext(), type, title, text, statusText);
  }

  private async failTransferNotification(
    type: 'send' | 'install',
    title: string,
    text: string,
    statusText: string
  ): Promise<void> {
    await TransferNotificationHelper.fail(this.getAbilityContext(), type, title, text, statusText);
  }

  private buildTransferProgressText(prefixRes: Resource, progress: number): string {
    return `${this.getResString(prefixRes)} ${progress}%`;
  }

  private async runTransferWithWatchdog<T>(
    transferFactory: (onProgress: (progress: number) => void) => Promise<T>,
    onProgress: (progress: number) => void,
    timeoutMs: number = 10000
  ): Promise<T> {
    let timerId: number = -1;
    let settled = false;

    const clearTimer = (): void => {
      if (timerId !== -1) {
        clearTimeout(timerId);
        timerId = -1;
      }
    };

    const resetTimer = (reject: (reason?: Object) => void): void => {
      clearTimer();
      timerId = setTimeout(() => {
        if (settled) {
          return;
        }
        settled = true;
        reject(new Error('Transfer stalled or disconnected'));
      }, timeoutMs);
    };

    return await new Promise<T>((resolve, reject) => {
      const progressHandler = (progress: number): void => {
        if (settled) {
          return;
        }
        resetTimer(reject);
        onProgress(progress);
      };

      resetTimer(reject);

      const transferPromise: Promise<T> = transferFactory(progressHandler);
      void transferPromise.then((result: T) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimer();
        resolve(result);
      }).catch((err: Object) => {
        if (settled) {
          return;
        }
        settled = true;
        clearTimer();
        reject(err);
      });
    });
  }

  private async pushUriFile(
    uri: string,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<void> {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(uri);
      const fileSize = Number(stat.size);
      if (!Number.isFinite(fileSize) || fileSize <= 0) {
        throw new Error('Invalid file size');
      }

      if (!this.device) {
        throw new Error('No active device');
      }
      await AdbTransferService.pushFileFromFd(this.getAbilityContext(), this.device, file.fd, fileSize, remotePath, onProgress);
    } finally {
      await fs.close(file.fd);
    }
  }

  private async installPackageFromUri(
    uri: string,
    remoteName: string,
    installArgs: string,
    onProgress?: (progress: number) => void
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(uri);
      const fileSize = Number(stat.size);
      if (!Number.isFinite(fileSize) || fileSize <= 0) {
        throw new Error('Invalid file size');
      }

      if (!this.device) {
        throw new Error('No active device');
      }
      return await AdbTransferService.installPackageFromFd(
        this.getAbilityContext(),
        this.device,
        file.fd,
        fileSize,
        remoteName,
        installArgs,
        onProgress
      );
    } finally {
      await fs.close(file.fd);
    }
  }

  aboutToAppear() {
    this.isPageActive = true;
    this.isExiting = false;
    this.isInitializingClient = false;
    this.isStartingSession = false;
    try {
      const params = this.getUIContext().getRouter().getState().params as Record<string, Object>;
      if (params && params['device']) {
        this.device = params['device'] as Device;

        // 检查是否是从 Index 页面预连接后跳转的
        if (params['clientReady'] === true) {
          ClientSessionManager.getInstance().stopAll();
          // 客户端已连接，从缓存获取
          this.context = this.getUIContext().getHostContext() as common.UIAbilityContext;
          // Note: Index already started connecting, so we might want to sync state if possible
          // But for now, just show "Connecting..."
          this.updateConnectionStatus(this.getResString($r('app.string.connecting_status')));
          this.initFromExistingClient();
        } else {
          try {
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.init_control_page_error') });
          } catch (e) {
            LoggerControlPage.error('Show toast failed:', e);
          }
          setTimeout(() => {
            this.exitPage();
          }, 1000);
        }
      }
    } catch (e) {
      LoggerControlPage.error('Failed to get router params:', e);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.init_control_page_error') });
      } catch (e) {
        LoggerControlPage.error('Show toast failed:', e);
      }
      setTimeout(() => {
        this.exitPage();
      }, 1000);
    }

    // 设置全屏并隐藏导航条
    this.setFullScreen();
  }
  
  aboutToDisappear() {
    this.isPageActive = false;
    this.stopStepTimer(); // Clean up timer

    if (!this.isExiting && (this.isConnected || ClientSessionManager.getInstance().hasActiveSession())) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.disconnecting_status') });
      } catch (e) {
        LoggerControlPage.error('Show disconnecting toast on disappear failed:', e);
      }
    }

    // 停止自动隐藏定时器
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }

    this.shutdownKeyboardHandling();

    // 关闭 Native Client (使用 SessionManager 统一管理)
    ClientSessionManager.getInstance().stopAll();
    this.nativeClient = undefined;

    // 恢复窗口状态
    this.restoreWindow();
  }
  
  async restoreWindow() {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      await windowClass.setWindowKeepScreenOn(false);
      // 恢复状态栏和导航栏
      await windowClass.setWindowSystemBarEnable(['status', 'navigation']);
      // 保持全屏布局，避免跳动，因为主页也是全屏布局
      await windowClass.setWindowLayoutFullScreen(true);
      // 恢复为正常方向
      await windowClass.setPreferredOrientation(window.Orientation.PORTRAIT);
      this.appliedAutoOrientation = '';
      this.isLandscape = false;
    } catch (err) {
      LoggerControlPage.error('Restore window failed:', err);
    }
  }

  private async setWindowKeepScreenOn(enabled: boolean): Promise<void> {
    if (enabled && !this.device?.keepScreenOnWhileConnected) {
      return;
    }

    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      await windowClass.setWindowKeepScreenOn(enabled);
    } catch (err) {
      LoggerControlPage.error('Set window keep-screen-on failed:', err);
    }
  }

  // 追踪是否正在退出，防止多重调用
  private isExiting: boolean = false;
  private isPageActive: boolean = false;

  onBackPress(): boolean {
    this.exitPage();
    return true;
  }

  // 统一退出页面逻辑
  async exitPage() {
    if (this.isExiting) {
      return;
    }
    this.isExiting = true;

    if (this.isConnected || ClientSessionManager.getInstance().hasActiveSession()) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.disconnecting_status') });
      } catch (e) {
        LoggerControlPage.error('Show disconnecting toast failed:', e);
      }
    }
    // 先恢复窗口状态
    await this.restoreWindow();
    // 再返回
    try {
      const router = this.getUIContext().getRouter();
      const length = router.getLength(); // 返回页面栈数量
      const lenNum = typeof length === 'string' ? parseInt(length) : Number(length);

      if (lenNum > 1) {
        router.back();
      } else {
        router.replaceUrl({ url: 'pages/Index' });
      }
    } catch (e) {
      LoggerControlPage.error('Router back failed:', e);
      // 尝试强制跳转首页
      try {
        this.getUIContext().getRouter().replaceUrl({ url: 'pages/Index' });
      } catch (err) {
        LoggerControlPage.error('Force replace Index failed:', err);
      }
    }
  }
  
  // 发送按键事件到 Native
  private sendKeyToWorker(keyCode: KeyCode): void {
    if (!this.nativeClient || !this.isConnected) return;
    const packets = ControlPacket.createKeyEventPair(keyCode);
    packets.forEach(p => this.nativeClient!.sendControl(p));
  }

  private async syncKeyboardUhidAvailability(client: NativeStreamClient): Promise<void> {
    if (this.isKeyboardAvailabilitySyncing) {
      this.keyboardAvailabilityResyncRequested = true;
      this.keyboardSyncToken++;
      return;
    }

    this.isKeyboardAvailabilitySyncing = true;
    try {
      do {
        this.keyboardAvailabilityResyncRequested = false;
        const token = ++this.keyboardSyncToken;
        if (!this.device) {
          return;
        }

        const shouldEnable = this.device.forcePhysicalKeyboard || await this.hasPhysicalAlphabeticKeyboard();
        if (this.nativeClient !== client || !this.isConnected || !this.isPageActive || token !== this.keyboardSyncToken) {
          continue;
        }

        if (shouldEnable) {
          await this.initKeyboardUhidForSession(client, token);
        } else {
          this.releaseKeyboardUhid();
        }
      } while (this.keyboardAvailabilityResyncRequested && this.nativeClient === client && this.isConnected && this.isPageActive);
    } finally {
      this.isKeyboardAvailabilitySyncing = false;
      if (this.keyboardAvailabilityResyncRequested) {
        const currentClient = this.nativeClient;
        if (currentClient && this.isConnected && this.isPageActive) {
          void this.syncKeyboardUhidAvailability(currentClient);
        }
      }
    }
  }

  private async hasPhysicalAlphabeticKeyboard(): Promise<boolean> {
    try {
      const deviceIds = await inputDevice.getDeviceList();
      for (const deviceId of deviceIds) {
        try {
          const keyboardType = await inputDevice.getKeyboardType(deviceId);
          if (keyboardType === inputDevice.KeyboardType.ALPHABETIC_KEYBOARD) {
            return true;
          }
        } catch (err) {
          LoggerControlPage.warn('[ControlPage] Get keyboard type failed:', err);
        }
      }
    } catch (err) {
      LoggerControlPage.warn('[ControlPage] Get input device list failed:', err);
    }
    return false;
  }

  private ensureInputDeviceChangeListener(): void {
    if (this.inputDeviceChangeListener) {
      return;
    }

    this.inputDeviceChangeListener = (_data: inputDevice.DeviceListener) => {
      const client = this.nativeClient;
      if (!client || !this.isConnected || !this.isPageActive || this.device?.forcePhysicalKeyboard) {
        return;
      }
      void this.syncKeyboardUhidAvailability(client);
    };

    try {
      inputDevice.on('change', this.inputDeviceChangeListener);
    } catch (err) {
      LoggerControlPage.warn('[ControlPage] Register input device listener failed:', err);
      this.inputDeviceChangeListener = undefined;
    }
  }

  private removeInputDeviceChangeListener(): void {
    if (!this.inputDeviceChangeListener) {
      return;
    }

    try {
      inputDevice.off('change', this.inputDeviceChangeListener);
    } catch (err) {
      LoggerControlPage.warn('[ControlPage] Unregister input device listener failed:', err);
    }
    this.inputDeviceChangeListener = undefined;
  }

  private async initKeyboardUhidForSession(client: NativeStreamClient, syncToken?: number): Promise<void> {
    if (this.isKeyboardUhidInitializing || this.keyboardUhid?.isCreated()) {
      return;
    }

    this.isKeyboardUhidInitializing = true;
    try {
      const available = await this.checkUhidAvailable(client);
      if (this.nativeClient !== client || !this.isConnected || !this.isPageActive ||
        (syncToken !== undefined && syncToken !== this.keyboardSyncToken)) {
        return;
      }

      if (!available) {
        LoggerControlPage.warn('[ControlPage] UHID keyboard unavailable on controlled device');
        return;
      }

      const keyboard = new KeyboardUhidController((data: ArrayBuffer): boolean => {
        if (this.nativeClient !== client || !this.isConnected) {
          return false;
        }
        return client.sendControl(data);
      });

      if (!keyboard.create()) {
        LoggerControlPage.warn('[ControlPage] UHID keyboard create packet was not accepted');
        return;
      }

      this.keyboardUhid = keyboard;
      this.requestKeyboardFocus();
      LoggerControlPage.info('[ControlPage] UHID keyboard enabled');
    } catch (err) {
      LoggerControlPage.warn('[ControlPage] Init UHID keyboard failed:', err);
    } finally {
      this.isKeyboardUhidInitializing = false;
    }
  }

  private async checkUhidAvailable(client: NativeStreamClient): Promise<boolean> {
    try {
      const result = await client.execShell('test -r /dev/uhid && test -w /dev/uhid && echo ok || echo no');
      const output = `${result.stdout}\n${result.stderr}`.toLowerCase();
      return output.includes('ok');
    } catch (err) {
      LoggerControlPage.warn('[ControlPage] UHID availability check failed:', err);
      return false;
    }
  }

  private releaseKeyboardUhid(): void {
    try {
      this.keyboardUhid?.destroy();
    } catch (err) {
      LoggerControlPage.warn('[ControlPage] Release UHID keyboard failed:', err);
    }
    this.keyboardUhid = undefined;
    this.isKeyboardUhidInitializing = false;
  }

  private shutdownKeyboardHandling(): void {
    this.removeInputDeviceChangeListener();
    this.keyboardSyncToken++;
    this.keyboardAvailabilityResyncRequested = false;
    this.releaseKeyboardUhid();
  }

  private requestKeyboardFocus(): void {
    setTimeout(() => {
      if (!this.isPageActive) {
        return;
      }
      try {
        this.getUIContext().getFocusController().requestFocus(this.KEYBOARD_FOCUS_ID);
      } catch (err) {
        LoggerControlPage.warn('[ControlPage] Request keyboard focus failed:', err);
      }
    }, 0);
  }

  private handleKeyboardEvent(event: KeyEvent): boolean {
    if (!this.isConnected || this.showSendFilePathDialog || !this.keyboardUhid?.isCreated()) {
      return false;
    }
    if (event.type !== KeyType.Down && event.type !== KeyType.Up) {
      return false;
    }
    return this.keyboardUhid.handleKeyCode(event.keyCode, event.type === KeyType.Down);
  }

  // 从已连接的客户端初始化（Native 架构）
  private async initFromExistingClient(): Promise<void> {
    if (!this.device || !this.context) return;
    if (this.isInitializingClient) {
      return;
    }
    if (this.nativeClient && this.serverJarData) {
      this.startNativeSession();
      return;
    }

    this.isInitializingClient = true;
    try {
      // 1. 预加载 server.jar
      this.serverJarData = await ServerManager.loadServerFromRawfile(this.context);

      // 2. 初始化 Native Client
      this.initNativeClient();

      // 3. 尝试启动会话 (如果 Surface 还没准备好，会在 onLoad 中再次调用)
      this.startNativeSession();

    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerControlPage.error('ControlPage: Init failed:', errMsg);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.init_control_page_error') });
      } catch (e) {
        LoggerControlPage.error('Show toast failed:', e);
      }
      setTimeout(() => {
        this.exitPage();
      }, 1500);
    } finally {
      this.isInitializingClient = false;
    }
  }

  // 初始化 Native Client 并设置监听器
  private initNativeClient(): void {
    if (!this.context || !this.device) return;
    if (this.nativeClient) {
      return;
    }

    const client = new NativeStreamClient(this.context, this.device, {
      onVideoConfig: (width: number, height: number) => {
        if (this.nativeClient !== client) {
          return;
        }
        this.videoWidth = width;
        this.videoHeight = height;
        this.calcVideoDisplaySize();
        void this.applyAutoSwitchOrientation();
      },
      onDisconnect: (reason: string) => {
        if (this.nativeClient !== client) {
          return;
        }
        this.stopStepTimer(); // Stop timer on disconnect
        LoggerControlPage.warn('[ControlPage] Client disconnected:', reason);
        this.shutdownKeyboardHandling();
        this.isConnected = false;
        this.connectionStatus = this.getResString($r('app.string.control_disconnected'));
        void this.setWindowKeepScreenOn(false);
        try {
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.control_disconnected') });
        } catch (err) {
          LoggerControlPage.error('Show toast failed:', err);
        }
        setTimeout(() => {
          this.exitPage();
        }, 1500);
      },
      onError: (error: string) => {
        if (this.nativeClient !== client) {
          return;
        }
        this.stopStepTimer(); // Stop timer on error
        LoggerControlPage.error('[ControlPage] Client error:', error);
        this.shutdownKeyboardHandling();
        void this.setWindowKeepScreenOn(false);
        try {
          this.getUIContext().getPromptAction().showToast({ message: error });
        } catch (err) {
          LoggerControlPage.error('Show toast failed:', err);
        }
        setTimeout(() => {
            this.exitPage();
        }, 1500);
      },
      onClipboard: (text: string) => {
        if (this.nativeClient !== client) {
          return;
        }
        this.syncClipboardToSystem(text);
      },
      onUhidOutput: (data: string) => {
        if (this.nativeClient !== client) {
          return;
        }
        this.keyboardUhid?.handleUhidOutput(data);
      },
      onFirstFrame: () => {
        if (this.nativeClient !== client) {
          return;
        }
        this.hasReceivedFirstFrame = true;
        this.applyConnectedStatus();
        this.requestKeyboardFocus();
      },
      onWaitAuth: () => {
        if (this.nativeClient !== client) {
          return;
        }
        this.updateConnectionStatus(this.getResString($r('app.string.adb_auth_waiting')));
        try {
             this.getUIContext().getPromptAction().showToast({ message: $r('app.string.auth_required_toast') });
        } catch (e) {
          LoggerControlPage.error('Show toast failed:', e);
        }
      }
    });

    this.nativeClient = client;
    // 注册到 SessionManager
    ClientSessionManager.getInstance().register(this.nativeClient);
  }

  // 尝试启动 Native 会话
  private async startNativeSession(): Promise<void> {
    if (this.isStarted || this.isStartingSession) {
      return;
    }
    if (!this.serverJarData || !this.surfaceReady || !this.surfaceId || !this.nativeClient) {
      return;
    }

    const client = this.nativeClient;
    this.isStarted = true;
    this.isStartingSession = true;
    this.hasReceivedFirstFrame = false;
    this.showLoading = true;
    try {
      this.updateConnectionStatus(this.getResString($r('app.string.connecting_status'))); // "正在连接..."
      
      // 启动会话 (异步)
      await client.start(this.serverJarData, this.surfaceId);
      if (this.nativeClient !== client || !this.isPageActive) {
        return;
      }
      
      this.isConnected = true;
      this.ensureInputDeviceChangeListener();
      void this.syncKeyboardUhidAvailability(client);
      this.requestKeyboardFocus();
      if (this.hasReceivedFirstFrame) {
        this.applyConnectedStatus();
      } else {
        this.applyWaitingForFirstFrameStatus();
      }
      void this.setWindowKeepScreenOn(true);
    } catch (err) {
      this.stopStepTimer(); // Stop timer on failure
      await this.setWindowKeepScreenOn(false);
      if (!this.isPageActive) {
          LoggerControlPage.debug('[ControlPage] Error ignored, page inactive:', err);
          return;
      }
      this.isStarted = false;
      let errMsg = err instanceof Error ? err.message : String(err);
      
      // Check if it's a resource string key
      if (errMsg.startsWith('app.string.')) {
         try {
             if (errMsg === 'app.string.connect_timeout_toast') {
                 errMsg = this.getResString($r('app.string.connect_timeout_toast'));
             } else if (errMsg === 'app.string.adb_auth_failed') {
                 errMsg = this.getResString($r('app.string.adb_auth_failed'));
             } else if (errMsg === 'app.string.adb_native_connect_failed') {
                 errMsg = this.getResString($r('app.string.adb_native_connect_failed'));
             } else if (errMsg === 'app.string.adb_wireless_tls_failed') {
                 errMsg = this.getResString($r('app.string.adb_wireless_tls_failed'));
             } else if (errMsg === 'app.string.adb_wireless_tls_interrupted') {
                 errMsg = this.getResString($r('app.string.adb_wireless_tls_interrupted'));
             } else if (errMsg === 'app.string.adb_wireless_protocol_failed') {
                 errMsg = this.getResString($r('app.string.adb_wireless_protocol_failed'));
             } else if (errMsg === 'app.string.server_prepare_failed') {
                 errMsg = this.getResString($r('app.string.server_prepare_failed'));
             } else if (errMsg === 'app.string.adb_connect_timeout') {
                 errMsg = this.getResString($r('app.string.adb_connect_timeout'));
             } else if (errMsg === 'app.string.adb_auth_timeout') {
                 errMsg = this.getResString($r('app.string.adb_auth_timeout'));
             } else if (errMsg === 'app.string.adb_auth_disconnected') {
                 errMsg = this.getResString($r('app.string.adb_auth_disconnected'));
             } else if (errMsg === 'app.string.connection_cancelled') {
                 // User cancelled, do not show error
                 return;
             }
         } catch (e) {
             LoggerControlPage.error('Failed to resolve error resource', e);
         }
      }

      LoggerControlPage.error('[ControlPage] Start session failed:', errMsg);
      
      // Use Dialog instead of Toast for critical connection errors so the user has time to read it
      // before calculations/cleanup closes the page.
      if (this.isPageActive) {
        try {
            this.getUIContext().getPromptAction().showDialog({
                title: $r('app.string.error_title'), // "Error" / "提示"
                message: errMsg,
                buttons: [
                    {
                        text: $r('app.string.confirm'), // "Confirm" / "确定"
                        color: '#007DFF' // Standard Blue, works in both modes
                    }
                ]
            }).then(() => {
                this.exitPage();
            });
        } catch (e) {
            // Fallback if dialog fails (shouldn't happen)
            this.getUIContext().getPromptAction().showToast({ message: errMsg });
            setTimeout(() => { this.exitPage(); }, 3000);
        }
      }
    } finally {
      this.isStartingSession = false;
    }
  }

  // 同步剪贴板到系统
  private async syncClipboardToSystem(text: string): Promise<void> {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await systemPasteboard.setData(pasteData);
      LoggerControlPage.debug('[ControlPage] Clipboard synced to system');
    } catch (err) {
      LoggerControlPage.error('[ControlPage] Failed to sync clipboard:', err);
    }
  }

  private async handleSendFile(): Promise<void> {
    if (!(await this.beginTransfer())) {
      return;
    }

    let fileName: string = this.getResString($r('app.string.send_file_start'));
    try {
      const uri = await this.pickDocument();
      if (!uri) {
        return;
      }

      fileName = this.getFileNameFromUri(uri);
      const remotePath = await this.promptSendFileTargetPath(this.buildDefaultRemotePath(fileName));
      if (!remotePath) {
        return;
      }
      await this.showTransferNotification(
        'send',
        this.getResString($r('app.string.send_file_notification_title')),
        fileName,
        this.getResString($r('app.string.transfer_notification_preparing'))
      );
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.send_file_start') });
      await this.runTransferWithWatchdog<void>((progressHandler: (progress: number) => void) => {
        return this.pushUriFile(uri, remotePath, progressHandler);
      }, (progress: number) => {
        void this.updateTransferNotification(
          'send',
          this.getResString($r('app.string.send_file_notification_title')),
          fileName,
          this.buildTransferProgressText($r('app.string.transfer_notification_sending_prefix'), progress),
          progress
        );
      });
      await this.completeTransferNotification(
        'send',
        this.getResString($r('app.string.send_file_notification_title')),
        fileName,
        `${this.getResString($r('app.string.transfer_notification_completed_prefix'))}${remotePath}`
      );
      this.getUIContext().getPromptAction().showToast({
        message: `${this.getResString($r('app.string.send_file_success_prefix'))}${remotePath}`
      });
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerControlPage.error('[ControlPage] Send file failed:', errMsg);
      await this.failTransferNotification(
        'send',
        this.getResString($r('app.string.send_file_notification_title')),
        fileName,
        `${this.getResString($r('app.string.transfer_notification_failed_prefix'))}${errMsg}`
      );
      this.getUIContext().getPromptAction().showDialog({
        title: $r('app.string.error_title'),
        message: `${this.getResString($r('app.string.send_file_failed_prefix'))}${errMsg}`,
        buttons: [{ text: $r('app.string.confirm'), color: '#007DFF' }]
      });
    } finally {
      this.isTransferBusy = false;
      this.startAutoHideTimer();
    }
  }

  private async handleInstallPackage(): Promise<void> {
    if (!(await this.beginTransfer())) {
      return;
    }

    let remoteName: string = this.getResString($r('app.string.install_app_start'));
    try {
      const uri = await this.pickDocument(['.apk']);
      if (!uri) {
        return;
      }

      remoteName = this.getFileNameFromUri(uri);
      await this.showTransferNotification(
        'install',
        this.getResString($r('app.string.install_app_notification_title')),
        remoteName,
        this.getResString($r('app.string.transfer_notification_preparing'))
      );
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.install_app_start') });
      const result: libscrcpy.AdbInstallPackageResult = await this.runTransferWithWatchdog<libscrcpy.AdbInstallPackageResult>((progressHandler: (progress: number) => void) => {
        return this.installPackageFromUri(uri, remoteName, '-r', progressHandler);
      }, (progress: number) => {
        const statusText = progress >= 95
          ? this.getResString($r('app.string.transfer_notification_installing'))
          : this.buildTransferProgressText($r('app.string.transfer_notification_uploading_prefix'), progress);
        void this.updateTransferNotification(
          'install',
          this.getResString($r('app.string.install_app_notification_title')),
          remoteName,
          statusText,
          progress
        );
      });
      if (!result.success) {
        const installOutput: string = result.stderr.length > 0
          ? result.stderr
          : (result.stdout.length > 0 ? result.stdout : `exitCode=${result.exitCode}`);
        throw new Error(installOutput);
      }
      await this.completeTransferNotification(
        'install',
        this.getResString($r('app.string.install_app_notification_title')),
        remoteName,
        this.getResString($r('app.string.transfer_notification_install_success'))
      );
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.install_app_success') });
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerControlPage.error('[ControlPage] Install package failed:', errMsg);
      await this.failTransferNotification(
        'install',
        this.getResString($r('app.string.install_app_notification_title')),
        remoteName,
        `${this.getResString($r('app.string.transfer_notification_failed_prefix'))}${this.resolveInstallErrorMessage(errMsg)}`
      );
      this.getUIContext().getPromptAction().showDialog({
        title: $r('app.string.error_title'),
        message: `${this.getResString($r('app.string.install_app_failed_prefix'))}${this.resolveInstallErrorMessage(errMsg)}`,
        buttons: [{ text: $r('app.string.confirm'), color: '#007DFF' }]
      });
    } finally {
      this.isTransferBusy = false;
      this.startAutoHideTimer();
    }
  }

  private async beginTransfer(): Promise<boolean> {
    if (this.isTransferBusy) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.transfer_busy') });
      return false;
    }
    if (!this.nativeClient || !this.isConnected || !this.nativeClient.isAdbReady()) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.control_disconnected') });
      return false;
    }
    this.isTransferBusy = true;
    this.showControlPanel = false;
    this.clearAutoHideTimer();
    return true;
  }

  private promptSendFileTargetPath(defaultPath: string): Promise<string | undefined> {
    this.sendFileTargetPath = defaultPath;
    this.showSendFilePathDialog = true;
    return new Promise<string | undefined>((resolve) => {
      this.pendingSendFilePathResolve = resolve;
    });
  }

  private closeSendFilePathDialog(result: string | undefined): void {
    this.showSendFilePathDialog = false;
    const resolver = this.pendingSendFilePathResolve;
    this.pendingSendFilePathResolve = undefined;
    if (resolver) {
      resolver(result);
    }
  }

  private confirmSendFilePath(): void {
    const targetPath = this.sendFileTargetPath.trim();
    if (targetPath.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.send_file_path_empty') });
      return;
    }
    this.closeSendFilePathDialog(targetPath);
  }

  private buildDefaultRemotePath(fileName: string): string {
    const configuredBasePath = this.device?.fileReceivePath?.trim() ?? '';
    const fallbackPath = '/sdcard/Download/';
    const basePath = configuredBasePath.length > 0 ? configuredBasePath : fallbackPath;
    const normalizedBasePath = basePath.endsWith('/') ? basePath : `${basePath}/`;
    return `${normalizedBasePath}${fileName}`;
  }

  private resolveInstallErrorMessage(rawMessage: string): string {
    const normalizedMessage = rawMessage.trim().toLowerCase();
    if (normalizedMessage.includes('reject adb install')) {
      return this.getResString($r('app.string.install_app_error_reject_adb'));
    }
    if (normalizedMessage.includes('install_failed_user_restricted')) {
      return this.getResString($r('app.string.install_app_error_user_restricted'));
    }
    if (normalizedMessage.includes('install_failed')) {
      return `${this.getResString($r('app.string.install_app_error_failed_prefix'))}${rawMessage}`;
    }
    return rawMessage;
  }

  private async pickDocument(fileSuffixFilters: Array<string> = []): Promise<string | undefined> {
    const documentPicker = new picker.DocumentViewPicker();
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    if (fileSuffixFilters.length > 0) {
      options.fileSuffixFilters = fileSuffixFilters;
    }

    try {
      const uris = await documentPicker.select(options);
      if (!uris || uris.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.file_pick_cancelled') });
        return undefined;
      }
      return uris[0];
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      if (errMsg.toLowerCase().includes('cancel')) {
        return undefined;
      }
      throw new Error(errMsg);
    }
  }

  private async readFileToArrayBuffer(uri: string): Promise<ArrayBuffer> {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const stat = fs.statSync(uri);
      const fileSize = Number(stat.size);
      if (!Number.isFinite(fileSize) || fileSize <= 0) {
        throw new Error('Invalid file size');
      }

      const fileData = new ArrayBuffer(fileSize);
      const bytesRead = fs.readSync(file.fd, fileData);
      if (bytesRead <= 0) {
        throw new Error('Failed to read file');
      }
      return bytesRead === fileSize ? fileData : fileData.slice(0, bytesRead);
    } finally {
      await fs.close(file.fd);
    }
  }

  private getFileNameFromUri(uri: string): string {
    const sanitizedUri = uri.split('?')[0];
    const lastSlash = sanitizedUri.lastIndexOf('/');
    const encodedName = lastSlash >= 0 ? sanitizedUri.substring(lastSlash + 1) : sanitizedUri;
    const fileName = decodeURIComponent(encodedName || '').trim();
    const normalizedFileName = fileName.replace(/[\\/:*?"<>|,]/g, '_');
    return normalizedFileName.length > 0 ? normalizedFileName : `file-${Date.now()}`;
  }



  private async applyAutoSwitchOrientation(): Promise<void> {
    if (!this.device?.autoSwitchOrientation || this.videoWidth <= 0 || this.videoHeight <= 0) {
      return;
    }

    const shouldLandscape = this.videoWidth > this.videoHeight;
    const targetOrientation = shouldLandscape ? 'landscape' : 'portrait';
    if (targetOrientation === this.appliedAutoOrientation) {
      return;
    }

    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      await windowClass.setPreferredOrientation(
        shouldLandscape ? window.Orientation.AUTO_ROTATION_LANDSCAPE : window.Orientation.PORTRAIT
      );
      this.isLandscape = shouldLandscape;
      this.appliedAutoOrientation = targetOrientation;
    } catch (err) {
      LoggerControlPage.error('Apply auto switch orientation failed:', err);
    }
  }

  async setFullScreen() {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const windowClass = await window.getLastWindow(ctx);
      // 设置全屏布局
      await windowClass.setWindowLayoutFullScreen(true);
      // 隐藏状态栏和导航栏
      await windowClass.setWindowSystemBarEnable([]);
      // 允许根据传感器自动旋转，支持横屏，但受限于系统的旋转锁定
      await windowClass.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
    } catch (err) {
      LoggerControlPage.error('Set fullscreen failed:', err);
    }
  }

  // 启动自动隐藏定时器
  startAutoHideTimer() {
    this.clearAutoHideTimer();
    this.autoHideTimer = setTimeout(() => {
      if (!this.showControlPanel && this.containerWidth > 0) {
        // 贴边隐藏：只露出一半
        const hiddenX = this.fabDockedLeft
          ? -this.FAB_SIZE / 2           // 左侧藏起来
          : this.containerWidth - this.FAB_SIZE / 2;  // 右侧藏起来
        this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
          this.fabX = hiddenX;
        })
      }
    }, 3000) as number;
  }
  
  // 清除自动隐藏定时器
  clearAutoHideTimer() {
    if (this.autoHideTimer !== -1) {
      clearTimeout(this.autoHideTimer);
      this.autoHideTimer = -1;
    }
  }
  
  // 显示悬浮按钮
  showFab() {
    if (this.containerWidth > 0) {
      const visibleX = this.fabDockedLeft
        ? 20                                          // 左侧显示位置
        : this.containerWidth - this.FAB_SIZE - 20;    // 右侧显示位置
      this.getUIContext().animateTo({ duration: 300, curve: Curve.EaseInOut }, () => {
        this.fabX = visibleX;
      })
      this.startAutoHideTimer();
    }
  }
  
  // 切换控制面板
  toggleControlPanel() {
    // 如果当前是隐藏状态(靠边)，先显示出来
    const isHiddenRight = this.fabX > this.containerWidth - this.FAB_SIZE;
    const isHiddenLeft = this.fabX < 0;
    if (this.containerWidth > 0 && (isHiddenRight || isHiddenLeft)) {
        this.showFab();
        return;
    }

    this.showControlPanel = !this.showControlPanel;
    if (this.showControlPanel) {
      this.clearAutoHideTimer();
    } else {
      this.startAutoHideTimer();
    }
  }

  // 初始化悬浮按钮位置
  initFabPosition() {
    if (this.containerWidth > 0 && this.containerHeight > 0 && !this.checkFabPosition) {
       this.fabX = this.containerWidth - this.FAB_SIZE - 20; // 默认右侧
       // 考虑底部安全区域，FAB放在容器中部偏下位置
       let targetY = this.containerHeight / 2; // 默认放在中间
       if (targetY < 50) targetY = 50;
       const maxY = this.containerHeight - this.FAB_SIZE - this.BOTTOM_SAFE_AREA;
       if (targetY > maxY) targetY = maxY;
       this.fabY = targetY;
       this.checkFabPosition = true;
    }
  }

  // 计算视频显示尺寸 - 保持比例
  calcVideoDisplaySize() {
    if (this.containerWidth === 0 || this.containerHeight === 0 || this.videoWidth === 0 || this.videoHeight === 0) {
      return;
    }

    const containerRatio = this.containerWidth / this.containerHeight;
    const videoRatio = this.videoWidth / this.videoHeight;

    if (containerRatio > videoRatio) {
      // 容器比视频宽，以高度为基准
      this.displayXComponentHeight = this.containerHeight;
      this.displayXComponentWidth = this.containerHeight * videoRatio;
    } else {
      // 容器比视频窄，以宽度为基准
      this.displayXComponentWidth = this.containerWidth;
      this.displayXComponentHeight = this.containerWidth / videoRatio;
    }
    
    // 重新校准悬浮按钮位置（如果有必要）
    if (this.checkFabPosition) {
      // 简单的越界检查，防止resize后按钮跑到看不见的地方
       if (this.fabX > this.containerWidth) this.fabX = this.containerWidth - this.FAB_SIZE;
       if (this.fabY > this.containerHeight) this.fabY = this.containerHeight - this.FAB_SIZE;
    }
  }
  
  build() {
    Stack() {
      Column() {
      // 主内容区域（视频 + 悬浮按钮）
      Stack() {
        // Loading indicator - 支持深色/浅色模式
        if (this.showLoading) {
          Column() {
            // 加载动画
            LoadingProgress()
              .width(64)
              .height(64)
              .color($r('sys.color.ohos_id_color_text_primary'))

            // 连接状态文字
            Text(`${this.connectionStatus} (${this.stepTime}s)`)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .margin({ top: 20 })
              .animation({ duration: 300, curve: Curve.EaseInOut })

            // 设备名提示
            if (this.device?.name) {
              Text(this.device.name)
                .fontSize(13)
                .fontColor($r('sys.color.ohos_id_color_text_secondary'))
                .margin({ top: 8 })
            }
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('sys.color.ohos_id_color_background'))
          .zIndex(100)
          .transition(TransitionEffect.OPACITY.animation({ duration: 400, curve: Curve.EaseOut }))
        }
        
        // 视频显示区域容器 - 用于获取可用空间
        Stack({ alignContent: Alignment.Center }) {
          XComponent({
            id: 'video_surface',
            type: XComponentType.SURFACE,
            controller: this.xComponentController,
            libraryname: 'scrcpy_native'
          })
            .onLoad(() => {
              this.surfaceId = this.xComponentController.getXComponentSurfaceId();
              this.surfaceReady = true;

              // 尝试启动 Native Session
              this.startNativeSession();
            })
            .width(this.displayXComponentWidth > 0 ? this.displayXComponentWidth : '100%')
            .height(this.displayXComponentHeight > 0 ? this.displayXComponentHeight : '100%')
            .backgroundColor($r('sys.color.black'))
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#000000') // 背景黑色，作为信箱模式的黑边
        .onAreaChange((_: Area, newArea: Area) => {
          // 获取容器实际尺寸(vp)
          this.containerWidth = newArea.width as number;
          this.containerHeight = newArea.height as number;
          LoggerControlPage.debug(`Container size changed: ${this.containerWidth}x${this.containerHeight}`);

          // 重新计算视频显示尺寸
          this.calcVideoDisplaySize();
          this.initFabPosition();
        })
        
        // 悬浮控制按钮
      if (this.containerWidth > this.containerHeight) {
        // 横屏模式：面板在按钮侧边展开（Row布局）
        Row() {
          // 展开的控制面板
          if (this.showControlPanel) {
            Row({ space: 8 }) {
              this.fabButtons()
            }
            .padding(8)
            .backgroundColor('#40000000')
            .borderRadius(12)
            .margin(this.fabDockedLeft ? { left: 8 } : { right: 8 })
            .gesture(TapGesture().onAction(() => {}))
          }

          // 悬浮触发按钮 - 白色小圆圈
          Column()
            .width(this.FAB_SIZE)
            .height(this.FAB_SIZE)
            .backgroundColor(this.showControlPanel ? '#FFFFFF' : '#B0FFFFFF')
            .borderRadius(this.FAB_SIZE / 2)
            .border({ width: 2, color: '#80FFFFFF' })
            .shadow({ radius: 6, color: '#40000000', offsetX: 1, offsetY: 1 })
            .onClick(() => { this.toggleControlPanel(); })
        }
        .direction(this.fabDockedLeft ? Direction.Rtl : Direction.Ltr)
        .alignItems(VerticalAlign.Center)
        .position({
          x: this.fabDockedLeft ? this.fabX : this.fabX + this.FAB_SIZE,
          y: this.fabY + this.FAB_SIZE / 2
        })
        .markAnchor({ x: this.fabDockedLeft ? '0%' : '100%', y: '50%' })
        .zIndex(200)
        .gesture(
            PanGesture({ fingers: 1, direction: PanDirection.All })
              .onActionStart((_: GestureEvent) => {
                 this.clearAutoHideTimer();
                 if (this.showControlPanel) {
                   this.showControlPanel = false;
                 }
                 this.dragStartX = this.fabX;
                 this.dragStartY = this.fabY;
              })
              .onActionUpdate((event: GestureEvent) => {
                 if (this.containerWidth > 0) {
                   this.fabX = this.dragStartX + event.offsetX;
                   this.fabY = this.dragStartY + event.offsetY;
                 }
              })
              .onActionEnd((_: GestureEvent) => {
                 if (this.containerWidth > 0) {
                   const midX = this.containerWidth / 2;
                   const isLeft = this.fabX < midX;
                   const dockX = isLeft ? 20 : this.containerWidth - this.FAB_SIZE - 20;
                   
                   let targetY = this.fabY;
                   if (targetY < 50) targetY = 50;
                   const maxY = this.containerHeight - this.FAB_SIZE - this.BOTTOM_SAFE_AREA;
                   if (targetY > maxY) targetY = maxY;

                   this.fabDockedLeft = isLeft;
                   this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                      this.fabX = dockX;
                      this.fabY = targetY;
                   });
                   
                   this.startAutoHideTimer();
                 }
              })
        )
      } else {
        // 竖屏模式：面板在按钮上方展开（Column布局）
        Column() {
          // 展开的控制面板
          if (this.showControlPanel) {
            Column({ space: 8 }) {
              this.fabButtons()
            }
            .padding(8)
            .backgroundColor('#40000000')
            .borderRadius(12)
            .margin({ bottom: 8 })
            // 防止面板捕获拖动手势
            .gesture(TapGesture().onAction(()=>{
               // 吞噬点击
            }))
          }

          // 悬浮触发按钮 - 白色小圆圈
          Column()
            .width(this.FAB_SIZE)
            .height(this.FAB_SIZE)
            .backgroundColor(this.showControlPanel ? '#FFFFFF' : '#B0FFFFFF')
            .borderRadius(this.FAB_SIZE / 2)
            .border({
              width: 2,
              color: '#80FFFFFF'
            })
            .shadow({
              radius: 6,
              color: '#40000000',
              offsetX: 1,
              offsetY: 1
            })
            .onClick(() => {
              this.toggleControlPanel();
            })
        }
        .alignItems(HorizontalAlign.Center)
        .position({ x: this.fabX + this.FAB_SIZE / 2, y: this.fabY + this.FAB_SIZE })
        .markAnchor({ x: '50%', y: '100%' })
        .zIndex(200)
        .gesture(
            PanGesture({ fingers: 1, direction: PanDirection.All })
              .onActionStart((_: GestureEvent) => {
                 this.clearAutoHideTimer();
                 if (this.showControlPanel) {
                   this.showControlPanel = false;
                 }
                 this.dragStartX = this.fabX;
                 this.dragStartY = this.fabY;
              })
              .onActionUpdate((event: GestureEvent) => {
                 if (this.containerWidth > 0) {
                   this.fabX = this.dragStartX + event.offsetX;
                   this.fabY = this.dragStartY + event.offsetY;
                 }
              })
              .onActionEnd((_: GestureEvent) => {
                 if (this.containerWidth > 0) {
                   const midX = this.containerWidth / 2;
                   const isLeft = this.fabX < midX;
                   const dockX = isLeft ? 20 : this.containerWidth - this.FAB_SIZE - 20;
                   
                   let targetY = this.fabY;
                   if (targetY < 50) targetY = 50;
                   const maxY = this.containerHeight - this.FAB_SIZE - this.BOTTOM_SAFE_AREA;
                   if (targetY > maxY) targetY = maxY;

                   this.getUIContext().animateTo({ duration: 300, curve: Curve.FastOutSlowIn }, () => {
                      this.fabDockedLeft = isLeft;
                      this.fabX = dockX;
                      this.fabY = targetY;
                   });
                   
                   this.startAutoHideTimer();
                 }
              })
        )
      }
      }
      .width('100%')
      .layoutWeight(1) // 占用剩余空间，让底部导航栏不覆盖视频
      .backgroundColor($r('sys.color.ohos_id_color_background'))
      .clip(false) // 允许悬浮按钮超出边界，实现吸边半隐藏效果
      
      // 底部导航栏
      if (this.device?.showBottomNavBar) {
        Row({ space: 40 }) {
          // 返回键
          Button() {
            SymbolGlyph($r('sys.symbol.arrow_left'))
              .fontSize(24)
              .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          }
          .width(52)
          .height(52)
          .backgroundColor(Color.Transparent)
          .borderRadius(26)
          .onClick(() => {
            this.sendKeyToWorker(KeyCode.KEYCODE_BACK);
          })

          // 主页键
          Button() {
            SymbolGlyph($r('sys.symbol.house'))
              .fontSize(24)
              .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          }
          .width(52)
          .height(52)
          .backgroundColor(Color.Transparent)
          .borderRadius(26)
          .onClick(() => {
            this.sendKeyToWorker(KeyCode.KEYCODE_HOME);
          })

          // 多任务键
          Button() {
            SymbolGlyph($r('sys.symbol.square'))
              .fontSize(24)
              .fontColor([$r('sys.color.ohos_id_color_text_primary')])
          }
          .width(52)
          .height(52)
          .backgroundColor(Color.Transparent)
          .borderRadius(26)
          .onClick(() => {
            this.sendKeyToWorker(KeyCode.KEYCODE_APP_SWITCH);
          })
        }
        .width('100%')
        .height(45)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.ohos_id_color_background'))
      }
    }
      .width('100%')
      .height('100%')
      .backgroundColor($r('sys.color.ohos_id_color_background'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.showSendFilePathDialog) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.closeSendFilePathDialog(undefined);
            })

          Column({ space: 16 }) {
            Text($r('app.string.send_file_path_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('sys.color.ohos_id_color_text_primary'))
              .width('100%')

            TextInput({ text: this.sendFileTargetPath, placeholder: $r('app.string.send_file_path_hint') })
              .width('100%')
              .height(48)
              .fontSize(14)
              .backgroundColor($r('app.color.bg_card'))
              .onChange((value: string) => {
                this.sendFileTargetPath = value;
              })

            Row({ space: 12 }) {
              Button($r('app.string.cancel'))
                .layoutWeight(1)
                .backgroundColor($r('app.color.btn_secondary'))
                .fontColor($r('app.color.text_primary'))
                .onClick(() => {
                  this.closeSendFilePathDialog(undefined);
                })

              Button($r('app.string.confirm'))
                .layoutWeight(1)
                .backgroundColor($r('app.color.btn_primary'))
                .fontColor('#FFFFFF')
                .onClick(() => {
                  this.confirmSendFilePath();
                })
            }
            .width('100%')
          }
          .width('84%')
          .padding(20)
          .backgroundColor($r('sys.color.ohos_id_color_background'))
          .borderRadius(16)
          .zIndex(10)
          .onClick(() => {
          })
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Center)
      }
    }
    .id(this.KEYBOARD_FOCUS_ID)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.ohos_id_color_background'))
    .focusable(true)
    .defaultFocus(true)
    .focusOnTouch(true)
    .onKeyEvent((event: KeyEvent): boolean => {
      return this.handleKeyboardEvent(event);
    })
    .onBlur(() => {
      this.keyboardUhid?.resetAll();
    })
  }
}
