import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { LoggerClientStream } from './Logger';

export enum RemoteLockState {
  LOCKED = 'locked',
  UNLOCKED = 'unlocked',
  UNKNOWN = 'unknown'
}

export enum RemoteLockInputTargetState {
  KEYGUARD = 'keyguard',
  OTHER = 'other',
  UNKNOWN = 'unknown'
}

export interface RemoteUnlockResult {
  attempted: boolean;
  credentialSubmitted: boolean;
  success: boolean;
  initialState: RemoteLockState;
  finalState: RemoteLockState;
}

export interface RemoteUnlockOptions {
  onCredentialSubmitted?: () => void;
  onLockedDetected?: () => void;
  shouldContinue?: () => boolean;
}

export const REMOTE_UNLOCK_CANCELLED_ERROR: string = 'Remote unlock cancelled';

export interface RemoteDisplaySize {
  width: number;
  height: number;
}

const BIDIRECTIONAL_LOCK_STATE_FIELDS: string[] = [
  'mKeyguardShowing',
  'isKeyguardShowing',
  'mShowingLockscreen',
  'keyguardShowing',
  'mKeyguardLocked',
  'isKeyguardLocked',
  'keyguardLocked'
];

const VENDOR_KEYGUARD_CONTEXT_FIELDS: string[] = [
  'showingAndNotOccluded'
];

const VENDOR_KEYGUARD_OCCLUSION_CONTEXT_FIELDS: string[] = [
  'mKeyguardOccluded',
  'isKeyguardOccluded',
  'keyguardOccluded'
];

const VENDOR_BIDIRECTIONAL_LOCK_STATE_FIELDS: string[] = [
  'mIsShowing'
];

// A true value is evidence that Keyguard is active, but false only means the
// device is not currently dreaming on the lock screen. It is not evidence
// that Keyguard itself has disappeared.
const LOCKED_ONLY_STATE_FIELDS: string[] = [
  'mDreamingLockscreen',
  'mAodShowing',
  'isStatusBarKeyguard'
];

const KEYGUARD_OCCLUSION_FIELDS: string[] = [
  'mKeyguardOccluded',
  'isKeyguardOccluded',
  'keyguardOccluded'
];

const KEYGUARD_DELEGATE_MARKER: string = 'keyguardservicedelegate';
const KEYGUARD_DELEGATE_STATE_FIELDS: string[] = ['showing'];
const KEYGUARD_DELEGATE_LOCKED_ONLY_FIELDS: string[] = ['showingAndNotOccluded', 'inputRestricted'];
const KEYGUARD_DELEGATE_OCCLUSION_FIELDS: string[] = ['occluded'];
const TRUST_LOCK_STATE_FIELDS: string[] = ['deviceLocked'];
const FOCUSED_WINDOW_FIELDS: string[] = ['mCurrentFocus=', 'mFocusedWindow='];
const KEYGUARD_WINDOW_TOKENS: string[] = [
  'keyguard',
  'lockscreen',
  'lock_screen',
  'systemui',
  // AOSP uses NotificationShade as the focused window title while the
  // Keyguard bouncer is visible. Older and customized builds may expose the
  // same SystemUI surface as StatusBar or Bouncer instead.
  'notificationshade',
  'notification shade',
  'statusbar',
  'status_bar',
  'bouncer'
];

function startsWithBooleanValue(valueText: string, prefix: string): boolean {
  if (!valueText.startsWith(prefix)) {
    return false;
  }
  const next = valueText.charAt(prefix.length);
  return next === '' || !((next >= 'a' && next <= 'z') ||
    (next >= '0' && next <= '9') || next === '_');
}

function containsBooleanField(output: string, fields: string[], expected: boolean): boolean {
  const lines = output.split('\n');
  const expectedValues = expected ? ['true', '1'] : ['false', '0'];
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex].toLowerCase();
    for (let fieldIndex = 0; fieldIndex < fields.length; fieldIndex++) {
      const field = fields[fieldIndex].toLowerCase();
      let searchStart = 0;
      while (searchStart < line.length) {
        const fieldStart = line.indexOf(field, searchStart);
        if (fieldStart < 0) {
          break;
        }

        // Match a field token, not a suffix inside another field. In
        // particular, "showingAndNotOccluded=true" must not be interpreted as
        // the standalone field "Occluded=true".
        const previous = fieldStart > 0 ? line.charAt(fieldStart - 1) : '';
        const hasIdentifierPrefix = (previous >= 'a' && previous <= 'z') ||
          (previous >= '0' && previous <= '9') || previous === '_';
        const valueText = line.substring(fieldStart + field.length).trim();
        if (!hasIdentifierPrefix) {
          for (let valueIndex = 0; valueIndex < expectedValues.length; valueIndex++) {
            const expectedValue = expectedValues[valueIndex];
            if (startsWithBooleanValue(valueText, `=${expectedValue}`) ||
              startsWithBooleanValue(valueText, `= ${expectedValue}`) ||
              startsWithBooleanValue(valueText, `: ${expectedValue}`) ||
              startsWithBooleanValue(valueText, `:${expectedValue}`)) {
              return true;
            }
          }
        }
        searchStart = fieldStart + field.length;
      }
    }
  }
  return false;
}

function extractContextWindow(output: string, marker: string, followingLines: number = 20): string {
  const lines = output.split('\n');
  const lowerMarker = marker.toLowerCase();
  const contextLines: string[] = [];
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    if (!lines[lineIndex].toLowerCase().includes(lowerMarker)) {
      continue;
    }
    const endIndex = Math.min(lines.length, lineIndex + followingLines + 1);
    for (let contextIndex = lineIndex; contextIndex < endIndex; contextIndex++) {
      contextLines.push(lines[contextIndex]);
    }
  }
  return contextLines.join('\n');
}

function parseKeyguardDelegateState(output: string): RemoteLockState {
  const delegateOutput = extractContextWindow(output, KEYGUARD_DELEGATE_MARKER);
  if (!delegateOutput) {
    return RemoteLockState.UNKNOWN;
  }
  if (containsBooleanField(delegateOutput, KEYGUARD_DELEGATE_OCCLUSION_FIELDS, true)) {
    return RemoteLockState.UNKNOWN;
  }
  const locked = containsBooleanField(delegateOutput, KEYGUARD_DELEGATE_STATE_FIELDS, true) ||
    containsBooleanField(delegateOutput, KEYGUARD_DELEGATE_LOCKED_ONLY_FIELDS, true);
  const unlocked = containsBooleanField(delegateOutput, KEYGUARD_DELEGATE_STATE_FIELDS, false);
  if (locked) {
    return RemoteLockState.LOCKED;
  }
  return unlocked ? RemoteLockState.UNLOCKED : RemoteLockState.UNKNOWN;
}

export function parseRemoteTrustLockState(output: string): RemoteLockState {
  const lines = output.split('\n');
  let currentLocked = false;
  let currentUnlocked = false;
  let anyLocked = false;
  let anyUnlocked = false;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex];
    const locked = containsBooleanField(line, TRUST_LOCK_STATE_FIELDS, true);
    const unlocked = containsBooleanField(line, TRUST_LOCK_STATE_FIELDS, false);
    if (!locked && !unlocked) {
      continue;
    }
    const isCurrentUser = line.toLowerCase().includes('(current)');
    currentLocked = currentLocked || (isCurrentUser && locked);
    currentUnlocked = currentUnlocked || (isCurrentUser && unlocked);
    anyLocked = anyLocked || locked;
    anyUnlocked = anyUnlocked || unlocked;
  }
  if (currentLocked) {
    return RemoteLockState.LOCKED;
  }
  if (currentUnlocked) {
    return RemoteLockState.UNLOCKED;
  }
  // Some Android 6/vendor dumps omit the current-user marker. Prefer a
  // positive lock signal when the remaining output conflicts.
  if (anyLocked) {
    return RemoteLockState.LOCKED;
  }
  return anyUnlocked ? RemoteLockState.UNLOCKED : RemoteLockState.UNKNOWN;
}

export function parseRemotePowerLockState(output: string): RemoteLockState {
  const lowerOutput = output.toLowerCase();
  const inactive = containsBooleanField(output, ['mInteractive', 'interactive'], false);
  const sleeping = lowerOutput.includes('mwakefulness=asleep') ||
    lowerOutput.includes('mwakefulnessraw=asleep') ||
    lowerOutput.includes('mwakefulness=dozing') ||
    lowerOutput.includes('mwakefulnessraw=dozing');
  // A sleeping/dozing display needs the same wake-and-reveal sequence even
  // when an OEM omits Keyguard fields from its window-policy dump. Awake is
  // deliberately not treated as unlocked because Keyguard may still show.
  return inactive || sleeping ? RemoteLockState.LOCKED : RemoteLockState.UNKNOWN;
}

export function parseRemoteLockInputTarget(output: string): RemoteLockInputTargetState {
  const lines = output.split('\n');
  let foundKeyguard = false;
  let foundOther = false;
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex].toLowerCase();
    for (let fieldIndex = 0; fieldIndex < FOCUSED_WINDOW_FIELDS.length; fieldIndex++) {
      const marker = FOCUSED_WINDOW_FIELDS[fieldIndex].toLowerCase();
      const markerIndex = line.indexOf(marker);
      if (markerIndex < 0) {
        continue;
      }
      const target = line.substring(markerIndex + marker.length).trim();
      if (!target || target === 'null') {
        continue;
      }
      let isKeyguard = false;
      for (let tokenIndex = 0; tokenIndex < KEYGUARD_WINDOW_TOKENS.length; tokenIndex++) {
        if (target.includes(KEYGUARD_WINDOW_TOKENS[tokenIndex])) {
          isKeyguard = true;
          break;
        }
      }
      foundKeyguard = foundKeyguard || isKeyguard;
      foundOther = foundOther || !isKeyguard;
    }
  }
  // A non-Keyguard focused window always wins. Some vendor dumps retain a
  // stale Keyguard entry while a launcher or assistant already owns input.
  if (foundOther) {
    return RemoteLockInputTargetState.OTHER;
  }
  return foundKeyguard ? RemoteLockInputTargetState.KEYGUARD : RemoteLockInputTargetState.UNKNOWN;
}

export function resolvePostCredentialLockState(
  observedState: RemoteLockState,
  inputTargetState: RemoteLockInputTargetState
): RemoteLockState {
  if (observedState === RemoteLockState.UNLOCKED) {
    return RemoteLockState.UNLOCKED;
  }
  // Some vendors keep KeyguardServiceDelegate showing=true for several
  // seconds after a successful credential. Once a verified Keyguard target
  // hands focus to a normal application, the focus transition is the fresher
  // and more useful unlock signal.
  if (inputTargetState === RemoteLockInputTargetState.OTHER) {
    return RemoteLockState.UNLOCKED;
  }
  if (observedState === RemoteLockState.LOCKED &&
    inputTargetState === RemoteLockInputTargetState.KEYGUARD) {
    return RemoteLockState.LOCKED;
  }
  return RemoteLockState.UNKNOWN;
}

export function parseRemoteLockState(output: string, includeVendorFields: boolean = true): RemoteLockState {
  // A show-when-locked window may keep Keyguard technically showing while
  // receiving all input itself. Never inject a credential in that state.
  if (containsBooleanField(output, KEYGUARD_OCCLUSION_FIELDS, true)) {
    return RemoteLockState.UNKNOWN;
  }
  const delegateState = parseKeyguardDelegateState(output);
  const hasVendorKeyguardContext = includeVendorFields &&
    (containsBooleanField(output, VENDOR_KEYGUARD_CONTEXT_FIELDS, true) ||
      containsBooleanField(output, VENDOR_KEYGUARD_CONTEXT_FIELDS, false)) &&
    (containsBooleanField(output, VENDOR_KEYGUARD_OCCLUSION_CONTEXT_FIELDS, true) ||
      containsBooleanField(output, VENDOR_KEYGUARD_OCCLUSION_CONTEXT_FIELDS, false));
  const hasLockedState = containsBooleanField(output, BIDIRECTIONAL_LOCK_STATE_FIELDS, true) ||
    (hasVendorKeyguardContext && containsBooleanField(output, VENDOR_BIDIRECTIONAL_LOCK_STATE_FIELDS, true));
  const hasUnlockedState = containsBooleanField(output, BIDIRECTIONAL_LOCK_STATE_FIELDS, false) ||
    (hasVendorKeyguardContext && containsBooleanField(output, VENDOR_BIDIRECTIONAL_LOCK_STATE_FIELDS, false));
  const hasLockedOnlyState = containsBooleanField(output, LOCKED_ONLY_STATE_FIELDS, true);
  // Prefer positive lock evidence. dumpsys often contains a mixture of
  // current and cached fragments on customized Android builds.
  if (hasLockedState || hasLockedOnlyState || delegateState === RemoteLockState.LOCKED) {
    return RemoteLockState.LOCKED;
  }
  if (hasUnlockedState || delegateState === RemoteLockState.UNLOCKED) {
    return RemoteLockState.UNLOCKED;
  }
  return RemoteLockState.UNKNOWN;
}

function isRemoteKeyguardOccluded(output: string): boolean {
  return containsBooleanField(output, KEYGUARD_OCCLUSION_FIELDS, true);
}

function parseRotationToken(line: string, marker: string): number | undefined {
  const markerIndex = line.indexOf(marker);
  if (markerIndex < 0) {
    return undefined;
  }

  let tokenText = line.substring(markerIndex + marker.length).trim();
  while (tokenText.startsWith(':') || tokenText.startsWith('=')) {
    tokenText = tokenText.substring(1).trim();
  }

  let token = '';
  for (let index = 0; index < tokenText.length; index++) {
    const char = tokenText.charAt(index);
    const isLetter = char >= 'a' && char <= 'z';
    const isDigit = char >= '0' && char <= '9';
    if (!isLetter && !isDigit && char !== '_') {
      break;
    }
    token += char;
  }

  if (token.startsWith('rotation_')) {
    token = token.substring('rotation_'.length);
  }
  const value = Number(token);
  if (!Number.isFinite(value)) {
    return undefined;
  }
  if (value >= 0 && value <= 3) {
    return value;
  }
  if (value === 90) {
    return 1;
  }
  if (value === 180) {
    return 2;
  }
  if (value === 270) {
    return 3;
  }
  return undefined;
}

export function parseRemoteDisplayRotation(output: string): number | undefined {
  const lines: string[] = output.split('\n');
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index].toLowerCase();
    const surfaceOrientation = parseRotationToken(line, 'surfaceorientation');
    if (surfaceOrientation !== undefined) {
      return surfaceOrientation;
    }
    const currentRotation = parseRotationToken(line, 'mcurrentrotation');
    if (currentRotation !== undefined) {
      return currentRotation;
    }

    const isDisplayLine = line.includes('displayid=0') || line.includes('displayinfo') ||
      line.includes('viewport internal');
    if (!isDisplayLine) {
      continue;
    }
    const orientation = parseRotationToken(line, 'orientation');
    if (orientation !== undefined) {
      return orientation;
    }
    const rotation = parseRotationToken(line, 'rotation');
    if (rotation !== undefined) {
      return rotation;
    }
  }
  return undefined;
}

export function applyRemoteDisplayRotation(size: RemoteDisplaySize, rotation: number): RemoteDisplaySize {
  if (rotation === 1 || rotation === 3) {
    return { width: size.height, height: size.width };
  }
  return size;
}

export function quoteRemoteShellArg(value: string): string {
  return `'${value.split("'").join("'\\''")}'`;
}

export function buildRemoteInputTextCommand(password: string): string {
  // Android's input command uses %s for spaces inside a single text argument.
  const inputText = password.split(' ').join('%s');
  return `input text ${quoteRemoteShellArg(inputText)}`;
}

export class RemoteUnlockHelper {
  private static readonly COMMAND_DELAY_MS: number = 350;
  private static readonly SWIPE_SETTLE_MS: number = 650;
  private static readonly VERIFY_DELAY_MS: number = 1200;

  private static async delay(durationMs: number): Promise<void> {
    await new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, durationMs);
    });
  }

  private static assertCanContinue(shouldContinue?: () => boolean): void {
    if (shouldContinue && !shouldContinue()) {
      throw new Error(REMOTE_UNLOCK_CANCELLED_ERROR);
    }
  }

  private static async queryLockState(
    client: NativeStreamClient,
    shouldContinue?: () => boolean
  ): Promise<RemoteLockState> {
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const policyResult = await client.execShell('dumpsys window policy');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    if (isRemoteKeyguardOccluded(policyResult.stdout)) {
      return RemoteLockState.UNKNOWN;
    }
    const observedStates: RemoteLockState[] = [parseRemoteLockState(policyResult.stdout)];
    if (observedStates[0] === RemoteLockState.LOCKED) {
      return RemoteLockState.LOCKED;
    }

    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const trustResult = await client.execShell('dumpsys trust');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const trustState = parseRemoteTrustLockState(trustResult.stdout);
    observedStates.push(trustState);
    if (trustState === RemoteLockState.LOCKED) {
      return RemoteLockState.LOCKED;
    }

    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const powerResult = await client.execShell('dumpsys power');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const powerState = parseRemotePowerLockState(powerResult.stdout);
    observedStates.push(powerState);
    if (powerState === RemoteLockState.LOCKED) {
      return RemoteLockState.LOCKED;
    }

    if (observedStates[0] === RemoteLockState.UNLOCKED && trustState === RemoteLockState.UNLOCKED) {
      return RemoteLockState.UNLOCKED;
    }

    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const activityResult = await client.execShell('dumpsys activity activities');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    if (isRemoteKeyguardOccluded(activityResult.stdout)) {
      return RemoteLockState.UNKNOWN;
    }
    // mIsShowing is only known to be a Keyguard field in the window-policy
    // output of specific vendors. In activity output it is too generic.
    observedStates.push(parseRemoteLockState(activityResult.stdout, false));
    if (observedStates.includes(RemoteLockState.LOCKED)) {
      return RemoteLockState.LOCKED;
    }
    return observedStates.includes(RemoteLockState.UNLOCKED)
      ? RemoteLockState.UNLOCKED
      : RemoteLockState.UNKNOWN;
  }

  private static async queryDisplayRotation(
    client: NativeStreamClient,
    shouldContinue?: () => boolean
  ): Promise<number> {
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const inputResult = await client.execShell('dumpsys input');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    let rotation = parseRemoteDisplayRotation(inputResult.stdout);
    if (rotation !== undefined) {
      return rotation;
    }

    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const windowResult = await client.execShell('dumpsys window displays');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    rotation = parseRemoteDisplayRotation(windowResult.stdout);
    return rotation ?? 0;
  }

  private static async queryLockInputTarget(
    client: NativeStreamClient,
    shouldContinue?: () => boolean
  ): Promise<RemoteLockInputTargetState> {
    // Window focus may be null for a few frames while Keyguard finishes its
    // transition. Retry only that transient state; never retry past a known
    // non-Keyguard owner because a credential must not reach an app.
    for (let attempt = 0; attempt < 3; attempt++) {
      RemoteUnlockHelper.assertCanContinue(shouldContinue);
      // Full window dump is used deliberately: several Android 6-11 vendor
      // builds ignore the "windows" subcommand and omit mCurrentFocus.
      const result = await client.execShell('dumpsys window');
      RemoteUnlockHelper.assertCanContinue(shouldContinue);
      const state = parseRemoteLockInputTarget(result.stdout);
      if (state !== RemoteLockInputTargetState.UNKNOWN) {
        return state;
      }
      if (attempt < 2) {
        await RemoteUnlockHelper.delay(200);
      }
    }
    return RemoteLockInputTargetState.UNKNOWN;
  }

  private static async queryDisplaySize(
    client: NativeStreamClient,
    shouldContinue?: () => boolean
  ): Promise<RemoteDisplaySize> {
    const fallback: RemoteDisplaySize = { width: 1080, height: 2400 };
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const result = await client.execShell('wm size');
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const lines: string[] = result.stdout.split('\n');
    let parsed: RemoteDisplaySize | undefined = undefined;
    for (let index = 0; index < lines.length; index++) {
      const line: string = lines[index];
      const colonIndex = line.lastIndexOf(':');
      const sizeText = (colonIndex >= 0 ? line.substring(colonIndex + 1) : line).trim();
      const separatorIndex = sizeText.indexOf('x');
      if (separatorIndex <= 0 || separatorIndex >= sizeText.length - 1) {
        continue;
      }
      const width = Number(sizeText.substring(0, separatorIndex).trim());
      const height = Number(sizeText.substring(separatorIndex + 1).trim());
      if (Number.isFinite(width) && Number.isFinite(height) && width > 0 && height > 0) {
        // Keep the last valid value so an override size takes precedence over
        // the physical size when both are present.
        parsed = { width, height };
      }
    }
    const rotation = await RemoteUnlockHelper.queryDisplayRotation(client, shouldContinue);
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const displaySize = applyRemoteDisplayRotation(parsed ?? fallback, rotation);
    LoggerClientStream.info(
      `[RemoteUnlock] display=${displaySize.width}x${displaySize.height} rotation=${rotation}`
    );
    return displaySize;
  }

  static async tryUnlock(
    client: NativeStreamClient,
    password: string,
    options?: RemoteUnlockOptions
  ): Promise<RemoteUnlockResult> {
    const shouldContinue = options?.shouldContinue;
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const initialState = await RemoteUnlockHelper.queryLockState(client, shouldContinue);
    LoggerClientStream.info(`[RemoteUnlock] detected state=${initialState}`);
    if (initialState !== RemoteLockState.LOCKED) {
      return {
        attempted: false,
        credentialSubmitted: false,
        success: initialState === RemoteLockState.UNLOCKED,
        initialState,
        finalState: initialState
      };
    }

    options?.onLockedDetected?.();

    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    await client.execShell('input keyevent KEYCODE_WAKEUP');
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.COMMAND_DELAY_MS);
    RemoteUnlockHelper.assertCanContinue(shouldContinue);

    const displaySize = await RemoteUnlockHelper.queryDisplaySize(client, shouldContinue);
    const centerX = Math.round(displaySize.width * 0.5);
    const startY = Math.round(displaySize.height * 0.82);
    const endY = Math.round(displaySize.height * 0.25);
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    await client.execShell(`input swipe ${centerX} ${startY} ${centerX} ${endY} 300`);
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.SWIPE_SETTLE_MS);
    RemoteUnlockHelper.assertCanContinue(shouldContinue);

    // Waking the screen can trigger face/fingerprint unlock, and an app may
    // also become an occluding show-when-locked window. Re-check immediately
    // before the sensitive command so the credential can only target an
    // active, non-occluded Keyguard.
    const preInputState = await RemoteUnlockHelper.queryLockState(client, shouldContinue);
    LoggerClientStream.info(`[RemoteUnlock] pre-input state=${preInputState}`);
    if (preInputState !== RemoteLockState.LOCKED) {
      return {
        attempted: true,
        credentialSubmitted: false,
        success: preInputState === RemoteLockState.UNLOCKED,
        initialState,
        finalState: preInputState
      };
    }

    const inputTargetState = await RemoteUnlockHelper.queryLockInputTarget(client, shouldContinue);
    LoggerClientStream.info(`[RemoteUnlock] pre-input target=${inputTargetState}`);
    if (inputTargetState !== RemoteLockInputTargetState.KEYGUARD) {
      return {
        attempted: true,
        credentialSubmitted: false,
        success: false,
        initialState,
        finalState: RemoteLockState.UNKNOWN
      };
    }

    // This command contains the configured credential. The sensitive shell
    // path suppresses it from both ArkTS and native ADB logs.
    // Mark the credential as submitted before handing the command to ADB. If
    // the transport fails after accepting it, retrying would risk entering the
    // credential twice on the remote device.
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    options?.onCredentialSubmitted?.();
    await client.execShellSensitive(buildRemoteInputTextCommand(password));
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.COMMAND_DELAY_MS);
    RemoteUnlockHelper.assertCanContinue(shouldContinue);

    // Some lock screens submit a complete PIN immediately. Do not send Enter
    // after Keyguard has disappeared, because it would target the foreground
    // application that becomes active after unlock.
    const preEnterObservedState = await RemoteUnlockHelper.queryLockState(client, shouldContinue);
    const preEnterTargetState = await RemoteUnlockHelper.queryLockInputTarget(client, shouldContinue);
    const preEnterState = resolvePostCredentialLockState(preEnterObservedState, preEnterTargetState);
    LoggerClientStream.info(
      `[RemoteUnlock] pre-enter state=${preEnterObservedState} target=${preEnterTargetState} ` +
      `resolved=${preEnterState}`
    );
    if (preEnterState !== RemoteLockState.LOCKED) {
      return {
        attempted: true,
        credentialSubmitted: true,
        success: preEnterState === RemoteLockState.UNLOCKED,
        initialState,
        finalState: preEnterState
      };
    }

    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    await client.execShell('input keyevent KEYCODE_ENTER');
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.VERIFY_DELAY_MS);
    RemoteUnlockHelper.assertCanContinue(shouldContinue);

    const finalObservedState = await RemoteUnlockHelper.queryLockState(client, shouldContinue);
    const finalTargetState = finalObservedState === RemoteLockState.UNLOCKED
      ? RemoteLockInputTargetState.OTHER
      : await RemoteUnlockHelper.queryLockInputTarget(client, shouldContinue);
    const finalState = resolvePostCredentialLockState(finalObservedState, finalTargetState);
    const success = finalState === RemoteLockState.UNLOCKED;
    LoggerClientStream.info(
      `[RemoteUnlock] attempted=true success=${success} observedState=${finalObservedState} ` +
      `target=${finalTargetState} finalState=${finalState}`
    );
    return {
      attempted: true,
      credentialSubmitted: true,
      success,
      initialState,
      finalState
    };
  }
}
