import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { PreferencesHelper } from '../helper/PreferencesHelper';

@Entry
@Component
struct BackgroundKeepAlivePage {
  @StorageProp(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY)
  private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @State backgroundKeepAliveEnabled: boolean = true;
  private preferences: PreferencesHelper = PreferencesHelper.getInstance();
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    void this.load();
  }

  private async load(): Promise<void> {
    this.backgroundKeepAliveEnabled = await this.preferences.getBackgroundKeepAliveEnabled();
  }

  private async update(enabled: boolean): Promise<void> {
    this.backgroundKeepAliveEnabled = enabled;
    await this.preferences.saveBackgroundKeepAliveEnabled(enabled);
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll(this.scroller) {
          Column({ space: 16 }) {
            Blank()
              .height(HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp))
              .width('100%')

            Column({ space: 8 }) {
              Row() {
                Text($r('app.string.background_keep_alive'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)

                Toggle({ type: ToggleType.Switch, isOn: this.backgroundKeepAliveEnabled })
                  .height(24)
                  .onChange((enabled: boolean): void => {
                    void this.update(enabled);
                  })
              }
              .width('100%')
              .height(48)

              Text($r('app.string.background_keep_alive_desc'))
                .width('100%')
                .fontSize(13)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding(16)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(12)
          }
          .height('100%')
          .width('100%')
          .padding(16)
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
    .bindToScrollable([this.scroller])
    .titleBar(HdsImmersiveHelper.buildMiniTitleBarOptions($r('app.string.background_keep_alive')))
    .backgroundColor(Color.Transparent)
  }
}
