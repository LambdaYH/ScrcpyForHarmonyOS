// 快捷 ADB 命令的全局存储（与设备无关，所有远控会话共享）
import preferences from '@ohos.data.preferences';
import { util } from '@kit.ArkTS';
import { QuickAdbCommand, QuickAdbCommandDraft } from '../entity/AdbCommand';
import { AdbCommandUtils } from './AdbCommandUtils';
import { LoggerAdbConsole } from './Logger';

const PREFS_NAME: string = 'adb_console_prefs';
const COMMANDS_KEY: string = 'quick_commands_v1';
const HISTORY_KEY: string = 'command_history_v1';
const MAX_COMMANDS: number = 50;
const MAX_HISTORY: number = 20;

export class QuickAdbCommandStore {
  private static instance?: QuickAdbCommandStore = undefined;
  private prefs?: preferences.Preferences = undefined;
  private commands: QuickAdbCommand[] = [];
  private history: string[] = [];
  private initPromise?: Promise<void> = undefined;
  private mutationQueue: Promise<void> = Promise.resolve();

  static getInstance(): QuickAdbCommandStore {
    if (QuickAdbCommandStore.instance === undefined) {
      QuickAdbCommandStore.instance = new QuickAdbCommandStore();
    }
    return QuickAdbCommandStore.instance;
  }

  async init(context: Context): Promise<void> {
    if (this.isReady()) {
      await this.mutationQueue;
      return;
    }
    if (this.initPromise !== undefined) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.loadFromPreferences(context);
    try {
      await this.initPromise;
    } finally {
      this.initPromise = undefined;
    }
  }

  isReady(): boolean {
    return this.prefs !== undefined;
  }

  getCommands(): QuickAdbCommand[] {
    return this.commands.slice();
  }

  getHistory(): string[] {
    return this.history.slice();
  }

  canAddMore(): boolean {
    return this.commands.length < MAX_COMMANDS;
  }

  async addCommand(draft: QuickAdbCommandDraft): Promise<QuickAdbCommand | undefined> {
    return this.enqueue(async (): Promise<QuickAdbCommand | undefined> => {
      const name: string = draft.name.trim();
      const command: string = draft.command.trim();
      if (name.length === 0 || command.length === 0) {
        return undefined;
      }
      if (this.commands.length >= MAX_COMMANDS) {
        return undefined;
      }
      const now: number = Date.now();
      const item: QuickAdbCommand = {
        id: util.generateRandomUUID(true),
        name: name,
        command: command,
        confirmBeforeRun: draft.confirmBeforeRun,
        timeoutSeconds: AdbCommandUtils.normalizeTimeout(draft.timeoutSeconds),
        createdAt: now,
        updatedAt: now
      };
      await this.persistCommands(this.commands.concat([item]));
      return item;
    });
  }

  async updateCommand(id: string, draft: QuickAdbCommandDraft): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      const name: string = draft.name.trim();
      const command: string = draft.command.trim();
      if (name.length === 0 || command.length === 0) {
        return;
      }
      const index: number = this.commands.findIndex((item: QuickAdbCommand): boolean => item.id === id);
      if (index < 0) {
        return;
      }
      const updated: QuickAdbCommand = {
        id: this.commands[index].id,
        name: name,
        command: command,
        confirmBeforeRun: draft.confirmBeforeRun,
        timeoutSeconds: AdbCommandUtils.normalizeTimeout(draft.timeoutSeconds),
        createdAt: this.commands[index].createdAt,
        updatedAt: Date.now()
      };
      const next: QuickAdbCommand[] = this.commands.slice();
      next[index] = updated;
      await this.persistCommands(next);
    });
  }

  async removeCommand(id: string): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      const next: QuickAdbCommand[] = this.commands.filter((item: QuickAdbCommand): boolean => item.id !== id);
      if (next.length === this.commands.length) {
        return;
      }
      await this.persistCommands(next);
    });
  }

  async moveCommand(fromIndex: number, toIndex: number): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (fromIndex < 0 || fromIndex >= this.commands.length) {
        return;
      }
      if (toIndex < 0 || toIndex >= this.commands.length) {
        return;
      }
      if (fromIndex === toIndex) {
        return;
      }
      const next: QuickAdbCommand[] = this.commands.slice();
      const moved: QuickAdbCommand[] = next.splice(fromIndex, 1);
      if (moved.length === 0) {
        return;
      }
      next.splice(toIndex, 0, moved[0]);
      await this.persistCommands(next);
    });
  }

  async recordHistory(command: string): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      const trimmed: string = command.trim();
      if (trimmed.length === 0) {
        return;
      }
      const next: string[] = [trimmed];
      for (const item of this.history) {
        if (item !== trimmed && next.length < MAX_HISTORY) {
          next.push(item);
        }
      }
      await this.persistHistory(next);
    });
  }

  async clearHistory(): Promise<void> {
    return this.enqueue(async (): Promise<void> => {
      if (this.history.length === 0) {
        return;
      }
      await this.persistHistory([]);
    });
  }

  private enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result: Promise<T> = this.mutationQueue.then(operation);
    this.mutationQueue = result.then((): void => {}, (): void => {});
    return result;
  }

  private async loadFromPreferences(context: Context): Promise<void> {
    try {
      const store: preferences.Preferences = await preferences.getPreferences(context, PREFS_NAME);
      const rawCommands: string = await store.get(COMMANDS_KEY, '[]') as string;
      this.commands = QuickAdbCommandStore.parseCommands(rawCommands);
      const rawHistory: string = await store.get(HISTORY_KEY, '[]') as string;
      this.history = QuickAdbCommandStore.parseHistory(rawHistory);
      this.prefs = store;
      LoggerAdbConsole.info(`Loaded ${this.commands.length} quick commands, ${this.history.length} history items`);
    } catch (err) {
      LoggerAdbConsole.error('Failed to load quick adb commands:', err);
      throw new Error(`${err}`);
    }
  }

  private async persistCommands(next: QuickAdbCommand[]): Promise<void> {
    if (this.prefs === undefined) {
      throw new Error('ADB command store is not ready');
    }
    try {
      await this.prefs.put(COMMANDS_KEY, JSON.stringify(next));
      await this.prefs.flush();
      this.commands = next;
    } catch (err) {
      LoggerAdbConsole.error('Failed to persist quick adb commands:', err);
      throw new Error(`${err}`);
    }
  }

  private async persistHistory(next: string[]): Promise<void> {
    if (this.prefs === undefined) {
      throw new Error('ADB command store is not ready');
    }
    try {
      await this.prefs.put(HISTORY_KEY, JSON.stringify(next));
      await this.prefs.flush();
      this.history = next;
    } catch (err) {
      LoggerAdbConsole.error('Failed to persist adb command history:', err);
      throw new Error(`${err}`);
    }
  }

  private static parseCommands(raw: string): QuickAdbCommand[] {
    let parsed: QuickAdbCommand[] = [];
    try {
      parsed = JSON.parse(raw) as QuickAdbCommand[];
    } catch (err) {
      LoggerAdbConsole.warn('Quick command json is invalid, ignored');
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const result: QuickAdbCommand[] = [];
    for (const item of parsed) {
      if (item === null || item === undefined) {
        continue;
      }
      if (typeof item.id !== 'string' || typeof item.name !== 'string' || typeof item.command !== 'string') {
        continue;
      }
      if (item.id.length === 0 || item.name.length === 0 || item.command.length === 0) {
        continue;
      }
      const createdAt: number = typeof item.createdAt === 'number' ? item.createdAt : Date.now();
      const command: QuickAdbCommand = {
        id: item.id,
        name: item.name,
        command: item.command,
        confirmBeforeRun: item.confirmBeforeRun === true,
        timeoutSeconds: AdbCommandUtils.normalizeTimeout(
          typeof item.timeoutSeconds === 'number' ? item.timeoutSeconds : AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS
        ),
        createdAt: createdAt,
        updatedAt: typeof item.updatedAt === 'number' ? item.updatedAt : createdAt
      };
      result.push(command);
      if (result.length >= MAX_COMMANDS) {
        break;
      }
    }
    return result;
  }

  private static parseHistory(raw: string): string[] {
    let parsed: string[] = [];
    try {
      parsed = JSON.parse(raw) as string[];
    } catch (err) {
      LoggerAdbConsole.warn('Adb command history json is invalid, ignored');
      return [];
    }
    if (!Array.isArray(parsed)) {
      return [];
    }
    const result: string[] = [];
    for (const item of parsed) {
      if (typeof item !== 'string') {
        continue;
      }
      const trimmed: string = item.trim();
      if (trimmed.length === 0 || result.indexOf(trimmed) >= 0) {
        continue;
      }
      result.push(trimmed);
      if (result.length >= MAX_HISTORY) {
        break;
      }
    }
    return result;
  }
}
