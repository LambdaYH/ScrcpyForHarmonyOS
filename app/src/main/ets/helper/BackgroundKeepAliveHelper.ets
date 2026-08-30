import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { LoggerClientSession } from './Logger';

export class BackgroundKeepAliveHelper {
  private static running: boolean = false;
  private static transition?: Promise<void>;

  static async start(context: common.UIAbilityContext): Promise<void> {
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
    if (!BackgroundKeepAliveHelper.running && !BackgroundKeepAliveHelper.transition) return;
    if (BackgroundKeepAliveHelper.transition) {
      try {
        await BackgroundKeepAliveHelper.transition;
      } catch (_err) {
      }
    }
    if (!BackgroundKeepAliveHelper.running) return;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      BackgroundKeepAliveHelper.running = false;
      LoggerClientSession.info('[BackgroundKeepAlive] data transfer task stopped');
    } catch (error) {
      LoggerClientSession.error('[BackgroundKeepAlive] stop failed:', error);
    }
  }

  static isRunning(): boolean {
    return BackgroundKeepAliveHelper.running;
  }

  private static async startInternal(context: common.UIAbilityContext): Promise<void> {
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.lambdayh.scrcpyHmos',
          abilityName: 'ScrcpyHmosAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1002,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      BackgroundKeepAliveHelper.running = true;
      LoggerClientSession.info('[BackgroundKeepAlive] data transfer task started');
    } catch (error) {
      BackgroundKeepAliveHelper.running = false;
      LoggerClientSession.error('[BackgroundKeepAlive] start failed:', error);
    }
  }
}
