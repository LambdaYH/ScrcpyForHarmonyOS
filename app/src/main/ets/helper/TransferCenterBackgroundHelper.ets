import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { LoggerAdb } from './Logger';
import { PreferencesHelper } from './PreferencesHelper';

export interface TransferCenterNotificationSummary {
  activeCount: number;
  averageProgress: number;
  deviceName: string;
  fileName: string;
}

interface TransferLiveViewData {
  title?: string;
}

interface TransferLiveViewContent {
  systemLiveView?: TransferLiveViewData;
}

interface TransferLiveViewNotification {
  id?: number;
  content?: TransferLiveViewContent;
}

export class TransferCenterBackgroundHelper {
  private static running: boolean = false;
  private static continuousTaskId?: number;
  private static notificationId?: number;
  private static notificationWantAgent?: WantAgent;
  private static cancelListenerRegistered: boolean = false;
  private static desiredSummary?: TransferCenterNotificationSummary;
  private static desiredRevision: number = 0;
  private static appliedRevision: number = 0;
  private static syncPromise?: Promise<void>;
  private static cancelledCallback?: () => void;
  private static publishTimerId: number = 0;
  private static lastPublishedAt: number = 0;
  private static lastPublishedActiveCount: number = -1;
  private static lastPublishedProgress: number = -1;
  private static publishGeneration: number = 0;
  private static readonly PUBLISH_INTERVAL_MS: number = 3000;
  private static readonly PROGRESS_DELTA: number = 2;

  private static readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (TransferCenterBackgroundHelper.continuousTaskId === undefined ||
        info.id !== TransferCenterBackgroundHelper.continuousTaskId) {
        return;
      }
      const notificationId = TransferCenterBackgroundHelper.notificationId;
      TransferCenterBackgroundHelper.clearRunningState();
      void TransferCenterBackgroundHelper.cancelNotification(notificationId);
      void PreferencesHelper.getInstance().clearTransferBackgroundIds();
      LoggerAdb.warn(
        `[TransferCenter] continuous task cancelled by system, reason=${info.reason}, id=${info.id}`
      );
      TransferCenterBackgroundHelper.cancelledCallback?.();
    };

  static setCancelledCallback(callback: () => void): void {
    TransferCenterBackgroundHelper.cancelledCallback = callback;
  }

  static sync(
    context: common.UIAbilityContext,
    summary?: TransferCenterNotificationSummary
  ): Promise<void> {
    TransferCenterBackgroundHelper.desiredSummary = summary;
    TransferCenterBackgroundHelper.desiredRevision++;
    if (!TransferCenterBackgroundHelper.syncPromise) {
      TransferCenterBackgroundHelper.syncPromise = TransferCenterBackgroundHelper.drain(context).finally(() => {
        TransferCenterBackgroundHelper.syncPromise = undefined;
      });
    }
    return TransferCenterBackgroundHelper.syncPromise;
  }

  /** Stops the transfer continuous task when the ability is being destroyed. */
  static shutdown(context: common.UIAbilityContext): Promise<void> {
    TransferCenterBackgroundHelper.desiredSummary = undefined;
    TransferCenterBackgroundHelper.desiredRevision++;
    if (!TransferCenterBackgroundHelper.syncPromise) {
      TransferCenterBackgroundHelper.syncPromise = TransferCenterBackgroundHelper.stopInternal(context).finally(() => {
        TransferCenterBackgroundHelper.syncPromise = undefined;
      });
    }
    return TransferCenterBackgroundHelper.syncPromise;
  }

  /**
   * Removes transfer-center live views left behind by a previous process.
   * A continuous-task notification can outlive the UIAbility, while the in-memory
   * task registry is recreated empty on the next launch.
   */
  static async clearStaleNotifications(context: common.UIAbilityContext): Promise<void> {
    const persisted = await PreferencesHelper.getInstance().getTransferBackgroundIds();
    if (persisted.continuousTaskId !== undefined) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(context, persisted.continuousTaskId);
      } catch (error) {
        // 9800005 means the task is already gone (for example after a process kill).
        if (TransferCenterBackgroundHelper.getErrorCode(error) !== 9800005) {
          LoggerAdb.warn('[TransferCenter] persisted task cleanup failed:', String(error));
        }
      }
    }
    await TransferCenterBackgroundHelper.cancelNotification(persisted.notificationId);
    await PreferencesHelper.getInstance().clearTransferBackgroundIds();
    try {
      const titlePrefix = `${TransferCenterBackgroundHelper.getString(context, 'transfer_center', 'Transfer Center')} ·`;
      const notifications = await notificationManager.getActiveNotifications();
      for (const request of notifications) {
        const liveViewNotification = request as TransferLiveViewNotification;
        const title = liveViewNotification.content?.systemLiveView?.title;
        if (liveViewNotification.id !== undefined && title !== undefined && title.startsWith(titlePrefix)) {
          await TransferCenterBackgroundHelper.cancelNotification(liveViewNotification.id);
        }
      }
    } catch (error) {
      LoggerAdb.warn('[TransferCenter] stale notification cleanup failed:', String(error));
    }
  }

  private static async drain(context: common.UIAbilityContext): Promise<void> {
    while (TransferCenterBackgroundHelper.appliedRevision < TransferCenterBackgroundHelper.desiredRevision) {
      const revision = TransferCenterBackgroundHelper.desiredRevision;
      const summary = TransferCenterBackgroundHelper.desiredSummary;
      if (!summary || summary.activeCount <= 0) {
        await TransferCenterBackgroundHelper.stopInternal(context);
      } else {
        await TransferCenterBackgroundHelper.ensureStarted(context);
        // A terminal update may have arrived while the task was being started.
        // Never publish a stale summary after the desired state has changed.
        if (revision === TransferCenterBackgroundHelper.desiredRevision &&
          TransferCenterBackgroundHelper.desiredSummary !== undefined) {
          await TransferCenterBackgroundHelper.publishSummary(context, summary);
        }
      }
      TransferCenterBackgroundHelper.appliedRevision = revision;
    }
  }

  private static async ensureStarted(context: common.UIAbilityContext): Promise<void> {
    if (TransferCenterBackgroundHelper.running) return;
    try {
      TransferCenterBackgroundHelper.ensureCancelListener();
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.lambdayh.scrcpyHmos',
          abilityName: 'ScrcpyHmosAbility',
          parameters: {
            openTransferCenter: true
          }
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1003,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [
        backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION
      ];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      const notification = await backgroundTaskManager.startBackgroundRunning(context, request);
      TransferCenterBackgroundHelper.running = true;
      TransferCenterBackgroundHelper.continuousTaskId = notification.continuousTaskId;
      TransferCenterBackgroundHelper.notificationId = notification.notificationId;
      TransferCenterBackgroundHelper.notificationWantAgent = agent;
      if (notification.continuousTaskId !== undefined && notification.notificationId !== undefined) {
        await PreferencesHelper.getInstance().saveTransferBackgroundIds(
          notification.continuousTaskId,
          notification.notificationId
        );
      }
      LoggerAdb.info(
        `[TransferCenter] continuous task started, id=${notification.continuousTaskId}, notification=${notification.notificationId}`
      );
    } catch (error) {
      TransferCenterBackgroundHelper.clearRunningState();
      LoggerAdb.error('[TransferCenter] start failed:', String(error));
    }
  }

  private static async stopInternal(context: common.UIAbilityContext): Promise<void> {
    const continuousTaskId = TransferCenterBackgroundHelper.continuousTaskId;
    const notificationId = TransferCenterBackgroundHelper.notificationId;
    if (!TransferCenterBackgroundHelper.running && notificationId === undefined) return;
    TransferCenterBackgroundHelper.cancelPendingPublish();
    let taskStopped = continuousTaskId === undefined;
    try {
      if (continuousTaskId !== undefined) {
        await backgroundTaskManager.stopBackgroundRunning(context, continuousTaskId);
        LoggerAdb.info(`[TransferCenter] continuous task stopped, id=${continuousTaskId}`);
      }
      taskStopped = true;
    } catch (error) {
      if (TransferCenterBackgroundHelper.getErrorCode(error) === 9800005) {
        taskStopped = true;
      } else {
        LoggerAdb.warn('[TransferCenter] stop failed:', String(error));
      }
    }
    const notificationStopped = await TransferCenterBackgroundHelper.cancelNotification(notificationId);
    if (!taskStopped || !notificationStopped) {
      // Keep the identifiers so a later sync or next launch can retry cleanup.
      TransferCenterBackgroundHelper.scheduleStopRetry(context);
      return;
    }
    TransferCenterBackgroundHelper.clearRunningState();
    TransferCenterBackgroundHelper.lastPublishedAt = 0;
    TransferCenterBackgroundHelper.lastPublishedActiveCount = -1;
    TransferCenterBackgroundHelper.lastPublishedProgress = -1;
    await PreferencesHelper.getInstance().clearTransferBackgroundIds();
  }

  private static async publishSummary(
    context: common.UIAbilityContext,
    summary: TransferCenterNotificationSummary
  ): Promise<void> {
    if (!TransferCenterBackgroundHelper.running ||
      TransferCenterBackgroundHelper.notificationId === undefined) {
      return;
    }
    const now = Date.now();
    const progressChanged = Math.abs(summary.averageProgress - TransferCenterBackgroundHelper.lastPublishedProgress)
      >= TransferCenterBackgroundHelper.PROGRESS_DELTA;
    const stateChanged = summary.activeCount !== TransferCenterBackgroundHelper.lastPublishedActiveCount;
    if (!stateChanged && !progressChanged &&
      now - TransferCenterBackgroundHelper.lastPublishedAt < TransferCenterBackgroundHelper.PUBLISH_INTERVAL_MS) {
      TransferCenterBackgroundHelper.scheduleDeferredPublish(context, summary);
      return;
    }
    TransferCenterBackgroundHelper.cancelPendingPublish();
    const title = TransferCenterBackgroundHelper.getString(context, 'transfer_center', 'Transfer Center');
    const activeText = TransferCenterBackgroundHelper.getString(
      context,
      'transfer_center_notification_active',
      'active transfers'
    );
    const clickHint = TransferCenterBackgroundHelper.getString(
      context,
      'transfer_center_notification_click_hint',
      'Tap to view details'
    );
    const notificationTitle = `${title} · ${summary.activeCount} ${activeText}`;
    const itemDetail = summary.activeCount === 1
      ? `${summary.deviceName} · ${summary.fileName}`
      : `${Math.max(0, Math.min(100, Math.round(summary.averageProgress)))}%`;
    const detail = `${clickHint} · ${itemDetail}`;
    try {
      await notificationManager.publish({
        id: TransferCenterBackgroundHelper.notificationId,
        wantAgent: TransferCenterBackgroundHelper.notificationWantAgent,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        template: {
          name: 'downloadTemplate',
          data: {
            title: notificationTitle,
            fileName: detail,
            progressValue: Math.max(0, Math.min(100, Math.round(summary.averageProgress)))
          }
        },
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title: notificationTitle,
            text: detail
          }
        }
      });
      TransferCenterBackgroundHelper.lastPublishedAt = Date.now();
      TransferCenterBackgroundHelper.lastPublishedActiveCount = summary.activeCount;
      TransferCenterBackgroundHelper.lastPublishedProgress = summary.averageProgress;
    } catch (error) {
      LoggerAdb.warn('[TransferCenter] progress publish failed:', String(error));
    }
  }

  private static async cancelNotification(notificationId?: number): Promise<boolean> {
    if (notificationId === undefined) return true;
    try {
      await notificationManager.cancel(notificationId);
      LoggerAdb.info(`[TransferCenter] notification cancelled, id=${notificationId}`);
      return true;
    } catch (error) {
      // The notification may already have been removed by the system or by a tap.
      LoggerAdb.debug('[TransferCenter] notification cancel skipped:', String(error));
      const message = String(error).toLowerCase();
      return TransferCenterBackgroundHelper.getErrorCode(error) === 9800005 ||
        message.includes('notification does not exist') ||
        message.includes('not exist');
    }
  }

  private static scheduleDeferredPublish(
    context: common.UIAbilityContext,
    summary: TransferCenterNotificationSummary
  ): void {
    if (TransferCenterBackgroundHelper.publishTimerId > 0) return;
    const generation = TransferCenterBackgroundHelper.publishGeneration;
    const delay = Math.max(
      100,
      TransferCenterBackgroundHelper.PUBLISH_INTERVAL_MS - (Date.now() - TransferCenterBackgroundHelper.lastPublishedAt)
    );
    TransferCenterBackgroundHelper.publishTimerId = setTimeout((): void => {
      TransferCenterBackgroundHelper.publishTimerId = 0;
      if (generation !== TransferCenterBackgroundHelper.publishGeneration ||
        !TransferCenterBackgroundHelper.running) return;
      // Use the newest desired summary; the captured value may already be stale.
      void TransferCenterBackgroundHelper.sync(context, TransferCenterBackgroundHelper.desiredSummary);
    }, delay);
  }

  private static cancelPendingPublish(): void {
    if (TransferCenterBackgroundHelper.publishTimerId > 0) {
      clearTimeout(TransferCenterBackgroundHelper.publishTimerId);
      TransferCenterBackgroundHelper.publishTimerId = 0;
    }
    TransferCenterBackgroundHelper.publishGeneration++;
  }

  private static scheduleStopRetry(context: common.UIAbilityContext): void {
    if (TransferCenterBackgroundHelper.publishTimerId > 0) return;
    const generation = TransferCenterBackgroundHelper.publishGeneration;
    TransferCenterBackgroundHelper.publishTimerId = setTimeout((): void => {
      TransferCenterBackgroundHelper.publishTimerId = 0;
      if (generation !== TransferCenterBackgroundHelper.publishGeneration ||
        TransferCenterBackgroundHelper.desiredSummary !== undefined) return;
      void TransferCenterBackgroundHelper.sync(context);
    }, 1500);
  }

  private static getString(context: common.UIAbilityContext, name: string, fallback: string): string {
    try {
      return context.resourceManager.getStringByNameSync(name);
    } catch (_err) {
      return fallback;
    }
  }

  private static ensureCancelListener(): void {
    if (TransferCenterBackgroundHelper.cancelListenerRegistered) return;
    try {
      backgroundTaskManager.on('continuousTaskCancel', TransferCenterBackgroundHelper.cancelCallback);
      TransferCenterBackgroundHelper.cancelListenerRegistered = true;
    } catch (error) {
      LoggerAdb.error('[TransferCenter] failed to register cancel listener:', String(error));
    }
  }

  private static clearRunningState(): void {
    TransferCenterBackgroundHelper.running = false;
    TransferCenterBackgroundHelper.continuousTaskId = undefined;
    TransferCenterBackgroundHelper.notificationId = undefined;
    TransferCenterBackgroundHelper.notificationWantAgent = undefined;
    TransferCenterBackgroundHelper.publishGeneration++;
  }

  private static getErrorCode(error: Object): number {
    return (error as BusinessError).code;
  }
}
