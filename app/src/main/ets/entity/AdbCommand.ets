// ADB 指令面板相关的数据模型

// 快捷 ADB 命令（全局通用，不绑定设备）
export interface QuickAdbCommand {
  id: string;
  name: string;
  command: string;
  confirmBeforeRun: boolean;
  timeoutSeconds: number;
  createdAt: number;
  updatedAt: number;
}

// 新建/编辑快捷命令时提交的草稿
export interface QuickAdbCommandDraft {
  name: string;
  command: string;
  confirmBeforeRun: boolean;
  timeoutSeconds: number;
}

// 一次 ADB shell 命令的执行结果
export interface AdbExecOutcome {
  ok: boolean;
  exitCode: number;
  exitCodeReliable: boolean;
  stdout: string;
  stderr: string;
  elapsedMs: number;
  timedOut: boolean;
  errorMessage: string;
}

export function createEmptyAdbExecOutcome(): AdbExecOutcome {
  const outcome: AdbExecOutcome = {
    ok: false,
    exitCode: -1,
    exitCodeReliable: false,
    stdout: '',
    stderr: '',
    elapsedMs: 0,
    timedOut: false,
    errorMessage: ''
  };
  return outcome;
}
