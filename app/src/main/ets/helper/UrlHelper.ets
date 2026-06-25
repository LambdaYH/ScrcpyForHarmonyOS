import { common, Want } from '@kit.AbilityKit';
import { LoggerDeviceDetail } from './Logger';

export class UrlHelper {
  static openUrl(context: common.UIAbilityContext, url: string): void {
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((err: Error) => {
      LoggerDeviceDetail.error('Failed to open URL:', err);
    });
  }
}
