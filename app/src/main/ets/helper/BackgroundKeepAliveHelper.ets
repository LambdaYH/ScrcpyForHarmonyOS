import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { LoggerClientSession } from './Logger';

export class BackgroundKeepAliveHelper {
  private static running: boolean = false;
  private static transition?: Promise<void>;
  private static cancelListenerRegistered: boolean = false;
  private static continuousTaskId?: number;
  private static notificationId?: number;
  private static progressUpdateQueue: Promise<void> = Promise.resolve();
  private static backgroundRequested: boolean = false;
  private static transferRequested: boolean = false;

  private static readonly cancelCallback =
    (info: backgroundTaskManager.ContinuousTaskCancelInfo): void => {
      if (BackgroundKeepAliveHelper.continuousTaskId !== undefined &&
        info.id !== BackgroundKeepAliveHelper.continuousTaskId) {
        return;
      }
      BackgroundKeepAliveHelper.running = false;
      BackgroundKeepAliveHelper.continuousTaskId = undefined;
      BackgroundKeepAliveHelper.notificationId = undefined;
      LoggerClientSession.warn(
        `[BackgroundKeepAlive] data transfer task cancelled by system, reason=${info.reason}, id=${info.id}`
      );
    };

  static async start(context: common.UIAbilityContext): Promise<void> {
    BackgroundKeepAliveHelper.backgroundRequested = true;
    await BackgroundKeepAliveHelper.ensureStarted(context);
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    BackgroundKeepAliveHelper.backgroundRequested = false;
    await BackgroundKeepAliveHelper.stopIfUnused(context);
  }

  static async startTransfer(context: common.UIAbilityContext): Promise<void> {
    BackgroundKeepAliveHelper.transferRequested = true;
    await BackgroundKeepAliveHelper.ensureStarted(context);
  }

  static async stopTransfer(context: common.UIAbilityContext): Promise<void> {
    BackgroundKeepAliveHelper.transferRequested = false;
    if (BackgroundKeepAliveHelper.backgroundRequested) {
      await BackgroundKeepAliveHelper.stopRunning(context, true);
      if (BackgroundKeepAliveHelper.backgroundRequested) {
        await BackgroundKeepAliveHelper.ensureStarted(context);
      }
      return;
    }
    await BackgroundKeepAliveHelper.stopIfUnused(context);
  }

  private static async ensureStarted(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundKeepAliveHelper.running) return;
    if (BackgroundKeepAliveHelper.transition) return BackgroundKeepAliveHelper.transition;
    BackgroundKeepAliveHelper.transition = BackgroundKeepAliveHelper.startInternal(context);
    try {
      await BackgroundKeepAliveHelper.transition;
    } finally {
      BackgroundKeepAliveHelper.transition = undefined;
    }
  }

  private static async stopIfUnused(context: common.UIAbilityContext): Promise<void> {
    if (BackgroundKeepAliveHelper.backgroundRequested || BackgroundKeepAliveHelper.transferRequested) {
      return;
    }
    await BackgroundKeepAliveHelper.stopRunning(context);
  }

  private static async stopRunning(context: common.UIAbilityContext, force: boolean = false): Promise<void> {
    if (!BackgroundKeepAliveHelper.running && !BackgroundKeepAliveHelper.transition) return;
    if (BackgroundKeepAliveHelper.transition) {
      try {
        await BackgroundKeepAliveHelper.transition;
      } catch (_err) {
      }
    }
    if (!BackgroundKeepAliveHelper.running) return;
    if (!force && (BackgroundKeepAliveHelper.backgroundRequested || BackgroundKeepAliveHelper.transferRequested)) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      BackgroundKeepAliveHelper.running = false;
      BackgroundKeepAliveHelper.continuousTaskId = undefined;
      BackgroundKeepAliveHelper.notificationId = undefined;
      LoggerClientSession.info('[BackgroundKeepAlive] data transfer task stopped');
    } catch (error) {
      BackgroundKeepAliveHelper.running = false;
      BackgroundKeepAliveHelper.continuousTaskId = undefined;
      BackgroundKeepAliveHelper.notificationId = undefined;
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

  static updateTransferProgress(
    title: string,
    fileName: string,
    statusText: string,
    progress: number
  ): Promise<void> {
    const update = BackgroundKeepAliveHelper.progressUpdateQueue.then(async (): Promise<void> => {
      await BackgroundKeepAliveHelper.updateTransferProgressInternal(
        title,
        fileName,
        statusText,
        progress
      );
    });
    BackgroundKeepAliveHelper.progressUpdateQueue = update;
    return update;
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
      const notification = await backgroundTaskManager.startBackgroundRunning(
        context,
        ['dataTransfer'],
        agent
      );
      BackgroundKeepAliveHelper.running = true;
      BackgroundKeepAliveHelper.continuousTaskId = notification.continuousTaskId;
      BackgroundKeepAliveHelper.notificationId = notification.notificationId;
      LoggerClientSession.info('[BackgroundKeepAlive] data transfer task started');
    } catch (error) {
      BackgroundKeepAliveHelper.running = false;
      BackgroundKeepAliveHelper.continuousTaskId = undefined;
      BackgroundKeepAliveHelper.notificationId = undefined;
      LoggerClientSession.error('[BackgroundKeepAlive] start failed:', error);
    }
  }

  private static async updateTransferProgressInternal(
    title: string,
    fileName: string,
    statusText: string,
    progress: number
  ): Promise<void> {
    if (!BackgroundKeepAliveHelper.running || BackgroundKeepAliveHelper.notificationId === undefined) {
      return;
    }
    const normalizedProgress = Math.max(0, Math.min(100, Math.round(progress)));
    try {
      await notificationManager.publish({
        id: BackgroundKeepAliveHelper.notificationId,
        notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
        template: {
          name: 'downloadTemplate',
          data: {
            title,
            fileName,
            progressValue: normalizedProgress
          }
        },
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            typeCode: 8,
            title,
            text: statusText
          }
        }
      });
    } catch (error) {
      LoggerClientSession.warn('[BackgroundKeepAlive] transfer progress update failed:', error);
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

  private static getErrorCode(error: Object): number {
    return (error as BusinessError).code;
  }
}
