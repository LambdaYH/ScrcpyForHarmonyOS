import preferences from '@ohos.data.preferences';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import deviceInfo from '@ohos.deviceInfo';
import * as libscrcpy from 'libscrcpy_native.so';

import { LoggerAdbKeyManager } from './Logger';
import { parseWirelessAdbEndpoint } from './WirelessAdbPairingUtils';
import type { WirelessAdbEndpoint } from './WirelessAdbPairingUtils';

class KeyGenerationInfo {
  generation: number;
  hasKey: boolean;

  constructor(generation: number, hasKey: boolean) {
    this.generation = generation;
    this.hasKey = hasKey;
  }
}

// ADB密钥管理

// 可序列化的密钥数据（用于 Worker 线程传递）
export interface AdbKeySerialData {
  privateKeyBase64: string;
  publicKeyBase64: string;
  adbPublicKeyBase64: string;
  keyGeneration: number;
}

export class QrPairingSessionInfo {
  sessionId: number;
  pairingCode: string;
  serviceName: string;

  constructor(sessionId: number, pairingCode: string, serviceName: string) {
    this.sessionId = sessionId;
    this.pairingCode = pairingCode;
    this.serviceName = serviceName;
  }
}

export interface QrPairingResult {
  guid: string;
  pairedHost: string;
  endpoint: WirelessAdbEndpoint | null;
}

class NativeAdbKeyFiles {
  pubKeyPath: string;
  priKeyPath: string;

  constructor(pubKeyPath: string, priKeyPath: string) {
    this.pubKeyPath = pubKeyPath;
    this.priKeyPath = priKeyPath;
  }
}

interface NativeQrPairingResult {
  guid: string;
  pairedHost: string;
  hostPort: string;
}

export class AdbKeyManager {
  private static instance: AdbKeyManager;
  private preferences?: preferences.Preferences;
  private publicKeyBase64: string = '';
  private privateKeyBase64: string = '';
  private adbPublicKeyBase64: string = ''; // 保存ADB格式的公钥
  private cachedKeyPair?: cryptoFramework.KeyPair; // 缓存生成的KeyPair
  private keyGeneration: number = 0; // 密钥代数，用于检测是否需要重新生成
  
  public getPrivateKeyBase64(): string {
    return this.privateKeyBase64;
  }

  public getAdbPublicKeyBase64(): string {
    return this.adbPublicKeyBase64;
  }

  private constructor() {}
  
  static getInstance(): AdbKeyManager {
    if (!AdbKeyManager.instance) {
      AdbKeyManager.instance = new AdbKeyManager();
    }
    return AdbKeyManager.instance;
  }
  
  async init(context: Context): Promise<void> {
    try {
      this.preferences = await preferences.getPreferences(context, 'adb_keys');
      
      // 加载默认密钥
      await this.loadKeys();
      
      // 关键：如果有保存的密钥但KeyPair为空（或者根本没密钥），生成新密钥
      if ((this.adbPublicKeyBase64 && !this.cachedKeyPair) || (!this.cachedKeyPair || !this.adbPublicKeyBase64)) {
        if (!this.adbPublicKeyBase64) {
             LoggerAdbKeyManager.info(`ADB: No saved keys, generating new key pair...`);
        } else {
             LoggerAdbKeyManager.warn(`ADB: Saved key found but KeyPair not loaded. Generating new key pair...`);
        }
        await this.generateKeyPair();
      } else {
        LoggerAdbKeyManager.info(`ADB: Successfully loaded common keys, generation: ${this.keyGeneration}`);
      }
    } catch (err) {
      LoggerAdbKeyManager.error('AdbKeyManager init failed:', err);
    }
  }
  
  private async loadKeys(): Promise<void> {
    try {
      if (!this.preferences) return;
      
      this.privateKeyBase64 = await this.preferences.get('private_key', '') as string;
      this.publicKeyBase64 = await this.preferences.get('public_key', '') as string;
      this.adbPublicKeyBase64 = await this.preferences.get('adb_public_key', '') as string;
      this.keyGeneration = await this.preferences.get('generation', 0) as number;
      
      // 如果有保存的密钥，重建KeyPair缓存
      if (this.privateKeyBase64 && this.publicKeyBase64) {
        await this.rebuildKeyPair();
      }
    } catch (err) {
      LoggerAdbKeyManager.error('Load keys failed:', err);
    }
  }
  
  private async saveKeys(): Promise<void> {
    try {
      if (!this.preferences) return;
      
      await this.preferences.put('private_key', this.privateKeyBase64);
      await this.preferences.put('public_key', this.publicKeyBase64);
      await this.preferences.put('adb_public_key', this.adbPublicKeyBase64);
      await this.preferences.put('generation', this.keyGeneration);
      
      await this.preferences.flush();
    } catch (err) {
      LoggerAdbKeyManager.error('Save keys failed:', err);
    }
  }

  private async generateKeyPair(): Promise<void> {
    try {
      // 生成RSA 2048密钥对
      const rsaGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const keyPair = await rsaGenerator.generateKeyPair();
      
      // 缓存KeyPair对象
      this.cachedKeyPair = keyPair;
      this.keyGeneration++; // 增加代数
      
      // 获取密钥编码 (PKCS8格式)
      const priKeyBlob = keyPair.priKey.getEncoded();
      const pubKeyBlob = keyPair.pubKey.getEncoded();
      
      // 转换为Base64保存
      const base64Helper = new util.Base64Helper();
      this.privateKeyBase64 = base64Helper.encodeToStringSync(priKeyBlob.data);
      this.publicKeyBase64 = base64Helper.encodeToStringSync(pubKeyBlob.data);
      
      this.adbPublicKeyBase64 = this.normalizeStoredPublicKey(this.publicKeyBase64).adbPublicKeyBase64;
      
      // 保存到preferences
      await this.saveKeys();
      
      LoggerAdbKeyManager.info(`ADB key pair generated and cached, generation: ${this.keyGeneration}`);
    } catch (err) {
      LoggerAdbKeyManager.error('Generate key pair failed:', err);
      this.privateKeyBase64 = 'DEFAULT_PRIVATE_KEY';
      this.publicKeyBase64 = 'DEFAULT_PUBLIC_KEY';
    }
  }

  private async rebuildKeyPair(): Promise<void> {
    try {
      LoggerAdbKeyManager.info('ADB: Attempting to rebuild KeyPair from saved keys...');
      const base64Helper = new util.Base64Helper();
      const priKeyData: Uint8Array = base64Helper.decodeSync(this.privateKeyBase64);
      const pubKeyData: Uint8Array = base64Helper.decodeSync(this.publicKeyBase64);
      
      const rsaGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const priKeyBlob: cryptoFramework.DataBlob = { data: priKeyData };
      const pubKeyBlob: cryptoFramework.DataBlob = { data: pubKeyData };
      
      this.cachedKeyPair = await rsaGenerator.convertKey(pubKeyBlob, priKeyBlob);
      LoggerAdbKeyManager.info('ADB: KeyPair rebuilt successfully');
    } catch (err) {
      LoggerAdbKeyManager.error('Rebuild KeyPair failed:', err);
      this.cachedKeyPair = undefined;
    }
  }
  
  getPublicKey(): string {
    return this.publicKeyBase64;
  }
  
  getPrivateKey(): string {
    return this.privateKeyBase64;
  }
  
  getPublicKeyBytes(): ArrayBuffer {
    try {
      // 优先使用保存的ADB格式公钥
      if (this.adbPublicKeyBase64) {
        LoggerAdbKeyManager.info('ADB: Using saved ADB format public key');
        const comment = this.buildPublicKeyComment();
        const keyWithComment = this.adbPublicKeyBase64 + comment;
        return buffer.from(keyWithComment, 'utf-8').buffer;
      }
      
      if (this.publicKeyBase64) {
        this.adbPublicKeyBase64 = this.normalizeStoredPublicKey(this.publicKeyBase64).adbPublicKeyBase64;
        if (this.adbPublicKeyBase64) {
          const comment = this.buildPublicKeyComment();
          const keyWithComment = this.adbPublicKeyBase64 + comment;
          return buffer.from(keyWithComment, 'utf-8').buffer;
        }
      }
      
      // 最后的fallback：使用PKCS格式
      if (this.publicKeyBase64) {
        LoggerAdbKeyManager.warn('ADB: Using fallback PKCS public key format (may not work)');
        const comment = this.buildPublicKeyComment();
        const keyWithComment = this.publicKeyBase64 + comment;
        return buffer.from(keyWithComment, 'utf-8').buffer;
      }
      
      LoggerAdbKeyManager.error('No public key available');
      return new ArrayBuffer(0);
    } catch (err) {
      LoggerAdbKeyManager.error('Get public key bytes failed:', err);
      return new ArrayBuffer(0);
    }
  }

  private buildPublicKeyComment(): string {
    const rawName = deviceInfo.marketName ? String(deviceInfo.marketName) : 'HarmonyOS';
    const normalizedName = rawName.trim().replace(/\s+/g, '_');
    return ` scrcpy@${normalizedName}\0`;
  }

  private buildPublicKeyPem(publicKeyBase64: string): string {
    return `-----BEGIN PUBLIC KEY-----\n${publicKeyBase64}\n-----END PUBLIC KEY-----`;
  }

  private normalizeStoredPublicKey(publicKeyBase64: string): libscrcpy.AdbNormalizedPublicKeyResult {
    return libscrcpy.adbNormalizePublicKey(this.buildPublicKeyPem(publicKeyBase64));
  }


  async signData(data: ArrayBuffer): Promise<ArrayBuffer> {
    try {
      // 如果没有缓存的KeyPair，先重建
      if (!this.cachedKeyPair) {
        LoggerAdbKeyManager.info('ADB: No cached KeyPair, rebuilding...');
        await this.rebuildKeyPair();
      }
      
      if (!this.cachedKeyPair || !this.cachedKeyPair.priKey) {
        throw new Error('No valid private key available');
      }
      
      // ADB使用RSA/ECB/NoPadding加密
      // 添加signature padding
      const SIGNATURE_PADDING = new Uint8Array([
        0x00, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00,
        0x30, 0x21, 0x30, 0x09, 0x06, 0x05, 0x2b, 0x0e, 0x03, 0x02, 0x1a, 0x05, 0x00,
        0x04, 0x14
      ]);
      
      // 合并padding和data
      const dataArray = new Uint8Array(data);
      const combined = new Uint8Array(SIGNATURE_PADDING.length + dataArray.length);
      combined.set(SIGNATURE_PADDING, 0);
      combined.set(dataArray, SIGNATURE_PADDING.length);
      
      LoggerAdbKeyManager.info('ADB: Signing with cached KeyPair, data length:', combined.length);
      
      // ADB签名实际上是用私钥"解密"token，所以使用DECRYPT模式
      const cipher = cryptoFramework.createCipher('RSA2048|NoPadding');
      await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, this.cachedKeyPair.priKey!, null);
      
      const inputBlob: cryptoFramework.DataBlob = { data: combined };
      const encrypted = await cipher.doFinal(inputBlob);
      
      LoggerAdbKeyManager.info('ADB: Signature generated successfully, length:', encrypted.data.length);
      
      return encrypted.data.buffer;
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerAdbKeyManager.error('Sign data failed:', errMsg);
      // 返回256字节的空签名（RSA2048签名大小）
      return new ArrayBuffer(256);
    }
  }
  
  async resetKeys(): Promise<void> {
    await this.generateKeyPair();
  }

  private async writeNativeKeyFiles(context: Context): Promise<NativeAdbKeyFiles> {
    const tempDir = context.tempDir;
    const pubKeyPath = tempDir + '/scrcpy_adbkey.pub';
    const priKeyPath = tempDir + '/scrcpy_adbkey';

    const pubKeyBytes = this.getPublicKeyBytes();
    const pubFile = await fs.open(pubKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      await fs.write(pubFile.fd, pubKeyBytes as ArrayBuffer);
    } finally {
      await fs.close(pubFile.fd);
    }

    const pemContent = "-----BEGIN PRIVATE KEY-----\n" + this.privateKeyBase64 + "\n-----END PRIVATE KEY-----";
    const priFile = await fs.open(priKeyPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      await fs.write(priFile.fd, pemContent);
    } finally {
      await fs.close(priFile.fd);
    }

    return new NativeAdbKeyFiles(pubKeyPath, priKeyPath);
  }

  async pairDevice(context: Context, hostPort: string, pairingCode: string): Promise<string> {
    await this.init(context);
    const keyFiles = await this.writeNativeKeyFiles(context);
    return await libscrcpy.adbPair(hostPort, pairingCode, keyFiles.pubKeyPath, keyFiles.priKeyPath);
  }

  async startQrPairingSession(context: Context, localIp: string): Promise<QrPairingSessionInfo> {
    await this.init(context);
    const keyFiles = await this.writeNativeKeyFiles(context);
    const sessionInfo: libscrcpy.AdbQrPairingSessionInfo =
      await libscrcpy.adbStartQrPairing(keyFiles.pubKeyPath, keyFiles.priKeyPath, localIp);
    return new QrPairingSessionInfo(sessionInfo.sessionId, sessionInfo.pairingCode, sessionInfo.serviceName);
  }

  async waitQrPairingSession(sessionId: number): Promise<QrPairingResult> {
    const result: NativeQrPairingResult =
      await libscrcpy.adbWaitQrPairing(sessionId) as NativeQrPairingResult;
    return {
      guid: result.guid,
      pairedHost: result.pairedHost,
      endpoint: parseWirelessAdbEndpoint(result.hostPort)
    };
  }

  stopQrPairingSession(sessionId: number): void {
    libscrcpy.adbStopQrPairing(sessionId);
  }

  // 获取公共密钥信息
  getCommonKeyInfo(): KeyGenerationInfo {
    return new KeyGenerationInfo(this.keyGeneration, !!this.cachedKeyPair);
  }

  // 导出可序列化的密钥数据（用于 Worker 线程传递）
  exportKeyData(): AdbKeySerialData {
    return {
      privateKeyBase64: this.privateKeyBase64,
      publicKeyBase64: this.publicKeyBase64,
      adbPublicKeyBase64: this.adbPublicKeyBase64,
      keyGeneration: this.keyGeneration
    };
  }

  // 从序列化数据初始化（Worker 线程中使用，不需要 Context）
  async initFromKeyData(data: AdbKeySerialData): Promise<void> {
    try {
      this.privateKeyBase64 = data.privateKeyBase64;
      this.publicKeyBase64 = data.publicKeyBase64;
      this.adbPublicKeyBase64 = data.adbPublicKeyBase64;
      this.keyGeneration = data.keyGeneration;

      // 从 base64 字符串重建 KeyPair（使用 cryptoFramework，不需要 Context）
      if (this.privateKeyBase64 && this.publicKeyBase64) {
        await this.rebuildKeyPair();
      }

      if (this.cachedKeyPair) {
        LoggerAdbKeyManager.info('ADB: KeyPair restored from serialized data, generation:', this.keyGeneration);
      } else {
        LoggerAdbKeyManager.error('ADB: Failed to restore KeyPair from serialized data');
      }
    } catch (err) {
      LoggerAdbKeyManager.error('initFromKeyData failed:', err);
    }
  }

  // 重新生成公共密钥
  async regenerateCommonKey(): Promise<void> {
    try {
      LoggerAdbKeyManager.info(`ADB: Regenerating common key...`);
      
      // 生成新密钥
      const rsaGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const keyPair = await rsaGenerator.generateKeyPair();
      
      this.cachedKeyPair = keyPair;
      this.keyGeneration++;
      
      const priKeyBlob = keyPair.priKey.getEncoded();
      const pubKeyBlob = keyPair.pubKey.getEncoded();
      
      const base64Helper = new util.Base64Helper();
      this.privateKeyBase64 = base64Helper.encodeToStringSync(priKeyBlob.data);
      this.publicKeyBase64 = base64Helper.encodeToStringSync(pubKeyBlob.data);
      this.adbPublicKeyBase64 = this.normalizeStoredPublicKey(this.publicKeyBase64).adbPublicKeyBase64;
      
      // 保存为默认密钥
      await this.saveKeys();
      
      LoggerAdbKeyManager.info(`ADB: Common key regenerated, new generation: ${this.keyGeneration}`);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbKeyManager.error('Regenerate common key failed:', error.message);
      throw error;
    }
  }

  // 导入自定义密钥
  async importCustomKey(privateKeyStr: string, publicKeyStr: string): Promise<void> {
    try {
      if (!privateKeyStr || !publicKeyStr) {
        throw new Error('Keys cannot be empty');
      }

      LoggerAdbKeyManager.info('ADB: Importing custom key...');
      
      const base64Helper = new util.Base64Helper();
      
      // 1. 处理私钥 (PEM -> Base64 -> Uint8Array)
      const cleanPriv = privateKeyStr.replace(/-----BEGIN PRIVATE KEY-----/g, '').replace(/-----END PRIVATE KEY-----/g, '').replace(/\s/g, '');
      let priKeyData: Uint8Array;
      try {
         priKeyData = base64Helper.decodeSync(cleanPriv);
      } catch (e) {
         throw new Error('Invalid Private Key Base64 format');
      }

      // 2. 处理公钥：统一交给 native 侧完成 PEM / ADB 格式解析与标准化
      const normalizedPublicKey: libscrcpy.AdbNormalizedPublicKeyResult =
        libscrcpy.adbNormalizePublicKey(publicKeyStr);
      const finalPublicKeyBase64: string = normalizedPublicKey.x509PublicKeyBase64;
      let adbFormatBase64: string = normalizedPublicKey.adbPublicKeyBase64;
      let pubKeyData: Uint8Array;
      try {
        pubKeyData = base64Helper.decodeSync(finalPublicKeyBase64);
      } catch (e) {
        throw new Error('Invalid Public Key format');
      }

      const rsaGenerator = cryptoFramework.createAsyKeyGenerator('RSA2048');
      const priKeyBlob: cryptoFramework.DataBlob = { data: priKeyData };
      const pubKeyBlob: cryptoFramework.DataBlob = { data: pubKeyData };
      
      // 3. 验证密钥对
      const keyPair = await rsaGenerator.convertKey(pubKeyBlob, priKeyBlob);
      
      // 4. 保存
      this.cachedKeyPair = keyPair;
      this.privateKeyBase64 = cleanPriv;
      this.publicKeyBase64 = finalPublicKeyBase64;
      this.keyGeneration++; 
      
      this.adbPublicKeyBase64 = adbFormatBase64;
      
      await this.saveKeys();
      LoggerAdbKeyManager.info('ADB: Custom key imported successfully');

    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbKeyManager.error('Import custom key failed:', error.message);
      throw error;
    }
  }

}
