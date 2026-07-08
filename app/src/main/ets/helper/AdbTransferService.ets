import { common } from '@kit.AbilityKit';
import fs from '@ohos.file.fs';
import { buffer } from '@kit.ArkTS';
import * as libscrcpy from 'libscrcpy_native.so';

import { Device } from '../entity/Device';
import { AdbKeyManager } from './AdbKeyManager';
import { LoggerAdb } from './Logger';

interface AdbKeyFilePaths {
  pubKeyPath: string;
  priKeyPath: string;
}

export class AdbTransferCancellationController {
  private adbId: number = -1;
  private cancellationRequested: boolean = false;
  private closePromise: Promise<void> | undefined = undefined;

  attach(adbId: number): void {
    this.adbId = adbId;
  }

  isCancellationRequested(): boolean {
    return this.cancellationRequested;
  }

  async cancel(): Promise<void> {
    this.cancellationRequested = true;
    await this.closeCurrent();
  }

  async closeCurrent(): Promise<void> {
    if (this.adbId < 0) {
      return;
    }
    const adbId = this.adbId;
    this.adbId = -1;
    this.closePromise = libscrcpy.adbClose(adbId);
    try {
      await this.closePromise;
    } catch (err) {
      LoggerAdb.warn('[AdbTransferService] Close transfer ADB session failed:', String(err));
    } finally {
      this.closePromise = undefined;
    }
  }
}

export class AdbTransferService {
  private static async writeKeyFiles(context: common.UIAbilityContext): Promise<AdbKeyFilePaths> {
    const keyManager = AdbKeyManager.getInstance();
    await keyManager.init(context);

    const tempDir = context.tempDir;
    const pubKeyPath = `${tempDir}/scrcpy_transfer_adbkey.pub`;
    const priKeyPath = `${tempDir}/scrcpy_transfer_adbkey`;

    const pubFile = await fs.open(pubKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    await fs.write(pubFile.fd, keyManager.getPublicKeyBytes());
    await fs.close(pubFile.fd);

    const pemContent = `-----BEGIN PRIVATE KEY-----\n${keyManager.getPrivateKeyBase64()}\n-----END PRIVATE KEY-----`;
    const priFile = await fs.open(priKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    await fs.write(priFile.fd, buffer.from(pemContent, 'utf-8').buffer);
    await fs.close(priFile.fd);

    const keyPaths: AdbKeyFilePaths = {
      pubKeyPath: pubKeyPath,
      priKeyPath: priKeyPath
    };
    return keyPaths;
  }

  private static mapNativeConnectError(connectRes: number, nativeDetail: string): string {
    const detail = nativeDetail.toLowerCase();
    LoggerAdb.error('[AdbTransferService] Native ADB connect detail:', nativeDetail);

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

    LoggerAdb.error('[AdbTransferService] Native ADB connect failed with code:', String(connectRes));
    return 'app.string.adb_native_connect_failed';
  }

  private static async closeSession(
    adbId: number,
    cancellationController?: AdbTransferCancellationController
  ): Promise<void> {
    if (adbId < 0) {
      return;
    }
    if (cancellationController) {
      await cancellationController.closeCurrent();
      return;
    }
    try {
      await libscrcpy.adbClose(adbId);
    } catch (err) {
      LoggerAdb.warn('[AdbTransferService] Close transfer ADB session failed:', String(err));
    }
  }

  private static async connect(
    context: common.UIAbilityContext,
    device: Device,
    cancellationController?: AdbTransferCancellationController
  ): Promise<number> {
    const keyPaths: AdbKeyFilePaths = await AdbTransferService.writeKeyFiles(context);
    const pubKeyPath: string = keyPaths.pubKeyPath;
    const priKeyPath: string = keyPaths.priKeyPath;
    const adbId: number = await libscrcpy.adbCreate(device.address, device.adbPort);
    if (adbId < 0) {
      throw new Error('app.string.adb_native_connect_failed');
    }
    cancellationController?.attach(adbId);
    if (cancellationController?.isCancellationRequested()) {
      await AdbTransferService.closeSession(adbId, cancellationController);
      throw new Error('Transfer cancelled');
    }

    let connectRes: number;
    try {
      connectRes = await libscrcpy.adbConnect(adbId, pubKeyPath, priKeyPath);
    } catch (err) {
      await AdbTransferService.closeSession(adbId, cancellationController);
      throw new Error(err instanceof Error ? err.message : String(err));
    }
    if (connectRes !== 0) {
      let mappedError: string;
      if (connectRes === -2) {
        mappedError = 'app.string.connect_timeout_toast';
      } else if (connectRes === -3) {
        mappedError = 'app.string.adb_auth_failed';
      } else if (connectRes === -4) {
        mappedError = 'app.string.adb_connect_timeout';
      } else if (connectRes === -5) {
        mappedError = 'app.string.adb_auth_timeout';
      } else if (connectRes === -6) {
        mappedError = 'app.string.connection_cancelled';
      } else if (connectRes === -7) {
        mappedError = 'app.string.adb_auth_disconnected';
      } else {
        const nativeDetail: string = String(libscrcpy.adbGetLastConnectError(adbId));
        mappedError = AdbTransferService.mapNativeConnectError(connectRes, nativeDetail);
      }
      await AdbTransferService.closeSession(adbId, cancellationController);
      throw new Error(mappedError);
    }
    if (cancellationController?.isCancellationRequested()) {
      await AdbTransferService.closeSession(adbId, cancellationController);
      throw new Error('Transfer cancelled');
    }

    return adbId;
  }

  static async pushFileFromFd(
    context: common.UIAbilityContext,
    device: Device,
    fd: number,
    fileSize: number,
    remotePath: string,
    onProgress?: (progress: number) => void,
    cancellationController?: AdbTransferCancellationController
  ): Promise<void> {
    let adbId = -1;
    try {
      LoggerAdb.info(`[AdbTransferService] Push file to ${remotePath} using dedicated ADB session`);
      adbId = await AdbTransferService.connect(context, device, cancellationController);
      await libscrcpy.adbPushFileFromFd(adbId, fd, fileSize, remotePath, onProgress);
    } finally {
      if (adbId >= 0) {
        await AdbTransferService.closeSession(adbId, cancellationController);
      }
    }
  }

  static async pullFileToFd(
    context: common.UIAbilityContext,
    device: Device,
    fd: number,
    remotePath: string,
    onProgress?: (progress: number) => void,
    cancellationController?: AdbTransferCancellationController
  ): Promise<number> {
    let adbId = -1;
    try {
      LoggerAdb.info(`[AdbTransferService] Pull file from ${remotePath} using dedicated ADB session`);
      adbId = await AdbTransferService.connect(context, device, cancellationController);
      return await libscrcpy.adbPullFileToFd(adbId, fd, remotePath, onProgress);
    } finally {
      if (adbId >= 0) {
        await AdbTransferService.closeSession(adbId, cancellationController);
      }
    }
  }

  static async installPackageFromFd(
    context: common.UIAbilityContext,
    device: Device,
    fd: number,
    fileSize: number,
    remoteName: string,
    installArgs: string = '-r',
    onProgress?: (progress: number) => void,
    cancellationController?: AdbTransferCancellationController
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    let adbId = -1;
    try {
      LoggerAdb.info(`[AdbTransferService] Install package ${remoteName} using dedicated ADB session`);
      adbId = await AdbTransferService.connect(context, device, cancellationController);
      return await libscrcpy.adbInstallPackageFromFd(adbId, fd, fileSize, remoteName, installArgs, onProgress);
    } finally {
      if (adbId >= 0) {
        await AdbTransferService.closeSession(adbId, cancellationController);
      }
    }
  }
}
