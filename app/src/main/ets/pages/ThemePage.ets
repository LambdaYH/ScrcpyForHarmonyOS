import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';
import { CheckItem } from '../components/CheckItem';

@Entry
@Component
struct ThemePage {
  @State private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @State selectedMode: string = 'system';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private themeScroller: Scroller = new Scroller();

  aboutToAppear() {
    HdsImmersiveHelper.syncPageTopInsetVp(this);
    this.initMode();
  }

  async initMode() {
    this.selectedMode = await this.preferencesHelper.getThemeMode();
  }

  async selectMode(mode: string) {
    this.selectedMode = mode;
    await this.preferencesHelper.saveThemeMode(mode);
    this.applyTheme(mode);
  }

  applyTheme(mode: string) {
    let colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (mode === 'light') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (mode === 'dark') {
      colorMode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      (this.getUIContext().getHostContext() as common.UIAbilityContext)
        .getApplicationContext().setColorMode(colorMode);
    } catch (err) {
      LoggerIndex.error('Set color mode failed:', err);
    }
  }

  private themeTitleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll(this.themeScroller) {
          Column() {
            Blank()
              .height(this.themeTitleOverlayHeight())
              .width('100%')

            Column() {
              CheckItem({
                title: $r('app.string.follow_system'),
                selected: this.selectedMode === 'system'
              })
                .onClick(() => { this.selectMode('system'); })

              CheckItem({
                title: $r('app.string.light_mode'),
                selected: this.selectedMode === 'light'
              })
                .onClick(() => { this.selectMode('light'); })

              CheckItem({
                title: $r('app.string.dark_mode_option'),
                selected: this.selectedMode === 'dark'
              })
                .onClick(() => { this.selectMode('dark'); })
            }
            .width('100%')
            .padding(16)
          }
          .width('100%')
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_primary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .hideToolBar(true)
    .navBarWidth('100%')
    .bindToScrollable([this.themeScroller])
    .titleBar(HdsImmersiveHelper.buildMiniTitleBarOptions($r('app.string.dark_mode')))
    .backgroundColor(Color.Transparent)
  }
}
