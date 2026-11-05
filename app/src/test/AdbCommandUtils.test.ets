import { describe, it, expect } from '@ohos/hypium';
import { AdbCommandUtils } from '../main/ets/helper/AdbCommandUtils';

export default function adbCommandUtilsTest() {
  describe('AdbCommandUtils', () => {
    it('quotesShellArguments', 0, () => {
      expect(AdbCommandUtils.shellQuote('pm list packages -3')).assertEqual("'pm list packages -3'");
      const quoted: string = AdbCommandUtils.shellQuote("echo 'hi'");
      expect(quoted.indexOf("'\\''")).assertLarger(-1);
      expect(quoted.startsWith("'")).assertTrue();
      expect(quoted.endsWith("'")).assertTrue();
    });

    it('wrapsCommandsWithTimeout', 0, () => {
      expect(AdbCommandUtils.buildTimedCommand('dumpsys battery', 15))
        .assertEqual("timeout -s KILL 15 sh -c 'dumpsys battery'");
      expect(AdbCommandUtils.buildTimedCommand('wm size', 0))
        .assertEqual("timeout -s KILL 1 sh -c 'wm size'");
      expect(AdbCommandUtils.buildTimedCommand('wm size', 99999))
        .assertEqual("timeout -s KILL 3600 sh -c 'wm size'");
    });

    it('supervisesWholeShellScript', 0, () => {
      const command: string = "printf '%s' 'a b' | cat; echo done";
      expect(AdbCommandUtils.buildTimedCommand(command, 2))
        .assertEqual(`timeout -s KILL 2 sh -c ${AdbCommandUtils.shellQuote(command)}`);
    });

    it('acceptsAdbShellPrefix', 0, () => {
      expect(AdbCommandUtils.normalizeCommand(' adb shell wm size ')).assertEqual('wm size');
      expect(AdbCommandUtils.normalizeCommand('shell dumpsys battery')).assertEqual('dumpsys battery');
      expect(AdbCommandUtils.normalizeCommand('echo shell')).assertEqual('echo shell');
      expect(AdbCommandUtils.normalizeCommand('adb shell')).assertEqual('');
    });

    it('normalizesTimeoutValues', 0, () => {
      expect(AdbCommandUtils.normalizeTimeout(0)).assertEqual(1);
      expect(AdbCommandUtils.normalizeTimeout(-5)).assertEqual(1);
      expect(AdbCommandUtils.normalizeTimeout(42.9)).assertEqual(42);
      expect(AdbCommandUtils.normalizeTimeout(Number.NaN)).assertEqual(AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS);
    });

    it('detectsTimeoutExitCodes', 0, () => {
      expect(AdbCommandUtils.isTimeoutExit(124)).assertTrue();
      expect(AdbCommandUtils.isTimeoutExit(137)).assertTrue();
      expect(AdbCommandUtils.isTimeoutExit(0)).assertFalse();
      expect(AdbCommandUtils.isTimeoutExit(1)).assertFalse();
    });

    it('detectsMissingTimeoutBinary', 0, () => {
      expect(AdbCommandUtils.looksLikeMissingTimeout(127, 'sh: timeout: not found')).assertTrue();
      expect(AdbCommandUtils.looksLikeMissingTimeout(127, '')).assertFalse();
      expect(AdbCommandUtils.looksLikeMissingTimeout(1, 'timeout')).assertFalse();
    });

    it('flagsDangerousCommands', 0, () => {
      expect(AdbCommandUtils.detectDanger('reboot')).assertEqual('reboot');
      expect(AdbCommandUtils.detectDanger('sh -c "rm -rf /data/local/tmp/x"')).assertEqual('rm -rf');
      expect(AdbCommandUtils.detectDanger('pm clear com.example')).assertEqual('pm clear');
      expect(AdbCommandUtils.detectDanger('wm size 1280x720')).assertEqual('wm size');
      expect(AdbCommandUtils.detectDanger('wm size reset')).assertEqual('wm size');
      expect(AdbCommandUtils.detectDanger('wm density 320')).assertEqual('wm density');
      expect(AdbCommandUtils.detectDanger('wm density reset')).assertEqual('wm density');
      expect(AdbCommandUtils.detectDanger('am force-stop com.example')).assertEqual('am force-stop');
      expect(AdbCommandUtils.detectDanger('pm list packages -3')).assertEqual('');
      expect(AdbCommandUtils.detectDanger('settings get system screen_brightness')).assertEqual('');
      expect(AdbCommandUtils.detectDanger('wm size')).assertEqual('');
      expect(AdbCommandUtils.detectDanger('adb shell wm size')).assertEqual('');
      expect(AdbCommandUtils.detectDanger('wm density')).assertEqual('');
    });

    it('truncatesLongOutput', 0, () => {
      expect(AdbCommandUtils.truncate('short', 10).truncated).assertFalse();
      expect(AdbCommandUtils.truncate('short', 10).text).assertEqual('short');
      const cut = AdbCommandUtils.truncate('0123456789abcdef', 10);
      expect(cut.truncated).assertTrue();
      expect(cut.text).assertEqual('0123456789');
    });
  });
}
