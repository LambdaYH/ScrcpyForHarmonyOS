import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { Logger } from '../helper/Logger';
import { UrlHelper } from '../helper/UrlHelper';
import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';

@Entry
@Component
struct FeedbackPage {
  @State isFileLoggingEnabled: boolean = Logger.isFileLoggingEnabled();
  @State private systemTopInsetVp: number = 0;
  private scroller: Scroller = new Scroller();
  private readonly surveyUri: string = 'https://ycnpnk66kngy.feishu.cn/share/base/form/shrcnfjGs1vppUxaCDwugqLWCEb';
  private readonly feedbackIssueUrl: string = 'https://github.com/LambdaYH/scrcpyHmos/issues/new';
  private readonly feedbackEmailUri: string = 'mailto:scrcpyHmos@outlook.com';

  aboutToAppear(): void {
    HdsImmersiveHelper.syncSystemTopInsetVp(this, (value: number): void => {
      this.systemTopInsetVp = value;
    });
  }

  private titleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  private getAbilityContext(): common.UIAbilityContext {
    return this.getUIContext().getHostContext() as common.UIAbilityContext;
  }

  private openUrl(url: string): void {
    UrlHelper.openUrl(this.getAbilityContext(), url);
  }

  private async handleExportLogs(): Promise<void> {
    await this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.export_logs_dialog_title'),
      message: $r('app.string.export_logs_hint'),
      buttons: [
        {
          text: $r('app.string.export_logs_dialog_confirm'),
          color: $r('app.color.btn_primary'),
        }
      ]
    });

    try {
      const content = await Logger.getLogContent();
      if (!content) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.export_logs_empty') });
      }

      const documentPicker = new picker.DocumentViewPicker();
      const saveOptions = new picker.DocumentSaveOptions();
      saveOptions.newFileNames = ['scrcpy_log_' + new Date().toISOString().slice(0, 10) + '.log'];
      const uris = await documentPicker.save(saveOptions);
      if (!uris || uris.length === 0) {
        return;
      }

      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
      fileIo.writeSync(file.fd, content);
      fileIo.closeSync(file);
      if (content) {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.export_logs_success') });
      }
    } catch (err) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.export_failed') });
    }
  }

  @Builder
  FeedbackButton(text: ResourceStr, onClick: () => void) {
    Button({ type: ButtonType.Normal, stateEffect: true }) {
      Row() {
        Text(text)
          .fontSize(16)
          .fontColor($r('app.color.text_primary'))

        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(18)
          .fontColor([$r('app.color.text_tertiary')])
      }
      .width('100%')
      .height(52)
      .justifyContent(FlexAlign.SpaceBetween)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
    .backgroundColor(Color.Transparent)
    .onClick(() => {
      onClick();
    })
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll(this.scroller) {
          Column({ space: 16 }) {
            Blank()
              .height(this.titleOverlayHeight())
              .width('100%')

            Column() {
              Row() {
                Text($r('app.string.file_logging'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.isFileLoggingEnabled })
                  .onChange((isOn: boolean) => {
                    this.isFileLoggingEnabled = isOn;
                    Logger.setFileLoggingEnabled(isOn);
                  })
                  .height(24)
              }
              .width('100%')
              .height(48)

              Button($r('app.string.export_logs'))
                .width('100%')
                .height(44)
                .fontSize(14)
                .type(ButtonType.Capsule)
                .enabled(this.isFileLoggingEnabled)
                .backgroundColor(this.isFileLoggingEnabled ? $r('app.color.btn_primary') : $r('app.color.text_tertiary'))
                .margin({ top: 8 })
                .onClick(() => {
                  this.handleExportLogs();
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)

            Column() {
              Text($r('app.string.feedback_card_title'))
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .margin({ bottom: 8 })

              this.FeedbackButton($r('app.string.survey'), () => {
                this.openUrl(this.surveyUri);
              })

              Divider().color($r('app.color.text_tertiary')).opacity(0.35)

              this.FeedbackButton($r('app.string.feedback_github_issue'), () => {
                this.openUrl(this.feedbackIssueUrl);
              })

              Divider().color($r('app.color.text_tertiary')).opacity(0.35)

              this.FeedbackButton($r('app.string.feedback_email'), () => {
                this.openUrl(this.feedbackEmailUri);
              })
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)

            Blank()
              .height(32)
          }
          .width('100%')
          .padding(16)
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .layoutWeight(1)
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
    .bindToScrollable([this.scroller])
    .titleBar(HdsImmersiveHelper.buildMiniTitleBarOptions($r('app.string.feedback')))
    .backgroundColor(Color.Transparent)
  }
}
