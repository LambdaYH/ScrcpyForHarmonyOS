import { LengthMetrics } from '@kit.ArkUI';
import { DividerShowType, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, SystemMaterialParams } from '@kit.UIDesignKit';
import { i18n } from '@kit.LocalizationKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';

@Entry
@Component
struct LanguagePage {
  @State selectedLanguage: string = 'system';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  aboutToAppear() {
    this.initLanguage();
  }

  async initLanguage() {
    this.selectedLanguage = await this.preferencesHelper.getLanguage();
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
        Column() {
          this.CheckItem($r('app.string.follow_system'), 'system')
          this.CheckItem($r('app.string.language_zh'), 'zh-Hans')
          this.CheckItem($r('app.string.language_en'), 'en-Latn-US')
        }
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_primary'))
      .padding({ top: 100 })
    }
    .width('100%')
    .height('100%')
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar({
      avoidLayoutSafeArea: true,
      padding: {
        start: LengthMetrics.vp(24),
        end: LengthMetrics.vp(24)
      },
      content: {
        title: {
          mainTitle: $r('app.string.language_settings'),
          mainTitleSize: 20
        },
        divider: {
          showType: DividerShowType.OFF
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.GRADIENT_BLUR
        },
        originalStyle: {
          backgroundStyle: {
            backgroundColor: '#0DFFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              backgroundColor: $r('sys.color.comp_background_tertiary'),
              iconColor: $r('sys.color.icon_primary')
            },
            dividerStyle: {
              dividerColor: Color.Transparent
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: '#14FFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              backgroundColor: $r('sys.color.comp_background_tertiary'),
              iconColor: $r('sys.color.icon_primary')
            },
            dividerStyle: {
              dividerColor: Color.Transparent
            }
          }
        },
        systemMaterialEffect: undefined
      }
    })
    .backgroundColor(Color.Transparent)
  }
}
