import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { LoggerClientSession } from './Logger';

/**
 * Protects the active remote-control connection while the application is in the background.
 * File transfers use a separate continuous task managed by TransferCenterBackgroundHelper.
 */
export class BackgroundKeepAliveHelper {
  private static running: boolean = false;
  private static requested: boolean = false;
  private static transition?: Promise<void>;
  private static cancelListenerRegistered: boolean = false;
  private static continuousTaskId?: number;
  private static notificationId?: number;
  private static notificationWantAgent?: WantAgent;
  /**
   * DATA_TRANSFER continuous tasks must keep their live-view state fresh.  A
   * remote-control session has no file percentage to report, so each heartbeat
   * sends a fresh progress value to keep the live view active. Keep this
   * comfortably below HarmonyOS' ten-minute update deadline.
   */
  private static readonly HEARTBEAT_INTERVAL_MS: number = 5 * 60 * 1000;
  private static heartbeatTimer?: number;
  private static heartbeatPublishing: boolean = false;
  private static lastProgressValue: number = -1;

  private static readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (BackgroundKeepAliveHelper.continuousTaskId === undefined ||
        info.id !== BackgroundKeepAliveHelper.continuousTaskId) {
        return;
      }
      BackgroundKeepAliveHelper.clearRunningState();
      LoggerClientSession.warn(
        `[BackgroundKeepAlive] data transfer task cancelled by system, reason=${info.reason}, id=${info.id}`
      );
    };

  static async start(context: common.UIAbilityContext): Promise<void> {
    BackgroundKeepAliveHelper.requested = true;
    if (BackgroundKeepAliveHelper.running) return;
    if (BackgroundKeepAliveHelper.transition) return BackgroundKeepAliveHelper.transition;
    BackgroundKeepAliveHelper.transition = BackgroundKeepAliveHelper.startInternal(context);
    try {
      await BackgroundKeepAliveHelper.transition;
    } finally {
      BackgroundKeepAliveHelper.transition = undefined;
    }
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    BackgroundKeepAliveHelper.requested = false;
    if (BackgroundKeepAliveHelper.transition) {
      try {
        await BackgroundKeepAliveHelper.transition;
      } catch (_err) {
      }
    }
    if (!BackgroundKeepAliveHelper.running || BackgroundKeepAliveHelper.continuousTaskId === undefined) return;
    const continuousTaskId = BackgroundKeepAliveHelper.continuousTaskId;
    BackgroundKeepAliveHelper.clearRunningState();
    try {
      await backgroundTaskManager.stopBackgroundRunning(context, continuousTaskId);
      LoggerClientSession.info('[BackgroundKeepAlive] remote connection task stopped');
    } catch (error) {
      if (BackgroundKeepAliveHelper.getErrorCode(error) === 9800005) {
        LoggerClientSession.info('[BackgroundKeepAlive] task was already stopped by system');
        return;
      }
      LoggerClientSession.error('[BackgroundKeepAlive] stop failed:', error);
    }
  }

  static isRunning(): boolean {
    return BackgroundKeepAliveHelper.running;
  }

  private static async startInternal(context: common.UIAbilityContext): Promise<void> {
    try {
      BackgroundKeepAliveHelper.ensureCancelListener();
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.lambdayh.scrcpyHmos',
          abilityName: 'ScrcpyHmosAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1002,
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
      if (!BackgroundKeepAliveHelper.requested) {
        await backgroundTaskManager.stopBackgroundRunning(context, notification.continuousTaskId);
        return;
      }
      BackgroundKeepAliveHelper.running = true;
      BackgroundKeepAliveHelper.continuousTaskId = notification.continuousTaskId;
      BackgroundKeepAliveHelper.notificationId = notification.notificationId;
      BackgroundKeepAliveHelper.notificationWantAgent = agent;
      await BackgroundKeepAliveHelper.publishLiveView(
        context,
        notification.notificationId,
        BackgroundKeepAliveHelper.randomProgress()
      );
      BackgroundKeepAliveHelper.startHeartbeat(context, notification.notificationId);
      LoggerClientSession.info(
        `[BackgroundKeepAlive] remote connection task started, id=${notification.continuousTaskId}`
      );
    } catch (error) {
      BackgroundKeepAliveHelper.clearRunningState();
      LoggerClientSession.error('[BackgroundKeepAlive] start failed:', error);
    }
  }

  private static async publishLiveView(
    context: common.UIAbilityContext,
    notificationId: number,
    progressValue: number
  ): Promise<void> {
    const title = BackgroundKeepAliveHelper.getString(
      context,
      'background_keep_alive_notification_title',
      'Remote connection'
    );
    const detail = BackgroundKeepAliveHelper.getString(
      context,
      'background_keep_alive_notification_click_hint',
      'Tap to return to the app'
    );
    try {
      await notificationManager.publish({
        id: notificationId,
        wantAgent: BackgroundKeepAliveHelper.notificationWantAgent,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        template: {
          name: 'downloadTemplate',
          data: {
            title,
            fileName: detail,
            progressValue
          }
        },
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title,
            text: detail
          }
        }
      });
    } catch (error) {
      LoggerClientSession.warn('[BackgroundKeepAlive] live view publish failed:', error);
    }
  }

  private static startHeartbeat(context: common.UIAbilityContext, notificationId: number): void {
    BackgroundKeepAliveHelper.stopHeartbeat();
    BackgroundKeepAliveHelper.heartbeatTimer = setInterval(() => {
      if (!BackgroundKeepAliveHelper.running ||
        BackgroundKeepAliveHelper.notificationId !== notificationId ||
        BackgroundKeepAliveHelper.heartbeatPublishing) {
        return;
      }
      const progressValue = BackgroundKeepAliveHelper.randomProgress();
      LoggerClientSession.info(`[BackgroundKeepAlive] heartbeat progress=${progressValue}`);
      BackgroundKeepAliveHelper.heartbeatPublishing = true;
      void BackgroundKeepAliveHelper.publishLiveView(
        context,
        notificationId,
        progressValue
      )
        .catch((error: Object) => {
          LoggerClientSession.warn('[BackgroundKeepAlive] heartbeat publish failed:', error);
        })
        .finally(() => {
          BackgroundKeepAliveHelper.heartbeatPublishing = false;
        });
    }, BackgroundKeepAliveHelper.HEARTBEAT_INTERVAL_MS);
  }

  private static stopHeartbeat(): void {
    if (BackgroundKeepAliveHelper.heartbeatTimer !== undefined) {
      clearInterval(BackgroundKeepAliveHelper.heartbeatTimer);
      BackgroundKeepAliveHelper.heartbeatTimer = undefined;
    }
    BackgroundKeepAliveHelper.heartbeatPublishing = false;
  }

  private static randomProgress(): number {
    let value = Math.floor(Math.random() * 101);
    if (value === BackgroundKeepAliveHelper.lastProgressValue) {
      value = (value + 1) % 101;
    }
    BackgroundKeepAliveHelper.lastProgressValue = value;
    return value;
  }

  private static getString(context: common.UIAbilityContext, name: string, fallback: string): string {
    try {
      return context.resourceManager.getStringByNameSync(name);
    } catch (_err) {
      return fallback;
    }
  }

  private static ensureCancelListener(): void {
    if (BackgroundKeepAliveHelper.cancelListenerRegistered) return;
    try {
      backgroundTaskManager.on('continuousTaskCancel', BackgroundKeepAliveHelper.cancelCallback);
      BackgroundKeepAliveHelper.cancelListenerRegistered = true;
    } catch (error) {
      LoggerClientSession.error('[BackgroundKeepAlive] failed to register cancel listener:', error);
    }
  }

  private static clearRunningState(): void {
    BackgroundKeepAliveHelper.stopHeartbeat();
    BackgroundKeepAliveHelper.running = false;
    BackgroundKeepAliveHelper.continuousTaskId = undefined;
    BackgroundKeepAliveHelper.notificationId = undefined;
    BackgroundKeepAliveHelper.notificationWantAgent = undefined;
    BackgroundKeepAliveHelper.lastProgressValue = -1;
  }

  private static getErrorCode(error: Object): number {
    return (error as BusinessError).code;
  }
}
