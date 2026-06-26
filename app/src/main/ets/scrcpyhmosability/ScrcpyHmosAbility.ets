import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import { i18n } from '@kit.LocalizationKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';

const DOMAIN = 0x0000;

export default class ScrcpyHmosAbility extends UIAbility {
  private initPromise: Promise<void> | undefined;
  private mainWindow: window.Window | null = null;
  private avoidAreaChangeCallback: ((data: window.AvoidAreaOptions) => void) | null = null;
  private windowSizeChangeCallback: ((size: window.Size) => void) | null = null;
  private safeAreaRefreshTimerId: number = 0;

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
    this.clearSafeAreaWatchers();
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
        this.mainWindow = windowClass;
        await windowClass.setWindowLayoutFullScreen(true);
        await windowClass.setPreferredOrientation(window.Orientation.AUTO_ROTATION_RESTRICTED);
        await windowClass.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000'
        });
        this.initSafeAreaTracking(windowStage, windowClass);
      } catch (exception) {
        HdsImmersiveHelper.publishSafeAreaInsets(
          HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP,
          HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP
        );
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
    this.clearSafeAreaWatchers();
    this.mainWindow = null;
    hilog.debug(DOMAIN, 'ScrcpyAbility', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    this.refreshSafeAreaFromMainWindow('foreground');
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

  private initSafeAreaTracking(windowStage: window.WindowStage, win: window.Window): void {
    try {
      const uiCtx = windowStage.getMainWindowSync().getUIContext();
      this.scheduleSafeAreaRefresh(win, uiCtx, 'loadContent');
      this.watchSafeAreaInsets(win, uiCtx);
    } catch (_err) {
      HdsImmersiveHelper.publishSafeAreaInsets(
        HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP,
        HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP
      );
    }
  }

  private refreshSafeAreaFromMainWindow(source: string): void {
    if (!this.mainWindow || !this.windowStage) {
      return;
    }
    try {
      const uiCtx = this.windowStage.getMainWindowSync().getUIContext();
      this.scheduleSafeAreaRefresh(this.mainWindow, uiCtx, source);
    } catch (_err) {
      HdsImmersiveHelper.publishSafeAreaInsets(
        HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP,
        HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP
      );
    }
  }

  private refreshSafeAreaInsets(win: window.Window, uiCtx: UIContext, source: string): void {
    try {
      const topInsetVp = Math.max(
        this.safeAreaTopHeight(win, uiCtx, window.AvoidAreaType.TYPE_SYSTEM),
        this.safeAreaTopHeight(win, uiCtx, window.AvoidAreaType.TYPE_CUTOUT)
      );
      const bottomInsetVp = Math.max(
        this.safeAreaBottomHeight(win, uiCtx, window.AvoidAreaType.TYPE_SYSTEM),
        this.safeAreaBottomHeight(win, uiCtx, window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR),
        this.safeAreaBottomHeight(win, uiCtx, window.AvoidAreaType.TYPE_SYSTEM_GESTURE),
        this.safeAreaBottomHeight(win, uiCtx, window.AvoidAreaType.TYPE_CUTOUT)
      );
      HdsImmersiveHelper.publishSafeAreaInsets(topInsetVp, bottomInsetVp);
    } catch (exception) {
      HdsImmersiveHelper.publishSafeAreaInsets(
        HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP,
        HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP
      );
      hilog.error(
        DOMAIN,
        'ScrcpyAbility',
        'Failed to refresh safe area insets (%{public}s). Cause: %{public}s',
        source,
        JSON.stringify(exception)
      );
    }
  }

  private safeAreaTopHeight(win: window.Window, uiCtx: UIContext, type: window.AvoidAreaType): number {
    try {
      return uiCtx.px2vp(win.getWindowAvoidArea(type).topRect.height);
    } catch (_err) {
      return 0;
    }
  }

  private safeAreaBottomHeight(win: window.Window, uiCtx: UIContext, type: window.AvoidAreaType): number {
    try {
      return uiCtx.px2vp(win.getWindowAvoidArea(type).bottomRect.height);
    } catch (_err) {
      return 0;
    }
  }

  private scheduleSafeAreaRefresh(win: window.Window, uiCtx: UIContext, source: string): void {
    this.refreshSafeAreaInsets(win, uiCtx, source);
    if (this.safeAreaRefreshTimerId > 0) {
      clearTimeout(this.safeAreaRefreshTimerId);
      this.safeAreaRefreshTimerId = 0;
    }
    this.safeAreaRefreshTimerId = setTimeout((): void => {
      this.safeAreaRefreshTimerId = 0;
      this.refreshSafeAreaInsets(win, uiCtx, `${source}_settled`);
    }, 80);
  }

  private watchSafeAreaInsets(win: window.Window, uiCtx: UIContext): void {
    this.clearSafeAreaWatchers();
    this.avoidAreaChangeCallback = (_data: window.AvoidAreaOptions): void => {
      this.scheduleSafeAreaRefresh(win, uiCtx, 'avoidAreaChange');
    };
    this.windowSizeChangeCallback = (_size: window.Size): void => {
      this.scheduleSafeAreaRefresh(win, uiCtx, 'windowSizeChange');
    };
    try {
      win.on('avoidAreaChange', this.avoidAreaChangeCallback);
    } catch (exception) {
      hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to watch avoidAreaChange. Cause: %{public}s', JSON.stringify(exception));
    }
    try {
      win.on('windowSizeChange', this.windowSizeChangeCallback);
    } catch (exception) {
      hilog.error(DOMAIN, 'ScrcpyAbility', 'Failed to watch windowSizeChange. Cause: %{public}s', JSON.stringify(exception));
    }
  }

  private clearSafeAreaWatchers(): void {
    const win = this.mainWindow;
    if (win && this.avoidAreaChangeCallback) {
      try {
        win.off('avoidAreaChange', this.avoidAreaChangeCallback);
      } catch (_err) {
      }
      this.avoidAreaChangeCallback = null;
    }
    if (win && this.windowSizeChangeCallback) {
      try {
        win.off('windowSizeChange', this.windowSizeChangeCallback);
      } catch (_err) {
      }
      this.windowSizeChangeCallback = null;
    }
    if (this.safeAreaRefreshTimerId > 0) {
      clearTimeout(this.safeAreaRefreshTimerId);
      this.safeAreaRefreshTimerId = 0;
    }
  }
}
