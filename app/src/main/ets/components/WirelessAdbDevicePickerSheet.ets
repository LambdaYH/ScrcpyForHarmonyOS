import { Device } from '../entity/Device';
import { formatWirelessAdbHostPort, normalizeWirelessAdbAddress } from '../helper/WirelessAdbPairingUtils';

@Component
export struct WirelessAdbDevicePickerSheet {
  @Prop connectHost: string = '';
  @Prop connectPort: string = '';
  @Prop devices: Device[] = [];
  @Prop pairedHost: string = '';
  @Prop portDiscoveryStatus: number = 0;
  @Prop hidePortDiscoveryStatus: boolean = false;
  @Prop hideDescription: boolean = false;
  sheetScroller: Scroller = new Scroller();
  onConnectHostChange: (value: string) => void = () => {};
  onConnectPortChange: (value: string) => void = () => {};
  onConnectDevice: (device: Device) => void = () => {};
  onDefaultConnect: () => void = () => {};
  onSaveAsNewDevice: () => void = () => {};
  onRetryDiscoverPort: () => void = () => {};

  private isSuggestedDevice(device: Device): boolean {
    if (!this.pairedHost.trim()) {
      return false;
    }
    return normalizeWirelessAdbAddress(device.address) === normalizeWirelessAdbAddress(this.pairedHost);
  }

  private getSortedDevices(): Device[] {
    const matchedDevices: Device[] = [];
    const otherDevices: Device[] = [];
    for (const device of this.devices) {
      if (this.isSuggestedDevice(device)) {
        matchedDevices.push(device);
      } else {
        otherDevices.push(device);
      }
    }
    return [...matchedDevices, ...otherDevices];
  }

  private hasSuggestedDevices(): boolean {
    return this.devices.some((device) => this.isSuggestedDevice(device));
  }

  private getPortDiscoveryText(): ResourceStr {
    if (this.portDiscoveryStatus === 1) {
      return $r('app.string.wireless_adb_pairing_port_discovering');
    }
    if (this.portDiscoveryStatus === 2) {
      return $r('app.string.wireless_adb_pairing_port_discovered');
    }
    if (this.portDiscoveryStatus === 3) {
      return $r('app.string.wireless_adb_pairing_port_discover_failed');
    }
    return '';
  }

  private getPortDiscoveryColor(): ResourceColor {
    if (this.portDiscoveryStatus === 1) {
      return '#D99A00';
    }
    if (this.portDiscoveryStatus === 2) {
      return '#18A058';
    }
    if (this.portDiscoveryStatus === 3) {
      return '#E64545';
    }
    return $r('app.color.text_secondary');
  }

  @Builder
  private PortDiscoveryStatusRow() {
    if (this.portDiscoveryStatus !== 0 && !this.hidePortDiscoveryStatus) {
      Row({ space: 6 }) {
        if (this.portDiscoveryStatus === 1) {
          LoadingProgress()
            .width(14)
            .height(14)
            .color(this.getPortDiscoveryColor())
        } else if (this.portDiscoveryStatus === 2) {
          SymbolGlyph($r('sys.symbol.checkmark'))
            .fontSize(14)
            .fontColor([this.getPortDiscoveryColor()])
        } else {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(15)
            .fontColor([this.getPortDiscoveryColor()])
        }

        Text(this.getPortDiscoveryText())
          .fontSize(13)
          .fontColor(this.getPortDiscoveryColor())
          .layoutWeight(1)

        if (this.portDiscoveryStatus === 3) {
          Button($r('app.string.wireless_adb_pairing_port_discover_retry'))
            .height(28)
            .padding({ left: 12, right: 12 })
            .fontSize(12)
            .fontColor($r('app.color.btn_primary'))
            .backgroundColor('#124A7BFF')
            .borderRadius(14)
            .onClick(() => {
              this.onRetryDiscoverPort();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  private DeviceItem(device: Device) {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row({ space: 12 }) {
          Column({ space: 4 }) {
            Text(device.name)
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })

            Text(formatWirelessAdbHostPort(device.address, device.adbPort))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Button($r('app.string.wireless_adb_pairing_device_sheet_use'))
            .fontSize(14)
            .padding({ left: 16, right: 16 })
            .height(36)
            .backgroundColor($r('app.color.btn_primary'))
            .fontColor('#FFFFFF')
            .onClick(() => {
              this.onConnectDevice(device);
            })
        }
        .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(12)
      .border({
        width: this.isSuggestedDevice(device) ? 2 : 1,
        color: this.isSuggestedDevice(device) ? '#4A7BFF' : '#12000000'
      })
      .onClick(() => {
        this.onConnectDevice(device);
      })

      if (this.isSuggestedDevice(device)) {
        Stack({ alignContent: Alignment.Center }) {
          Text($r('app.string.wireless_adb_pairing_device_sheet_matched'))
            .fontSize(10)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(1)
            .textAlign(TextAlign.Center)
        }
        .width(68)
        .height(20)
        .backgroundColor('#4A7BFF')
        .borderRadius(4)
        .shadow({
          radius: 6,
          color: '#334A7BFF',
          offsetX: 1,
          offsetY: 2
        })
        .rotate({ angle: -47 })
        .offset({ x: -17, y: 7 })
      }
    }
    .width('100%')
    .clip(true)
  }

  build() {
    Scroll(this.sheetScroller) {
      Column({ space: 16 }) {
        Column({ space: 10 }) {
          if (!this.hideDescription) {
            Text($r('app.string.wireless_adb_pairing_nearby_devices_desc'))
              .width('100%')
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
        }

        this.PortDiscoveryStatusRow()

        Row({ space: 10 }) {
          Column({ space: 8 }) {
            Text($r('app.string.wireless_adb_pairing_connect_host_label'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            TextInput({ placeholder: $r('app.string.wireless_adb_pairing_connect_host_hint'), text: this.connectHost })
              .type(InputType.Normal)
              .height(48)
              .fontSize(14)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(24)
              .caretColor($r('app.color.btn_primary'))
              .onChange((value: string) => {
                this.onConnectHostChange(value);
              })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text($r('app.string.wireless_adb_pairing_connect_port_label'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            TextInput({ placeholder: $r('app.string.wireless_adb_pairing_connect_port_hint'), text: this.connectPort })
              .type(InputType.Number)
              .height(48)
              .fontSize(14)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(24)
              .caretColor($r('app.color.btn_primary'))
              .onChange((value: string) => {
                this.onConnectPortChange(value);
              })
          }
          .width(112)
          .alignItems(HorizontalAlign.Start)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)

        Row({ space: 10 }) {
          Button($r('app.string.wireless_adb_pairing_save_as_new_device_button'))
            .layoutWeight(1)
            .height(48)
            .type(ButtonType.Capsule)
            .fontSize(15)
            .fontColor($r('app.color.btn_primary'))
            .backgroundColor($r('app.color.bg_card'))
            .onClick(() => {
              this.onSaveAsNewDevice();
            })

          Button($r('app.string.wireless_adb_pairing_default_connect_button'))
            .layoutWeight(1)
            .height(48)
            .type(ButtonType.Capsule)
            .fontSize(15)
            .fontColor('#FFFFFF')
            .backgroundColor($r('app.color.btn_primary'))
            .onClick(() => {
              this.onDefaultConnect();
            })
        }
        .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 16 })

        if (this.getSortedDevices().length === 0) {
          Column() {
            Text($r('app.string.wireless_adb_pairing_device_sheet_empty'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding(24)
          .justifyContent(FlexAlign.Center)
        } else {
          Column({ space: 10 }) {
            if (this.hasSuggestedDevices()) {
              Row({ space: 10 }) {
                Divider()
                  .strokeWidth(1)
                  .color('#12000000')
                  .vertical(false)
                  .layoutWeight(1)

                Text($r('app.string.wireless_adb_pairing_device_sheet_same_ip_desc'))
                  .fontSize(13)
                  .lineHeight(20)
                  .fontColor($r('app.color.text_secondary'))
                  .textAlign(TextAlign.Center)

                Divider()
                  .strokeWidth(1)
                  .color('#12000000')
                  .vertical(false)
                  .layoutWeight(1)
              }
                .width('100%')
                .alignItems(VerticalAlign.Center)
            }

            Column({ space: 12 }) {
              ForEach(this.getSortedDevices(), (device: Device) => {
                this.DeviceItem(device)
              }, (device: Device) => device.uuid)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .clip(false)
    .backgroundColor($r('app.color.bg_primary'))
  }
}
