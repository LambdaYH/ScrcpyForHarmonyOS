import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import { i18n } from '@kit.LocalizationKit';

const DOMAIN = 0x0000;

export default class ScrcpyHmosAbility extends UIAbility {
  private initPromise: Promise<void> | undefined;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onCreate');
    
    // 初始化ADB密钥
    AdbKeyManager.getInstance().init(this.context);

    // 初始化数据存储并设置语言/主题
    this.initPromise = PreferencesHelper.getInstance().init(this.context).then(async () => {
      // Apply saved theme
      const theme = await PreferencesHelper.getInstance().getThemeMode();
      let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
      if (theme === 'light') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      } else if (theme === 'dark') {
        colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
      this.context.getApplicationContext().setColorMode(colorMode);

      // Apply saved language or follow system logic
      await this.checkLanguageStatus();
    });
  }


  onDestroy(): void {
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onDestroy');
  }

  private windowStage?: window.WindowStage;

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onWindowStageCreate');
    this.windowStage = windowStage;

    windowStage.loadContent('pages/Index', async (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      // Enable full screen
      try {
        let windowClass: window.Window = windowStage.getMainWindowSync();
        await windowClass.setWindowLayoutFullScreen(true);
        await windowClass.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
      } catch (exception) {
        hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to set the window layout to full-screen mode. Cause: ' + JSON.stringify(exception));
      }
      hilog.info(DOMAIN, 'ScrcpyAbility', 'Succeeded in loading the content.');
    });

    if (this.initPromise) {
      this.initPromise.then(() => {
        // Init done
      }).catch((err: Error) => {
        hilog.error(DOMAIN, 'ScrcpyAbility', 'Init promise failed: %{public}s', JSON.stringify(err));
      });
    }
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onForeground');
    this.checkLanguageStatus();
  }

  private async checkLanguageStatus(): Promise<void> {
    try {
      const language = await PreferencesHelper.getInstance().getLanguage();
      hilog.debug(DOMAIN, 'ScrcpyAbility', 'Checking language status, preference: %{public}s', language);
      
      if (language !== 'system') {
        // Explicit preference
        try {
           const currentAppLang = i18n.System.getAppPreferredLanguage();
           if (currentAppLang !== language) {
             hilog.debug(DOMAIN, 'ScrcpyAbility', 'Setting app language to explicit: %{public}s', language);
             i18n.System.setAppPreferredLanguage(language);
           }
        } catch (err) {
           hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to set language. Cause: %{public}s', JSON.stringify(err));
        }
      } else {
        // Follow System (Manual Sync)
        // Since 'default' setting might be flaky, we explicit sync with system language here.
        try {
          const sysLang = i18n.System.getSystemLanguage();
          const currentAppLang = i18n.System.getAppPreferredLanguage();
          
          hilog.debug(DOMAIN, 'ScrcpyAbility', 'System Language: %{public}s, Current App Language: %{public}s', sysLang, currentAppLang);

          // We check if we need to update. 
          // Note: getAppPreferredLanguage might return previously set explicit lang.
          // If preference knows it should be system, we force sysLang.
          
          // Optimization: Check for Traditional Chinese edge case if needed, or just trust sysLang
          // But generally, overwrite with sysLang if different.
          if (currentAppLang !== sysLang) {
             hilog.info(DOMAIN, 'ScrcpyAbility', 'Preference is system, syncing app language to: %{public}s', sysLang);
             if(sysLang.startsWith('zh')) {
               i18n.System.setAppPreferredLanguage('zh-Hans');
             }else{
               i18n.System.setAppPreferredLanguage('en-Latn-US');
             }
          }
        } catch (e) {
             hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to sync system language: ' + JSON.stringify(e));
        }
      }
    } catch (e) {
      hilog.error(DOMAIN, 'ScrcpyAbility', 'checkLanguageStatus failed: ' + JSON.stringify(e));
    }
  }

  onBackground(): void {
    // Ability has back to background
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onBackground');
  }
}
