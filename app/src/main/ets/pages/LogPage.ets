import { LengthMetrics } from '@kit.ArkUI';
import { DividerShowType, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, SystemMaterialParams } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { Logger, LoggerIndex, LogLevel } from '../helper/Logger';


@Entry
@Component
struct LogPage {
  @State logContent: string = 'Loading...';
  @State selectedLogLevel: number = Logger.getLogLevel();
  @State isFileLoggingEnabled: boolean = Logger.isFileLoggingEnabled();
  private scroller: Scroller = new Scroller();

  aboutToAppear() {
    this.refreshLogs();
  }

  async refreshLogs() {
    try {
      const content = await Logger.getLogContent();
      this.logContent = content || '暂无日志';
      // Scroll to bottom after loading
      setTimeout(() => {
        this.scroller.scrollEdge(Edge.Bottom);
      }, 100);
    } catch (e) {
      const errMsg = e instanceof Error ? e.message : String(e);
      LoggerIndex.error('Load logs failed:', errMsg);
      this.logContent = 'Failed to load logs.';
    }
  }

  async clearLogs() {
    this.getUIContext().showAlertDialog({
      title: $r('app.string.clear_logs_confirm_title'),
      message: $r('app.string.clear_logs_confirm_msg'),
      primaryButton: {
        value: $r('app.string.cancel'),
        action: () => {
        }
      },
      secondaryButton: {
        value: $r('app.string.clear'),
        fontColor: Object($r('app.color.btn_danger')),
        action: () => {
          Logger.clearLogs();
          this.refreshLogs();
          this.getUIContext().getPromptAction().showToast({ message: $r('app.string.logs_cleared') });
        }
      }
    });
  }

  build() {
    HdsNavigation() {
      Column() {
        Row() {
          Toggle({ type: ToggleType.Switch, isOn: this.isFileLoggingEnabled })
            .onChange((isOn: boolean) => {
              this.isFileLoggingEnabled = isOn;
              Logger.setFileLoggingEnabled(isOn);
            })
            .height(24)
            .margin({ left: 12 })

          Blank()

          if (this.isFileLoggingEnabled) {
            Select([
              { value: 'DEBUG' },
              { value: 'INFO' },
              { value: 'WARN' },
              { value: 'ERROR' }
            ])
              .selected(this.selectedLogLevel)
              .value(LogLevel[this.selectedLogLevel])
              .font({ size: 12 })
              .fontColor($r('app.color.text_primary'))
              .selectedOptionFont({ size: 12 })
              .optionFont({ size: 12 })
              .backgroundColor($r('app.color.bg_card'))
              .onSelect((index: number) => {
                this.selectedLogLevel = index;
                Logger.setLogLevel(index);
              })
          }
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 24 })
        .alignItems(VerticalAlign.Center)

        if (this.isFileLoggingEnabled) {
          Scroll(this.scroller) {
            Text(this.logContent.length > 50000 ? '... (日志过长，仅显示最后部分)\n' + this.logContent.slice(-50000) : this.logContent)
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .fontFamily('Monospace')
              .width('100%')
              .padding(16)
              .copyOption(CopyOptions.LocalDevice)
          }
          .layoutWeight(1)
          .width('100%')
          .edgeEffect(EdgeEffect.Spring)
          .align(Alignment.TopStart)
          .backgroundColor($r('app.color.bg_primary'))
        } else {
          Blank().layoutWeight(1)
        }

        Row() {
          if (this.isFileLoggingEnabled) {
            Button($r('app.string.refresh'))
              .fontSize(14)
              .backgroundColor($r('app.color.btn_secondary'))
              .fontColor($r('app.color.text_primary'))
              .margin({ right: 12 })
              .onClick(() => {
                this.refreshLogs();
              })
              .layoutWeight(1)
          }

          Button($r('app.string.clear_logs'))
            .fontSize(14)
            .backgroundColor($r('app.color.btn_danger'))
            .fontColor(Color.White)
            .onClick(() => {
              this.clearLogs();
            })
            .layoutWeight(this.isFileLoggingEnabled ? 1 : 0.5)
            .width(this.isFileLoggingEnabled ? 'auto' : '50%')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 28 })
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.bg_card'))
        .shadow({ radius: 8, color: '#1A000000', offsetY: -2 })
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
          mainTitle: $r('app.string.system_log'),
          mainTitleSize: 20
        },
        divider: {
          showType: DividerShowType.OFF
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: HdsImmersiveHelper.getScrollEffectType()
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
