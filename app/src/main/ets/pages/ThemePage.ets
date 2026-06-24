import { LengthMetrics } from '@kit.ArkUI';
import { DividerShowType, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, SystemMaterialParams } from '@kit.UIDesignKit';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';

@Entry
@Component
struct ThemePage {
  @State selectedMode: string = 'system';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  aboutToAppear() {
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
      (this.getUIContext().getHostContext() as common.UIAbilityContext).getApplicationContext().setColorMode(colorMode);
    } catch (err) {
      LoggerIndex.error('Set color mode failed:', err);
    }
  }

  @Builder
  CheckItem(title: ResourceStr, mode: string) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .layoutWeight(1)
      
      if (this.selectedMode === mode) {
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
      this.selectMode(mode);
    })
  }

  build() {
    HdsNavigation() {
      Column() {
        Column() {
          this.CheckItem($r('app.string.follow_system'), 'system')
          this.CheckItem($r('app.string.light_mode'), 'light')
          this.CheckItem($r('app.string.dark_mode_option'), 'dark')
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
          mainTitle: $r('app.string.dark_mode'),
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
            backgroundColor: '#1AFFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              backgroundColor: Color.Transparent,
              iconColor: $r('sys.color.icon_primary')
            },
            dividerStyle: {
              dividerColor: Color.Transparent
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: '#1AFFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              backgroundColor: Color.Transparent,
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
