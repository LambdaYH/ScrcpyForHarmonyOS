import preferences from '@ohos.data.preferences';
import cryptoFramework from '@ohos.security.cryptoFramework';
import { util } from '@kit.ArkTS';
import { buffer } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import deviceInfo from '@ohos.deviceInfo';
import * as libscrcpy from 'libscrcpy_native.so';

import { LoggerAdbKeyManager } from './Logger';
// RSA公钥解析结果
class RsaKeyParams {
  modulus: bigint;
  exponent: number;
  
  constructor(modulus: bigint, exponent: number) {
    this.modulus = modulus;
    this.exponent = exponent;
  }
}

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

export interface QrPairingSessionInfo {
  sessionId: number;
  pairingCode: string;
  serviceName: string;
}

export interface QrPairingResult {
  guid: string;
  pairedHost: string;
  hostPort: string;
}

interface NativeAdbKeyFiles {
  pubKeyPath: string;
  priKeyPath: string;
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
      
      // 生成并保存ADB格式公钥
      const adbFormatKey = this.convertRsaPublicKeyToAdbFormat();
      if (adbFormatKey && adbFormatKey.byteLength > 0) {
        this.adbPublicKeyBase64 = base64Helper.encodeToStringSync(new Uint8Array(adbFormatKey));
        LoggerAdbKeyManager.info('ADB: ADB format public key generated and saved');
      }
      
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
      
      // 如果有cachedKeyPair，实时生成ADB格式公钥
      if (this.cachedKeyPair && this.cachedKeyPair.pubKey) {
        const adbFormatKey = this.convertRsaPublicKeyToAdbFormat();
        if (adbFormatKey && adbFormatKey.byteLength > 0) {
          LoggerAdbKeyManager.info('ADB: Generated ADB format key on-the-fly, size:', adbFormatKey.byteLength);
          
          const base64Helper = new util.Base64Helper();
          const base64Key = base64Helper.encodeToStringSync(new Uint8Array(adbFormatKey));
          const comment = this.buildPublicKeyComment();
          const keyWithComment = base64Key + comment;
          
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


  
  // 将RSA公钥转换为ADB格式（524字节）
  private convertRsaPublicKeyToAdbFormat(): ArrayBuffer | null {
    try {
      if (!this.cachedKeyPair || !this.cachedKeyPair.pubKey) {
        return null;
      }
      
      // 从PKCS#8格式公钥中提取modulus和exponent
      const pubKeyBlob = this.cachedKeyPair.pubKey.getEncoded();
      const keyData = new Uint8Array(pubKeyBlob.data);
      
      // 解析PKCS#8 DER编码获取modulus和exponent
      // PKCS#8公钥格式：SEQUENCE { SEQUENCE { OID, NULL }, BIT STRING { SEQUENCE { INTEGER(n), INTEGER(e) } } }
      const parsed = this.parseRsaPublicKey(keyData);
      if (!parsed) {
        LoggerAdbKeyManager.error('Failed to parse RSA public key');
        return null;
      }
      
      const modulus = parsed.modulus;
      const exponent = parsed.exponent;
      LoggerAdbKeyManager.info('ADB: RSA key parsed - modulus length:', modulus.toString().length, 'exponent:', exponent);
      
      // 转换为ADB格式
      return this.buildAdbPublicKey(modulus, exponent);
    } catch (err) {
      LoggerAdbKeyManager.error('Convert RSA public key to ADB format failed:', err);
      return null;
    }
  }
  
  // 解析PKCS#8 DER编码的RSA公钥
  private parseRsaPublicKey(keyData: Uint8Array): RsaKeyParams | null {
    try {
      let offset = 0;
      
      // 跳过外层SEQUENCE和算法标识符，直接找到BIT STRING中的公钥内容
      // 简单解析：查找0x02（INTEGER标记）后的大整数
      while (offset < keyData.length - 10) {
        if (keyData[offset] === 0x02) { // INTEGER tag
          // 读取长度
          offset++;
          let length = keyData[offset];
          offset++;
          
          if (length & 0x80) {
            const numBytes = length & 0x7f;
            length = 0;
            for (let i = 0; i < numBytes; i++) {
              length = (length << 8) | keyData[offset++];
            }
          }
          
          // 读取modulus（跳过可能的前导0x00）
          let modulusBytes = keyData.slice(offset, offset + length);
          if (modulusBytes[0] === 0x00) {
            modulusBytes = modulusBytes.slice(1);
          }
          
          // 转换为bigint
          let modulus = 0n;
          for (let i = 0; i < modulusBytes.length; i++) {
            modulus = (modulus << 8n) | BigInt(modulusBytes[i]);
          }
          
          offset += length;
          
          // 读取exponent
          if (keyData[offset] === 0x02) {
            offset++;
            const expLen = keyData[offset++];
            let exponent = 0;
            for (let i = 0; i < expLen; i++) {
              exponent = (exponent << 8) | keyData[offset++];
            }
            
            return new RsaKeyParams(modulus, exponent);
          }
        }
        offset++;
      }
      
      return null;
    } catch (err) {
      LoggerAdbKeyManager.error('Parse RSA public key failed:', err);
      return null;
    }
  }
  
  // 构建ADB格式的公钥（524字节）
  private buildAdbPublicKey(n: bigint, e: number): ArrayBuffer {
    const KEY_LENGTH_WORDS = 64; // 2048 bits / 32 bits = 64 words
    const r32 = 1n << 32n;
    
    // 计算 r = 2^(KEY_LENGTH_WORDS * 32)
    const r = 1n << BigInt(KEY_LENGTH_WORDS * 32);
    
    // 计算 rr = (r^2) mod n
    const rr = (r * r) % n;
    
    // 计算 n0inv = -(n^-1 mod 2^32)
    const rem = n % r32;
    const n0inv = this.modInverse(rem, r32);
    
    // 将n和rr分解为32位整数数组
    const myN: number[] = [];
    const myRr: number[] = [];
    
    let tempN = n;
    let tempRr = rr;
    
    for (let i = 0; i < KEY_LENGTH_WORDS; i++) {
      myN.push(Number(tempN % r32));
      tempN = tempN / r32;
      
      myRr.push(Number(tempRr % r32));
      tempRr = tempRr / r32;
    }
    
    // 构建524字节的ADB公钥格式
    try {
      const buf = buffer.from(new ArrayBuffer(524));
      let offset = 0;
      
      // KEY_LENGTH_WORDS (4 bytes, little-endian)
      buf.writeUInt32LE(KEY_LENGTH_WORDS, offset);
      offset += 4;
      
      // n0inv negated (4 bytes, little-endian)
      // 需要将bigint转换为有符号int32，处理溢出
      const n0invValue = Number(n0inv % r32);
      const negatedValue = -n0invValue;
      // 使用无符号写入，然后解释为有符号
      const uint32Value = (negatedValue >>> 0); // 转换为无符号32位整数
      buf.writeUInt32LE(uint32Value, offset);
      offset += 4;
      
      // myN array (256 bytes)
      for (let i = 0; i < KEY_LENGTH_WORDS; i++) {
        buf.writeUInt32LE(myN[i] >>> 0, offset);
        offset += 4;
      }
      
      // myRr array (256 bytes)
      for (let i = 0; i < KEY_LENGTH_WORDS; i++) {
        buf.writeUInt32LE(myRr[i] >>> 0, offset);
        offset += 4;
      }
      
      // exponent (4 bytes, little-endian)
      buf.writeUInt32LE(e >>> 0, offset);
      
      return buf.buffer;
    } catch (err) {
      LoggerAdbKeyManager.error('Build ADB public key failed:', err);
      return new ArrayBuffer(0);
    }
  }
  
  // 计算模逆：a^-1 mod m
  private modInverse(a: bigint, m: bigint): bigint {
    const m0 = m;
    let x0 = 0n;
    let x1 = 1n;
    
    if (m === 1n) return 0n;
    
    let tempA = a;
    let tempM = m;
    
    while (tempA > 1n) {
      const q = tempA / tempM;
      let t = tempM;
      
      tempM = tempA % tempM;
      tempA = t;
      t = x0;
      
      x0 = x1 - q * x0;
      x1 = t;
    }
    
    if (x1 < 0n) x1 += m0;
    
    return x1;
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

    const keyFiles: NativeAdbKeyFiles = {
      pubKeyPath: pubKeyPath,
      priKeyPath: priKeyPath
    };
    return keyFiles;
  }

  async pairDevice(context: Context, hostPort: string, pairingCode: string): Promise<string> {
    await this.init(context);
    const keyFiles = await this.writeNativeKeyFiles(context);
    return await libscrcpy.adbPair(hostPort, pairingCode, keyFiles.pubKeyPath, keyFiles.priKeyPath);
  }

  async startQrPairingSession(context: Context, localIp: string): Promise<QrPairingSessionInfo> {
    await this.init(context);
    const keyFiles = await this.writeNativeKeyFiles(context);
    const sessionInfo: QrPairingSessionInfo =
      await libscrcpy.adbStartQrPairing(keyFiles.pubKeyPath, keyFiles.priKeyPath, localIp);
    return sessionInfo;
  }

  async waitQrPairingSession(sessionId: number): Promise<QrPairingResult> {
    return await libscrcpy.adbWaitQrPairing(sessionId);
  }

  async discoverConnectHostPort(localIp: string, preferredHost: string = ''): Promise<string> {
    return await libscrcpy.adbDiscoverConnectHostPort(localIp, preferredHost);
  }

  async discoverConnectHostPorts(localIp: string, preferredHost: string = ''): Promise<string[]> {
    return await libscrcpy.adbDiscoverConnectHostPorts(localIp, preferredHost);
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
      
      const adbFormatKey = this.convertRsaPublicKeyToAdbFormat();
      if (adbFormatKey && adbFormatKey.byteLength > 0) {
        this.adbPublicKeyBase64 = base64Helper.encodeToStringSync(new Uint8Array(adbFormatKey));
      }
      
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

      // 2. 处理公钥 (ADB Format or PEM -> X.509 Base64 -> Uint8Array)
      // 用户提供的可能是 adbkey.pub (Base64 + comment, ADB binary format)
      // 也可能是 standard PEM (X.509)
      let pubKeyData: Uint8Array | null = null;
      let finalPublicKeyBase64 = ''; // The X.509/PEM format one we want to save
      let adbFormatBase64 = ''; // The ADB format one

      // 尝试解析为PEM
      if (publicKeyStr.includes('-----BEGIN PUBLIC KEY-----')) {
        const cleanPub = publicKeyStr.replace(/-----BEGIN PUBLIC KEY-----/g, '').replace(/-----END PUBLIC KEY-----/g, '').replace(/\s/g, '');
        try {
          pubKeyData = base64Helper.decodeSync(cleanPub);
          finalPublicKeyBase64 = cleanPub;
          // 生成ADB格式用于保存
          // (稍后在生成keypair成功后做)
        } catch (e) {
          LoggerAdbKeyManager.warn('ADB: Failed to decode public key as PEM');
        }
      } 
      
      // 如果不是PEM，或者解析失败，尝试解析为ADB格式 (OpenSSH style: type base64 comment)
      if (!pubKeyData) {
        try {
          // 提取Base64部分 (通常是第一部分)
          const parts = publicKeyStr.trim().split(/\s+/);
          let adbBase64 = parts[0];
          // 有些格式是 "ssh-rsa <key> <comment>" 或 "<key> <comment>"
          // adbkey.pub 通常是 "<base64> <user@host>"
          if (parts.length > 1 && parts[0].length < 20) {
             adbBase64 = parts[1]; // handle type prefix if any
          } else {
             adbBase64 = parts[0];
          }

          const adbKeyBytes = base64Helper.decodeSync(adbBase64);
          LoggerAdbKeyManager.info('ADB: Detected potential ADB format key, length:', adbKeyBytes.byteLength);

          // 尝试转换为X.509
          pubKeyData = this.convertAdbKeyToX509(adbKeyBytes);
          if (pubKeyData) {
            finalPublicKeyBase64 = base64Helper.encodeToStringSync(pubKeyData);
            adbFormatBase64 = adbBase64; 
            LoggerAdbKeyManager.info('ADB: Successfully converted ADB public key to X.509');
          }
        } catch (e) {
          LoggerAdbKeyManager.warn('ADB: Failed to parse as ADB key format:', e);
        }
      }

      if (!pubKeyData) {
        throw new Error('Could not parse public key (supported: PEM or ADB format)');
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
      
      // 保存ADB格式公钥
      if (adbFormatBase64) {
        this.adbPublicKeyBase64 = adbFormatBase64;
      } else {
        // 如果输入的是PEM，尝试并生成ADB格式
        const adbFormatKey = this.convertRsaPublicKeyToAdbFormat();
        if (adbFormatKey && adbFormatKey.byteLength > 0) {
          this.adbPublicKeyBase64 = base64Helper.encodeToStringSync(new Uint8Array(adbFormatKey));
        } else {
          this.adbPublicKeyBase64 = '';
        }
      }
      
      await this.saveKeys();
      LoggerAdbKeyManager.info('ADB: Custom key imported successfully');

    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbKeyManager.error('Import custom key failed:', error.message);
      throw error;
    }
  }

  // 将ADB格式公钥转换为X.509 SubjectPublicKeyInfo (DER)
  private convertAdbKeyToX509(adbKeyBytes: Uint8Array): Uint8Array | null {
    try {
      // ADB Interface: struct RSAPublicKey { int len; uint32_t n0inv; uint32_t n[RSANUMWORDS]; uint32_t rr[RSANUMWORDS]; int exponent; }
      // RSANUMWORDS = 64 (2048 bits)
      // Total size = 4 + 4 + 256 + 256 + 4 = 524 bytes
      const expectedSize = 524;
      if (adbKeyBytes.byteLength < expectedSize) {
        LoggerAdbKeyManager.warn(`ADB key size mismatch: got ${adbKeyBytes.byteLength}, expected >= ${expectedSize}`);
        // 继续尝试，也许只是后面有杂数据
      }

      const view = new DataView(adbKeyBytes.buffer, adbKeyBytes.byteOffset, adbKeyBytes.byteLength);
      let offset = 0;

      const len = view.getInt32(offset, true); // Little Endian
      offset += 4;
      if (len !== 64) {
        LoggerAdbKeyManager.warn(`ADB key invalid len word: ${len} (expected 64)`);
        return null;
      }

      const n0inv = view.getUint32(offset, true);
      offset += 4;

      // Read N (256 bytes) - stored as Little Endian words, and Little Endian bytes?
      // Standard ADB key generation implies simple memcpy of the number.
      // Since it's Little Endian, to get Big Endian (ASN.1), we just need to reverse the bytes.
      const nBytes = new Uint8Array(adbKeyBytes.slice(offset, offset + 256));
      nBytes.reverse(); 
      offset += 256;

      // Skip RR (256 bytes)
      offset += 256;

      // Read Exponent (4 bytes, Little Endian)
      const e = view.getUint32(offset, true);
      offset += 4;

      // Create ASN.1 DER structure
      // Sequence
      //   Sequence (Algorithm Identifier)
      //     OID rsaEncryption (1.2.840.113549.1.1.1)
      //     NULL
      //   BitString
      //     Sequence (RSAPublicKey)
      //       Integer n
      //       Integer e
      
      return this.buildX509PublicKey(nBytes, e);

    } catch (e) {
      LoggerAdbKeyManager.error('Convert ADB key to X509 failed:', e);
      return null;
    }
  }

  private buildX509PublicKey(nBytes: Uint8Array, e: number): Uint8Array {
    // Helper to build explicit ASN.1 structure
    // This is a minimal builder specifically for RSA Public Key
    
    // Encode E as byte array (Big Endian)
    // E is usually 65537 (0x010001), 3 bytes
    // Or 3 (0x03), 1 byte
    let eBytes: number[] = [];
    let tempE = e;
    while (tempE > 0) {
      eBytes.unshift(tempE & 0xff);
      tempE >>>= 8;
    }
    if (eBytes.length === 0) eBytes = [0];

    // Build Inner Sequence (RSAPublicKey)
    // Integer N
    // If top bit of N is set, prepend 0x00 to make it positive
    const nPrefix = (nBytes[0] & 0x80) ? [0x00] : [];
    const nEncoded = this.createAsn1Item(0x02, new Uint8Array([...nPrefix, ...nBytes]));
    
    // Integer E
    const eEncoded = this.createAsn1Item(0x02, new Uint8Array(eBytes));
    
    const rsaPublicKeySeq = this.createAsn1Item(0x30, new Uint8Array([...nEncoded, ...eEncoded]));

    // Build Algorithm Identifier
    // OID: 1.2.840.113549.1.1.1 (rsaEncryption) -> 06 09 2a 86 48 86 f7 0d 01 01 01
    const oid = new Uint8Array([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01]);
    const nullParam = new Uint8Array([0x05, 0x00]);
    const algoId = this.createAsn1Item(0x30, new Uint8Array([...oid, ...nullParam]));

    // Build BitString
    // Prepend 0x00 (unused bits count) to rsaPublicKeySeq
    const bitStringData = new Uint8Array([0x00, ...rsaPublicKeySeq]);
    const bitString = this.createAsn1Item(0x03, bitStringData);

    // Outer Sequence
    const x509 = this.createAsn1Item(0x30, new Uint8Array([...algoId, ...bitString]));
    
    return x509;
  }

  private createAsn1Item(tag: number, content: Uint8Array): Uint8Array {
    const len = content.length;
    let lenBytes: number[];
    if (len < 128) {
      lenBytes = [len];
    } else if (len < 256) {
      lenBytes = [0x81, len];
    } else if (len < 65536) {
      lenBytes = [0x82, (len >>> 8) & 0xff, len & 0xff];
    } else {
      // 2048 keys won't exceed this
      lenBytes = [0x82, (len >>> 8) & 0xff, len & 0xff]; 
    }
    
    return new Uint8Array([tag, ...lenBytes, ...content]);
  }

}
