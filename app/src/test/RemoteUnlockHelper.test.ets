import { describe, expect, it } from '@ohos/hypium';
import {
  applyRemoteDisplayRotation,
  buildRemoteInputTextCommand,
  parseRemoteLockInputTarget,
  parseRemoteDisplayRotation,
  parseRemoteLockState,
  parseRemotePowerLockState,
  parseRemoteTrustLockState,
  quoteRemoteShellArg,
  resolvePostCredentialLockState,
  RemoteDisplaySize,
  RemoteLockInputTargetState,
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

    it('prefersLockedWhenFragmentsConflict', 0, () => {
      const output = 'isKeyguardShowing=false\nmShowingLockscreen=true';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.LOCKED);
    });

    it('doesNotTreatInactiveDreamingAsUnlocked', 0, () => {
      const locked = 'mKeyguardShowing=true\nmDreamingLockscreen=false';
      expect(parseRemoteLockState(locked)).assertEqual(RemoteLockState.LOCKED);
      expect(parseRemoteLockState('mDreamingLockscreen=false')).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('prefersLockedDreamingSignalWhenFragmentsConflict', 0, () => {
      const output = 'mKeyguardShowing=false\nmDreamingLockscreen=true';
      expect(parseRemoteLockState(output)).assertEqual(RemoteLockState.LOCKED);
    });

    it('parsesAndroidKeyguardServiceDelegateState', 0, () => {
      const locked = 'KeyguardServiceDelegate\n  showing=true\n  showingAndNotOccluded=true\n  occluded=false';
      const unlocked = 'KeyguardServiceDelegate\n  showing=false\n  showingAndNotOccluded=false\n  occluded=false';
      const occluded = 'KeyguardServiceDelegate\n  showing=true\n  occluded=true';
      expect(parseRemoteLockState(locked)).assertEqual(RemoteLockState.LOCKED);
      expect(parseRemoteLockState(unlocked)).assertEqual(RemoteLockState.UNLOCKED);
      expect(parseRemoteLockState(occluded)).assertEqual(RemoteLockState.UNKNOWN);
      expect(parseRemoteLockState('SomeComponent: showing=true')).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('parsesAndroidAndVendorNumericLockFields', 0, () => {
      expect(parseRemoteLockState('isKeyguardLocked=1')).assertEqual(RemoteLockState.LOCKED);
      expect(parseRemoteLockState('isKeyguardLocked=0')).assertEqual(RemoteLockState.UNLOCKED);
      expect(parseRemoteLockState('mAodShowing=1')).assertEqual(RemoteLockState.LOCKED);
    });

    it('parsesCurrentUserTrustState', 0, () => {
      const locked = 'User "Owner" (id=0) (current): trusted=0, deviceLocked=1';
      const unlocked = 'User "Owner" (id=0) (current): trusted=1, deviceLocked=0';
      const currentUnlockedWithLockedProfile = `${unlocked}\nUser "Work" (id=10): deviceLocked=1`;
      expect(parseRemoteTrustLockState(locked)).assertEqual(RemoteLockState.LOCKED);
      expect(parseRemoteTrustLockState(unlocked)).assertEqual(RemoteLockState.UNLOCKED);
      expect(parseRemoteTrustLockState(currentUnlockedWithLockedProfile)).assertEqual(RemoteLockState.UNLOCKED);
    });

    it('doesNotAcceptBooleanValuePrefixes', 0, () => {
      expect(parseRemoteTrustLockState('User (current): deviceLocked=10')).assertEqual(RemoteLockState.UNKNOWN);
      expect(parseRemoteLockState('isKeyguardLocked=falsePositive')).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('treatsSleepingOrDozingDisplayAsLockedEvidence', 0, () => {
      expect(parseRemotePowerLockState('mWakefulness=Asleep\nmInteractive=false'))
        .assertEqual(RemoteLockState.LOCKED);
      expect(parseRemotePowerLockState('mWakefulness=Dozing\nmInteractive=true'))
        .assertEqual(RemoteLockState.LOCKED);
      expect(parseRemotePowerLockState('mWakefulness=Awake\nmInteractive=true'))
        .assertEqual(RemoteLockState.UNKNOWN);
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

    it('usesPostCredentialFocusTransitionAsUnlockEvidence', 0, () => {
      expect(resolvePostCredentialLockState(RemoteLockState.LOCKED, RemoteLockInputTargetState.OTHER))
        .assertEqual(RemoteLockState.UNLOCKED);
      expect(resolvePostCredentialLockState(RemoteLockState.UNKNOWN, RemoteLockInputTargetState.OTHER))
        .assertEqual(RemoteLockState.UNLOCKED);
      expect(resolvePostCredentialLockState(RemoteLockState.LOCKED, RemoteLockInputTargetState.KEYGUARD))
        .assertEqual(RemoteLockState.LOCKED);
      expect(resolvePostCredentialLockState(RemoteLockState.UNKNOWN, RemoteLockInputTargetState.UNKNOWN))
        .assertEqual(RemoteLockState.UNKNOWN);
    });

    it('doesNotUseGenericVendorFieldInActivityOutput', 0, () => {
      expect(parseRemoteLockState('mIsShowing=true', false)).assertEqual(RemoteLockState.UNKNOWN);
    });

    it('doesNotUseGenericVendorFieldWithoutKeyguardContext', 0, () => {
      expect(parseRemoteLockState('SomePolicyController: mIsShowing=true')).assertEqual(RemoteLockState.UNKNOWN);
      expect(parseRemoteLockState('SomePolicyController: mIsShowing=false')).assertEqual(RemoteLockState.UNKNOWN);
      expect(parseRemoteLockState('showingAndNotOccluded=true\nSomePolicyController: mIsShowing=true'))
        .assertEqual(RemoteLockState.UNKNOWN);
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
