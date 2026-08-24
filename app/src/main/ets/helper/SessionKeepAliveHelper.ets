import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { LoggerClientSession } from './Logger';

export class SessionKeepAliveHelper {
  private static running: boolean = false;
  private static transition?: Promise<void>;

  static async start(context: common.UIAbilityContext): Promise<void> {
    if (SessionKeepAliveHelper.running) return;
    if (SessionKeepAliveHelper.transition) return SessionKeepAliveHelper.transition;
    SessionKeepAliveHelper.transition = SessionKeepAliveHelper.startInternal(context);
    try { await SessionKeepAliveHelper.transition; }
    finally { SessionKeepAliveHelper.transition = undefined; }
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    if (!SessionKeepAliveHelper.running && !SessionKeepAliveHelper.transition) return;
    if (SessionKeepAliveHelper.transition) {
      try { await SessionKeepAliveHelper.transition; } catch (_err) {}
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
      SessionKeepAliveHelper.running = false;
      LoggerClientSession.info('[SessionKeepAlive] continuous task stopped');
    } catch (error) {
      LoggerClientSession.error('[SessionKeepAlive] stop failed:', error);
    }
  }

  static isRunning(): boolean { return SessionKeepAliveHelper.running; }

  private static async startInternal(context: common.UIAbilityContext): Promise<void> {
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{
          bundleName: 'com.lambdayh.scrcpyHmos',
          abilityName: 'ScrcpyHmosAbility'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 1001,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      await backgroundTaskManager.startBackgroundRunning(
        context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        agent
      );
      SessionKeepAliveHelper.running = true;
      LoggerClientSession.info('[SessionKeepAlive] continuous task started');
    } catch (error) {
      SessionKeepAliveHelper.running = false;
      LoggerClientSession.error('[SessionKeepAlive] start failed:', error);
    }
  }
}
