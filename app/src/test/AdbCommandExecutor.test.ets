import { describe, it, expect } from '@ohos/hypium';
import { AdbShellCommandResult } from 'libscrcpy_native.so';
import { AdbCommandExecutor } from '../main/ets/helper/AdbCommandExecutor';

function shellResult(exitCode: number, reliable: boolean = true): AdbShellCommandResult {
  const result: AdbShellCommandResult = {
    exitCode: exitCode,
    exitCodeReliable: reliable,
    stdout: 'output',
    stderr: exitCode === 0 ? '' : 'failure'
  };
  return result;
}

export default function adbCommandExecutorTest() {
  describe('AdbCommandExecutor', () => {
    it('executesOnceAndPreservesOutput', 0, async () => {
      let calls: number = 0;
      let script: string = '';
      const outcome = await AdbCommandExecutor.execute('adb shell wm size', 3,
        (value: string): Promise<AdbShellCommandResult> => {
          calls++;
          script = value;
          return Promise.resolve(shellResult(0));
        });
      expect(calls).assertEqual(1);
      expect(script).assertEqual("timeout -s KILL 3 sh -c 'wm size'");
      expect(outcome.ok).assertTrue();
      expect(outcome.stdout).assertEqual('output');
      expect(outcome.timedOut).assertFalse();
    });

    it('reportsTimeoutAndStderr', 0, async () => {
      const outcome = await AdbCommandExecutor.execute('sleep 5', 1,
        (): Promise<AdbShellCommandResult> => Promise.resolve(shellResult(137)));
      expect(outcome.ok).assertFalse();
      expect(outcome.timedOut).assertTrue();
      expect(outcome.stderr).assertEqual('failure');
    });

    it('doesNotTreatUnreliableExitAsSuccess', 0, async () => {
      const outcome = await AdbCommandExecutor.execute('echo ok', 1,
        (): Promise<AdbShellCommandResult> => Promise.resolve(shellResult(0, false)));
      expect(outcome.ok).assertFalse();
      expect(outcome.exitCodeReliable).assertFalse();
    });

    it('doesNotRetryFailedCommands', 0, async () => {
      let calls: number = 0;
      let rejected: boolean = false;
      try {
        await AdbCommandExecutor.execute('echo ok', 1, (): Promise<AdbShellCommandResult> => {
          calls++;
          return Promise.reject(new Error('Disconnected'));
        });
      } catch (err) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(calls).assertEqual(1);
    });

    it('rejectsEmptyCommandWithoutSending', 0, async () => {
      let calls: number = 0;
      let rejected: boolean = false;
      try {
        await AdbCommandExecutor.execute('adb shell ', 1, (): Promise<AdbShellCommandResult> => {
          calls++;
          return Promise.resolve(shellResult(0));
        });
      } catch (err) {
        rejected = true;
      }
      expect(rejected).assertTrue();
      expect(calls).assertEqual(0);
    });
  });
}
