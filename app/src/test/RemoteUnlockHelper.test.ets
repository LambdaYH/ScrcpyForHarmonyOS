import { describe, expect, it } from '@ohos/hypium';
import {
  applyRemoteDisplayRotation,
  buildRemoteInputTextCommand,
  parseRemoteDisplayRotation,
  parseRemoteLockState,
  quoteRemoteShellArg,
  RemoteDisplaySize,
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

    it('rejectsConflictingCurrentAndHistoricalFragments', 0, () => {
      const output = 'isKeyguardShowing=false\nmShowingLockscreen=true';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('doesNotInjectWhenKeyguardIsOccluded', 0, () => {
      const output = 'mKeyguardShowing=true\nmKeyguardOccluded=true';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('parsesZtePolicyWithoutTreatingNotOccludedAsOccluded', 0, () => {
      const locked = 'mKeyguardOccluded=false\nshowingAndNotOccluded=true\nmIsShowing=true';
      // ZTE keeps showingAndNotOccluded=true even after Keyguard disappears.
      // mIsShowing is the authoritative current state on this device.
      const unlocked = 'mKeyguardOccluded=false\nshowingAndNotOccluded=true\nmIsShowing=false';
      expect(parseRemoteLockState(locked)).assertEqual(RemoteLockState.LOCKED);
      expect(parseRemoteLockState(unlocked)).assertEqual(RemoteLockState.UNLOCKED);
    });

    it('parsesDisplayRotationVariants', 0, () => {
      expect(parseRemoteDisplayRotation('SurfaceOrientation: 1')).assertEqual(1);
      expect(parseRemoteDisplayRotation('Viewport INTERNAL: displayId=0, orientation=3, logicalFrame=[0, 0, 2400, 1080]'))
        .assertEqual(3);
      expect(parseRemoteDisplayRotation('mCurrentRotation=ROTATION_180')).assertEqual(2);
    });

    it('appliesQuarterTurnToDisplaySize', 0, () => {
      const portrait: RemoteDisplaySize = { width: 1080, height: 2400 };
      expect(applyRemoteDisplayRotation(portrait, 0).width).assertEqual(1080);
      expect(applyRemoteDisplayRotation(portrait, 0).height).assertEqual(2400);
      expect(applyRemoteDisplayRotation(portrait, 1).width).assertEqual(2400);
      expect(applyRemoteDisplayRotation(portrait, 1).height).assertEqual(1080);
      expect(applyRemoteDisplayRotation(portrait, 3).width).assertEqual(2400);
      expect(applyRemoteDisplayRotation(portrait, 3).height).assertEqual(1080);
    });

    it('buildsQuotedInputCommand', 0, () => {
      expect(quoteRemoteShellArg('7783')).assertEqual("'7783'");
      expect(buildRemoteInputTextCommand('77 83')).assertEqual("input text '77%s83'");
    });
  });
}
