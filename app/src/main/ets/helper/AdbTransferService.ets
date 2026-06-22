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

  private static async connect(context: common.UIAbilityContext, device: Device): Promise<number> {
    const keyPaths: AdbKeyFilePaths = await AdbTransferService.writeKeyFiles(context);
    const pubKeyPath: string = keyPaths.pubKeyPath;
    const priKeyPath: string = keyPaths.priKeyPath;
    const adbId: number = await libscrcpy.adbCreate(device.address, device.adbPort);
    if (adbId < 0) {
      throw new Error('app.string.adb_native_connect_failed');
    }

    const connectRes: number = await libscrcpy.adbConnect(adbId, pubKeyPath, priKeyPath);
    if (connectRes !== 0) {
      if (connectRes === -2) {
        throw new Error('app.string.connect_timeout_toast');
      }
      if (connectRes === -3) {
        throw new Error('app.string.adb_auth_failed');
      }
      if (connectRes === -4) {
        throw new Error('app.string.adb_connect_timeout');
      }
      if (connectRes === -5) {
        throw new Error('app.string.adb_auth_timeout');
      }
      if (connectRes === -6) {
        throw new Error('app.string.connection_cancelled');
      }
      if (connectRes === -7) {
        throw new Error('app.string.adb_auth_disconnected');
      }
      const nativeDetail: string = String(libscrcpy.adbGetLastConnectError(adbId));
      throw new Error(AdbTransferService.mapNativeConnectError(connectRes, nativeDetail));
    }

    return adbId;
  }

  static async pushFileFromFd(
    context: common.UIAbilityContext,
    device: Device,
    fd: number,
    fileSize: number,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<void> {
    let adbId = -1;
    try {
      LoggerAdb.info(`[AdbTransferService] Push file to ${remotePath} using dedicated ADB session`);
      adbId = await AdbTransferService.connect(context, device);
      await libscrcpy.adbPushFileFromFd(adbId, fd, fileSize, remotePath, onProgress);
    } finally {
      if (adbId >= 0) {
        libscrcpy.adbClose(adbId);
      }
    }
  }

  static async pullFileToFd(
    context: common.UIAbilityContext,
    device: Device,
    fd: number,
    remotePath: string,
    onProgress?: (progress: number) => void
  ): Promise<number> {
    let adbId = -1;
    try {
      LoggerAdb.info(`[AdbTransferService] Pull file from ${remotePath} using dedicated ADB session`);
      adbId = await AdbTransferService.connect(context, device);
      return await libscrcpy.adbPullFileToFd(adbId, fd, remotePath, onProgress);
    } finally {
      if (adbId >= 0) {
        libscrcpy.adbClose(adbId);
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
    onProgress?: (progress: number) => void
  ): Promise<libscrcpy.AdbInstallPackageResult> {
    let adbId = -1;
    try {
      LoggerAdb.info(`[AdbTransferService] Install package ${remoteName} using dedicated ADB session`);
      adbId = await AdbTransferService.connect(context, device);
      return await libscrcpy.adbInstallPackageFromFd(adbId, fd, fileSize, remoteName, installArgs, onProgress);
    } finally {
      if (adbId >= 0) {
        libscrcpy.adbClose(adbId);
      }
    }
  }
}
