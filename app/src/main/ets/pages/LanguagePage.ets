import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { i18n } from '@kit.LocalizationKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';

@Entry
@Component
struct LanguagePage {
  @State selectedLanguage: string = 'system';
  @State private systemTopInsetVp: number = 0;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private languageScroller: Scroller = new Scroller();

  aboutToAppear() {
    HdsImmersiveHelper.syncSystemTopInsetVp(this, (value: number): void => {
      this.systemTopInsetVp = value;
    });
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
        if(targetLang.startsWith('zh')) {
          targetLang = 'zh-Hans';
        }else{
          targetLang = 'en-Latn-US';
        }
      }
      
      // Use standard API to set app language (API 9+)
      i18n.System.setAppPreferredLanguage(targetLang);
      LoggerIndex.info('[LanguagePage] Set app language via i18n.System.setAppPreferredLanguage:', targetLang);
    } catch (err) {
      LoggerIndex.error('[LanguagePage] Failed to set app language:', err);
    }
  }

  @Builder
  CheckItem(title: ResourceStr, tag: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      
      if (this.selectedLanguage === tag) {
        SymbolGlyph($r('sys.symbol.checkmark'))
          .fontSize(24)
          .fontColor([$r('app.color.btn_primary')])
      }
    }
    .width('100%')
    .height(56)
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .margin({ bottom: 12 })
    .onClick(() => {
      this.selectLanguage(tag);
    })
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
              this.CheckItem($r('app.string.follow_system'), 'system')
              this.CheckItem($r('app.string.language_zh'), 'zh-Hans')
              this.CheckItem($r('app.string.language_en'), 'en-Latn-US')
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
