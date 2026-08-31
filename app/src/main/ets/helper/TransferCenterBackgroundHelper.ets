import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { LoggerAdb } from './Logger';

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

  private static readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (TransferCenterBackgroundHelper.continuousTaskId === undefined ||
        info.id !== TransferCenterBackgroundHelper.continuousTaskId) {
        return;
      }
      const notificationId = TransferCenterBackgroundHelper.notificationId;
      TransferCenterBackgroundHelper.clearRunningState();
      void TransferCenterBackgroundHelper.cancelNotification(notificationId);
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

  /**
   * Removes transfer-center live views left behind by a previous process.
   * A continuous-task notification can outlive the UIAbility, while the in-memory
   * task registry is recreated empty on the next launch.
   */
  static async clearStaleNotifications(context: common.UIAbilityContext): Promise<void> {
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
        await TransferCenterBackgroundHelper.publishSummary(context, summary);
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
    TransferCenterBackgroundHelper.clearRunningState();
    await TransferCenterBackgroundHelper.cancelNotification(notificationId);
    if (continuousTaskId === undefined) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context, continuousTaskId);
      LoggerAdb.info(`[TransferCenter] continuous task stopped, id=${continuousTaskId}`);
    } catch (error) {
      if (TransferCenterBackgroundHelper.getErrorCode(error) === 9800005) {
        return;
      }
      LoggerAdb.warn('[TransferCenter] stop failed:', String(error));
    }
  }

  private static async publishSummary(
    context: common.UIAbilityContext,
    summary: TransferCenterNotificationSummary
  ): Promise<void> {
    if (!TransferCenterBackgroundHelper.running ||
      TransferCenterBackgroundHelper.notificationId === undefined) {
      return;
    }
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
    } catch (error) {
      LoggerAdb.warn('[TransferCenter] progress publish failed:', String(error));
    }
  }

  private static async cancelNotification(notificationId?: number): Promise<void> {
    if (notificationId === undefined) return;
    try {
      await notificationManager.cancel(notificationId);
      LoggerAdb.info(`[TransferCenter] notification cancelled, id=${notificationId}`);
    } catch (error) {
      // The notification may already have been removed by the system or by a tap.
      LoggerAdb.debug('[TransferCenter] notification cancel skipped:', String(error));
    }
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
  }

  private static getErrorCode(error: Object): number {
    return (error as BusinessError).code;
  }
}
