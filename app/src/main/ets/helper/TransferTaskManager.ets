import { common } from '@kit.AbilityKit';
import { Device } from '../entity/Device';
import { AdbTransferCancellationController } from './AdbTransferService';
import {
  TransferCenterBackgroundHelper,
  TransferCenterNotificationSummary
} from './TransferCenterBackgroundHelper';
import { TransferNotificationHelper } from './TransferNotificationHelper';
import { LoggerAdb } from './Logger';

export const TRANSFER_ACTIVE_COUNT_KEY: string = 'transferCenterActiveCount';
export const TRANSFER_TASK_VERSION_KEY: string = 'transferCenterTaskVersion';
export const TRANSFER_CENTER_OPEN_REQUEST_KEY: string = 'transferCenterOpenRequested';
const TRANSFER_MANAGER_INSTANCE_KEY: string = 'transferCenterManagerInstance';

if (!AppStorage.has(TRANSFER_ACTIVE_COUNT_KEY)) {
  AppStorage.setOrCreate<number>(TRANSFER_ACTIVE_COUNT_KEY, 0);
}
if (!AppStorage.has(TRANSFER_TASK_VERSION_KEY)) {
  AppStorage.setOrCreate<number>(TRANSFER_TASK_VERSION_KEY, 0);
}
if (!AppStorage.has(TRANSFER_CENTER_OPEN_REQUEST_KEY)) {
  AppStorage.setOrCreate<boolean>(TRANSFER_CENTER_OPEN_REQUEST_KEY, false);
}

export enum TransferTaskType {
  SEND = 0,
  PULL = 1,
  INSTALL = 2
}

export enum TransferTaskStatus {
  PREPARING = 0,
  RUNNING = 1,
  COMPLETED = 2,
  FAILED = 3,
  CANCELLED = 4
}

export interface TransferTaskSnapshot {
  id: string;
  type: TransferTaskType;
  deviceName: string;
  deviceAddress: string;
  fileName: string;
  progress: number;
  status: TransferTaskStatus;
  statusText: string;
  createdAt: number;
  updatedAt: number;
}

interface TransferTaskRecord extends TransferTaskSnapshot {
  cancellationController: AdbTransferCancellationController;
}

export interface CreateTransferTaskOptions {
  type: TransferTaskType;
  device: Device;
  fileName: string;
  preparingText: string;
  cancellationController: AdbTransferCancellationController;
}

export class TransferTaskManager {
  static readonly MAX_CONCURRENT_TRANSFERS: number = 8;
  private static instance?: TransferTaskManager;
  private readonly tasks: Map<string, TransferTaskRecord> = new Map<string, TransferTaskRecord>();
  private sequence: number = 0;
  private version: number = 0;
  private lastContext?: common.UIAbilityContext;

  private constructor() {
    TransferCenterBackgroundHelper.setCancelledCallback((): void => {
      void this.cancelAllActive('Transfer notification dismissed');
    });
  }

  static getInstance(): TransferTaskManager {
    const sharedInstance = AppStorage.get<TransferTaskManager>(TRANSFER_MANAGER_INSTANCE_KEY);
    if (sharedInstance) {
      TransferTaskManager.instance = sharedInstance;
      return sharedInstance;
    }
    if (!TransferTaskManager.instance) {
      TransferTaskManager.instance = new TransferTaskManager();
      AppStorage.setOrCreate<TransferTaskManager>(TRANSFER_MANAGER_INSTANCE_KEY, TransferTaskManager.instance);
    }
    return TransferTaskManager.instance;
  }

  static requestTransferCenter(): void {
    AppStorage.setOrCreate<boolean>(TRANSFER_CENTER_OPEN_REQUEST_KEY, true);
  }

  canStartTransfer(): boolean {
    return this.getActiveCount() < TransferTaskManager.MAX_CONCURRENT_TRANSFERS;
  }

  getActiveCount(): number {
    let count = 0;
    this.tasks.forEach((task: TransferTaskRecord): void => {
      if (this.isActive(task.status)) count++;
    });
    return count;
  }

  async createTask(
    context: common.UIAbilityContext,
    options: CreateTransferTaskOptions
  ): Promise<string> {
    if (!this.canStartTransfer()) {
      throw new Error('app.string.transfer_limit_reached');
    }
    this.lastContext = context;
    const now = Date.now();
    const id = `transfer-${now}-${++this.sequence}`;
    const task: TransferTaskRecord = {
      id,
      type: options.type,
      deviceName: options.device.name,
      deviceAddress: `${options.device.address}:${options.device.adbPort}`,
      fileName: options.fileName,
      progress: 0,
      status: TransferTaskStatus.PREPARING,
      statusText: options.preparingText,
      createdAt: now,
      updatedAt: now,
      cancellationController: options.cancellationController
    };
    this.tasks.set(id, task);
    this.publishState();
    await TransferNotificationHelper.prepare(context);
    await this.syncNotification(context);
    return id;
  }

  updateProgress(taskId: string, progress: number, statusText: string): void {
    const task = this.tasks.get(taskId);
    if (!task || !this.isActive(task.status)) return;
    const normalizedProgress = Math.max(0, Math.min(100, Math.round(progress)));
    if (task.progress === normalizedProgress && task.statusText === statusText &&
      task.status === TransferTaskStatus.RUNNING) {
      return;
    }
    task.progress = normalizedProgress;
    task.status = TransferTaskStatus.RUNNING;
    task.statusText = statusText;
    task.updatedAt = Date.now();
    this.publishState();
    this.scheduleNotificationSync();
  }

  async completeTask(taskId: string, statusText: string): Promise<void> {
    const task = this.tasks.get(taskId);
    if (!task || !this.isActive(task.status)) return;
    task.progress = 100;
    task.status = TransferTaskStatus.COMPLETED;
    task.statusText = statusText;
    task.updatedAt = Date.now();
    this.publishState();
    this.cleanupFinishedTasks();
    if (this.lastContext) await this.syncNotification(this.lastContext);
  }

  async failTask(taskId: string, statusText: string): Promise<void> {
    const task = this.tasks.get(taskId);
    if (!task || !this.isActive(task.status)) return;
    task.status = TransferTaskStatus.FAILED;
    task.statusText = statusText;
    task.updatedAt = Date.now();
    this.publishState();
    this.cleanupFinishedTasks();
    if (this.lastContext) await this.syncNotification(this.lastContext);
  }

  async cancelTask(taskId: string, statusText?: string): Promise<void> {
    const task = this.tasks.get(taskId);
    if (!task || !this.isActive(task.status)) return;
    task.status = TransferTaskStatus.CANCELLED;
    task.statusText = statusText ?? 'Cancelled';
    task.updatedAt = Date.now();
    this.publishState();
    try {
      await task.cancellationController.cancel();
    } catch (error) {
      LoggerAdb.warn(`[TransferCenter] cancel task ${taskId} failed:`, String(error));
    }
    this.cleanupFinishedTasks();
    if (this.lastContext) await this.syncNotification(this.lastContext);
  }

  getTasks(): Array<TransferTaskSnapshot> {
    const result: Array<TransferTaskSnapshot> = [];
    this.tasks.forEach((task: TransferTaskRecord): void => {
      result.push({
        id: task.id,
        type: task.type,
        deviceName: task.deviceName,
        deviceAddress: task.deviceAddress,
        fileName: task.fileName,
        progress: task.progress,
        status: task.status,
        statusText: task.statusText,
        createdAt: task.createdAt,
        updatedAt: task.updatedAt
      });
    });
    result.sort((left: TransferTaskSnapshot, right: TransferTaskSnapshot): number => {
      const leftActive = this.isActive(left.status);
      const rightActive = this.isActive(right.status);
      if (leftActive !== rightActive) return leftActive ? -1 : 1;
      return right.createdAt - left.createdAt;
    });
    return result;
  }

  private async cancelAllActive(statusText: string): Promise<void> {
    const activeIds: Array<string> = [];
    this.tasks.forEach((task: TransferTaskRecord, id: string): void => {
      if (this.isActive(task.status)) activeIds.push(id);
    });
    for (const id of activeIds) {
      await this.cancelTask(id, statusText);
    }
  }

  private isActive(status: TransferTaskStatus): boolean {
    return status === TransferTaskStatus.PREPARING || status === TransferTaskStatus.RUNNING;
  }

  private publishState(): void {
    this.version++;
    AppStorage.setOrCreate<number>(TRANSFER_ACTIVE_COUNT_KEY, this.getActiveCount());
    AppStorage.setOrCreate<number>(TRANSFER_TASK_VERSION_KEY, this.version);
  }

  private scheduleNotificationSync(): void {
    if (!this.lastContext) return;
    void this.syncNotification(this.lastContext);
  }

  private async syncNotification(context: common.UIAbilityContext): Promise<void> {
    const activeTasks = this.getTasks().filter((task: TransferTaskSnapshot): boolean => {
      return this.isActive(task.status);
    });
    if (activeTasks.length === 0) {
      await TransferCenterBackgroundHelper.sync(context);
      return;
    }
    let totalProgress = 0;
    activeTasks.forEach((task: TransferTaskSnapshot): void => {
      totalProgress += task.progress;
    });
    const firstTask = activeTasks[0];
    const summary: TransferCenterNotificationSummary = {
      activeCount: activeTasks.length,
      averageProgress: totalProgress / activeTasks.length,
      deviceName: firstTask.deviceName,
      fileName: firstTask.fileName
    };
    await TransferCenterBackgroundHelper.sync(context, summary);
  }

  private cleanupFinishedTasks(): void {
    const finished = this.getTasks().filter((task: TransferTaskSnapshot): boolean => {
      return !this.isActive(task.status);
    });
    if (finished.length <= 40) return;
    finished.slice(40).forEach((task: TransferTaskSnapshot): void => {
      this.tasks.delete(task.id);
    });
  }
}
