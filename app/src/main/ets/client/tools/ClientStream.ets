// ClientStream - 客户端流管理
import { Device } from '../../entity/Device';
import { AdbKeyManager } from '../../helper/AdbKeyManager';
import { ServerManager } from '../../helper/ServerManager';
import { LoggerClientStream } from '../../helper/Logger';
import { buffer, util } from '@kit.ArkTS';
import * as libscrcpy from 'libscrcpy_native.so';
import fs from '@ohos.file.fs';

export class ClientStream {
  private static readonly SERVER_STOP_WAIT_MS: number = 1200;
  private static readonly SERVER_STOP_POLL_INTERVAL_MS: number = 50;
  private adbId: number = -1;
  private shellStreamId: number = -1;
  private isClosing: boolean = false;
  private device: Device;

  constructor(device: Device) {
    this.device = device;
  }

  getAdbId(): number {
    return this.adbId;
  }

  isAdbReady(): boolean {
    return this.adbId >= 0 && libscrcpy.adbIsConnected(this.adbId);
  }

  private ensureAdbReady(): void {
    if (!this.isAdbReady()) {
      throw new Error('ADB is not connected');
    }
  }

  // 为 Native 模式准备服务端：连接 ADB 并推送服务端。
  async prepareServerForNative(
    context: Context, // 需要Context来获取AdbKeyManager
    serverJarData: ArrayBuffer | null,
    onWaitAuth?: () => void
  ): Promise<number> {
    try {
      this.isClosing = false;

      // 1. 初始化 ADB 密钥管理器
      const keyManager = AdbKeyManager.getInstance();
      await keyManager.init(context);

      // 导出密钥到临时文件
      const tempDir = context.tempDir;
      const pubKeyPath = tempDir + '/scrcpy_adbkey.pub';
      const priKeyPath = tempDir + '/scrcpy_adbkey';
      
      // Write Public Key
      const pubKeyBytes = keyManager.getPublicKeyBytes();
      const pubFile = await fs.open(pubKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.write(pubFile.fd, pubKeyBytes as ArrayBuffer);
      await fs.close(pubFile.fd);

      // Write Private Key (PEM)
      const priKeyBase64 = keyManager.getPrivateKeyBase64();
      const pemContent = "-----BEGIN PRIVATE KEY-----\n" + priKeyBase64 + "\n-----END PRIVATE KEY-----";
      const priFile = await fs.open(priKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      await fs.write(priFile.fd, pemContent);
      await fs.close(priFile.fd);

      // 2. 连接ADB (Native)
      LoggerClientStream.info(`[ClientStream] Connecting to Native ADB at ${this.device.address}:${this.device.adbPort}`);
      this.adbId = await libscrcpy.adbCreate(this.device.address, this.device.adbPort);
      if (this.adbId < 0) {
          throw new Error('app.string.adb_native_connect_failed');
      }

      const connectRes: number = await libscrcpy.adbConnect(this.adbId, pubKeyPath, priKeyPath, onWaitAuth);
      if (connectRes !== 0) {
          if (connectRes === -2) {
             throw new Error('app.string.connect_timeout_toast');
          } else if (connectRes === -3) {
             throw new Error('app.string.adb_auth_failed');
          } else if (connectRes === -4) {
             throw new Error('app.string.adb_connect_timeout');
          } else if (connectRes === -5) {
             throw new Error('app.string.adb_auth_timeout');
          } else if (connectRes === -6) {
             throw new Error('app.string.connection_cancelled');
          } else if (connectRes === -7) {
             throw new Error('app.string.adb_auth_disconnected');
          } else {
             const nativeDetail: string = libscrcpy.adbGetLastConnectError(this.adbId);
             throw new Error(this.mapNativeConnectError(connectRes, nativeDetail));
          }
      }
      LoggerClientStream.info('[ClientStream] Native ADB connected');

      // 3. 推送服务端
      const serverPath = `/data/local/tmp/scrcpy-server-${ServerManager.getVersion()}`;
      if (serverJarData && serverJarData.byteLength > 0) {
          LoggerClientStream.info(`[ClientStream] Pushing server to ${serverPath}...`);
          await libscrcpy.adbPushFile(this.adbId, serverJarData, serverPath);
      } else {
          LoggerClientStream.warn('[ClientStream] No server jar data, skipping push');
      }

      return this.adbId;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerClientStream.error('[ClientStream] prepareServerForNative failed:', errMsg);
      this.close();
      throw (err instanceof Error) ? err : new Error(String(err));
    }
  }

  async startServer(args: string): Promise<void> {
    const serverPath = `/data/local/tmp/scrcpy-server-${ServerManager.getVersion()}`;
    const cmd = `CLASSPATH=${serverPath} app_process / com.genymobile.scrcpy.Server ${ServerManager.getVersion()} ${args} 2>&1`;

    this.stopServer();

    this.shellStreamId = await libscrcpy.adbGetShell(this.adbId);
    if (this.shellStreamId < 0) {
      throw new Error('Native ADB Get Shell failed');
    }
    const shellStreamId = this.shellStreamId;

    const cmdBytes = buffer.from(cmd + '\n', 'utf-8');
    await libscrcpy.adbStreamWrite(this.adbId, shellStreamId, cmdBytes.buffer);

    this.readShellOutputAsync(shellStreamId);
  }

  async pushFile(
    data: ArrayBuffer,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<void> {
    this.ensureAdbReady();
    LoggerClientStream.info(`[ClientStream] Pushing file to ${remotePath}`);
    await libscrcpy.adbPushFile(this.adbId, data, remotePath, onProgress);
  }

  async pushFileFromFd(
    fd: number,
    fileSize: number,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<void> {
    this.ensureAdbReady();
    LoggerClientStream.info(`[ClientStream] Pushing file to ${remotePath}`);
    await libscrcpy.adbPushFileFromFd(this.adbId, fd, fileSize, remotePath, onProgress);
  }

  async listRemoteDirectory(remotePath: string): Promise<Array<libscrcpy.RemoteFileEntry>> {
    this.ensureAdbReady();
    return await libscrcpy.adbListDirectory(this.adbId, remotePath);
  }

  async execShell(cmd: string): Promise<libscrcpy.AdbShellCommandResult> {
    this.ensureAdbReady();
    LoggerClientStream.info(`[ClientStream] Exec shell: ${cmd}`);
    return await libscrcpy.adbExecShell(this.adbId, cmd);
  }

  async installPackage(
    apkData: ArrayBuffer,
    remoteName: string,
    installArgs: string = '-r',
    onProgress?: (progress: number) => void
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    this.ensureAdbReady();
    LoggerClientStream.info(`[ClientStream] Installing package via ${remoteName}`);
    return await libscrcpy.adbInstallPackage(this.adbId, apkData, remoteName, installArgs, onProgress);
  }

  async installPackageFromFd(
    fd: number,
    fileSize: number,
    remoteName: string,
    installArgs: string = '-r',
    onProgress?: (progress: number) => void
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    this.ensureAdbReady();
    LoggerClientStream.info(`[ClientStream] Installing package via ${remoteName}`);
    return await libscrcpy.adbInstallPackageFromFd(this.adbId, fd, fileSize, remoteName, installArgs, onProgress);
  }

  // 异步读取Shell输出
  private async readShellOutputAsync(shellStreamId: number) {
    try {
        const decoder = util.TextDecoder.create('utf-8');
        while (!this.isClosing && this.adbId >= 0) {
            const isClosed: boolean = libscrcpy.adbIsStreamClosed(this.adbId, shellStreamId);
            if (isClosed) {
                LoggerClientStream.info('[ClientStream] Shell stream closed by remote');
                break;
            }
            
            const data: ArrayBuffer = libscrcpy.adbStreamRead(this.adbId, shellStreamId, 1024);
            if (data.byteLength > 0) {
                const text = decoder.decodeToString(new Uint8Array(data));
                LoggerClientStream.info('[ServerOutput] ' + text.trim());
            } else {
                await new Promise<void>(resolve => setTimeout(resolve, 100));
            }
        }
    } catch (e) {
        LoggerClientStream.error('[ClientStream] Read shell output failed', JSON.stringify(e));
    }
    // Do not close the whole ADB connection here.
    // Native stream threads may still be running and own the shutdown order.
    if (this.shellStreamId === shellStreamId) {
      this.shellStreamId = -1;
    }
  }

  stopServer(): void {
    if (this.adbId < 0 || this.shellStreamId < 0) {
      return;
    }

    const shellStreamId = this.shellStreamId;
    this.shellStreamId = -1;
    try {
      libscrcpy.adbStreamClose(this.adbId, shellStreamId);
    } catch (e) {
      LoggerClientStream.error('[ClientStream] stopServer failed', JSON.stringify(e));
    }
  }

  async stopServerAndWait(timeoutMs: number = ClientStream.SERVER_STOP_WAIT_MS): Promise<void> {
    if (this.adbId < 0 || this.shellStreamId < 0) {
      return;
    }

    const shellStreamId = this.shellStreamId;
    this.stopServer();

    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      if (this.adbId < 0 || libscrcpy.adbIsStreamClosed(this.adbId, shellStreamId)) {
        return;
      }
      await new Promise<void>(resolve => setTimeout(resolve, ClientStream.SERVER_STOP_POLL_INTERVAL_MS));
    }

    LoggerClientStream.warn('[ClientStream] Timed out waiting for server shell to close');
  }

  isServerShellAlive(): boolean {
    if (this.adbId < 0 || this.shellStreamId < 0) {
      return false;
    }
    return !libscrcpy.adbIsStreamClosed(this.adbId, this.shellStreamId);
  }

  close() {
      if (this.isClosing) return;
      this.isClosing = true;
      this.stopServer();
      
      if (this.adbId >= 0) {
          libscrcpy.adbClose(this.adbId);
          this.adbId = -1;
          this.shellStreamId = -1;
      }
  }

  private mapNativeConnectError(connectRes: number, nativeDetail: string): string {
    const detail = nativeDetail.toLowerCase();
    LoggerClientStream.error('[ClientStream] Native ADB connect detail:', nativeDetail);

    if (detail.includes('stls upgrade failed') || detail.includes('tls handshake failed')) {
      return 'app.string.adb_wireless_tls_failed';
    }
    if (detail.includes('tlsadbchannel: read failed')) {
      return 'app.string.adb_wireless_tls_interrupted';
    }
    if (detail.includes('unexpected initial adb response') || detail.includes('expected cnxn')) {
      return 'app.string.adb_wireless_protocol_failed';
    }
    if (detail.includes('connect response failed')) {
      return 'app.string.adb_connect_timeout';
    }

    LoggerClientStream.error('[ClientStream] Native ADB connect failed with code:', String(connectRes));
    return 'app.string.adb_native_connect_failed';
  }
}
