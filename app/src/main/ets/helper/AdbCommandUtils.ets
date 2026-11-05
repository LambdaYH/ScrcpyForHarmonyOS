// ADB 指令的工具方法：命令包装、超时判定、危险命令识别、输出截断
// 这些方法保持纯函数，便于单元测试。

export interface TruncatedText {
  text: string;
  truncated: boolean;
}

export class AdbCommandUtils {
  static readonly DEFAULT_TIMEOUT_SECONDS: number = 15;
  static readonly MIN_TIMEOUT_SECONDS: number = 1;
  static readonly MAX_TIMEOUT_SECONDS: number = 3600;
  // 结果卡最多渲染/复制的字符数，避免一次性铺开超大输出
  static readonly MAX_DISPLAY_CHARS: number = 12000;

  // 高风险命令：命中后执行前必须二次确认
  private static readonly DANGER_PATTERNS: string[] = [
    '\\breboot\\b',
    '\\bshutdown\\b',
    '\\bpoweroff\\b',
    '\\bhalt\\b',
    '\\brm\\s+-[a-z]*[rf][a-z]*\\b',
    '\\bpm\\s+clear\\b',
    '\\bpm\\s+uninstall\\b',
    '\\bsettings\\s+put\\b',
    '\\bwm\\s+size\\b(?=\\s+(?:reset\\b|\\d+[xX]\\d+))',
    '\\bwm\\s+density\\b(?=\\s+(?:reset\\b|\\d+\\b))',
    '(^|\\s)su(\\s|$)',
    '\\bdd\\s+if=',
    '\\bmkfs\\b',
    '\\bfastboot\\b',
    '\\bam\\s+force-stop\\b',
    '\\bsvc\\s+(power|data|wifi)\\b',
    '\\binput\\s+keyevent\\s+26\\b'
  ];

  // 用单引号包裹任意 shell 参数，内部的单引号按 POSIX 规则转义
  static shellQuote(value: string): string {
    return `'${value.split("'").join("'\\''")}'`;
  }

  // 用设备侧 toybox timeout 包一层，避免 logcat 之类的命令永久挂起。
  // 监管整个脚本，确保管道、分号和 shell 内置命令也受超时约束。
  static buildTimedCommand(command: string, timeoutSeconds: number): string {
    const seconds: number = AdbCommandUtils.normalizeTimeout(timeoutSeconds);
    return `timeout -s KILL ${seconds} sh -c ${AdbCommandUtils.shellQuote(command)}`;
  }

  static normalizeCommand(command: string): string {
    return command.trim().replace(/^(?:adb\s+)?shell(?:\s+|$)/, '').trim();
  }

  static normalizeTimeout(timeoutSeconds: number): number {
    if (!Number.isFinite(timeoutSeconds)) {
      return AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS;
    }
    const seconds: number = Math.floor(timeoutSeconds);
    if (seconds < AdbCommandUtils.MIN_TIMEOUT_SECONDS) {
      return AdbCommandUtils.MIN_TIMEOUT_SECONDS;
    }
    if (seconds > AdbCommandUtils.MAX_TIMEOUT_SECONDS) {
      return AdbCommandUtils.MAX_TIMEOUT_SECONDS;
    }
    return seconds;
  }

  // toybox/GNU timeout 超时返回 124；被信号杀死时可能得到 137(128+9)
  static isTimeoutExit(exitCode: number): boolean {
    return exitCode === 124 || exitCode === 137;
  }

  // 设备上没有 timeout 命令时（老系统），允许调用方重试裸命令
  static looksLikeMissingTimeout(exitCode: number, stderr: string): boolean {
    if (exitCode !== 127) {
      return false;
    }
    return stderr.toLowerCase().indexOf('timeout') >= 0;
  }

  // 返回命中的危险命令片段，未命中返回空字符串
  static detectDanger(command: string): string {
    const text: string = command.trim();
    if (text.length === 0) {
      return '';
    }
    for (const pattern of AdbCommandUtils.DANGER_PATTERNS) {
      const match: RegExpExecArray | null = new RegExp(pattern, 'i').exec(text);
      if (match !== null) {
        return match[0].trim();
      }
    }
    return '';
  }

  static truncate(text: string, maxChars: number = AdbCommandUtils.MAX_DISPLAY_CHARS): TruncatedText {
    if (text.length <= maxChars) {
      const whole: TruncatedText = { text: text, truncated: false };
      return whole;
    }
    const cut: TruncatedText = { text: text.substring(0, maxChars), truncated: true };
    return cut;
  }
}
