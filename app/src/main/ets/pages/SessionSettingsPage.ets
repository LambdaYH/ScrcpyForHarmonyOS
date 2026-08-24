import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { ClientSessionManager } from '../helper/ClientSessionManager';
import { LoggerClientSession } from '../helper/Logger';

@Entry
@Component
struct SessionSettingsPage {
  @StorageProp(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY)
  private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @State maxSessions: number = 3;
  private preferences: PreferencesHelper = PreferencesHelper.getInstance();
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void { void this.load(); }

  private async load(): Promise<void> {
    this.maxSessions = await this.preferences.getMaxRetainedSessions();
  }

  private async updateMax(delta: number): Promise<void> {
    const previous = this.maxSessions;
    this.maxSessions = Math.max(1, Math.min(6, this.maxSessions + delta));
    LoggerClientSession.info(`[SessionSettings] maxSessions ${previous} -> ${this.maxSessions}`);
    await this.save();
  }

  private async save(): Promise<void> {
    await this.preferences.saveMaxRetainedSessions(this.maxSessions);
    ClientSessionManager.getInstance().configure(this.maxSessions);
  }

  @Builder
  CounterRow(title: Resource, description: Resource) {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title).fontSize(16).fontWeight(FontWeight.Medium).fontColor($r('app.color.text_primary'))
        Text(description).fontSize(13).fontColor($r('app.color.text_secondary'))
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

      Row({ space: 18 }) {
        Stack() {
          Text('-').fontSize(20).fontColor('#FFFFFF')
        }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.btn_primary'))
          .opacity(this.maxSessions > 1 ? 1 : 0.4)
          .enabled(this.maxSessions > 1)
          .onClick((): void => {
            void this.updateMax(-1);
          })
        Text(`${this.maxSessions}`)
          .fontSize(20)
          .fontWeight(FontWeight.Medium)
          .width(36)
          .textAlign(TextAlign.Center)
        Stack() {
          Text('+').fontSize(20).fontColor('#FFFFFF')
        }
          .width(40)
          .height(40)
          .borderRadius(20)
          .backgroundColor($r('app.color.btn_primary'))
          .opacity(this.maxSessions < 6 ? 1 : 0.4)
          .enabled(this.maxSessions < 6)
          .onClick((): void => {
            void this.updateMax(1);
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.End)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
  }

  build() {
    HdsNavigation() {
      Scroll(this.scroller) {
        Column({ space: 12 }) {
          Blank().height(HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp)).width('100%')
          this.CounterRow(
            $r('app.string.max_retained_sessions'), $r('app.string.max_retained_sessions_desc'))
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(false)
    .hideToolBar(true)
    .titleBar(HdsImmersiveHelper.buildMiniTitleBarOptions($r('app.string.session_settings')))
    .bindToScrollable([this.scroller])
    .backgroundColor($r('app.color.bg_primary'))
  }
}
