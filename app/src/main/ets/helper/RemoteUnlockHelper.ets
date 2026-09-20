import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { LoggerClientStream } from './Logger';
import { ServerManager } from './ServerManager';

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

export interface RemoteDeviceLockState {
  interactive: boolean;
  deviceLocked: boolean;
  keyguardShowing: boolean;
  sdk: number;
}

const REMOTE_LOCK_STATE_OUTPUT_PREFIX: string = 'SCRCPY_HMOS_LOCK_STATE_V1';

function parseRemoteBooleanFlag(value: string): boolean | undefined {
  if (value === '1') {
    return true;
  }
  if (value === '0') {
    return false;
  }
  return undefined;
}

export function parseRemoteDeviceLockState(output: string): RemoteDeviceLockState | undefined {
  const lines: string[] = output.split('\n');
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex].trim();
    if (!line.startsWith(REMOTE_LOCK_STATE_OUTPUT_PREFIX)) {
      continue;
    }

    let interactive: boolean | undefined = undefined;
    let deviceLocked: boolean | undefined = undefined;
    let keyguardShowing: boolean | undefined = undefined;
    let sdk: number | undefined = undefined;
    const tokens: string[] = line.split(' ');
    for (let tokenIndex = 1; tokenIndex < tokens.length; tokenIndex++) {
      const token = tokens[tokenIndex].trim();
      const separatorIndex = token.indexOf('=');
      if (separatorIndex <= 0 || separatorIndex >= token.length - 1) {
        continue;
      }
      const key = token.substring(0, separatorIndex);
      const value = token.substring(separatorIndex + 1);
      if (key === 'interactive') {
        interactive = parseRemoteBooleanFlag(value);
      } else if (key === 'deviceLocked') {
        deviceLocked = parseRemoteBooleanFlag(value);
      } else if (key === 'keyguardShowing') {
        keyguardShowing = parseRemoteBooleanFlag(value);
      } else if (key === 'sdk') {
        const parsedSdk = Number(value);
        if (Number.isInteger(parsedSdk) && parsedSdk >= 23) {
          sdk = parsedSdk;
        }
      }
    }

    if (interactive !== undefined && deviceLocked !== undefined &&
      keyguardShowing !== undefined && sdk !== undefined) {
      return { interactive, deviceLocked, keyguardShowing, sdk };
    }
  }
  return undefined;
}

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

  private static async queryDeviceLockState(
    client: NativeStreamClient,
    shouldContinue?: () => boolean
  ): Promise<RemoteDeviceLockState> {
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const result = await client.execShell(ServerManager.buildRemoteLockStateCommand(client.getAdbId()));
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    if (result.exitCodeReliable && result.exitCode !== 0) {
      throw new Error(`Remote lock state probe exited with code ${result.exitCode}`);
    }
    const state = parseRemoteDeviceLockState(result.stdout);
    if (!state) {
      throw new Error('Remote lock state probe returned invalid output');
    }
    LoggerClientStream.info(
      `[RemoteUnlock] probe interactive=${state.interactive} deviceLocked=${state.deviceLocked} ` +
      `keyguardShowing=${state.keyguardShowing} sdk=${state.sdk}`
    );
    return state;
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

  private static async runUnlock(
    client: NativeStreamClient,
    password: string,
    options?: RemoteUnlockOptions
  ): Promise<RemoteUnlockResult> {
    const shouldContinue = options?.shouldContinue;
    RemoteUnlockHelper.assertCanContinue(shouldContinue);
    const initialProbe = await RemoteUnlockHelper.queryDeviceLockState(client, shouldContinue);
    const initialState = initialProbe.deviceLocked ? RemoteLockState.LOCKED : RemoteLockState.UNLOCKED;
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
    if (!initialProbe.interactive) {
      await client.execShell('input keyevent KEYCODE_WAKEUP');
      await RemoteUnlockHelper.delay(RemoteUnlockHelper.COMMAND_DELAY_MS);
      RemoteUnlockHelper.assertCanContinue(shouldContinue);
    }

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
    const preInputProbe = await RemoteUnlockHelper.queryDeviceLockState(client, shouldContinue);
    const preInputState = preInputProbe.deviceLocked ? RemoteLockState.LOCKED : RemoteLockState.UNLOCKED;
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

    if (!preInputProbe.keyguardShowing) {
      LoggerClientStream.warn('[RemoteUnlock] device is locked but Keyguard is not showing');
      return {
        attempted: true,
        credentialSubmitted: false,
        success: false,
        initialState,
        finalState: RemoteLockState.UNKNOWN
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
    const preEnterProbe = await RemoteUnlockHelper.queryDeviceLockState(client, shouldContinue);
    const preEnterObservedState = preEnterProbe.deviceLocked
      ? RemoteLockState.LOCKED
      : RemoteLockState.UNLOCKED;
    const preEnterTargetState = await RemoteUnlockHelper.queryLockInputTarget(client, shouldContinue);
    const preEnterState = !preEnterProbe.deviceLocked
      ? RemoteLockState.UNLOCKED
      : (preEnterProbe.keyguardShowing && preEnterTargetState === RemoteLockInputTargetState.KEYGUARD
        ? RemoteLockState.LOCKED
        : RemoteLockState.UNKNOWN);
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

    const finalProbe = await RemoteUnlockHelper.queryDeviceLockState(client, shouldContinue);
    const finalObservedState = finalProbe.deviceLocked ? RemoteLockState.LOCKED : RemoteLockState.UNLOCKED;
    const finalTargetState = !finalProbe.deviceLocked
      ? RemoteLockInputTargetState.OTHER
      : await RemoteUnlockHelper.queryLockInputTarget(client, shouldContinue);
    const finalState = !finalProbe.deviceLocked
      ? RemoteLockState.UNLOCKED
      : (finalProbe.keyguardShowing && finalTargetState === RemoteLockInputTargetState.KEYGUARD
        ? RemoteLockState.LOCKED
        : RemoteLockState.UNKNOWN);
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

  private static async removeRemoteLockStateProbe(client: NativeStreamClient): Promise<void> {
    try {
      const remotePath = ServerManager.getRemoteLockStatePath(client.getAdbId());
      const result = await client.execShell(`rm -f ${remotePath}`);
      if (result.exitCodeReliable && result.exitCode !== 0) {
        LoggerClientStream.warn(
          `[RemoteUnlock] remove probe exited with code ${result.exitCode}`
        );
        return;
      }
      LoggerClientStream.info('[RemoteUnlock] remote lock state probe removed');
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      LoggerClientStream.warn('[RemoteUnlock] remove probe failed:', message);
    }
  }

  static async tryUnlock(
    client: NativeStreamClient,
    password: string,
    options?: RemoteUnlockOptions
  ): Promise<RemoteUnlockResult> {
    try {
      return await RemoteUnlockHelper.runUnlock(client, password, options);
    } finally {
      // The probe must remain available for all lock-state checks in one
      // unlock attempt, then it can be removed. Cleanup is best-effort and
      // must never turn a successful remote-control connection into a failure.
      await RemoteUnlockHelper.removeRemoteLockStateProbe(client);
    }
  }
}
