import { LengthMetrics } from '@kit.ArkUI';
import { DividerShowType, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerIndex } from '../helper/Logger';

@Entry
@Component
struct ThemePage {
  @State selectedMode: string = 'system';
  @State private systemTopInsetVp: number = 0;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private themeScroller: Scroller = new Scroller();

  aboutToAppear() {
    HdsImmersiveHelper.syncSystemTopInsetVp(this, (value: number): void => {
      this.systemTopInsetVp = value;
    });
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

  private themeTitleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
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
        Scroll(this.themeScroller) {
          Column() {
            Blank()
              .height(this.themeTitleOverlayHeight())
              .width('100%')

            Column() {
              this.CheckItem($r('app.string.follow_system'), 'system')
              this.CheckItem($r('app.string.light_mode'), 'light')
              this.CheckItem($r('app.string.dark_mode_option'), 'dark')
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
        systemMaterialEffect: HdsImmersiveHelper.buildHdsImmersiveSystemMaterialEffect()
      }
    })
    .backgroundColor(Color.Transparent)
  }
}
