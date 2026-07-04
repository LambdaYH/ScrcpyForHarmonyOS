import {
  BottomBuilderShowType,
  DividerShowType,
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  ScrollEffectType
} from '@kit.UIDesignKit';
import { CapsuleSegmentButtonV2, ColorMetrics, LengthMetrics, SegmentButtonV2Items } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import display from '@ohos.display';
import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { AdbKeyManager, QrPairingResult, QrPairingSessionInfo } from '../helper/AdbKeyManager';
import { LoggerAdbManage } from '../helper/Logger';
import { WirelessAdbDevicePickerSheet } from '../components/WirelessAdbDevicePickerSheet';
import { WirelessAdbPickerHelpDialog } from '../components/WirelessAdbPickerHelpDialog';
import { DeviceDetail } from './DeviceDetail';
import {
  cloneDeviceForWirelessAdb,
  discoverWirelessAdbConnectHostPort,
  normalizeWirelessAdbAddress,
  parseWirelessAdbEndpoint,
  resolvePreferredLocalIp
} from '../helper/WirelessAdbPairingUtils';
import type { WirelessAdbEndpoint } from '../helper/WirelessAdbPairingUtils';

@Entry
@Component
struct WirelessAdbPairPage {
  @StorageProp(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY)
  private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @State selectedTab: number = 0;
  @State hostPort: string = '';
  @State pairingCode: string = '';
  @State isPairing: boolean = false;
  @State connectHost: string = '';
  @State connectPort: string = '';
  @State pairedDeviceHost: string = '';
  @State discoveredConnectEndpoint: WirelessAdbEndpoint | null = null;
  @State connectPortDiscoveryStatus: number = 0;
  @State showDevicePickerSheet: boolean = false;
  @State showQrPairingSheet: boolean = false;
  @State showAddDeviceSheet: boolean = false;
  @State addDevicePrefillHost: string = '';
  @State addDevicePrefillPort: number = 0;
  @State qrPairingPayload: string = '';
  @State qrPairingCode: string = '';
  @State qrPairingErrorText: string = '';
  @State qrPairingSessionId: number = 0;
  @State isStartingQrPairing: boolean = false;
  @State isWaitingQrPairing: boolean = false;
  private connectPortDiscoveryToken: number = 0;
  private adbKeyManager: AdbKeyManager = AdbKeyManager.getInstance();
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private pairScroller: Scroller = new Scroller();
  private qrPairingSheetScroller: Scroller = new Scroller();
  private devicePickerSheetScroller: Scroller = new Scroller();
  private readonly pairBottomBuilderHeight: number = 58;
  private devicePickerHelpDialogController: CustomDialogController = new CustomDialogController({
    builder: WirelessAdbPickerHelpDialog({
      title: $r('app.string.wireless_adb_picker_help_title'),
      steps: [
        $r('app.string.wireless_adb_picker_help_step_1'),
        $r('app.string.wireless_adb_picker_help_step_2'),
        $r('app.string.wireless_adb_picker_help_step_3'),
        $r('app.string.wireless_adb_picker_help_step_4')
      ]
    }),
    alignment: DialogAlignment.Center,
    autoCancel: true,
    customStyle: true,
    maskColor: '#80000000'
  });

  aboutToDisappear(): void {
    this.cancelQrPairingSession(false);
  }

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

  private buildDevicePickerTitleBarOptions(): HdsNavigationTitleBarOptions {
    return HdsImmersiveHelper.buildModalTitleBarOptions(
      $r('app.string.wireless_adb_pairing_device_sheet_title'),
      [
        {
          icon: $r('sys.symbol.info_circle'),
          action: (): void => {
            this.devicePickerHelpDialogController.open();
          }
        },
        {
          icon: $r('sys.symbol.xmark'),
          action: (): void => {
            this.showDevicePickerSheet = false;
          }
        }
      ]
    );
  }

  private resetAddDevicePrefill(): void {
    this.addDevicePrefillHost = '';
    this.addDevicePrefillPort = 0;
  }

  private openAddDeviceSheetWithPrefill(host: string, portText: string): void {
    const port = Number(portText.trim());
    this.addDevicePrefillHost = host.trim();
    this.addDevicePrefillPort = Number.isInteger(port) && port > 0 && port <= 65535 ? port : 0;
    this.showAddDeviceSheet = true;
  }

  build() {
    Stack() {
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
            .constraintSize({ minHeight: '100%' })
            .padding({ left: 16, right: 16, top: 8, bottom: 72 })
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

      Column() {
        Blank()
      }
        .width(0)
        .height(0)
        .bindSheet(this.showQrPairingSheet, this.QrPairingSheetModal(), {
          height: SheetSize.MEDIUM,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          showClose: false,
          maskColor: '#66000000',
          backgroundColor: $r('app.color.bg_primary'),
          radius: LengthMetrics.vp(28),
          onDisappear: (): void => {
            this.handleQrPairingSheetDismiss();
          }
        })

      Column() {
        Blank()
      }
        .width(0)
        .height(0)
        .bindSheet(this.showAddDeviceSheet, this.AddDeviceSheet(), {
          height: SheetSize.LARGE,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          showClose: false,
          maskColor: '#66000000',
          backgroundColor: $r('app.color.bg_primary'),
          radius: LengthMetrics.vp(28),
          onDisappear: (): void => {
            this.showAddDeviceSheet = false;
            this.resetAddDevicePrefill();
          }
        })

      Column() {
        Blank()
      }
        .width(0)
        .height(0)
        .bindSheet(this.showDevicePickerSheet, this.PairedDeviceSheet(), {
          height: SheetSize.LARGE,
          preferType: SheetType.BOTTOM,
          dragBar: true,
          showClose: false,
          maskColor: '#66000000',
          backgroundColor: $r('app.color.bg_primary'),
          radius: LengthMetrics.vp(28),
          onDisappear: (): void => {
            this.showDevicePickerSheet = false;
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private PairingTabBar() {
    Column() {
      CapsuleSegmentButtonV2({
        items: new SegmentButtonV2Items([
          { text: $r('app.string.wireless_adb_pairing_tab_code') },
          { text: $r('app.string.wireless_adb_pairing_tab_qr') }
        ]),
        selectedIndex: this.selectedTab,
        $selectedIndex: (index: number) => {
          if (this.selectedTab === 1 && index !== 1) {
            this.cancelQrPairingSession(false);
          }
          this.selectedTab = index;
        },
        itemSpace: LengthMetrics.vp(8),
        itemFontSize: LengthMetrics.vp(14),
        itemSelectedFontSize: LengthMetrics.vp(14),
        itemFontWeight: FontWeight.Regular,
        itemSelectedFontWeight: FontWeight.Medium,
        itemFontColor: ColorMetrics.rgba(0, 0, 0, 0.9),
        itemSelectedFontColor: ColorMetrics.rgba(255, 255, 255, 1),
        itemSelectedBackgroundColor: ColorMetrics.rgba(74, 123, 255, 1),
        itemBorderRadius: LengthMetrics.vp(20),
        buttonBackgroundColor: ColorMetrics.rgba(255, 255, 255, 0.75),
        buttonMinHeight: LengthMetrics.vp(40),
        buttonPadding: LengthMetrics.vp(2),
        buttonBorderRadius: LengthMetrics.vp(22)
      })
      .width('100%')
      .backgroundColor(Color.Transparent)
      .border({
        width: 1,
        color: '#40FFFFFF'
      })
      .borderRadius(22)
      .shadow({
        radius: 12,
        color: '#1F000000',
        offsetX: 0,
        offsetY: 3
      })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 2, bottom: 8 })
  }

  @Builder
  private PairingCodeTab() {
    Column({ space: 16 }) {
      this.InstructionCard(
        $r('app.string.wireless_adb_pairing_code_title'),
        [
          $r('app.string.wireless_adb_pairing_code_step_1'),
          $r('app.string.wireless_adb_pairing_code_step_2'),
          $r('app.string.wireless_adb_pairing_code_step_3')
        ]
      )

      this.InstructionCard(
        $r('app.string.wireless_adb_pairing_connect_desc_title'),
        [
          $r('app.string.wireless_adb_pairing_connect_desc_step_1'),
          $r('app.string.wireless_adb_pairing_connect_desc_step_2'),
          $r('app.string.wireless_adb_pairing_connect_desc_step_3')
        ],
        true
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
          .enabled(!this.isPairing && !this.isStartingQrPairing)
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
  }

  @Builder
  private QrCodeTab() {
    Column({ space: 16 }) {
      this.InstructionCard(
        $r('app.string.wireless_adb_pairing_qr_title'),
        [
          $r('app.string.wireless_adb_pairing_qr_step_1'),
          $r('app.string.wireless_adb_pairing_qr_step_2'),
          $r('app.string.wireless_adb_pairing_qr_step_3')
        ]
      )

      this.InstructionCard(
        $r('app.string.wireless_adb_pairing_connect_desc_title'),
        [
          $r('app.string.wireless_adb_pairing_connect_desc_step_1'),
          $r('app.string.wireless_adb_pairing_connect_desc_step_2'),
          $r('app.string.wireless_adb_pairing_connect_desc_step_3')
        ],
        true
      )

      Column({ space: 14 }) {
        Text($r('app.string.wireless_adb_pairing_scan_title'))
          .width('100%')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))

        Text($r('app.string.wireless_adb_pairing_scan_desc'))
          .width('100%')
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))

        Button(this.getQrActionButtonText())
          .width('100%')
          .height(48)
          .type(ButtonType.Capsule)
          .enabled(!this.isStartingQrPairing && !this.isPairing)
          .backgroundColor(this.isStartingQrPairing ? $r('app.color.text_tertiary') : $r('app.color.btn_primary'))
          .onClick(() => {
            this.handleQrActionButtonClick();
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
  private QrPairingSheet() {
    Scroll(this.qrPairingSheetScroller) {
      Column({ space: 16 }) {
        Text($r('app.string.wireless_adb_pairing_scan_desc'))
          .width('100%')
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
          .padding({ left: 20, right: 20 })

        if (this.qrPairingPayload) {
          Column({ space: 12 }) {
            QRCode(this.qrPairingPayload)
              .width(240)
              .height(240)
              .color('#111111')
              .backgroundColor('#FFFFFFFF')

            Text(this.qrPairingCode)
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))

            Text(this.getQrStatusText())
              .fontSize(13)
              .fontColor(this.qrPairingErrorText ? $r('app.color.icon_red') : $r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ top: 4, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .clip(false)
    .backgroundColor($r('app.color.bg_primary'))
  }

  @Builder
  private AddDeviceSheet() {
    DeviceDetail({
      embeddedMode: true,
      initialAddress: this.addDevicePrefillHost,
      initialAdbPort: this.addDevicePrefillPort,
      onFinish: (): void => {
        this.showAddDeviceSheet = false;
      }
    })
  }

  @Builder
  private QrPairingSheetModal() {
    HdsNavigation() {
      this.QrPairingSheet()
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(HdsImmersiveHelper.buildModalTitleBarOptions(
      $r('app.string.wireless_adb_pairing_scan_title'),
      [{
        icon: $r('sys.symbol.xmark'),
        action: (): void => {
          this.handleQrPairingSheetDismiss();
        }
      }]
    ))
    .bindToScrollable([this.qrPairingSheetScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private PairedDeviceSheet() {
    HdsNavigation() {
      WirelessAdbDevicePickerSheet({
        connectHost: this.connectHost,
        connectPort: this.connectPort,
        devices: this.preferencesHelper.getDevicesList(),
        pairedHost: this.pairedDeviceHost,
        sheetScroller: this.devicePickerSheetScroller,
        portDiscoveryStatus: this.connectPortDiscoveryStatus,
        onConnectHostChange: (value: string): void => {
          this.connectHost = value;
        },
        onConnectPortChange: (value: string): void => {
          this.connectPort = value;
        },
        onConnectDevice: (device: Device): void => {
          this.connectPairedDevice(device);
        },
        onDefaultConnect: (): void => {
          this.connectWithDefaultConfig();
        },
        onSaveAsNewDevice: (): void => {
          this.showDevicePickerSheet = false;
          this.openAddDeviceSheetWithPrefill(this.connectHost, this.connectPort);
        },
        onRetryDiscoverPort: (): void => {
          this.retryConnectPortDiscovery();
        }
      })
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(this.buildDevicePickerTitleBarOptions())
    .bindToScrollable([this.devicePickerSheetScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private InstructionCard(title: ResourceStr, steps: ResourceStr[], compactParallel: boolean = false) {
    Column({ space: compactParallel ? 8 : 12 }) {
      Text(title)
        .width('100%')
        .fontSize(compactParallel ? 15 : 16)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      ForEach(steps, (step: ResourceStr) => {
        if (compactParallel) {
          Row({ space: 8 }) {
            Blank()
              .width(5)
              .height(5)
              .borderRadius(3)
              .backgroundColor($r('app.color.text_secondary'))
              .margin({ top: 6 })

            Text(step)
              .layoutWeight(1)
              .fontSize(12)
              .lineHeight(18)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        } else {
          Text(step)
            .width('100%')
            .fontSize(13)
            .lineHeight(20)
            .fontColor($r('app.color.text_secondary'))
        }
      })
    }
    .width('100%')
    .padding(compactParallel ? 16 : 20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }

  async handlePairDevice(): Promise<void> {
    const trimmedHostPort = this.hostPort.trim();
    const trimmedCode = this.pairingCode.trim();
    if (!trimmedHostPort || !trimmedCode) {
      this.showToast($r('app.string.adb_pair_fill_required'));
      return;
    }

    this.isPairing = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('Context unavailable');
      }
      const guid = await this.adbKeyManager.pairDevice(context, trimmedHostPort, trimmedCode);
      this.markPairSuccess(parseWirelessAdbEndpoint(trimmedHostPort)?.host ?? trimmedHostPort);
      this.showTextToast(this.getString($r('app.string.adb_pair_success')) + guid);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error('ADB pair failed:', error);
      this.showTextToast(this.resolvePairErrorMessage(error.message));
    } finally {
      this.isPairing = false;
    }
  }

  private handleQrActionButtonClick(): void {
    this.handleStartQrPairing();
  }

  private async handleStartQrPairing(): Promise<void> {
    if (this.isStartingQrPairing || this.isPairing) {
      return;
    }

    this.cancelQrPairingSession(true);
    this.isStartingQrPairing = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('Context unavailable');
      }

      const ip = await resolvePreferredLocalIp();
      const sessionInfo = await this.adbKeyManager.startQrPairingSession(context, ip);
      LoggerAdbManage.info(`QR pairing session created sessionId=${sessionInfo.sessionId}`);

      this.applyQrPairingSession(sessionInfo);
      this.showToast($r('app.string.wireless_adb_pairing_scan_detected'));
      this.waitForQrPairingResult(sessionInfo.sessionId);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error('Start QR pairing failed:', error);
      this.showTextToast(this.resolveQrPairErrorMessage(error.message));
      this.cancelQrPairingSession(true);
    } finally {
      this.isStartingQrPairing = false;
    }
  }

  private waitForQrPairingResult(sessionId: number): void {
    this.isWaitingQrPairing = true;
    this.adbKeyManager.waitQrPairingSession(sessionId).then((result: QrPairingResult) => {
      if (this.qrPairingSessionId !== sessionId) {
        return;
      }
      this.qrPairingSessionId = 0;
      this.isWaitingQrPairing = false;
      this.showQrPairingSheet = false;
      LoggerAdbManage.info(`QR pairing succeeded sessionId=${sessionId} guid=${result.guid} pairedHost=${result.pairedHost} hostPort=${result.endpoint?.hostPort ?? ''}`);
      const knownConnectEndpoint = result.endpoint;
      this.markPairSuccess(result.pairedHost, knownConnectEndpoint);
      this.showTextToast(this.getString($r('app.string.adb_pair_success')) + result.guid);
    }).catch((err: Error) => {
      if (this.qrPairingSessionId !== sessionId) {
        return;
      }
      this.qrPairingSessionId = 0;
      this.isWaitingQrPairing = false;
      const message = err instanceof Error ? err.message : String(err);
      if (message.toLowerCase().includes('canceled')) {
        return;
      }
      LoggerAdbManage.warn('Wait QR pairing failed:', message);
      const friendlyMessage = this.resolveQrPairErrorMessage(message);
      this.qrPairingErrorText = friendlyMessage;
      this.showQrPairingSheet = true;
      this.showTextToast(friendlyMessage);
    });
  }

  private cancelQrPairingSession(clearDisplay: boolean): void {
    if (this.qrPairingSessionId > 0) {
      try {
        this.adbKeyManager.stopQrPairingSession(this.qrPairingSessionId);
      } catch (err) {
        LoggerAdbManage.error('Stop QR pairing failed:', err);
      }
    }

    this.qrPairingSessionId = 0;
    this.isWaitingQrPairing = false;
    this.isStartingQrPairing = false;

    if (clearDisplay) {
      this.qrPairingPayload = '';
      this.qrPairingCode = '';
      this.qrPairingErrorText = '';
      this.showQrPairingSheet = false;
    }
  }

  private handleQrPairingSheetDismiss(): void {
    this.cancelQrPairingSession(true);
  }

  private applyQrPairingSession(sessionInfo: QrPairingSessionInfo): void {
    this.qrPairingSessionId = sessionInfo.sessionId;
    this.qrPairingCode = sessionInfo.pairingCode;
    this.qrPairingErrorText = '';
    this.qrPairingPayload = `WIFI:T:ADB;S:${sessionInfo.serviceName};P:${sessionInfo.pairingCode};;`;
    this.showQrPairingSheet = true;
  }

  private markPairSuccess(pairedHost: string, knownConnectEndpoint: WirelessAdbEndpoint | null = null): void {
    LoggerAdbManage.info(`Mark pair success pairedHost=${pairedHost} knownConnectHostPort=${knownConnectEndpoint?.hostPort ?? ''}`);
    this.pairedDeviceHost = pairedHost;
    this.discoveredConnectEndpoint = knownConnectEndpoint;
    this.connectHost = knownConnectEndpoint?.host ?? this.pairedDeviceHost;
    this.connectPortDiscoveryStatus = knownConnectEndpoint ? 2 : 1;
    this.connectPort = knownConnectEndpoint?.port ?? '';
    if (!this.discoveredConnectEndpoint) {
      this.discoverConnectHostPort(this.pairedDeviceHost);
    }
    this.showDevicePickerSheet = true;
  }

  private async discoverConnectHostPort(pairedHost: string): Promise<void> {
    if (!pairedHost.trim()) {
      return;
    }
    const discoveryToken = ++this.connectPortDiscoveryToken;
    this.connectPortDiscoveryStatus = 1;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      if (!context) {
        throw new Error('Context unavailable');
      }
      LoggerAdbManage.info(`Discover connect hostPort start pairedHost=${pairedHost}`);
      const discoveredHostPort = await discoverWirelessAdbConnectHostPort(context, pairedHost);
      if (this.connectPortDiscoveryToken !== discoveryToken ||
        normalizeWirelessAdbAddress(this.pairedDeviceHost) !== normalizeWirelessAdbAddress(pairedHost)) {
        return;
      }
      this.discoveredConnectEndpoint = discoveredHostPort;
      this.connectHost = discoveredHostPort.host;
      this.connectPort = discoveredHostPort.port;
      this.connectPortDiscoveryStatus = 2;
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.warn('Discover connect hostPort failed:', error.message);
      if (this.connectPortDiscoveryToken === discoveryToken &&
        normalizeWirelessAdbAddress(this.pairedDeviceHost) === normalizeWirelessAdbAddress(pairedHost)) {
        this.discoveredConnectEndpoint = null;
        this.connectPortDiscoveryStatus = 3;
      }
    }
  }

  private retryConnectPortDiscovery(): void {
    if (!this.pairedDeviceHost.trim() || this.connectPortDiscoveryStatus === 1) {
      return;
    }
    ++this.connectPortDiscoveryToken;
    this.discoveredConnectEndpoint = null;
    this.connectPort = '';
    this.discoverConnectHostPort(this.pairedDeviceHost);
  }

  private getQrActionButtonText(): ResourceStr {
    if (this.isStartingQrPairing) {
      return $r('app.string.wireless_adb_pairing_scan_processing');
    }

    return $r('app.string.wireless_adb_pairing_scan_camera');
  }

  private getQrStatusText(): ResourceStr {
    if (this.qrPairingErrorText) {
      return this.qrPairingErrorText;
    }

    if (this.isWaitingQrPairing) {
      return $r('app.string.wireless_adb_pairing_qr_status_waiting');
    }

    return $r('app.string.wireless_adb_pairing_qr_status_ready');
  }

  private resolveConnectHost(): string {
    return this.connectHost.trim() || this.pairedDeviceHost;
  }

  private resolveConnectPortText(): string {
    return this.connectPort.trim();
  }

  private connectPairedDevice(device: Device): void {
    const host = this.resolveConnectHost();
    const trimmedPort = this.resolveConnectPortText();
    if (!trimmedPort) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_required'));
      return;
    }

    const port = Number(trimmedPort);
    if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_invalid'));
      return;
    }

    const quickConnectDevice = cloneDeviceForWirelessAdb(device);
    quickConnectDevice.address = host;
    quickConnectDevice.adbPort = port;
    this.showDevicePickerSheet = false;
    this.navigateToControlPage(quickConnectDevice);
  }

  private connectWithDefaultConfig(): void {
    const host = this.resolveConnectHost();
    const trimmedPort = this.resolveConnectPortText();
    if (!trimmedPort) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_required'));
      return;
    }

    const port = Number(trimmedPort);
    if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_invalid'));
      return;
    }

    const defaultDevice = new Device(`wireless-adb-${Date.now()}`, Device.TYPE_NETWORK);
    defaultDevice.name = this.getString($r('app.string.wireless_adb_pairing_default_device_name'));
    defaultDevice.address = host;
    defaultDevice.adbPort = port;
    this.showDevicePickerSheet = false;
    this.navigateToControlPage(defaultDevice);
  }

  private navigateToControlPage(device: Device): void {
    let homeDisplayOrientation: number = -1;
    try {
      homeDisplayOrientation = display.getDefaultDisplaySync().orientation;
    } catch (err) {
      LoggerAdbManage.error('Capture home display orientation failed:', err);
    }

    this.getUIContext().getRouter().pushUrl({
      url: 'pages/ControlPage',
      params: {
        device: device,
        clientReady: true,
        homeDisplayOrientation: homeDisplayOrientation
      }
    }).catch((err: Error) => {
      LoggerAdbManage.error('Quick connect navigate failed:', err);
      this.showToast($r('app.string.navigate_failed'));
    });
  }

  private showToast(message: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message });
  }

  private showTextToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message: message });
  }

  private getString(resource: Resource): string {
    return this.getUIContext().getHostContext()!.resourceManager.getStringSync(resource.id);
  }

  private resolvePairErrorMessage(rawMessage: string): string {
    const resourceManager = this.getUIContext().getHostContext()?.resourceManager;
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

  private resolveQrPairErrorMessage(rawMessage: string): string {
    const lowerMessage = rawMessage.toLowerCase();
    if (lowerMessage.includes('no default network') || lowerMessage.includes('no available local ip')) {
      return this.getString($r('app.string.wireless_adb_pairing_qr_local_ip_failed'));
    }

    if (lowerMessage.includes('timed out waiting for android device') ||
      lowerMessage.includes('timed out waiting for android pairing service')) {
      return this.getString($r('app.string.wireless_adb_pairing_qr_timeout'));
    }

    return this.getString($r('app.string.adb_pair_failed_prefix')) + rawMessage;
  }
}
