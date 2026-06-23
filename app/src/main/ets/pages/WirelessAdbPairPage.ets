import { AdbKeyManager } from '../helper/AdbKeyManager';
import { LoggerAdbManage } from '../helper/Logger';

@Entry
@Component
struct WirelessAdbPairPage {
  @State hostPort: string = '';
  @State pairingCode: string = '';
  @State isPairing: boolean = false;
  private adbKeyManager: AdbKeyManager = AdbKeyManager.getInstance();

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

        Text($r('app.string.wireless_adb_pairing'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 12 })
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 12, right: 24, top: 38 })

      Scroll() {
        Column({ space: 16 }) {
          Column({ space: 10 }) {
            Text($r('app.string.wireless_adb_pairing'))
              .width('100%')
              .fontSize(20)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text($r('app.string.wireless_adb_pairing_desc'))
              .width('100%')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(20)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(16)

          Column({ space: 12 }) {
            Text($r('app.string.wireless_adb_pairing_steps_title'))
              .width('100%')
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            Text($r('app.string.wireless_adb_pairing_step_1'))
              .width('100%')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))

            Text($r('app.string.wireless_adb_pairing_step_2'))
              .width('100%')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))

            Text($r('app.string.wireless_adb_pairing_step_3'))
              .width('100%')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))

            Text($r('app.string.wireless_adb_pairing_step_4'))
              .width('100%')
              .fontSize(13)
              .lineHeight(20)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding(20)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(16)

          Column({ space: 10 }) {
            Text($r('app.string.adb_pair_address'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))

            TextInput({ placeholder: $r('app.string.adb_pair_address_hint'), text: this.hostPort })
              .height(48)
              .fontSize(14)
              .backgroundColor($r('app.color.bg_card'))
              .onChange((value) => this.hostPort = value)

            Text($r('app.string.adb_pair_code'))
              .width('100%')
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.text_primary'))
              .margin({ top: 8 })

            TextInput({ placeholder: $r('app.string.adb_pair_code_hint'), text: this.pairingCode })
              .height(48)
              .fontSize(14)
              .backgroundColor($r('app.color.bg_card'))
              .onChange((value) => this.pairingCode = value)

            Button(this.isPairing ? $r('app.string.adb_pairing') : $r('app.string.wireless_adb_pairing_start'))
              .width('100%')
              .height(48)
              .margin({ top: 12 })
              .type(ButtonType.Capsule)
              .enabled(!this.isPairing)
              .backgroundColor(this.isPairing ? $r('app.color.text_tertiary') : $r('app.color.btn_primary'))
              .onClick(() => {
                this.handlePairDevice();
              })
          }
          .width('100%')
          .padding(20)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(16)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8, bottom: 24 })
      }
      .scrollBar(BarState.Off)
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  async handlePairDevice(): Promise<void> {
    const trimmedHostPort = this.hostPort.trim();
    const trimmedCode = this.pairingCode.trim();
    if (!trimmedHostPort || !trimmedCode) {
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.adb_pair_fill_required') });
      return;
    }

    this.isPairing = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('Context unavailable');
      }
      const guid = await this.adbKeyManager.pairDevice(context, trimmedHostPort, trimmedCode);
      this.getUIContext().getPromptAction().showToast({
        message: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.adb_pair_success').id) + guid
      });
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error('ADB pair failed:', error);
      this.getUIContext().getPromptAction().showToast({
        message: this.resolvePairErrorMessage(error.message)
      });
    } finally {
      this.isPairing = false;
    }
  }

  private resolvePairErrorMessage(rawMessage: string): string {
    const hostContext = this.getUIContext().getHostContext();
    const resourceManager = hostContext?.resourceManager;
    if (!resourceManager) {
      return rawMessage;
    }

    const lowerMessage = rawMessage.toLowerCase();
    const getString = (res: Resource): string => resourceManager.getStringSync(res.id);

    let detail = getString($r('app.string.adb_pair_failed_generic'));
    if (lowerMessage.includes('pairing address is empty') || lowerMessage.includes('must be host:port') ||
      lowerMessage.includes('invalid ipv6 pairing address')) {
      detail = getString($r('app.string.adb_pair_failed_invalid_address'));
    } else if (lowerMessage.includes('failed to resolve pairing address')) {
      detail = getString($r('app.string.adb_pair_failed_resolve'));
    } else if (lowerMessage.includes('connection refused')) {
      detail = getString($r('app.string.adb_pair_failed_refused'));
    } else if (lowerMessage.includes('connect timeout')) {
      detail = getString($r('app.string.adb_pair_failed_timeout'));
    } else if (lowerMessage.includes('tls handshake failed')) {
      detail = getString($r('app.string.adb_pair_failed_tls'));
    } else if (lowerMessage.includes('failed to initialize pairing cipher') ||
      lowerMessage.includes('failed to decrypt peer info')) {
      detail = getString($r('app.string.adb_pair_failed_code_or_expired'));
    } else if (lowerMessage.includes('failed to connect pairing socket')) {
      detail = getString($r('app.string.adb_pair_failed_connect'));
    }

    return getString($r('app.string.adb_pair_failed_prefix')) + detail;
  }
}
