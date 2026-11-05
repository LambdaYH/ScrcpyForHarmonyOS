import { AdbShellCommandResult } from 'libscrcpy_native.so';
import { AdbExecOutcome } from '../entity/AdbCommand';
import { AdbCommandUtils } from './AdbCommandUtils';

export class AdbCommandExecutor {
  static async execute(
    command: string,
    timeoutSeconds: number,
    execShell: (script: string) => Promise<AdbShellCommandResult>
  ): Promise<AdbExecOutcome> {
    const normalized: string = AdbCommandUtils.normalizeCommand(command);
    if (normalized.length === 0) {
      throw new Error('Empty ADB shell command');
    }
    const startedAt: number = Date.now();
    const result: AdbShellCommandResult = await execShell(
      AdbCommandUtils.buildTimedCommand(normalized, timeoutSeconds)
    );
    const timedOut: boolean = result.exitCodeReliable && AdbCommandUtils.isTimeoutExit(result.exitCode);
    const outcome: AdbExecOutcome = {
      ok: result.exitCodeReliable && result.exitCode === 0 && !timedOut,
      exitCode: result.exitCode,
      exitCodeReliable: result.exitCodeReliable,
      stdout: result.stdout,
      stderr: result.stderr,
      elapsedMs: Date.now() - startedAt,
      timedOut: timedOut,
      errorMessage: ''
    };
    return outcome;
  }
}
