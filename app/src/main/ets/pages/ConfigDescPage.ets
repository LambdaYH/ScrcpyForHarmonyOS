import { HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { common } from '@kit.AbilityKit';
import { UrlHelper } from '../helper/UrlHelper';

interface ConfigItem {
  title: ResourceStr;
  desc: ResourceStr;
}

@Entry
@Component
struct ConfigDescPage {
  @State private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  private configScroller: Scroller = new Scroller();

  private openUrl(url: string) {
    UrlHelper.openUrl(this.getUIContext().getHostContext() as common.UIAbilityContext, url);
  }

  aboutToAppear(): void {
    HdsImmersiveHelper.syncSystemTopInsetVp(this, (value: number): void => {
      this.systemTopInsetVp = value;
    });
  }

  private configTitleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll(this.configScroller) {
          Column({ space: 24 }) {
            Blank()
              .height(this.configTitleOverlayHeight())
              .width('100%')

            Column() {
              Text($r('app.string.help_config_ref'))
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .margin({ bottom: 8 })

              Text('https://github.com/Genymobile/scrcpy?tab=readme-ov-file')
                .fontSize(14)
                .fontColor($r('app.color.btn_primary'))
                .width('100%')
                .onClick(() => {
                  this.openUrl('https://github.com/Genymobile/scrcpy?tab=readme-ov-file');
                })
            }
            .width('100%')

            this.ConfigSection($r('app.string.config_display_settings'), [
              { title: $r('app.string.config_show_bottom_nav_bar_title'), desc: $r('app.string.config_show_bottom_nav_bar_desc') },
              { title: $r('app.string.config_auto_switch_orientation_title'), desc: $r('app.string.config_auto_switch_orientation_desc') },
              { title: $r('app.string.config_keep_screen_on_connected_title'), desc: $r('app.string.config_keep_screen_on_connected_desc') }
            ] as ConfigItem[])

            this.ConfigSection($r('app.string.config_video_settings'), [
              { title: $r('app.string.config_video_codec_title'), desc: $r('app.string.config_video_codec_desc') },
              { title: $r('app.string.config_max_size_title'), desc: $r('app.string.config_max_size_desc') },
              { title: $r('app.string.config_bitrate_title'), desc: $r('app.string.config_bitrate_desc') },
              { title: $r('app.string.config_max_fps_title'), desc: $r('app.string.config_max_fps_desc') },
              { title: $r('app.string.config_crop_title'), desc: $r('app.string.config_crop_desc') }
            ] as ConfigItem[])

            this.ConfigSection($r('app.string.config_audio_settings'), [
              { title: $r('app.string.config_enable_audio_title'), desc: $r('app.string.config_enable_audio_desc') },
              { title: $r('app.string.config_audio_codec_title'), desc: $r('app.string.config_audio_codec_desc') },
              { title: $r('app.string.config_audio_bitrate_title'), desc: $r('app.string.config_audio_bitrate_desc') }
            ] as ConfigItem[])

            this.ConfigSection($r('app.string.config_behavior_settings'), [
              { title: $r('app.string.config_show_touches_title'), desc: $r('app.string.config_show_touches_desc') },
              { title: $r('app.string.config_stay_awake_title'), desc: $r('app.string.config_stay_awake_desc') },
              { title: $r('app.string.config_clipboard_title'), desc: $r('app.string.config_clipboard_desc') }
            ] as ConfigItem[])

            this.ConfigSection($r('app.string.config_connection_actions'), [
              { title: $r('app.string.config_turn_screen_on_connect_title'), desc: $r('app.string.config_turn_screen_on_connect_desc') },
              { title: $r('app.string.config_turn_screen_off_connect_title'), desc: $r('app.string.config_turn_screen_off_connect_desc') },
            ] as ConfigItem[])

            this.ConfigSection($r('app.string.config_disconnection_actions'), [
              { title: $r('app.string.config_turn_screen_off_close_title'), desc: $r('app.string.config_turn_screen_off_close_desc') }
            ] as ConfigItem[])

            this.ConfigSection($r('app.string.config_advanced_options'), [
              { title: $r('app.string.config_downsize_error_title'), desc: $r('app.string.config_downsize_error_desc') },
              { title: $r('app.string.config_force_adb_forward_title'), desc: $r('app.string.config_force_adb_forward_desc') },
              { title: $r('app.string.config_connect_start_title'), desc: $r('app.string.config_connect_start_desc') },
              { title: $r('app.string.config_server_log_title'), desc: $r('app.string.config_server_log_desc') }
            ] as ConfigItem[])

          }
          .width('100%')
          .padding(16)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
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
    .bindToScrollable([this.configScroller])
    .titleBar(HdsImmersiveHelper.buildMiniTitleBarOptions($r('app.string.config_desc_title'), '#1AFFFFFF', '#1AFFFFFF'))
    .backgroundColor(Color.Transparent)
  }

  @Builder
  ConfigSection(title: ResourceStr, items: ConfigItem[]) {
    Column() {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 12 })
        .width('100%')

      ForEach(items, (item: ConfigItem) => {
        Column() {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.info_circle'))
              .fontSize(14)
              .fontColor([$r('app.color.btn_primary')])

            Text(item.title)
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
          }
          .padding({ left: 12, right: 16, top: 6, bottom: 6 })
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(16)

          Text(item.desc)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(20)
            .width('100%')
            .margin({ top: 8 })
        }
        .margin({ bottom: 16 })
        .alignItems(HorizontalAlign.Start)
      })
    }
    .width('100%')
  }
}
