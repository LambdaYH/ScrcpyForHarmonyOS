import { describe, expect, it } from '@ohos/hypium';
import {
  buildRemoteInputTextCommand,
  parseRemoteLockState,
  quoteRemoteShellArg,
  RemoteLockState
} from '../main/ets/helper/RemoteUnlockHelper';

export default function remoteUnlockHelperTest() {
  describe('RemoteUnlockHelper', () => {
    it('detectsLockedKeyguard', 0, () => {
      const output = 'mKeyguardShowing=true\nKeyguardController: mKeyguardGoingAway=false';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.LOCKED);
    });

    it('detectsUnlockedKeyguard', 0, () => {
      const output = 'mKeyguardShowing=false\nisKeyguardShowing=false';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.UNLOCKED);
    });

    it('doesNotGuessUnknownState', 0, () => {
      expect(parseRemoteLockState('mKeyguardGoingAway=false')).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('prefersLockedWhenDumpsysContainsMixedFragments', 0, () => {
      const output = 'isKeyguardShowing=false\nmShowingLockscreen=true';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.LOCKED);
    });

    it('buildsQuotedInputCommand', 0, () => {
      expect(quoteRemoteShellArg('7783')).assertEqual("'7783'");
      expect(buildRemoteInputTextCommand('77 83')).assertEqual("input text '77%s83'");
    });
  });
}
