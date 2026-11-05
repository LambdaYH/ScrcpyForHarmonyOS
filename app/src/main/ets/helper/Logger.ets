// Logger - Hilog 封装类
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';

const DOMAIN = 0x0001;
const LOG_FILE_NAME = 'app.log';
const BACKUP_LOG_FILE_NAME = 'app.log.bak';
const MAX_LOG_SIZE = 2 * 1024 * 1024; // 2MB

export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3
}

/**
 * Logger 类 - 封装 HarmonyOS Hilog 和文件日志 (Async I/O)
 * 用于替代 console.log/info/warn/error/debug
 */
export class Logger {
  private tag: string;
  private static context: common.UIAbilityContext | null = null;
  private static logQueue: string[] = [];
  private static isWriting: boolean = false;
  private static logFilePath: string = '';
  private static fileLogLevel: LogLevel = LogLevel.INFO;
  private static isFileEnabled: boolean = false; // 默认关闭

  constructor(tag: string) {
    this.tag = tag;
  }

  // ... (init method remains same)

  /**
   * 设置是否启用文件日志
   */
  static setFileLoggingEnabled(enable: boolean) {
    Logger.isFileEnabled = enable;
  }

  /**
   * 获取是否启用文件日志
   */
  static isFileLoggingEnabled(): boolean {
    return Logger.isFileEnabled;
  }

  /**
   * 初始化文件日志 (Async)
   * @param context 应用上下文
   */
  static async init(context: common.UIAbilityContext): Promise<void> {
    Logger.context = context;
    const filesDir = context.filesDir;
    Logger.logFilePath = `${filesDir}/${LOG_FILE_NAME}`;
    const backupPath = `${filesDir}/${BACKUP_LOG_FILE_NAME}`;

    try {
      // 检查文件是否存在
      const exists = await fileIo.access(Logger.logFilePath);
      if (exists) {
        const stat = await fileIo.stat(Logger.logFilePath);
        // 如果日志文件超过最大限制
        if (stat.size > MAX_LOG_SIZE) {
          // 备份当期日志（覆盖旧备份）
          try {
            await fileIo.copyFile(Logger.logFilePath, backupPath);
          } catch (e) {
            console.error('Backup log file failed:', e);
          }

          // 删除原文件以重新创建
          try {
            await fileIo.unlink(Logger.logFilePath);
          } catch (e) {
            console.error('Unlink log file failed:', e);
          }
        }
      }
      
      // 尝试创建/打开文件一次以确保权限和路径正常，但不需要保持打开的fd
      // 我们在写入时使用 append 模式更安全（虽然效率稍低，但对于日志来说可以接受，且避免了fd泄露风险）
      // 或者，为了性能，我们可以在 processQueue 中打开一次，处理完一批再关闭，或者长期保持。
      // 这里采用: processQueue 负责打开和关闭，或者保持开启。
      // 为了简单和稳健，我们在 processQueue 中处理。

    } catch (e) {
      console.error('Init logger file failed:', e);
    }
  }

  /**
   * 设置文件日志写入级别
   */
  static setLogLevel(level: LogLevel) {
    Logger.fileLogLevel = level;
  }

  /**
   * 获取当前文件日志写入级别
   */
  static getLogLevel(): LogLevel {
    return Logger.fileLogLevel;
  }

  /**
   * 获取日志内容（包含备份和当前日志）
   */
  static async getLogContent(): Promise<string> {
    if (!Logger.context) return '';
    const filesDir = Logger.context.filesDir;
    const logPath = `${filesDir}/${LOG_FILE_NAME}`;
    const backupPath = `${filesDir}/${BACKUP_LOG_FILE_NAME}`;
    let content = '';

    try {
      // 读取备份日志
      const backupExists = await fileIo.access(backupPath);
      if (backupExists) {
        content += await fileIo.readText(backupPath);
        content += '\n--- Rotation ---\n';
      }
      
      // 读取当前日志
      const logExists = await fileIo.access(logPath);
      if (logExists) {
        content += await fileIo.readText(logPath);
      }
    } catch (e) {
      console.error('Read log content failed:', e);
    }

    return content;
  }

  /**
   * 清空日志
   */
  static async clearLogs(): Promise<void> {
    if (!Logger.context) return;
    const filesDir = Logger.context.filesDir;
    const logPath = `${filesDir}/${LOG_FILE_NAME}`;
    const backupPath = `${filesDir}/${BACKUP_LOG_FILE_NAME}`;

    try {
      const backupExists = await fileIo.access(backupPath);
      if (backupExists) await fileIo.unlink(backupPath);
      
      const logExists = await fileIo.access(logPath);
      if (logExists) await fileIo.unlink(logPath);

      // 重新初始化
      await Logger.init(Logger.context);
    } catch (e) {
      console.error('Clear logs failed:', e);
    }
  }

  /**
   * 写入文件日志 (加入队列)
   */
  private writeToFile(level: LogLevel, levelName: string, msg: string): void {
    if (!Logger.context) return; // 还没初始化
    if (!Logger.isFileEnabled) return; // 开关未打开
    if (level < Logger.fileLogLevel) return; // 级别控制

    const now = new Date();
    // 简单的时间格式化: 2024-01-23T12:00:00.000
    const timeStr = now.toISOString().replace('Z', '').replace('T', ' ');
    const logLine = `${timeStr} [${levelName}] [${this.tag}] ${msg}\n`;
    
    Logger.logQueue.push(logLine);
    Logger.processQueue();
  }

  /**
   * 处理日志队列 (Async)
   */
  private static async processQueue() {
    if (Logger.isWriting || Logger.logQueue.length === 0) return;

    Logger.isWriting = true;

    try {
      // 取出当前所有待写入的日志，清空队列
      // 这样可以一次性写入，减少IO次数
      const logsToWrite = [...Logger.logQueue];
      Logger.logQueue = []; // 清空

      if (logsToWrite.length === 0) {
        Logger.isWriting = false;
        return;
      }

      const content = logsToWrite.join('');
      
      // 写入文件
      if (Logger.logFilePath) {
        const file = await fileIo.open(Logger.logFilePath, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.APPEND);
        await fileIo.write(file.fd, content);
        await fileIo.close(file.fd);
      }
    } catch (e) {
      console.error('Write log file failed:', e);
      // 失败的日志可能会丢失，防止无限循环错误，暂时不放回队列
    } finally {
      Logger.isWriting = false;
      // 如果在写入过程中有新日志进入，继续处理
      if (Logger.logQueue.length > 0) {
        setTimeout(() => {
           Logger.processQueue(); 
        }, 10);
      }
    }
  }

  /**
   * Debug 级别日志
   */
  debug(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.debug(DOMAIN, this.tag, '%{public}s', formattedMsg);
    this.writeToFile(LogLevel.DEBUG, 'DEBUG', formattedMsg);
  }

  /**
   * Info 级别日志
   */
  info(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.info(DOMAIN, this.tag, '%{public}s', formattedMsg);
    this.writeToFile(LogLevel.INFO, 'INFO', formattedMsg);
  }

  /**
   * Warn 级别日志
   */
  warn(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.warn(DOMAIN, this.tag, '%{public}s', formattedMsg);
    this.writeToFile(LogLevel.WARN, 'WARN', formattedMsg);
  }

  /**
   * Error 级别日志
   */
  error(msg: string, ...args: (string | number | boolean | object | undefined | null)[]): void {
    const formattedMsg = this.formatMessage(msg, args);
    hilog.error(DOMAIN, this.tag, '%{public}s', formattedMsg);
    this.writeToFile(LogLevel.ERROR, 'ERROR', formattedMsg);
  }

  /**
   * 格式化消息，将参数拼接到消息中
   */
  private formatMessage(msg: string, args: (string | number | boolean | object | undefined | null)[]): string {
    if (args.length === 0) {
      return msg;
    }
    const argsStr = args.map(arg => {
      if (arg === null) return 'null';
      if (arg === undefined) return 'undefined';
      if (arg instanceof Error) {
        return arg.stack ? `${arg.message} | ${arg.stack}` : arg.message;
      }
      if (typeof arg === 'object') {
        try {
          return JSON.stringify(arg);
        } catch {
          return String(arg);
        }
      }
      return String(arg);
    }).join(' ');
    return `${msg} ${argsStr}`;
  }
}

// 预定义的 Logger 实例，方便各模块使用
export const LoggerIndex = new Logger('Index');
export const LoggerControlPage = new Logger('ControlPage');
export const LoggerHelpPage = new Logger('HelpPage');
export const LoggerDeviceDetail = new Logger('DeviceDetail');
export const LoggerAdbManage = new Logger('AdbManage');
export const LoggerAdbConsole = new Logger('AdbConsole');
export const LoggerPublicTools = new Logger('PublicTools');
export const LoggerServerManager = new Logger('ServerManager');
export const LoggerAdbKeyManager = new Logger('AdbKeyManager');
export const LoggerPreferences = new Logger('Preferences');
export const LoggerClient = new Logger('Client');
export const LoggerClientStream = new Logger('ClientStream');
export const LoggerAdb = new Logger('Adb');
export const LoggerClientSession = new Logger('ClientSessionManager');
