import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { i18n } from '@kit.LocalizationKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';
import { CheckItem } from '../components/CheckItem';

@Entry
@Component
struct LanguagePage {
  @State private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @State selectedLanguage: string = 'system';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private languageScroller: Scroller = new Scroller();

  aboutToAppear() {
    HdsImmersiveHelper.syncPageTopInsetVp(this);
    this.initLanguage();
  }

  async initLanguage() {
    this.selectedLanguage = await this.preferencesHelper.getLanguage();
  }

  private languageTitleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  async selectLanguage(lan: string) {
    this.selectedLanguage = lan;
    await this.preferencesHelper.saveLanguage(lan);
    this.applyLanguage(lan);
  }

  applyLanguage(lan: string) {
    try {
      let targetLang = lan;
      if (lan === 'system') {
        targetLang = i18n.System.getSystemLanguage();
        if (targetLang.startsWith('zh')) {
          targetLang = 'zh-Hans';
        } else {
          targetLang = 'en-Latn-US';
        }
      }
      i18n.System.setAppPreferredLanguage(targetLang);
      LoggerIndex.info('[LanguagePage] Set app language:', targetLang);
    } catch (err) {
      LoggerIndex.error('[LanguagePage] Failed to set app language:', err);
    }
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll(this.languageScroller) {
          Column() {
            Blank()
              .height(this.languageTitleOverlayHeight())
              .width('100%')

            Column() {
              CheckItem({
                title: $r('app.string.follow_system'),
                selected: this.selectedLanguage === 'system'
              })
                .onClick(() => { this.selectLanguage('system'); })

              CheckItem({
                title: $r('app.string.language_zh'),
                selected: this.selectedLanguage === 'zh-Hans'
              })
                .onClick(() => { this.selectLanguage('zh-Hans'); })

              CheckItem({
                title: $r('app.string.language_en'),
                selected: this.selectedLanguage === 'en-Latn-US'
              })
                .onClick(() => { this.selectLanguage('en-Latn-US'); })
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
    .bindToScrollable([this.languageScroller])
    .titleBar(HdsImmersiveHelper.buildMiniTitleBarOptions($r('app.string.language_settings')))
    .backgroundColor(Color.Transparent)
  }
}
