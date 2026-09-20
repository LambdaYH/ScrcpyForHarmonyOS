import { describe, expect, it } from '@ohos/hypium';
import {
  applyRemoteDisplayRotation,
  buildRemoteInputTextCommand,
  parseRemoteDeviceLockState,
  parseRemoteLockInputTarget,
  parseRemoteDisplayRotation,
  quoteRemoteShellArg,
  RemoteDisplaySize,
  RemoteLockInputTargetState
} from '../main/ets/helper/RemoteUnlockHelper';

export default function remoteUnlockHelperTest() {
  describe('RemoteUnlockHelper', () => {
    it('parsesOfficialRemoteLockStateProbe', 0, () => {
      const unlocked = parseRemoteDeviceLockState(
        'SCRCPY_HMOS_LOCK_STATE_V1 interactive=1 deviceLocked=0 keyguardShowing=0 sdk=33'
      );
      expect(unlocked?.interactive).assertTrue();
      expect(unlocked?.deviceLocked).assertFalse();
      expect(unlocked?.keyguardShowing).assertFalse();
      expect(unlocked?.sdk).assertEqual(33);

      const locked = parseRemoteDeviceLockState(
        'SCRCPY_HMOS_LOCK_STATE_V1 interactive=0 deviceLocked=1 keyguardShowing=1 sdk=23'
      );
      expect(locked?.interactive).assertFalse();
      expect(locked?.deviceLocked).assertTrue();
      expect(locked?.keyguardShowing).assertTrue();
    });

    it('rejectsIncompleteRemoteLockStateProbe', 0, () => {
      expect(parseRemoteDeviceLockState('SCRCPY_HMOS_LOCK_STATE_V1 deviceLocked=0')).assertUndefined();
      expect(parseRemoteDeviceLockState('unrelated output')).assertUndefined();
    });

    it('requiresKeyguardToOwnWindowFocusBeforeCredentialInput', 0, () => {
      const keyguard = 'mCurrentFocus=Window{42 u0 com.android.systemui/.keyguard.KeyguardViewMediator}';
      const vendorSystemUi = 'mFocusedWindow=Window{43 u0 com.oplus.systemui/.BiometricUnlock}';
      const notificationShade = 'mCurrentFocus=Window{44 u0 NotificationShade}';
      const legacyStatusBar = 'mFocusedWindow=Window{45 u0 StatusBar}';
      const foregroundApp = 'mCurrentFocus=Window{44 u0 com.baidu.searchbox/.MainActivity}';
      const staleConflict = `${keyguard}\n${foregroundApp}`;
      expect(parseRemoteLockInputTarget(keyguard)).assertEqual(RemoteLockInputTargetState.KEYGUARD);
      expect(parseRemoteLockInputTarget(vendorSystemUi)).assertEqual(RemoteLockInputTargetState.KEYGUARD);
      expect(parseRemoteLockInputTarget(notificationShade)).assertEqual(RemoteLockInputTargetState.KEYGUARD);
      expect(parseRemoteLockInputTarget(legacyStatusBar)).assertEqual(RemoteLockInputTargetState.KEYGUARD);
      expect(parseRemoteLockInputTarget(foregroundApp)).assertEqual(RemoteLockInputTargetState.OTHER);
      expect(parseRemoteLockInputTarget(staleConflict)).assertEqual(RemoteLockInputTargetState.OTHER);
      expect(parseRemoteLockInputTarget('mCurrentFocus=null')).assertEqual(RemoteLockInputTargetState.UNKNOWN);
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
