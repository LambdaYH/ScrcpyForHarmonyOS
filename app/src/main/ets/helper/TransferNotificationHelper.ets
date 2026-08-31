import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { LoggerAdb } from './Logger';

type TransferNotificationType = 'send' | 'pull' | 'install';

/**
 * Prepares notification access for the transfer-center Live View.
 * Ordinary progress updates are intentionally not published. Completion and
 * failure results remain as one-shot ordinary notifications.
 */
export class TransferNotificationHelper {
  private static readonly SEND_NOTIFICATION_ID: number = 3001;
  private static readonly INSTALL_NOTIFICATION_ID: number = 3002;
  private static readonly PULL_NOTIFICATION_ID: number = 3003;
  private static slotReady: boolean = false;
  private static availabilityChecked: boolean = false;
  private static notificationEnabled: boolean = true;
  private static readonly publishQueues = new Map<number, Promise<void>>();

  private static getNotificationId(type: TransferNotificationType): number {
    if (type === 'send') return TransferNotificationHelper.SEND_NOTIFICATION_ID;
    return type === 'pull'
      ? TransferNotificationHelper.PULL_NOTIFICATION_ID
      : TransferNotificationHelper.INSTALL_NOTIFICATION_ID;
  }

  private static async ensureAvailable(context: common.UIAbilityContext): Promise<boolean> {
    if (TransferNotificationHelper.availabilityChecked) {
      return TransferNotificationHelper.notificationEnabled;
    }

    if (!TransferNotificationHelper.slotReady) {
      try {
        await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      } catch (error) {
        LoggerAdb.warn('[TransferNotification] addSlot failed:', String(error));
      }
      TransferNotificationHelper.slotReady = true;
    }

    try {
      const enabled = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        await notificationManager.requestEnableNotification(context);
        TransferNotificationHelper.notificationEnabled = await notificationManager.isNotificationEnabled();
      } else {
        TransferNotificationHelper.notificationEnabled = true;
      }
    } catch (error) {
      LoggerAdb.warn('[TransferNotification] ensure notification availability failed:', String(error));
      TransferNotificationHelper.notificationEnabled = false;
    }

    TransferNotificationHelper.availabilityChecked = true;
    return TransferNotificationHelper.notificationEnabled;
  }

  static async prepare(context: common.UIAbilityContext): Promise<boolean> {
    return await TransferNotificationHelper.ensureAvailable(context);
  }

  static async complete(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    fileName: string,
    statusText: string
  ): Promise<void> {
    await TransferNotificationHelper.publishResult(context, type, title, fileName, statusText);
  }

  static async fail(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    fileName: string,
    statusText: string
  ): Promise<void> {
    await TransferNotificationHelper.publishResult(context, type, title, fileName, statusText);
  }

  private static async publishResult(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    fileName: string,
    statusText: string
  ): Promise<void> {
    const id = TransferNotificationHelper.getNotificationId(type);
    const run = async (): Promise<void> => {
      if (!await TransferNotificationHelper.ensureAvailable(context)) return;
      try {
        await notificationManager.publish({
          id,
          notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
          isOngoing: false,
          isUnremovable: false,
          content: {
            notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
            normal: {
              title,
              text: statusText,
              additionalText: fileName
            }
          }
        });
      } catch (error) {
        LoggerAdb.warn('[TransferNotification] result publish failed:', String(error));
      }
    };
    const previous = TransferNotificationHelper.publishQueues.get(id) ?? Promise.resolve();
    const current = previous.then(run, run);
    TransferNotificationHelper.publishQueues.set(id, current);
    void current.then((): void => {
      if (TransferNotificationHelper.publishQueues.get(id) === current) {
        TransferNotificationHelper.publishQueues.delete(id);
      }
    });
    return current;
  }
}
