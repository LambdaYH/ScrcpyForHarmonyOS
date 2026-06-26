import { Device, ExtraParam } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { LoggerDeviceDetail } from '../helper/Logger';

import { util } from '@kit.ArkTS';
import { HdsNavigation, HdsNavigationTitleBarOptions, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';

@Component
struct SheetTitleBlurBackground {
  blurHeight: number = 70

  build() {
    Row()
      .width('100%')
      .height(this.blurHeight)
      .clip(true)
      .linearGradientBlur(8, {
        fractionStops: [[1, 0], [1, 0.33], [0, 0.66], [0, 1]],
        direction: GradientDirection.Bottom
      })
      .backgroundColor('#14FFFFFF')
      .hitTestBehavior(HitTestMode.None)
      .zIndex(1)
  }
}

@Component
struct SheetTitleSymbol {
  symbol: Resource = $r('sys.symbol.xmark')
  symbolSize: number = 22
  color: ResourceColor = $r('sys.color.icon_primary')

  build() {
    SymbolGlyph(this.symbol)
      .fontSize(this.symbolSize)
      .fontColor([this.color])
      .renderingStrategy(SymbolRenderingStrategy.SINGLE)
  }
}

@Component
struct GlassSheetTitle {
  title: ResourceStr = $r('app.string.add_device_title')
  onClose: () => void = () => {}

  build() {
    Stack({ alignContent: Alignment.Top }) {
      SheetTitleBlurBackground({ blurHeight: 70 })
      Row() {
        Text(this.title)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
          .layoutWeight(1)

        Button() {
          SheetTitleSymbol()
        }
        .width(42)
        .height(42)
        .backgroundColor($r('app.color.sheet_close_bg'))
        .borderRadius(21)
        .border({ width: 1, color: $r('app.color.sheet_close_border') })
        .onClick(this.onClose)
      }
      .width('100%')
      .height(70)
      .padding({ left: 18, right: 14, top: 8 })
      .alignItems(VerticalAlign.Center)
      .zIndex(2)
    }
    .width('100%')
    .height(70)
    .zIndex(2)
  }
}

@Entry
@Component
export struct DeviceDetail {
  embeddedMode: boolean = false;
  onFinish: () => void = () => {};
  @State device: Device = new Device('', 0);
  @State isEditMode: boolean = false;
  @State private systemTopInsetVp: number = 0;
  @State nameError: boolean = false;
  @State addressError: boolean = false;
  @State portError: boolean = false;
  @State maxFpsInput: string = '';
  @State maxVideoBitInput: string = '';
  private detailScroller: Scroller = new Scroller();
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();

  // 视频编码选项
  private videoCodecOptions: SelectOption[] = [
    { value: 'h264' },
    { value: 'h265' }
  ];

  // 旋转角度选项
  private rotationOptions: SelectOption[] = [
    { value: $r('app.string.rotation_0') },
    { value: $r('app.string.rotation_90') },
    { value: $r('app.string.rotation_180') },
    { value: $r('app.string.rotation_270') }
  ];

  // 音频编码选项
  private audioCodecOptions: SelectOption[] = [
    { value: 'opus' },
    { value: 'aac' },
    { value: 'flac' },
    { value: 'raw' }
  ];

  aboutToAppear() {
    if (this.embeddedMode) {
      this.initDefaultDevice();
      return;
    }
    HdsImmersiveHelper.syncSystemTopInsetVp(this, (value: number): void => {
      this.systemTopInsetVp = value;
    });
    try {
      const params = this.getUIContext().getRouter().getState().params as Record<string, Object>;
      if (params && params['device']) {
        this.device = params['device'] as Device;
        this.isEditMode = true;
        this.syncVideoInputsFromDevice();
      } else {
        this.initDefaultDevice();
      }
    } catch (e) {
      LoggerDeviceDetail.error('Failed to get router params:', e);
      // 默认为新设备
      this.initDefaultDevice();
    }
  }

  private initDefaultDevice(): void {
    // 生成UUID
    this.device.uuid = util.generateRandomUUID(true);
    // 新增设备默认参数
    this.device.maxFps = 60;
    this.device.maxVideoBit = 4_000_000;
    this.syncVideoInputsFromDevice();

    // 生成时间戳 YYYYMMDDHHmm
    const now = new Date();
    const timestamp = `${now.getFullYear()}${String(now.getMonth() + 1).padStart(2, '0')}${String(now.getDate()).padStart(2, '0')}${String(now.getHours()).padStart(2, '0')}${String(now.getMinutes()).padStart(2, '0')}`;

    try {
      const baseName = this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.new_device').id);
      this.device.name = `${baseName} ${timestamp}`;
    } catch (e) {
      this.device.name = `New Device ${timestamp}`;
    }
  }

  private syncVideoInputsFromDevice(): void {
    this.maxFpsInput = this.device.maxFps > 0 ? this.device.maxFps.toString() : '';
    this.maxVideoBitInput = this.device.maxVideoBit > 0 ? this.device.maxVideoBit.toString() : '';
  }

  private detailTitleOverlayHeight(): number {
    return this.embeddedMode
      ? 70
      : HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  private buildDetailTitleBarOptions(): HdsNavigationTitleBarOptions {
    return HdsImmersiveHelper.buildMiniTitleBarOptions(
      this.isEditMode ? $r('app.string.edit_device') : $r('app.string.add_device_title')
    );
  }

  @Builder
  private DeviceFormContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      Scroll(this.detailScroller) {
        Column({ space: 16 }) {
          Blank()
            .height(this.detailTitleOverlayHeight())
            .width('100%')

          // 基本信息
          Column({ space: 8 }) {
            Row() {
              Text($r('app.string.device_name'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text(' *')
                .fontSize(14)
                .fontColor(Color.Red)
            }
            TextInput({ text: this.device.name })
              .borderColor(this.nameError ? Color.Red : $r('sys.color.ohos_id_color_component_normal'))
              .borderWidth(this.nameError ? 2 : 0)
              .onChange((value: string) => {
                this.device.name = value;
                if (value.trim()) {
                  this.nameError = false;
                }
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Column({ space: 8 }) {
            Row() {
              Text($r('app.string.device_address'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text(' *')
                .fontSize(14)
                .fontColor(Color.Red)
            }
            TextInput({ text: this.device.address, placeholder: '127.0.0.1' })
              .borderColor(this.addressError ? Color.Red : $r('sys.color.ohos_id_color_component_normal'))
              .borderWidth(this.addressError ? 2 : 0)
              .onChange((value: string) => {
                this.device.address = value;
                if (value.trim()) {
                  this.addressError = false;
                }
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Column({ space: 8 }) {
            Row() {
              Text($r('app.string.device_adb_port'))
                .fontSize(14)
                .fontColor($r('app.color.text_secondary'))
              Text(' *')
                .fontSize(14)
                .fontColor(Color.Red)
            }
            TextInput({ 
              text: this.device.adbPort > 0 ? this.device.adbPort.toString() : '', 
              placeholder: '5555' 
            })
              .type(InputType.Number)
              .borderColor(this.portError ? Color.Red : $r('sys.color.ohos_id_color_component_normal'))
              .borderWidth(this.portError ? 2 : 0)
              .onChange((value: string) => {
                if (value === '') {
                  this.device.adbPort = 0;
                } else {
                  const num = parseInt(value);
                  this.device.adbPort = isNaN(num) ? 0 : num;
                }
                if (value.trim() && parseInt(value) > 0) {
                  this.portError = false;
                }
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          Row() {
            Text($r('app.string.show_bottom_nav_bar'))
            Toggle({ type: ToggleType.Switch, isOn: this.device.showBottomNavBar })
              .onChange((isOn: boolean) => {
                this.device.showBottomNavBar = isOn;
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)

          Row() {
            Text($r('app.string.auto_switch_orientation'))
            Toggle({ type: ToggleType.Switch, isOn: this.device.autoSwitchOrientation })
              .onChange((isOn: boolean) => {
                this.device.autoSwitchOrientation = isOn;
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)

          Row() {
            Text($r('app.string.keep_screen_on_while_connected'))
            Toggle({ type: ToggleType.Switch, isOn: this.device.keepScreenOnWhileConnected })
              .onChange((isOn: boolean) => {
                this.device.keepScreenOnWhileConnected = isOn;
              })
          }
          .width('100%')
          .justifyContent(FlexAlign.SpaceBetween)

          Column({ space: 8 }) {
            Text($r('app.string.file_receive_default_path'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
            TextInput({
              text: this.device.fileReceivePath,
              placeholder: $r('app.string.file_receive_default_path_hint')
            })
              .onChange((value: string) => {
                this.device.fileReceivePath = value;
              })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')

          // 视频设置
          Column({ space: 12 }) {
            Text($r('app.string.video_settings'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.video_codec'))
                .layoutWeight(1)
              Select(this.videoCodecOptions)
                .selected(this.getVideoCodecIndex())
                .value(this.device.videoCodec.toUpperCase())
                .onSelect((index: number) => {
                  this.device.videoCodec = this.videoCodecOptions[index].value as string;
                })
            }
            .width('100%')

            Row() {
              Text($r('app.string.max_size'))
                .layoutWeight(1)
              TextInput({ text: this.device.maxSize ? this.device.maxSize.toString() : '', placeholder: $r('app.string.default_value') })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  const num = parseInt(value);
                  this.device.maxSize = isNaN(num) ? 0 : num;
                })
            }
            .width('100%')

            Row() {
              Text($r('app.string.max_fps'))
                .layoutWeight(1)
              TextInput({ text: this.maxFpsInput, placeholder: $r('app.string.default_value') })
                .type(InputType.Number)
                .width(100)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.maxFpsInput = value;
                  if (!value.trim()) {
                    this.device.maxFps = 0;
                    return;
                  }
                  const num = parseInt(value);
                  if (!isNaN(num)) {
                    this.device.maxFps = num;
                  }
                })
            }
            .width('100%')

            Row() {
              Text($r('app.string.bitrate'))
                .layoutWeight(1)
              TextInput({ text: this.maxVideoBitInput, placeholder: $r('app.string.default_value') })
                .type(InputType.Number)
                .width(120)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.maxVideoBitInput = value;
                  if (!value.trim()) {
                    this.device.maxVideoBit = 0;
                    return;
                  }
                  const num = parseInt(value);
                  if (!isNaN(num)) {
                    this.device.maxVideoBit = num;
                  }
                })
            }
            .width('100%')

            Row() {
              Text($r('app.string.crop'))
                .layoutWeight(1)
              TextInput({ text: this.device.crop, placeholder: $r('app.string.crop_placeholder') })
                .width(150)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  this.device.crop = value;
                })
            }
            .width('100%')

            Row() {
              Text($r('app.string.display_id'))
                .layoutWeight(1)
              TextInput({ text: this.device.displayId ? this.device.displayId.toString() : '', placeholder: $r('app.string.default_value') })
                .type(InputType.Number)
                .width(80)
                .textAlign(TextAlign.End)
                .onChange((value: string) => {
                  const num = parseInt(value);
                  this.device.displayId = isNaN(num) ? 0 : num;
                })
            }
            .width('100%')

            Row() {
              Column() {
                Text($r('app.string.config_screen_rotation_title'))
                  .width('100%')
                Text($r('app.string.config_screen_rotation_desc'))
                  .fontSize(12)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Select(this.rotationOptions)
                .selected(this.getRotationIndex())
                .value(this.getRotationString(this.device.captureOrientation))
                .onSelect((index: number) => {
                  const orientations = [-1, 90, 180, 270];
                  this.device.captureOrientation = orientations[index];
                })
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 音频设置
          Column({ space: 12 }) {
            Text($r('app.string.audio_settings'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.enable_audio'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.isAudio })
                .onChange((isOn: boolean) => {
                  this.device.isAudio = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            if (this.device.isAudio) {
              Row() {
                Text($r('app.string.audio_codec'))
                  .layoutWeight(1)
                Select(this.audioCodecOptions)
                  .selected(this.getAudioCodecIndex())
                  .value(this.device.audioCodec.toUpperCase())
                  .onSelect((index: number) => {
                    this.device.audioCodec = this.audioCodecOptions[index].value as string;
                  })
              }
              .width('100%')

              Row() {
                Text($r('app.string.audio_bitrate'))
                  .layoutWeight(1)
                TextInput({ text: this.device.maxAudioBit ? this.device.maxAudioBit.toString() : '', placeholder: $r('app.string.default_value') })
                  .type(InputType.Number)
                  .width(120)
                  .textAlign(TextAlign.End)
                  .onChange((value: string) => {
                    const num = parseInt(value);
                    this.device.maxAudioBit = isNaN(num) ? 0 : num;
                  })
              }
              .width('100%')
            }
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 行为设置
          Column({ space: 12 }) {
            Text($r('app.string.behavior_settings'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.show_touches'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.showTouches })
                .onChange((isOn: boolean) => {
                  this.device.showTouches = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.stay_awake'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.stayAwake })
                .onChange((isOn: boolean) => {
                  this.device.stayAwake = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.clipboard_autosync'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.clipboardAutosync })
                .onChange((isOn: boolean) => {
                  this.device.clipboardAutosync = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 连接时操作
          Column({ space: 12 }) {
            Text($r('app.string.connection_actions'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.turn_screen_on'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.wakeOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.wakeOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.turn_screen_off'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.lightOffOnConnect })
                .onChange((isOn: boolean) => {
                  this.device.lightOffOnConnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 断开时操作
          Column({ space: 12 }) {
            Text($r('app.string.disconnection_actions'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.turn_screen_off_on_close'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.powerOffScreenOnClose })
                .onChange((isOn: boolean) => {
                  this.device.powerOffScreenOnClose = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.auto_reconnect'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.autoReconnect })
                .onChange((isOn: boolean) => {
                  this.device.autoReconnect = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 高级选项
          Column({ space: 12 }) {
            Text($r('app.string.advanced_options'))
              .fontSize(16)
              .fontWeight(FontWeight.Medium)

            Row() {
              Text($r('app.string.downsize_on_error'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.downsizeOnError })
                .onChange((isOn: boolean) => {
                  this.device.downsizeOnError = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.force_adb_forward'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.forceAdbForward })
                .onChange((isOn: boolean) => {
                  this.device.forceAdbForward = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.force_physical_keyboard'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.forcePhysicalKeyboard })
                .onChange((isOn: boolean) => {
                  this.device.forcePhysicalKeyboard = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.connect_on_start'))
              Toggle({ type: ToggleType.Switch, isOn: this.device.connectOnStart })
                .onChange((isOn: boolean) => {
                  this.device.connectOnStart = isOn;
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)

            Row() {
              Text($r('app.string.server_log_level'))
                .layoutWeight(1)
              Select([
                { value: 'verbose' },
                { value: 'debug' },
                { value: 'info' },
                { value: 'warn' },
                { value: 'error' }
              ])
                .selected(['verbose', 'debug', 'info', 'warn', 'error'].indexOf(this.device.logLevel))
                .value(this.device.logLevel)
                .onSelect((index: number) => {
                  const levels = ['verbose', 'debug', 'info', 'warn', 'error'];
                  this.device.logLevel = levels[index];
                })
                .width(100)
            }
            .width('100%')
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)

          // 额外参数
          Column({ space: 12 }) {
            Row() {
              Text($r('app.string.extra_params'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
              
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.plus'))
                  .fontSize(20)
                  .fontColor([$r('sys.color.ohos_id_color_text_primary_contrary')])
                  .renderingStrategy(SymbolRenderingStrategy.SINGLE)
              }
              .width(32)
              .height(32)
              .backgroundColor($r('app.color.btn_primary'))
              .onClick(() => {
                const newParam: ExtraParam = { key: '', value: '' };
                this.device.extraParams.push(newParam);
                this.device.extraParams = [...this.device.extraParams]; // trigger re-render
              })
            }
            .width('100%')

            Text($r('app.string.extra_params_hint'))
              .fontSize(12)
              .fontColor($r('app.color.text_tertiary'))
              .width('100%')

            ForEach(this.device.extraParams, (param: ExtraParam, index: number) => {
              Row({ space: 8 }) {
                TextInput({ text: param.key, placeholder: $r('app.string.param_name') })
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.extraParams[index].key = value;
                  })
                
                Text('=')
                  .fontSize(16)
                  .fontColor($r('app.color.text_secondary'))
                
                TextInput({ text: param.value, placeholder: $r('app.string.param_value') })
                  .layoutWeight(1)
                  .onChange((value: string) => {
                    this.device.extraParams[index].value = value;
                  })
                
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.minus'))
                  .fontSize(18)
                  .fontColor([$r('app.color.icon_red')])
                }
                .width(32)
                .height(32)
                .backgroundColor($r('app.color.bg_action_red'))
                .onClick(() => {
                  this.device.extraParams.splice(index, 1);
                  this.device.extraParams = [...this.device.extraParams]; // trigger re-render
                })
              }
              .width('100%')
            }, (param: ExtraParam, index: number) => `${index}`)
          }
          .width('100%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(8)
        }
        .padding({
          left: 16,
          right: 16,
          top: this.embeddedMode ? 8 : 16,
          bottom: 88
        })
      }
      .width('100%')
      .height('100%')
      .edgeEffect(EdgeEffect.Spring) // 添加下拉/上拉回弹效果

      // 底部按钮
      Row({ space: 16 }) {
        if (this.isEditMode) {
          Button($r('app.string.delete'), { type: ButtonType.Capsule, stateEffect: true })
            .fontSize(16)
            .backgroundColor($r('app.color.btn_danger_bg'))
            .fontColor($r('app.color.btn_danger_text'))
            .width(120)
            .height(44)
            .onClick(() => {
              this.deleteDevice();
            })
        }

        Button($r('app.string.device_button'), { type: ButtonType.Capsule, stateEffect: true })
          .fontSize(16)
          .backgroundColor($r('app.color.btn_primary'))
          .width(120)
          .height(44)
          .layoutWeight(1)
          .onClick(() => {
            this.saveDevice();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 16 + 24 })
      .backgroundColor(Color.Transparent)
    }
    .layoutWeight(1)
    .width('100%')
  }

  build() {
    if (this.embeddedMode) {
      Stack({ alignContent: Alignment.Top }) {
        this.DeviceFormContent()
        GlassSheetTitle({
          title: $r('app.string.add_device_title'),
          onClose: (): void => {
            this.closePage();
          }
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    } else {
      HdsNavigation() {
        Column() {
          this.DeviceFormContent()
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
      .titleBar(this.buildDetailTitleBarOptions())
      .bindToScrollable([this.detailScroller])
      .backgroundColor(Color.Transparent)
    }
  }

  getVideoCodecIndex(): number {
    const index = this.videoCodecOptions.findIndex(opt => opt.value === this.device.videoCodec);
    return index >= 0 ? index : 0;
  }

  getRotationIndex(): number {
    const orientations = [-1, 90, 180, 270];
    const index = orientations.indexOf(this.device.captureOrientation);
    return index >= 0 ? index : 0;
  }

  getRotationString(orientation: number): ResourceStr {
    if (orientation === 90) return $r('app.string.rotation_90');
    if (orientation === 180) return $r('app.string.rotation_180');
    if (orientation === 270) return $r('app.string.rotation_270');
    return $r('app.string.rotation_0');
  }

  getAudioCodecIndex(): number {
    const index = this.audioCodecOptions.findIndex(opt => opt.value === this.device.audioCodec);
    return index >= 0 ? index : 0;
  }

  private closePage(): void {
    if (this.embeddedMode) {
      this.onFinish();
      return;
    }
    this.getUIContext().getRouter().back();
  }

  async saveDevice() {
    // Reset errors
    this.nameError = false;
    this.addressError = false;
    this.portError = false;

    // Validate required fields
    let hasError = false;
    
    if (!this.device.name || !this.device.name.trim()) {
      this.nameError = true;
      hasError = true;
    }
    
    if (!this.device.address || !this.device.address.trim()) {
      this.addressError = true;
      hasError = true;
    }
    
    if (!this.device.adbPort || this.device.adbPort <= 0) {
      this.portError = true;
      hasError = true;
    }

    if (hasError) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.fill_complete_info') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
      return;
    }

    try {
      if (this.isEditMode) {
        await this.preferencesHelper.update(this.device);
      } else {
        await this.preferencesHelper.insert(this.device);
      }
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_success') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
      this.closePage();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
    }
  }

  async deleteDevice() {
    try {
      await this.preferencesHelper.delete(this.device.uuid);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_success') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
      this.closePage();
    } catch (err) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
      } catch (e) {
        LoggerDeviceDetail.error('Show toast failed:', e);
      }
    }
  }
}
