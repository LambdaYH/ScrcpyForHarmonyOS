import {
  BottomBuilderShowType,
  DividerShowType,
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { LengthMetrics } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import { LoggerAdbManage } from '../helper/Logger';

interface PairingPayload {
  hostPort: string;
  pairingCode: string;
}

@Entry
@Component
struct WirelessAdbPairPage {
  @StorageProp(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY)
  private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @State selectedTab: number = 0;
  @State hostPort: string = '';
  @State pairingCode: string = '';
  @State isPairing: boolean = false;
  @State isResolvingScan: boolean = false;
  private adbKeyManager: AdbKeyManager = AdbKeyManager.getInstance();
  private pairScroller: Scroller = new Scroller();
  private readonly pairBottomBuilderHeight: number = 58;

  private pairTitleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp, this.pairBottomBuilderHeight);
  }

  private buildPairTitleBarOptions(): HdsNavigationTitleBarOptions {
    const immersiveMaterialEffect = HdsImmersiveHelper.buildHdsImmersiveSystemMaterialEffect();
    const scrollEffectType: ScrollEffectType = immersiveMaterialEffect === undefined
      ? ScrollEffectType.GRADIENT_BLUR
      : ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
    return {
      enableComponentSafeArea: false,
      avoidLayoutSafeArea: true,
      padding: {
        start: LengthMetrics.vp(24),
        end: LengthMetrics.vp(24)
      },
      content: {
        title: {
          mainTitle: $r('app.string.wireless_adb_pairing'),
          mainTitleSize: 20
        },
        bottomBuilder: {
          builder: (): void => this.PairingTabBar(),
          height: 58,
          showType: BottomBuilderShowType.DIRECTLY_SHOW
        },
        divider: {
          showType: DividerShowType.OFF
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: scrollEffectType
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
        systemMaterialEffect: immersiveMaterialEffect
      }
    };
  }

  build() {
    HdsNavigation() {
      Column() {
        Scroll(this.pairScroller) {
          Column({ space: 16 }) {
            Blank()
              .height(this.pairTitleOverlayHeight())
              .width('100%')

            if (this.selectedTab === 0) {
              this.PairingCodeTab()
            } else {
              this.QrCodeTab()
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 24 })
        }
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .width('100%')
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
    .bindToScrollable([this.pairScroller])
    .titleBar(this.buildPairTitleBarOptions())
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private PairingTabBar() {
    Column() {
      Row({ space: 8 }) {
        this.TabButton(0, $r('app.string.wireless_adb_pairing_tab_code'))
        this.TabButton(1, $r('app.string.wireless_adb_pairing_tab_qr'))
      }
      .width('100%')
      .backgroundColor(Color.Transparent)
      .borderRadius(28)
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 2, bottom: 2 })
  }

  @Builder
  private TabButton(index: number, title: ResourceStr) {
    Button() {
      Text(title)
        .fontSize(14)
        .fontWeight(this.selectedTab === index ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selectedTab === index ? '#FFFFFF' : $r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .type(ButtonType.Capsule)
    .layoutWeight(1)
    .height(40)
    .padding({ left: 10, right: 10 })
    .backgroundColor(this.selectedTab === index ? '#4A7BFF' : '#30FFFFFF')
    .border({
      width: 1,
      color: this.selectedTab === index ? '#5D8BFF' : '#52FFFFFF'
    })
    .shadow(this.selectedTab === index ? {
      radius: 20,
      color: '#284A7BFF',
      offsetX: 0,
      offsetY: 8
    } : {
      radius: 10,
      color: '#12000000',
      offsetX: 0,
      offsetY: 4
    })
    .onClick(() => {
      this.selectedTab = index;
    })
  }

  @Builder
  private PairingCodeTab() {
    Column({ space: 16 }) {
      this.InstructionCard(
        $r('app.string.wireless_adb_pairing_code_title'),
        [
          $r('app.string.wireless_adb_pairing_code_step_1'),
          $r('app.string.wireless_adb_pairing_code_step_2'),
          $r('app.string.wireless_adb_pairing_code_step_3'),
          $r('app.string.wireless_adb_pairing_code_step_4')
        ]
      )

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
          .enabled(!this.isPairing && !this.isResolvingScan)
          .backgroundColor(this.isPairing || this.isResolvingScan ?
            $r('app.color.text_tertiary') : $r('app.color.btn_primary'))
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
  }

  @Builder
  private QrCodeTab() {
    Column({ space: 16 }) {
      this.InstructionCard(
        $r('app.string.wireless_adb_pairing_qr_title'),
        [
          $r('app.string.wireless_adb_pairing_qr_step_1'),
          $r('app.string.wireless_adb_pairing_qr_step_2'),
          $r('app.string.wireless_adb_pairing_qr_step_3'),
          $r('app.string.wireless_adb_pairing_qr_step_4')
        ]
      )

      Column({ space: 12 }) {
        Text($r('app.string.wireless_adb_pairing_scan_title'))
          .width('100%')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Button() {
          Row({ space: 8 }) {
            SymbolGlyph($r('sys.symbol.camera'))
              .fontSize(18)
              .fontColor(['#FFFFFF'])

            Text(this.isResolvingScan ? $r('app.string.wireless_adb_pairing_scan_processing') :
              $r('app.string.wireless_adb_pairing_scan_camera'))
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .fontColor('#FFFFFF')
          }
        }
        .width('100%')
        .height(48)
        .type(ButtonType.Capsule)
        .enabled(!this.isPairing && !this.isResolvingScan)
        .backgroundColor(this.isPairing || this.isResolvingScan ?
          $r('app.color.text_tertiary') : $r('app.color.btn_primary'))
        .onClick(() => {
          this.handleScanByCamera();
        })
      }
      .width('100%')
      .padding(20)
      .backgroundColor($r('app.color.bg_card'))
      .borderRadius(16)
    }
    .width('100%')
  }

  @Builder
  private InstructionCard(title: ResourceStr, steps: ResourceStr[]) {
    Column({ space: 12 }) {
      Text(title)
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      ForEach(steps, (step: ResourceStr) => {
        Text(step)
          .width('100%')
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
      })
    }
    .width('100%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
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

  async handleScanByCamera(): Promise<void> {
    if (this.isPairing || this.isResolvingScan) {
      return;
    }

    const context = this.getUIContext().getHostContext();
    if (!context) {
      this.showToast($r('app.string.wireless_adb_pairing_scan_unavailable'));
      return;
    }

    this.isResolvingScan = true;
    try {
      const result = await scanBarcode.startScanForResult(context, this.buildQrScanOptions());
      await this.applyScanText(result?.originalValue ?? '');
    } catch (err) {
      this.handleScanError(err);
    } finally {
      this.isResolvingScan = false;
    }
  }

  private buildQrScanOptions(): scanBarcode.ScanOptions {
    return {
      scanTypes: [scanCore.ScanType.QR_CODE],
      enableMultiMode: false,
      enableAlbum: true
    };
  }

  private async applyScanText(rawText: string): Promise<void> {
    const parsed = this.parsePairingPayload(rawText);
    if (!parsed) {
      this.showToast($r('app.string.wireless_adb_pairing_scan_invalid'));
      return;
    }

    await this.applyParsedPayload(parsed);
  }

  private async applyParsedPayload(payload: PairingPayload): Promise<void> {
    this.hostPort = payload.hostPort;
    this.pairingCode = payload.pairingCode;
    this.showToast($r('app.string.wireless_adb_pairing_scan_detected'));
    await this.handlePairDevice();
  }

  private parsePairingPayload(rawText: string): PairingPayload | null {
    const trimmed = rawText.trim();
    if (!trimmed) {
      return null;
    }

    const candidates: string[] = [trimmed];
    try {
      const decoded = decodeURIComponent(trimmed);
      if (decoded !== trimmed) {
        candidates.push(decoded);
      }
    } catch (_err) {
    }

    for (const candidate of candidates) {
      const fromJson = this.tryParseJsonPayload(candidate);
      if (fromJson) {
        return fromJson;
      }

      const fromWifiPayload = this.tryParseWifiPayload(candidate);
      if (fromWifiPayload) {
        return fromWifiPayload;
      }

      const fromKeyValuePayload = this.tryParseKeyValuePayload(candidate);
      if (fromKeyValuePayload) {
        return fromKeyValuePayload;
      }

      const fromLooseText = this.tryParseLoosePayload(candidate);
      if (fromLooseText) {
        return fromLooseText;
      }
    }

    return null;
  }

  private tryParseJsonPayload(text: string): PairingPayload | null {
    try {
      const value = JSON.parse(text) as Record<string, string | number | boolean | null | undefined>;
      return this.extractPayloadFromRecord(value);
    } catch (_err) {
      return null;
    }
  }

  private tryParseWifiPayload(text: string): PairingPayload | null {
    if (!text.startsWith('WIFI:')) {
      return null;
    }

    const payload = text.substring(5);
    const record: Record<string, string> = {};
    for (const segment of payload.split(';')) {
      const separator = segment.indexOf(':');
      if (separator <= 0) {
        continue;
      }
      const key = segment.substring(0, separator).trim().toLowerCase();
      const value = segment.substring(separator + 1).trim();
      if (key && value) {
        record[key] = value;
      }
    }

    const type = record['t'];
    if (type && type.toUpperCase() !== 'ADB') {
      return null;
    }

    const service = record['s'];
    const host = record['h'] ?? record['host'];
    const port = record['r'] ?? record['port'];
    const pairingCode = record['p'] ?? record['code'] ?? record['pairingcode'];

    let hostPort = '';
    if (service && this.isHostPort(service)) {
      hostPort = service;
    } else if (host && port) {
      hostPort = this.normalizeHostPort(host, port);
    }

    return this.buildPayload(hostPort, pairingCode ?? '');
  }

  private tryParseKeyValuePayload(text: string): PairingPayload | null {
    const hostPort = this.extractNamedValue(text, ['hostport', 'pairingaddress', 'address']);
    const host = this.extractNamedValue(text, ['host', 'ip', 'ipaddr']);
    const port = this.extractNamedValue(text, ['port', 'pairingport']);
    const pairingCode = this.extractNamedValue(text, ['pairingcode', 'paircode', 'code', 'password']);

    const normalizedHostPort = hostPort ?? (host && port ? this.normalizeHostPort(host, port) : '');
    return this.buildPayload(normalizedHostPort, pairingCode ?? '');
  }

  private tryParseLoosePayload(text: string): PairingPayload | null {
    const hostPortMatch = text.match(/((?:\[[0-9A-Fa-f:.]+\])|(?:\d{1,3}\.){3}\d{1,3}|[A-Za-z0-9._-]+):(\d{1,5})/);
    const pairingCodeMatch = text.match(/(^|[^\d])(\d{6})([^\d]|$)/);
    if (!hostPortMatch || !pairingCodeMatch) {
      return null;
    }

    const hostPort = `${hostPortMatch[1]}:${hostPortMatch[2]}`;
    const pairingCode = pairingCodeMatch[2];
    return this.buildPayload(hostPort, pairingCode);
  }

  private extractPayloadFromRecord(record: Record<string, string | number | boolean | null | undefined>): PairingPayload | null {
    const hostPort = this.readRecordValue(record, ['hostPort', 'pairingAddress', 'address']);
    const host = this.readRecordValue(record, ['host', 'ip', 'ipAddr']);
    const port = this.readRecordValue(record, ['port', 'pairingPort']);
    const pairingCode = this.readRecordValue(record, ['pairingCode', 'pairCode', 'code', 'password']);

    const normalizedHostPort = hostPort ?? (host && port ? this.normalizeHostPort(host, port) : '');
    return this.buildPayload(normalizedHostPort, pairingCode ?? '');
  }

  private readRecordValue(
    record: Record<string, string | number | boolean | null | undefined>,
    keys: string[]
  ): string | null {
    for (const key of keys) {
      const value = record[key];
      if (value === undefined || value === null) {
        continue;
      }
      const normalized = String(value).trim();
      if (normalized) {
        return normalized;
      }
    }

    return null;
  }

  private extractNamedValue(text: string, keys: string[]): string | null {
    for (const key of keys) {
      const regex = new RegExp(`${key}\\s*[:=]\\s*([^\\s;,&]+)`, 'i');
      const match = text.match(regex);
      if (match && match[1]) {
        return match[1].trim();
      }
    }

    return null;
  }

  private buildPayload(hostPort: string, pairingCode: string): PairingPayload | null {
    const normalizedHostPort = hostPort.trim();
    const normalizedCode = pairingCode.trim();
    if (!this.isHostPort(normalizedHostPort) || !/^\d{6}$/.test(normalizedCode)) {
      return null;
    }

    return {
      hostPort: normalizedHostPort,
      pairingCode: normalizedCode
    };
  }

  private isHostPort(value: string): boolean {
    return /^(?:\[[0-9A-Fa-f:.]+\]|(?:\d{1,3}\.){3}\d{1,3}|[A-Za-z0-9._-]+):\d{1,5}$/.test(value.trim());
  }

  private normalizeHostPort(host: string, port: string): string {
    return `${host.trim()}:${port.trim()}`;
  }

  private handleScanError(err: Object): void {
    const error = err as BusinessError;
    LoggerAdbManage.error('ADB QR scan failed:', error);

    if (error?.code === scanCore.ScanErrorCode.SCAN_SERVICE_CANCELED) {
      return;
    }

    this.showToast($r('app.string.wireless_adb_pairing_scan_failed'));
  }

  private showToast(message: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message });
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
