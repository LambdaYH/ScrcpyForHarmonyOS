import { LengthMetrics } from '@kit.ArkUI';
import { DividerShowType, HdsNavigation, HdsNavigationTitleMode, ScrollEffectType, SystemMaterialParams } from '@kit.UIDesignKit';
import { common, Want } from '@kit.AbilityKit';
import { LoggerDeviceDetail } from '../helper/Logger';

interface ConfigItem {
  title: ResourceStr;
  desc: ResourceStr;
}

@Entry
@Component
struct ConfigDescPage {

  private openUrl(url: string) {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((err: Error) => {
      LoggerDeviceDetail.error('Failed to open URL:', err);
    });
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll() {
          Column({ space: 24 }) {

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
          mainTitle: $r('app.string.config_desc_title'),
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
