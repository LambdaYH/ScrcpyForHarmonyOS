import { NativeStreamClient } from '../client/tools/NativeStreamClient';
import { LoggerClientStream } from './Logger';

export enum RemoteLockState {
  LOCKED = 'locked',
  UNLOCKED = 'unlocked',
  UNKNOWN = 'unknown'
}

export interface RemoteUnlockResult {
  attempted: boolean;
  success: boolean;
  initialState: RemoteLockState;
  finalState: RemoteLockState;
}

interface RemoteDisplaySize {
  width: number;
  height: number;
}

const LOCK_STATE_FIELDS: string[] = [
  'mKeyguardShowing',
  'isKeyguardShowing',
  'mShowingLockscreen',
  'keyguardShowing',
  'mDreamingLockscreen'
];

function containsBooleanField(output: string, expected: boolean): boolean {
  const lines = output.split('\n');
  const expectedValue = expected ? 'true' : 'false';
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex].toLowerCase();
    for (let fieldIndex = 0; fieldIndex < LOCK_STATE_FIELDS.length; fieldIndex++) {
      const field = LOCK_STATE_FIELDS[fieldIndex].toLowerCase();
      const fieldStart = line.indexOf(field);
      if (fieldStart < 0) {
        continue;
      }
      const valueText = line.substring(fieldStart + field.length).trim();
      if (valueText.startsWith(`=${expectedValue}`) || valueText.startsWith(`: ${expectedValue}`) ||
        valueText.startsWith(`:${expectedValue}`)) {
        return true;
      }
    }
  }
  return false;
}

export function parseRemoteLockState(output: string): RemoteLockState {
  // A positive keyguard field wins if dumpsys contains both current and
  // historical state fragments. This errs on the side of verifying unlock.
  if (containsBooleanField(output, true)) {
    return RemoteLockState.LOCKED;
  }
  if (containsBooleanField(output, false)) {
    return RemoteLockState.UNLOCKED;
  }
  return RemoteLockState.UNKNOWN;
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

  private static async queryLockState(client: NativeStreamClient): Promise<RemoteLockState> {
    const policyResult = await client.execShell('dumpsys window policy');
    let state = parseRemoteLockState(policyResult.stdout);
    if (state !== RemoteLockState.UNKNOWN) {
      return state;
    }

    const activityResult = await client.execShell('dumpsys activity activities');
    state = parseRemoteLockState(activityResult.stdout);
    return state;
  }

  private static async queryDisplaySize(client: NativeStreamClient): Promise<RemoteDisplaySize> {
    const fallback: RemoteDisplaySize = { width: 1080, height: 2400 };
    const result = await client.execShell('wm size');
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
    return parsed ?? fallback;
  }

  static async tryUnlock(client: NativeStreamClient, password: string): Promise<RemoteUnlockResult> {
    const initialState = await RemoteUnlockHelper.queryLockState(client);
    LoggerClientStream.info(`[RemoteUnlock] detected state=${initialState}`);
    if (initialState !== RemoteLockState.LOCKED) {
      return {
        attempted: false,
        success: initialState === RemoteLockState.UNLOCKED,
        initialState,
        finalState: initialState
      };
    }

    await client.execShell('input keyevent KEYCODE_WAKEUP');
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.COMMAND_DELAY_MS);

    const displaySize = await RemoteUnlockHelper.queryDisplaySize(client);
    const centerX = Math.round(displaySize.width * 0.5);
    const startY = Math.round(displaySize.height * 0.82);
    const endY = Math.round(displaySize.height * 0.25);
    await client.execShell(`input swipe ${centerX} ${startY} ${centerX} ${endY} 300`);
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.SWIPE_SETTLE_MS);

    // This command contains the configured credential. The sensitive shell
    // path suppresses it from both ArkTS and native ADB logs.
    await client.execShellSensitive(buildRemoteInputTextCommand(password));
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.COMMAND_DELAY_MS);
    await client.execShell('input keyevent KEYCODE_ENTER');
    await RemoteUnlockHelper.delay(RemoteUnlockHelper.VERIFY_DELAY_MS);

    const finalState = await RemoteUnlockHelper.queryLockState(client);
    const success = finalState === RemoteLockState.UNLOCKED;
    LoggerClientStream.info(`[RemoteUnlock] attempted=true success=${success} finalState=${finalState}`);
    return {
      attempted: true,
      success,
      initialState,
      finalState
    };
  }
}
