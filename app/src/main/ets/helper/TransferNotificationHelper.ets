import { common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { LoggerAdb } from './Logger';

type TransferNotificationType = 'send' | 'pull' | 'install';

export class TransferNotificationHelper {
  private static readonly SEND_NOTIFICATION_ID: number = 3001;
  private static readonly INSTALL_NOTIFICATION_ID: number = 3002;
  private static readonly PULL_NOTIFICATION_ID: number = 3003;
  private static slotReady: boolean = false;
  private static availabilityChecked: boolean = false;
  private static notificationEnabled: boolean = true;
  private static readonly lastProgress = new Map<number, number>();
  private static readonly lastPublishAt = new Map<number, number>();
  private static readonly lastStatusText = new Map<number, string>();
  private static readonly lastDetailText = new Map<number, string>();
  private static readonly lastOngoing = new Map<number, boolean>();
  private static readonly recentProgressPublishes = new Map<number, Array<number>>();
  private static readonly MAX_PROGRESS_PUBLISHES_PER_SECOND: number = 5;

  private static getNotificationId(type: TransferNotificationType): number {
    if (type === 'send') {
      return TransferNotificationHelper.SEND_NOTIFICATION_ID;
    }
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
      } catch (err) {
        LoggerAdb.warn('[TransferNotification] addSlot failed:', String(err));
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
    } catch (err) {
      LoggerAdb.warn('[TransferNotification] ensure notification availability failed:', String(err));
      TransferNotificationHelper.notificationEnabled = false;
    }

    TransferNotificationHelper.availabilityChecked = true;
    return TransferNotificationHelper.notificationEnabled;
  }

  private static async publish(
    context: common.UIAbilityContext,
    id: number,
    title: string,
    statusText: string,
    detailText: string,
    ongoing: boolean
  ): Promise<void> {
    const available = await TransferNotificationHelper.ensureAvailable(context);
    if (!available) {
      return;
    }

    const lastStatusText = TransferNotificationHelper.lastStatusText.get(id) ?? '';
    const lastDetailText = TransferNotificationHelper.lastDetailText.get(id) ?? '';
    const lastOngoing = TransferNotificationHelper.lastOngoing.get(id);
    if (lastStatusText === statusText && lastDetailText === detailText && lastOngoing === ongoing) {
      return;
    }

    try {
      await notificationManager.publish({
        id,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        isOngoing: ongoing,
        isUnremovable: ongoing,
        content: {
          notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title,
            text: statusText,
            additionalText: detailText
          }
        }
      });
      TransferNotificationHelper.lastStatusText.set(id, statusText);
      TransferNotificationHelper.lastDetailText.set(id, detailText);
      TransferNotificationHelper.lastOngoing.set(id, ongoing);
    } catch (err) {
      LoggerAdb.warn('[TransferNotification] publish failed:', String(err));
    }
  }

  static async start(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    text: string,
    statusText: string
  ): Promise<void> {
    const id = TransferNotificationHelper.getNotificationId(type);
    TransferNotificationHelper.lastProgress.set(id, 0);
    TransferNotificationHelper.lastPublishAt.set(id, 0);
    TransferNotificationHelper.recentProgressPublishes.set(id, []);
    await TransferNotificationHelper.publish(context, id, title, statusText, text, true);
  }

  static async updateProgress(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    text: string,
    statusText: string,
    progress: number
  ): Promise<void> {
    const id = TransferNotificationHelper.getNotificationId(type);
    const now = Date.now();
    const lastProgress = TransferNotificationHelper.lastProgress.get(id) ?? -1;
    const normalizedProgress = Math.max(0, Math.min(100, progress));
    const isBoundaryProgress = normalizedProgress === 0 || normalizedProgress === 100;
    const crossedInstallThreshold = lastProgress < 95 && normalizedProgress >= 95;

    if (!isBoundaryProgress && !crossedInstallThreshold) {
      const recent = TransferNotificationHelper.recentProgressPublishes.get(id) ?? [];
      const filtered = recent.filter((timestamp: number) => now - timestamp < 1000);
      if (filtered.length >= TransferNotificationHelper.MAX_PROGRESS_PUBLISHES_PER_SECOND) {
        TransferNotificationHelper.recentProgressPublishes.set(id, filtered);
        return;
      }
      filtered.push(now);
      TransferNotificationHelper.recentProgressPublishes.set(id, filtered);
    }

    TransferNotificationHelper.lastProgress.set(id, normalizedProgress);
    TransferNotificationHelper.lastPublishAt.set(id, now);
    await TransferNotificationHelper.publish(context, id, title, statusText, text, true);
  }

  static async complete(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    text: string,
    statusText: string
  ): Promise<void> {
    const id = TransferNotificationHelper.getNotificationId(type);
    TransferNotificationHelper.lastProgress.delete(id);
    TransferNotificationHelper.lastPublishAt.delete(id);
    TransferNotificationHelper.lastStatusText.delete(id);
    TransferNotificationHelper.lastDetailText.delete(id);
    TransferNotificationHelper.lastOngoing.delete(id);
    TransferNotificationHelper.recentProgressPublishes.delete(id);
    await TransferNotificationHelper.publish(context, id, title, statusText, text, false);
  }

  static async fail(
    context: common.UIAbilityContext,
    type: TransferNotificationType,
    title: string,
    text: string,
    statusText: string
  ): Promise<void> {
    const id = TransferNotificationHelper.getNotificationId(type);
    TransferNotificationHelper.lastProgress.delete(id);
    TransferNotificationHelper.lastPublishAt.delete(id);
    TransferNotificationHelper.lastStatusText.delete(id);
    TransferNotificationHelper.lastDetailText.delete(id);
    TransferNotificationHelper.lastOngoing.delete(id);
    TransferNotificationHelper.recentProgressPublishes.delete(id);
    await TransferNotificationHelper.publish(context, id, title, statusText, text, false);
  }

  static async cancel(type: TransferNotificationType): Promise<void> {
    const id = TransferNotificationHelper.getNotificationId(type);
    TransferNotificationHelper.lastProgress.delete(id);
    TransferNotificationHelper.lastPublishAt.delete(id);
    TransferNotificationHelper.lastStatusText.delete(id);
    TransferNotificationHelper.lastDetailText.delete(id);
    TransferNotificationHelper.lastOngoing.delete(id);
    TransferNotificationHelper.recentProgressPublishes.delete(id);
    try {
      await notificationManager.cancel(id);
    } catch (err) {
      LoggerAdb.warn('[TransferNotification] cancel failed:', String(err));
    }
  }
}
