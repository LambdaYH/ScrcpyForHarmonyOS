import { common, Want } from '@kit.AbilityKit';
import { LoggerDeviceDetail } from '../helper/Logger';

interface ConfigItem {
  title: ResourceStr;
  desc: ResourceStr;
}

@Entry
@Component
struct HelpPage {
  @State private selectedTab: number = 0;

  private openUrl(url: string) {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: url
    };
    context.startAbility(want).catch((err: Error) => {
      LoggerDeviceDetail.error('Failed to open URL:', err);
    });
  }

  build() {
    Column() {
      Row() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.arrow_left'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .width(40)
        .height(40)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.getUIContext().getRouter().back();
        })
        .margin({ right: 12 })

        Text($r('app.string.help_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 12, right: 24, top: 38 })
      .alignItems(VerticalAlign.Center)

      this.TabBar()

      Scroll() {
        Column() {
          if (this.selectedTab === 0) {
            this.UsageTab()
          } else if (this.selectedTab === 1) {
            this.ConfigTab()
          } else {
            this.FabTab()
          }
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  private TabBar() {
    Row({ space: 8 }) {
      this.TabButton(0, $r('app.string.help_tab_usage'))
      this.TabButton(1, $r('app.string.help_tab_config'))
      this.TabButton(2, $r('app.string.help_tab_fab'))
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 8 })
  }

  @Builder
  private TabButton(index: number, title: ResourceStr) {
    Button() {
      Text(title)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.selectedTab === index ? '#FFFFFF' : $r('app.color.text_primary'))
    }
    .type(ButtonType.Capsule)
    .layoutWeight(1)
    .height(36)
    .backgroundColor(this.selectedTab === index ? $r('app.color.btn_primary') : $r('app.color.btn_secondary'))
    .onClick(() => {
      this.selectedTab = index;
    })
  }

  @Builder
  private UsageTab() {
    Column() {
      Text($r('app.string.help_intro'))
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .fontWeight(FontWeight.Bold)
        .width('100%')
        .textAlign(TextAlign.Start)
        .lineHeight(24)
        .margin({ bottom: 12 })

      Text($r('app.string.help_feature'))
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(24)
        .margin({ bottom: 24 })

      Text($r('app.string.help_usage_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 12 })
        .width('100%')

      Text($r('app.string.help_controlled_end'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8, top: 4 })
        .width('100%')

      Text($r('app.string.help_tcpip_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 8, top: 4 })
        .width('100%')

      this.InstructionItem(1, $r('app.string.help_step_1'))
      this.InstructionItem(2, $r('app.string.help_step_2'))
      this.InstructionItem(3, $r('app.string.help_step_3'))

      Text($r('app.string.help_note'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ top: 4, bottom: 12 })
        .width('100%')

      Text($r('app.string.help_wireless_pairing_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 8, top: 12 })
        .width('100%')

      this.InstructionItem(1, $r('app.string.help_wireless_controlled_step_1'))
      this.InstructionItem(2, $r('app.string.help_wireless_controlled_step_2'))

      Text($r('app.string.help_control_end'))
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 8, top: 8 })
        .width('100%')

      Text($r('app.string.help_tcpip_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 8, top: 4 })
        .width('100%')

      this.InstructionItem(1, $r('app.string.help_step_4'))

      Text($r('app.string.help_wireless_pairing_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 8, top: 12 })
        .width('100%')

      this.InstructionItem(1, $r('app.string.help_wireless_control_step_1'))
      this.InstructionItem(2, $r('app.string.help_wireless_control_step_2'))
      this.InstructionItem(3, $r('app.string.help_wireless_control_step_3'))
    }
    .width('100%')
  }

  @Builder
  private ConfigTab() {
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
        { title: $r('app.string.config_turn_screen_off_connect_title'), desc: $r('app.string.config_turn_screen_off_connect_desc') }
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
  }

  @Builder
  private FabTab() {
    Column() {
      Text($r('app.string.help_fab_intro'))
        .fontSize(15)
        .lineHeight(22)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')
        .margin({ bottom: 16 })

      this.HelpDescSection('back', $r('app.string.help_fab_back_title'), $r('app.string.help_fab_back_desc'))
      this.HelpDescSection('home', $r('app.string.help_fab_home_title'), $r('app.string.help_fab_home_desc'))
      this.HelpDescSection('recent', $r('app.string.help_fab_recent_title'), $r('app.string.help_fab_recent_desc'))
      this.HelpDescSection('rotate', $r('app.string.help_fab_rotate_title'), $r('app.string.help_fab_rotate_desc'))
      this.HelpDescSection('clipboard', $r('app.string.help_fab_clipboard_title'), $r('app.string.help_fab_clipboard_desc'))
      this.HelpDescSection('file', $r('app.string.help_fab_send_file_title'), $r('app.string.help_fab_send_file_desc'))
      this.HelpDescSection('install', $r('app.string.help_fab_install_title'), $r('app.string.help_fab_install_desc'))
      this.HelpDescSection('disconnect', $r('app.string.help_fab_disconnect_title'), $r('app.string.help_fab_disconnect_desc'))
    }
    .width('100%')
  }

  @Builder
  private HelpDescSection(iconType: string, title: ResourceStr, desc: ResourceStr) {
    Row({ space: 12 }) {
      this.FabIcon(iconType)

      Column() {
        Text(title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .margin({ bottom: 4 })

        Text(desc)
          .fontSize(14)
          .fontColor($r('app.color.text_secondary'))
          .lineHeight(20)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .margin({ bottom: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  private FabIcon(iconType: string) {
    Row() {
      if (iconType === 'back') {
        SymbolGlyph($r('sys.symbol.arrow_left'))
          .fontSize(22)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'home') {
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'recent') {
        SymbolGlyph($r('sys.symbol.square'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'rotate') {
        SymbolGlyph($r('sys.symbol.rectangle_rotate'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'disconnect') {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'file') {
        SymbolGlyph($r('sys.symbol.arrow_right_folder_circle'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'install') {
        SymbolGlyph($r('sys.symbol.more'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else if (iconType === 'clipboard') {
        SymbolGlyph($r('sys.symbol.plus_square'))
          .fontSize(20)
          .fontColor(['#FFFFFF'])
      } else {
        Text('?')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#FFFFFF')
      }
    }
    .width(44)
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#80000000')
    .borderRadius(22)
  }

  @Builder
  private InstructionItem(index: number, text: ResourceStr) {
    Row() {
      Text(`${index}. `)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(24)
        .alignSelf(ItemAlign.Start)
      Text(text)
        .fontSize(16)
        .fontColor($r('app.color.text_primary'))
        .lineHeight(24)
        .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .margin({ bottom: 8 })
  }

  @Builder
  private ConfigSection(title: ResourceStr, items: ConfigItem[]) {
    Column() {
      Text(title)
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 12 })
        .width('100%')

      ForEach(items, (item: ConfigItem) => {
        Column() {
          Text(item.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .margin({ bottom: 4 })
            .width('100%')

          Text(item.desc)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .lineHeight(20)
            .width('100%')
        }
        .margin({ bottom: 16 })
        .alignItems(HorizontalAlign.Start)
      })
    }
    .width('100%')
  }
}
