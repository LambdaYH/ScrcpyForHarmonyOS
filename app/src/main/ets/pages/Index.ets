import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { ClientSessionManager } from '../helper/ClientSessionManager';

import { Logger, LoggerIndex } from '../helper/Logger';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { AdbKeyManager, QrPairingResult, QrPairingSessionInfo } from '../helper/AdbKeyManager';

import { common } from '@kit.AbilityKit';
import { ComponentContent, LengthMetrics } from '@kit.ArkUI';
import { connection } from '@kit.NetworkKit';
import pasteboard from '@ohos.pasteboard';
import display from '@ohos.display';
import { DeviceDetail } from './DeviceDetail';
import { WirelessAdbDevicePickerSheet } from '../components/WirelessAdbDevicePickerSheet';
import { WirelessAdbPickerHelpDialog } from '../components/WirelessAdbPickerHelpDialog';
import {
  cloneDeviceForWirelessAdb,
  discoverWirelessAdbConnectHostPort,
  normalizeWirelessAdbAddress,
  parseWirelessAdbEndpoint,
  resolvePreferredLocalIp,
  startNearbyAdbDiscovery
} from '../helper/WirelessAdbPairingUtils';
import type { NearbyAdbDiscoverySession, WirelessAdbEndpoint } from '../helper/WirelessAdbPairingUtils';
import {
  DividerShowType,
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  SystemMaterialParams
} from '@kit.UIDesignKit';

interface HomePairMethodMenuParams {
  onSelect: (index: number) => void;
}

@Builder
function HomePairMethodMenuItem(title: ResourceStr, icon: Resource, index: number, onSelect: (index: number) => void) {
  MenuItem({ startIcon: icon, content: title })
    .height(48)
    .contentFont({
      size: 15
    })
    .contentFontColor($r('app.color.text_primary'))
  .onClick(() => {
    onSelect(index);
  })
}

@Builder
function HomePairMethodMenuBuilder(params: HomePairMethodMenuParams) {
  Menu() {
    HomePairMethodMenuItem($r('app.string.wireless_adb_pairing_nearby_devices_menu'), $r('sys.symbol.link'), 0,
      params.onSelect)
    HomePairMethodMenuItem($r('app.string.wireless_adb_pairing_tab_code'), $r('sys.symbol.key'), 1, params.onSelect)
    HomePairMethodMenuItem($r('app.string.wireless_adb_pairing_tab_qr'), $r('sys.symbol.qrcode'), 2, params.onSelect)
  }
    .width(176)
    .menuItemDivider({
      strokeWidth: LengthMetrics.vp(0.5),
      color: '#08000000',
      startMargin: LengthMetrics.vp(14),
      endMargin: LengthMetrics.vp(14)
    })
  .backgroundColor('#70FFFFFF')
  .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
  .borderRadius(18)
  .shadow({
    radius: 18,
    color: '#1F000000',
    offsetX: 0,
    offsetY: 6
  })
}

@Entry
@Component
struct Index {
  @State devicesList: Device[] = [];
  @State currentIndex: number = 0;
  @State showAddDeviceSheet: boolean = false;
  @State addDevicePrefillHost: string = '';
  @State addDevicePrefillPort: number = 0;
  @State showHomeCodePairSheet: boolean = false;
  @State showHomeQrPairSheet: boolean = false;
  @State @Watch('onHomeQuickConnectSheetVisibilityChange') showHomeQuickConnectSheet: boolean = false;
  @State showHomePairDeviceSheet: boolean = false;
  @State homePairHostPort: string = '';
  @State homePairCode: string = '';
  @State homePairing: boolean = false;
  @State homeQrPayload: string = '';
  @State homeQrCode: string = '';
  @State homeQrErrorText: string = '';
  @State homeQrSessionId: number = 0;
  @State homeQrStarting: boolean = false;
  @State homeQrWaiting: boolean = false;
  @State homePairedHost: string = '';
  @State homeDiscoveredConnectEndpoint: WirelessAdbEndpoint | null = null;
  @State homeConnectPortDiscoveryStatus: number = 0;
  @State homeConnectHost: string = '';
  @State homeConnectPort: string = '';
  @State homeQuickConnectCandidates: WirelessAdbEndpoint[] = [];
  @State homeQuickConnectInactiveCandidates: string[] = [];
  @State homeQuickConnectDiscoveryStatus: number = 0;
  @State homeQuickConnectErrorText: string = '';
  @StorageProp(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY)
  private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @StorageProp(HdsImmersiveHelper.BOTTOM_SAFE_INSET_VP_KEY)
  private systemBottomInsetVp: number = HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private adbKeyManager: AdbKeyManager = AdbKeyManager.getInstance();
  private homeTabsController: HdsTabsController = new HdsTabsController();
  private deviceListScroller: Scroller = new Scroller();
  private moreListScroller: Scroller = new Scroller();
  private homeCodePairSheetScroller: Scroller = new Scroller();
  private homeQrPairSheetScroller: Scroller = new Scroller();
  private homeQuickConnectSheetScroller: Scroller = new Scroller();
  private homePairDeviceSheetScroller: Scroller = new Scroller();
  private readonly bottomDockHeightVp: number = 54;
  private readonly bottomDockRadiusVp: number = 27;
  private readonly bottomDockSideButtonSizeVp: number = 48;
  private readonly bottomDockCenterButtonHitSizeVp: number = 72;
  private readonly bottomDockBarBottomMarginVp: number = 28;
  private readonly homePairMenuButtonId: string = 'home_pair_menu_button';
  private homePairMenuContent?: ComponentContent<HomePairMethodMenuParams>;
  private homeConnectPortDiscoveryToken: number = 0;
  private homeQuickConnectLastLogSignature: string = '';
  private homeQuickConnectDiscoverySession: NearbyAdbDiscoverySession | null = null;
  private homePairDeviceSheetFromQuickConnect: boolean = false;
  @State localIpList: string[] = [];
  
  private ipListDialogController: CustomDialogController = new CustomDialogController({
    builder: IpListDialog({
      ipList: this.localIpList,
      onCopy: (ip: string): void => this.copyTextToClipboard(ip)
    }),
    alignment: DialogAlignment.Center,
    autoCancel: true,
    customStyle: true
  });
  private codePairHelpDialogController: CustomDialogController = new CustomDialogController({
    builder: WirelessPairHelpDialog({
      title: $r('app.string.wireless_adb_pairing_code_title'),
      steps: [
        $r('app.string.wireless_adb_pairing_code_step_1'),
        $r('app.string.wireless_adb_pairing_code_step_2'),
        $r('app.string.wireless_adb_pairing_code_step_3')
      ]
    }),
    alignment: DialogAlignment.Center,
    autoCancel: true,
    customStyle: true,
    maskColor: '#80000000'
  });
  private qrPairHelpDialogController: CustomDialogController = new CustomDialogController({
    builder: WirelessPairHelpDialog({
      title: $r('app.string.wireless_adb_pairing_qr_title'),
      steps: [
        $r('app.string.wireless_adb_pairing_qr_step_1'),
        $r('app.string.wireless_adb_pairing_qr_step_2'),
        $r('app.string.wireless_adb_pairing_qr_step_3')
      ]
    }),
    alignment: DialogAlignment.Center,
    autoCancel: true,
    customStyle: true,
    maskColor: '#80000000'
  });
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

  aboutToAppear() {
    this.initPreferences();
  }
  
  onPageShow() {
    // 每次显示首页时，确保清理掉可能存在的后台会话
    ClientSessionManager.getInstance().stopAll();
    this.loadDevices();
  }

  aboutToDisappear(): void {
    this.cancelHomeQrPairing(false);
  }
  


  async loadDevices(): Promise<boolean> {
    this.devicesList = this.preferencesHelper.getDevicesList();
    return this.devicesList.length > 0;
  }

  async initPreferences() {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await this.preferencesHelper.init(context);
      Logger.init(context as common.UIAbilityContext);
      const hasDevices = await this.loadDevices();
      
      // 检查自动连接
      if (hasDevices) {
        const autoConnectDevice = this.devicesList.find(d => d.connectOnStart);
        if (autoConnectDevice) {
          LoggerIndex.info('[Index] Auto-connecting to device:', autoConnectDevice.name);
          // 稍微延迟一下，让UI先渲染出来
          setTimeout(() => {
            this.connectDevice(autoConnectDevice);
          }, 500);
        }
      }
    } catch (err) {
      LoggerIndex.error('Init preferences failed:', err);
    }
  }

  private switchHomeTab(index: number): void {
    this.currentIndex = index;
  }

  private bottomDockBottomGap(): number {
    const centeredGap: number = this.bottomDockBarBottomMarginVp
      + (56 / 2)
      - (this.bottomDockCenterButtonHitSizeVp / 2);
    return Math.max(centeredGap, this.systemBottomInsetVp + centeredGap);
  }

  private dockReserveHeight(): number {
    return this.systemBottomInsetVp + 24;
  }

  private deviceListTopSpacerHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  private buildLiquidGlassGradient(): LinearGradientOptions {
    const colors: Array<[ResourceColor, number]> = [
      ['#82FFFFFF', 0.00],
      ['#26FFFFFF', 0.22],
      ['#12FFFFFF', 0.46],
      ['#18FFFFFF', 0.72],
      ['#00FFFFFF', 1.00]
    ];
    return {
      angle: 132,
      colors: colors
    };
  }

  private dockMaterialBackgroundColor(): ResourceColor {
    return $r('app.color.bg_card');
  }

  private dockMaterialBorderColor(): ResourceColor {
    return '#24FFFFFF';
  }

  private dockMaterialShadowColor(): ResourceColor {
    return '#18000000';
  }

  private openDeviceDetailPage(): void {
    this.resetAddDevicePrefill();
    this.showAddDeviceSheet = true;
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

  private openHomePairMethodMenu(): void {
    if (this.homePairMenuContent === undefined) {
      const params: HomePairMethodMenuParams = {
        onSelect: (index: number): void => {
          void this.selectPairMethod(index);
        }
      };
      this.homePairMenuContent = new ComponentContent(this.getUIContext(), wrapBuilder(HomePairMethodMenuBuilder), params);
    }
    this.getUIContext().getPromptAction().openMenu(this.homePairMenuContent, {
      id: this.homePairMenuButtonId
    }, {
      backgroundColor: Color.Transparent
    }).catch((err: Error) => {
      LoggerIndex.error(`[Index] open home pair method menu failed: ${err.message}`);
    });
  }

  private async closeHomePairMethodMenu(): Promise<void> {
    if (this.homePairMenuContent === undefined) {
      return;
    }
    try {
      await this.getUIContext().getPromptAction().closeMenu(this.homePairMenuContent);
    } catch (_) {
    }
  }

  private async selectPairMethod(index: number): Promise<void> {
    await this.closeHomePairMethodMenu();
    if (index === 0) {
      this.openHomeQuickConnectSheet();
      return;
    }
    if (index === 1) {
      this.homePairHostPort = '';
      this.homePairCode = '';
      this.showHomeCodePairSheet = true;
      return;
    }
    if (index === 2) {
      this.startHomeQrPairing();
    }
  }

  private isHdsImmersiveEnhancedAvailable(): boolean {
    return HdsImmersiveHelper.isHdsImmersiveEnhancedAvailable();
  }

  private buildHdsImmersiveSystemMaterialEffect(): SystemMaterialParams | undefined {
    return HdsImmersiveHelper.buildHdsImmersiveSystemMaterialEffect();
  }

  private buildDeviceTitleBarOptions(): HdsNavigationTitleBarOptions {
    const immersiveMaterialEffect: SystemMaterialParams | undefined = this.buildHdsImmersiveSystemMaterialEffect();
    const scrollEffectType: ScrollEffectType = immersiveMaterialEffect === undefined
      ? ScrollEffectType.GRADIENT_BLUR
      : ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
    return {
      avoidLayoutSafeArea: true,
      padding: {
        start: LengthMetrics.vp(24),
        end: LengthMetrics.vp(24)
      },
      content: {
        title: {
          mainTitle: $r('app.string.scrcpy_devices'),
          mainTitleSize: 22
        },
        menu: {
          value: [{
            content: {
              icon: $r('sys.symbol.link'),
              label: $r('app.string.wireless_adb_pairing'),
              componentId: this.homePairMenuButtonId,
              action: (): void => {
                this.openHomePairMethodMenu();
              }
            }
          }],
          maxCount: 1
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
            backgroundColor: '#1AFFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
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
            backgroundColor: '#1AFFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
            },
            menuStyle: {
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

  private buildMoreTitleBarOptions(): HdsNavigationTitleBarOptions {
    const immersiveMaterialEffect: SystemMaterialParams | undefined = this.buildHdsImmersiveSystemMaterialEffect();
    const scrollEffectType: ScrollEffectType = immersiveMaterialEffect === undefined
      ? ScrollEffectType.GRADIENT_BLUR
      : ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
    return {
      avoidLayoutSafeArea: true,
      padding: {
        start: LengthMetrics.vp(24),
        end: LengthMetrics.vp(24)
      },
      content: {
        title: {
          mainTitle: $r('app.string.more_title'),
          mainTitleSize: 22
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
            backgroundColor: '#1AFFFFFF'
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
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
              mainTitleColor: $r('sys.color.font_primary'),
              subTitleColor: $r('sys.color.font_secondary')
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

  private buildHomePairDeviceSheetTitleBarOptions(): HdsNavigationTitleBarOptions {
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
            this.showHomePairDeviceSheet = false;
          }
        }
      ]
    );
  }

  @Builder
  private HomeBackdrop() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_primary'))
  }

  private bottomTabColor(index: number): ResourceColor {
    return this.currentIndex === index ? $r('app.color.btn_primary') : $r('app.color.tab_color_unselected');
  }

  @Builder
  private BottomTabIcon(icon: Resource, index: number) {
    SymbolGlyph(icon)
      .fontSize(24)
      .fontColor([this.bottomTabColor(index)])
  }

  @Builder
  private BottomTabBarItem(icon: Resource, label: ResourceStr, index: number) {
    Column() {
      Row() {
        this.BottomTabIcon(icon, index)
      }
      .width(28)
      .height(28)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)

      Text(label)
        .fontSize(10)
        .fontColor(this.bottomTabColor(index))
        .height(15)
        .lineHeight(15)
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
  }

  @Builder
  private BottomAddTabBarItem() {
    Column({ space: 3 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(27)
          .fontColor([Color.White])
      }
      .width(42)
      .height(42)
      .justifyContent(FlexAlign.Center)
      .alignItems(VerticalAlign.Center)
      .borderRadius(21)
      .backgroundColor($r('app.color.btn_primary'))
      .shadow({
        radius: 12,
        color: '#22000000',
        offsetX: 0,
        offsetY: 4
      })

      Text('')
        .fontSize(10)
    }
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  HomeTabsWithFloatingStyle() {
    HdsTabs({ controller: this.homeTabsController }) {
      TabContent() {
        this.DeviceListPage()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .tabBar(this.BottomTabBarItem($r('sys.symbol.house'), $r('app.string.tab_devices'), 0))

      TabContent() {
        Column()
          .width('100%')
          .height('100%')
      }
      .tabBar(this.BottomAddTabBarItem())

      TabContent() {
        this.MorePage()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .tabBar(this.BottomTabBarItem($r('sys.symbol.gearshape'), $r('app.string.tab_more'), 2))
    }
    .width('100%')
    .height('100%')
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    .barHeight(56)
    .barFloatingStyle({
      barWidth: { smallWidth: 320, mediumWidth: 360, largeWidth: 400 },
      barBottomMargin: this.bottomDockBarBottomMarginVp,
      systemMaterialEffect: this.buildHdsImmersiveSystemMaterialEffect()
    })
    .animationDuration(300)
    .scrollable(false)
    .onContentWillChange((_currentIndex: number, comingIndex: number) => {
      if (comingIndex === 1) {
        this.openDeviceDetailPage();
        return false;
      }
      return true;
    })
    .onAnimationStart((_from: number, target: number) => {
      if (target !== 1) {
        this.currentIndex = target;
      }
    })
    .onChange((index: number) => {
      if (index !== 1) {
        this.currentIndex = index;
      }
    })
    .backgroundColor(Color.Transparent)
  }

  @Builder
  HomeTabs() {
    HdsTabs({ controller: this.homeTabsController }) {
      TabContent() {
        this.DeviceListPage()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .tabBar(this.BottomTabBarItem($r('sys.symbol.house'), $r('app.string.tab_devices'), 0))

      TabContent() {
        Column()
          .width('100%')
          .height('100%')
      }
      .tabBar(this.BottomAddTabBarItem())

      TabContent() {
        this.MorePage()
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .tabBar(this.BottomTabBarItem($r('sys.symbol.gearshape'), $r('app.string.tab_more'), 2))
    }
    .width('100%')
    .height('100%')
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    .barHeight(56)
    .margin({ bottom: this.systemBottomInsetVp + 15 })
    .animationDuration(300)
    .scrollable(false)
    .onContentWillChange((_currentIndex: number, comingIndex: number) => {
      if (comingIndex === 1) {
        this.openDeviceDetailPage();
        return false;
      }
      return true;
    })
    .onAnimationStart((_from: number, target: number) => {
      if (target !== 1) {
        this.currentIndex = target;
      }
    })
    .onChange((index: number) => {
      if (index !== 1) {
        this.currentIndex = index;
      }
    })
    .backgroundColor(Color.Transparent)
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
  private HomeCodePairSheetModal() {
    HdsNavigation() {
      this.HomeCodePairSheet()
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(HdsImmersiveHelper.buildModalTitleBarOptions(
      $r('app.string.wireless_adb_pairing_tab_code'),
      [{
        icon: $r('sys.symbol.xmark'),
        action: (): void => {
          this.showHomeCodePairSheet = false;
        }
      }]
    ))
    .bindToScrollable([this.homeCodePairSheetScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private HomeQrPairSheetModal() {
    HdsNavigation() {
      this.HomeQrPairSheet()
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
          this.handleHomeQrSheetDismiss();
        }
      }]
    ))
    .bindToScrollable([this.homeQrPairSheetScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private HomeCodePairSheet() {
    Scroll(this.homeCodePairSheetScroller) {
      Column({ space: 16 }) {
        this.HomePairSheetDesc($r('app.string.wireless_adb_pairing_code_sheet_desc'), (): void => {
          this.codePairHelpDialogController.open();
        })

        TextInput({ placeholder: $r('app.string.adb_pair_address_hint'), text: this.homePairHostPort })
          .height(52)
          .fontSize(16)
          .type(InputType.Normal)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(14)
          .caretColor($r('app.color.btn_primary'))
          .onChange((value: string) => {
            this.homePairHostPort = value;
          })

        TextInput({ placeholder: $r('app.string.adb_pair_code_hint'), text: this.homePairCode })
          .height(52)
          .fontSize(16)
          .type(InputType.Number)
          .maxLength(6)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(14)
          .caretColor($r('app.color.btn_primary'))
          .onChange((value: string) => {
            this.homePairCode = value;
          })

        Button(this.homePairing ? $r('app.string.adb_pairing') : $r('app.string.wireless_adb_pairing_start'))
          .width('100%')
          .height(48)
          .type(ButtonType.Capsule)
          .backgroundColor(this.homePairing ? $r('app.color.text_tertiary') : $r('app.color.btn_primary'))
          .enabled(!this.homePairing)
          .onClick(() => {
            this.handleHomeCodePairing();
          })
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .clip(false)
    .backgroundColor($r('app.color.bg_primary'))
  }

  @Builder
  private HomePairSheetDesc(desc: ResourceStr, onHelpClick: () => void) {
    Text() {
      Span(desc)
      Span(' ')
      Span($r('app.string.use_help'))
        .fontColor($r('app.color.btn_primary'))
    }
    .fontSize(14)
    .fontColor($r('app.color.text_secondary'))
    .lineHeight(20)
    .width('100%')
    .onClick(() => {
      onHelpClick();
    })
  }

  @Builder
  private HomeQrPairSheet() {
    Scroll(this.homeQrPairSheetScroller) {
      Column({ space: 12 }) {
        this.HomePairSheetDesc($r('app.string.wireless_adb_pairing_scan_desc'), (): void => {
          this.qrPairHelpDialogController.open();
        })

        if (this.homeQrPayload) {
          QRCode(this.homeQrPayload)
            .width(240)
            .height(240)
            .color('#111111')
            .backgroundColor('#FFFFFFFF')

          Text(this.homeQrCode)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))

          Text(this.getHomeQrStatusText())
            .fontSize(13)
            .fontColor(this.homeQrErrorText ? '#E64545' : $r('app.color.text_secondary'))
            .textAlign(TextAlign.Center)
            .width('100%')
        } else if (this.homeQrErrorText) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(28)
            .fontColor(['#E64545'])
            .margin({ top: 24 })

          Text(this.homeQrErrorText)
            .width('100%')
            .fontSize(14)
            .lineHeight(20)
            .fontColor('#E64545')
            .textAlign(TextAlign.Center)

          Button($r('app.string.wireless_adb_pairing_qr_refresh'))
            .height(40)
            .padding({ left: 18, right: 18 })
            .type(ButtonType.Capsule)
            .fontSize(14)
            .fontColor('#FFFFFF')
            .backgroundColor($r('app.color.btn_primary'))
            .enabled(!this.homeQrStarting && !this.homeQrWaiting)
            .onClick(() => {
              this.startHomeQrPairing();
            })
        } else {
          LoadingProgress()
            .width(36)
            .height(36)
            .color($r('app.color.btn_primary'))
          Text($r('app.string.wireless_adb_pairing_scan_processing'))
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .clip(false)
    .backgroundColor($r('app.color.bg_primary'))
  }

  @Builder
  private HomePairDeviceSheet() {
    HdsNavigation() {
      WirelessAdbDevicePickerSheet({
        connectHost: this.homeConnectHost,
        connectPort: this.homeConnectPort,
        devices: this.preferencesHelper.getDevicesList(),
        pairedHost: this.homePairedHost,
        sheetScroller: this.homePairDeviceSheetScroller,
        portDiscoveryStatus: this.homeConnectPortDiscoveryStatus,
        hidePortDiscoveryStatus: this.homePairDeviceSheetFromQuickConnect,
        hideDescription: this.homePairDeviceSheetFromQuickConnect,
        onConnectHostChange: (value: string): void => {
          this.homeConnectHost = value;
        },
        onConnectPortChange: (value: string): void => {
          this.homeConnectPort = value;
        },
        onConnectDevice: (device: Device): void => {
          this.connectHomePairedDevice(device);
        },
        onDefaultConnect: (): void => {
          this.connectHomeWithDefaultConfig();
        },
        onSaveAsNewDevice: (): void => {
          this.showHomePairDeviceSheet = false;
          this.homePairDeviceSheetFromQuickConnect = false;
          this.openAddDeviceSheetWithPrefill(this.homeConnectHost, this.homeConnectPort);
        },
        onRetryDiscoverPort: (): void => {
          this.retryHomeConnectPortDiscovery();
        }
      })
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(this.buildHomePairDeviceSheetTitleBarOptions())
    .bindToScrollable([this.homePairDeviceSheetScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  private HomeQuickConnectSheet() {
    Scroll(this.homeQuickConnectSheetScroller) {
      Column({ space: 16 }) {
        Text($r('app.string.wireless_adb_pairing_nearby_devices_sheet_desc'))
          .width('100%')
          .fontSize(14)
          .lineHeight(22)
          .fontColor($r('app.color.text_secondary'))

        if (this.homeQuickConnectCandidates.length > 0) {
          Column({ space: 12 }) {
            ForEach(this.homeQuickConnectCandidates, (endpoint: WirelessAdbEndpoint) => {
              Row({ space: 12 }) {
                Column() {
                  Text(endpoint.hostPort)
                    .width('100%')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(this.isHomeQuickConnectInactive(endpoint.hostPort) ? $r('app.color.text_tertiary') : $r('app.color.text_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)

                Button($r('app.string.wireless_adb_pairing_nearby_devices_use'))
                  .type(ButtonType.Capsule)
                  .height(36)
                  .padding({ left: 16, right: 16 })
                  .fontSize(14)
                  .fontColor('#FFFFFF')
                  .backgroundColor($r('app.color.btn_primary'))
                  .opacity(this.isHomeQuickConnectInactive(endpoint.hostPort) ? 0.45 : 1)
                  .enabled(!this.isHomeQuickConnectInactive(endpoint.hostPort))
                  .onClick(() => {
                    this.openHomeQuickConnectHostPort(endpoint);
                  })
              }
              .width('100%')
              .padding(16)
              .backgroundColor($r('app.color.bg_card'))
              .borderRadius(20)
              .opacity(this.isHomeQuickConnectInactive(endpoint.hostPort) ? 0.72 : 1)
            }, (endpoint: WirelessAdbEndpoint) => endpoint.hostPort)

            if (this.homeQuickConnectDiscoveryStatus === 1) {
              Row({ space: 8 }) {
                LoadingProgress()
                  .width(16)
                  .height(16)
                Text($r('app.string.wireless_adb_pairing_nearby_devices_loading'))
                  .fontSize(13)
                  .fontColor($r('app.color.text_secondary'))
              }
              .width('100%')
              .justifyContent(FlexAlign.Center)
              .padding({ top: 4 })
            }
          }
          .width('100%')
        } else if (this.homeQuickConnectDiscoveryStatus === 1) {
          Column({ space: 12 }) {
            LoadingProgress()
              .width(32)
              .height(32)

            Text($r('app.string.wireless_adb_pairing_nearby_devices_loading'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
          }
          .width('100%')
          .padding({ top: 24, bottom: 24 })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        } else {
          Column({ space: 12 }) {
            Text(this.homeQuickConnectErrorText || this.getString($r('app.string.wireless_adb_pairing_nearby_devices_empty')))
              .width('100%')
              .fontSize(14)
              .lineHeight(22)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)

            Button($r('app.string.wireless_adb_pairing_nearby_devices_retry'))
              .type(ButtonType.Capsule)
              .height(40)
              .padding({ left: 18, right: 18 })
              .fontSize(14)
              .fontColor('#FFFFFF')
              .backgroundColor($r('app.color.btn_primary'))
              .onClick(() => {
                this.retryHomeQuickConnectDiscovery();
              })
          }
          .width('100%')
          .padding({ top: 24, bottom: 24 })
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
      }
      .width('100%')
      .constraintSize({ minHeight: '100%' })
      .padding({ left: 20, right: 20, top: 8, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
    .clip(false)
    .backgroundColor($r('app.color.bg_primary'))
  }

  @Builder
  private HomeSheetAnchors() {
    Column()
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
          this.loadDevices();
        }
      })

    Column()
      .width(0)
      .height(0)
      .bindSheet(this.showHomeCodePairSheet, this.HomeCodePairSheetModal(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        dragBar: true,
        showClose: false,
        maskColor: '#66000000',
        backgroundColor: $r('app.color.bg_primary'),
        radius: LengthMetrics.vp(28),
        onDisappear: (): void => {
          this.showHomeCodePairSheet = false;
        }
      })

    Column()
      .width(0)
      .height(0)
      .bindSheet(this.showHomeQrPairSheet, this.HomeQrPairSheetModal(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        dragBar: true,
        showClose: false,
        maskColor: '#66000000',
        backgroundColor: $r('app.color.bg_primary'),
        radius: LengthMetrics.vp(28),
        onDisappear: (): void => {
          this.handleHomeQrSheetDismiss();
        }
      })

    Column()
      .width(0)
      .height(0)
      .bindSheet(this.showHomeQuickConnectSheet, this.HomeQuickConnectSheetModal(), {
        height: SheetSize.MEDIUM,
        preferType: SheetType.BOTTOM,
        dragBar: true,
        showClose: false,
        maskColor: '#66000000',
        backgroundColor: $r('app.color.bg_primary'),
        onDisappear: (): void => {
          this.handleHomeQuickConnectSheetDisappear();
        }
      })

    Column()
      .width(0)
      .height(0)
      .bindSheet(this.showHomePairDeviceSheet, this.HomePairDeviceSheet(), {
        height: SheetSize.LARGE,
        preferType: SheetType.BOTTOM,
        dragBar: true,
        showClose: false,
        maskColor: '#66000000',
        backgroundColor: $r('app.color.bg_primary'),
        radius: LengthMetrics.vp(28),
        onWillDisappear: (): void => {
          if (this.homePairDeviceSheetFromQuickConnect) {
            this.homePairDeviceSheetFromQuickConnect = false;
            this.showHomeQuickConnectSheet = true;
          }
        },
        onDisappear: (): void => {
          this.showHomePairDeviceSheet = false;
        }
      })
  }

  build() {
    Stack() {
      this.HomeBackdrop()
      if (this.isHdsImmersiveEnhancedAvailable()) {
        this.HomeTabsWithFloatingStyle()
      } else {
        this.HomeTabs()
      }

      this.HomeSheetAnchors()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  // --- Page Content Builders ---

  @Builder
  DeviceListPage() {
    HdsNavigation() {
      Column() {
        if (this.devicesList.length === 0) {
          Column() {
            Text($r('app.string.no_devices'))
              .fontSize(16)
              .fontColor($r('app.color.text_tertiary'))
            Text($r('app.string.add_device_hint'))
              .fontSize(14)
              .fontColor($r('app.color.text_placeholder'))
              .margin({ top: 8 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
        } else {
          List({ space: 12, scroller: this.deviceListScroller }) {
            ListItem() {
              Column()
                .width('100%')
                .height(this.deviceListTopSpacerHeight())
            }
            ForEach(this.devicesList, (device: Device) => {
              ListItem() {
                this.DeviceItemView(device)
              }
              .swipeAction({ end: this.ItemEnd(device) })
            })
            ListItem() {
              Column()
                .width('100%')
                .height(this.dockReserveHeight())
            }
          }
          .scrollBar(BarState.Off)
          .width('100%')
          .height('100%')
          .padding({ left: 16, right: 16 })
          .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(this.buildDeviceTitleBarOptions())
    .bindToScrollable([this.deviceListScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  MorePage() {
    HdsNavigation() {
      Column() {
        List({ scroller: this.moreListScroller }) {
          ListItem() {
            Column()
              .width('100%')
              .height(this.deviceListTopSpacerHeight())
          }

          ListItem() {
            Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.key'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.key_settings'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/AdbManagePage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })

          ListItem() {
            Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.wifi'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })

                Text($r('app.string.wireless_adb_pairing'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/WirelessAdbPairPage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })
          
          ListItem() {
            Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.translate'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.language_settings'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/LanguagePage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })

          ListItem() {
            Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.picture'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.dark_mode'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/ThemePage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })

          ListItem() {
             Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.doc_text'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.help'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/HelpPage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
           .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })
          
          ListItem() {
             Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.wifi'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.view_ip'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.showLocalIp();
            })
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })

          ListItem() {
             Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.square_and_pencil'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })

                Text($r('app.string.feedback'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }

              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/FeedbackPage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
           .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .margin({ bottom: 12 })

          ListItem() {
             Row() {
              Row() {
                SymbolGlyph($r('sys.symbol.info_circle'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.about_us'))
                  .fontSize(16)
                  .fontColor($r('app.color.text_primary'))
              }
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(24)
                .fontColor([$r('app.color.text_tertiary')])
            }
            .width('100%')
            .height(56)
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.getUIContext().getRouter().pushUrl({ url: 'pages/AboutPage' }).catch((err: Error) => {
                LoggerIndex.error('Push url failed:', err);
              });
            })
          }
           .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)

          ListItem() {
            Column()
              .width('100%')
              .height(this.dockReserveHeight())
          }
        }
        .scrollBar(BarState.Off)
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 16, top: 8 })
        .nestedScroll({ scrollForward: NestedScrollMode.SELF_ONLY, scrollBackward: NestedScrollMode.SELF_ONLY })
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
    }
    .width('100%')
    .height('100%')
    .titleMode(HdsNavigationTitleMode.MINI)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(this.buildMoreTitleBarOptions())
    .bindToScrollable([this.moreListScroller])
    .backgroundColor(Color.Transparent)
  }

  @Builder
  DeviceItemView(device: Device) {
    Column() {
      Row() {
        Column() {
          Text(device.name)
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
          Text(`${device.address}:${device.adbPort}`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))
            .margin({ top: 4 })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        
        Button($r('app.string.connect'))
          .fontSize(14)
          .padding({ left: 16, right: 16 })
          .height(36)
          .onClick(() => {
            this.connectDevice(device);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(8)
  }

  private async handleHomeCodePairing(): Promise<void> {
    if (this.homePairing) {
      return;
    }

    const hostPort = this.homePairHostPort.trim();
    const code = this.homePairCode.trim();
    if (!hostPort || !code) {
      this.showToast($r('app.string.adb_pair_fill_required'));
      return;
    }

    this.homePairing = true;
    try {
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('Context unavailable');
      }
      const guid = await this.adbKeyManager.pairDevice(context, hostPort, code);
      LoggerIndex.info(`[Index] Home code pairing success guid=${guid}`);
      const pairedHost = parseWirelessAdbEndpoint(hostPort)?.host ?? hostPort.trim();
      this.prepareHomePairedDeviceSelection(pairedHost);
      this.showHomeCodePairSheet = false;
      this.showHomePairDeviceSheet = true;
      this.showTextToast(this.getString($r('app.string.adb_pair_success')) + guid);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerIndex.error('[Index] Home code pairing failed:', error.message);
      this.showTextToast(this.resolvePairErrorMessage(error.message));
    } finally {
      this.homePairing = false;
    }
  }

  private async startHomeQrPairing(): Promise<void> {
    if (this.homeQrStarting || this.homeQrWaiting || this.homePairing) {
      return;
    }

    this.cancelHomeQrPairing(true);
    this.homeQrStarting = true;
    try {
      this.showHomeQrPairSheet = true;
      const context = this.getUIContext().getHostContext();
      if (!context) {
        throw new Error('Context unavailable');
      }

      const ip = await resolvePreferredLocalIp();
      const sessionInfo: QrPairingSessionInfo = await this.adbKeyManager.startQrPairingSession(context, ip);
      this.homeQrSessionId = sessionInfo.sessionId;
      this.homeQrCode = sessionInfo.pairingCode;
      this.homeQrErrorText = '';
      this.homeQrPayload = `WIFI:T:ADB;S:${sessionInfo.serviceName};P:${sessionInfo.pairingCode};;`;
      this.homeQrStarting = false;
      this.homeQrWaiting = true;
      LoggerIndex.info(`[Index] Home QR pairing session created sessionId=${sessionInfo.sessionId}`);
      this.waitHomeQrPairingResult(sessionInfo.sessionId);
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerIndex.error('[Index] Start home QR pairing failed:', error.message);
      this.homeQrErrorText = this.resolveQrPairErrorMessage(error.message);
      this.showTextToast(this.homeQrErrorText);
    } finally {
      if (this.homeQrSessionId === 0) {
        this.homeQrStarting = false;
      }
    }
  }

  private waitHomeQrPairingResult(sessionId: number): void {
    this.adbKeyManager.waitQrPairingSession(sessionId).then(async (result: QrPairingResult) => {
      if (this.homeQrSessionId !== sessionId) {
        return;
      }
      this.homeQrSessionId = 0;
      this.homeQrStarting = false;
      this.homeQrWaiting = false;
      this.showHomeQrPairSheet = false;
      const pairedHost = result.pairedHost;
      const knownConnectEndpoint = result.endpoint;
      LoggerIndex.info(`[Index] Home QR pairing succeeded guid=${result.guid} pairedHost=${pairedHost} hostPort=${knownConnectEndpoint?.hostPort ?? ''}`);
      this.prepareHomePairedDeviceSelection(pairedHost, knownConnectEndpoint);
      this.showHomePairDeviceSheet = true;
      this.showTextToast(this.getString($r('app.string.adb_pair_success')) + result.guid);
    }).catch((err: Error) => {
      if (this.homeQrSessionId !== sessionId) {
        return;
      }
      this.homeQrSessionId = 0;
      this.homeQrStarting = false;
      this.homeQrWaiting = false;
      const message = err instanceof Error ? err.message : String(err);
      if (message.toLowerCase().includes('canceled')) {
        return;
      }
      this.homeQrErrorText = this.resolveQrPairErrorMessage(message);
      this.showHomeQrPairSheet = true;
      this.showTextToast(this.homeQrErrorText);
    });
  }

  private prepareHomePairedDeviceSelection(pairedHost: string, knownConnectEndpoint: WirelessAdbEndpoint | null = null): void {
    LoggerIndex.info(`[Index] Prepare paired device selection pairedHost=${pairedHost} knownConnectHostPort=${knownConnectEndpoint?.hostPort ?? ''}`);
    this.homePairedHost = pairedHost;
    this.homeDiscoveredConnectEndpoint = knownConnectEndpoint;
    this.homeConnectHost = knownConnectEndpoint?.host ?? pairedHost;
    this.homeConnectPortDiscoveryStatus = knownConnectEndpoint ? 2 : 1;
    this.homeConnectPort = knownConnectEndpoint?.port ?? '';
    if (!this.homeDiscoveredConnectEndpoint) {
      this.discoverHomeConnectHostPort(pairedHost);
    }
  }

  @Builder
  private HomeQuickConnectSheetModal() {
    HdsNavigation() {
      this.HomeQuickConnectSheet()
    }
    .titleMode(HdsNavigationTitleMode.MODAL)
    .hideBackButton(true)
    .hideToolBar(true)
    .navBarWidth('100%')
    .titleBar(HdsImmersiveHelper.buildModalTitleBarOptions(
      $r('app.string.wireless_adb_pairing_nearby_devices_sheet_title'),
      [{
        icon: $r('sys.symbol.xmark'),
        action: (): void => {
          this.handleHomeQuickConnectSheetDisappear();
        }
      }]
    ))
    .bindToScrollable([this.homeQuickConnectSheetScroller])
    .backgroundColor(Color.Transparent)
  }

  private async discoverHomeConnectHostPort(pairedHost: string): Promise<void> {
    if (!pairedHost.trim()) {
      return;
    }
    const discoveryToken = ++this.homeConnectPortDiscoveryToken;
    this.homeConnectPortDiscoveryStatus = 1;
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      if (!context) {
        throw new Error('Context unavailable');
      }
      LoggerIndex.info(`[Index] Discover connect hostPort start pairedHost=${pairedHost}`);
      const discoveredHostPort = await discoverWirelessAdbConnectHostPort(context, pairedHost);
      if (this.homeConnectPortDiscoveryToken !== discoveryToken ||
        normalizeWirelessAdbAddress(this.homePairedHost) !== normalizeWirelessAdbAddress(pairedHost)) {
        return;
      }
      this.homeDiscoveredConnectEndpoint = discoveredHostPort;
      this.homeConnectHost = discoveredHostPort.host;
      this.homeConnectPort = discoveredHostPort.port;
      this.homeConnectPortDiscoveryStatus = 2;
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerIndex.warn('[Index] Discover connect hostPort failed:', error.message);
      if (this.homeConnectPortDiscoveryToken === discoveryToken &&
        normalizeWirelessAdbAddress(this.homePairedHost) === normalizeWirelessAdbAddress(pairedHost)) {
        this.homeDiscoveredConnectEndpoint = null;
        this.homeConnectPortDiscoveryStatus = 3;
      }
    }
  }

  private retryHomeConnectPortDiscovery(): void {
    if (!this.homePairedHost.trim() || this.homeConnectPortDiscoveryStatus === 1) {
      return;
    }
    ++this.homeConnectPortDiscoveryToken;
    this.homeDiscoveredConnectEndpoint = null;
    this.homeConnectPort = '';
    this.discoverHomeConnectHostPort(this.homePairedHost);
  }

  private openHomeQuickConnectSheet(): void {
    this.showHomeQuickConnectSheet = true;
  }

  private onHomeQuickConnectSheetVisibilityChange(): void {
    if (!this.showHomeQuickConnectSheet) {
      return;
    }
    setTimeout(() => {
      if (this.showHomeQuickConnectSheet) {
        this.startHomeQuickConnectDiscovery();
      }
    }, 0);
  }

  private isHomeQuickConnectInactive(hostPort: string): boolean {
    return this.homeQuickConnectInactiveCandidates.includes(hostPort);
  }

  private logHomeQuickConnectSnapshot(activeHostPorts: string[], inactiveHostPorts: string[]): void {
    const signature = `${activeHostPorts.join(',')}|${inactiveHostPorts.join(',')}`;
    if (signature === this.homeQuickConnectLastLogSignature) {
      return;
    }
    this.homeQuickConnectLastLogSignature = signature;
    if (activeHostPorts.length > 0) {
      LoggerIndex.info(`[Index] Nearby devices updated active=${activeHostPorts.join(',')} inactive=${inactiveHostPorts.join(',') || '-'}`);
      return;
    }
    if (inactiveHostPorts.length > 0) {
      LoggerIndex.info(`[Index] Nearby devices temporarily unavailable inactive=${inactiveHostPorts.join(',')}`);
      return;
    }
    LoggerIndex.info('[Index] Nearby devices scanning, no connect address discovered yet');
  }

  private stopHomeQuickConnectDiscovery(): void {
    this.homeQuickConnectDiscoverySession?.stop();
    this.homeQuickConnectDiscoverySession = null;
  }

  private applyHomeQuickConnectCandidates(activeEndpoints: WirelessAdbEndpoint[]): void {
    let candidates = [...this.homeQuickConnectCandidates];
    const existingSet = new Set(candidates.map((endpoint) => endpoint.hostPort));
    for (const endpoint of activeEndpoints) {
      if (!existingSet.has(endpoint.hostPort)) {
        candidates = [...candidates, endpoint];
      }
    }
    if (candidates.length !== this.homeQuickConnectCandidates.length ||
      candidates.some((value, index) => value.hostPort !== this.homeQuickConnectCandidates[index].hostPort)) {
      this.homeQuickConnectCandidates = candidates;
    }
    const activeSet = new Set(activeEndpoints.map((endpoint) => endpoint.hostPort));
    const inactiveCandidates = candidates
      .filter((endpoint) => !activeSet.has(endpoint.hostPort))
      .map((endpoint) => endpoint.hostPort);
    if (inactiveCandidates.length !== this.homeQuickConnectInactiveCandidates.length ||
      inactiveCandidates.some((value, index) => value !== this.homeQuickConnectInactiveCandidates[index])) {
      this.homeQuickConnectInactiveCandidates = inactiveCandidates;
    }
    this.logHomeQuickConnectSnapshot(activeEndpoints.map((endpoint) => endpoint.hostPort), inactiveCandidates);
  }

  private startHomeQuickConnectDiscovery(): void {
    this.stopHomeQuickConnectDiscovery();
    this.homeQuickConnectDiscoveryStatus = 1;
    this.homeQuickConnectErrorText = '';
    this.homeQuickConnectCandidates = [];
    this.homeQuickConnectInactiveCandidates = [];
    this.homeQuickConnectLastLogSignature = '';
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext | undefined;
      if (!context) {
        throw new Error('Context unavailable');
      }
      this.homeQuickConnectDiscoverySession = startNearbyAdbDiscovery(context, (activeEndpoints) => {
        this.applyHomeQuickConnectCandidates(activeEndpoints);
      }, (error) => {
        LoggerIndex.warn('[Index] Discover nearby devices failed:', error.message);
        this.homeQuickConnectDiscoveryStatus = 3;
        this.homeQuickConnectErrorText = this.resolveQrPairErrorMessage(error.message);
        this.stopHomeQuickConnectDiscovery();
      });
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerIndex.warn('[Index] Discover nearby devices failed:', error.message);
      this.homeQuickConnectDiscoveryStatus = 3;
      this.homeQuickConnectErrorText = this.resolveQrPairErrorMessage(error.message);
    }
  }

  private retryHomeQuickConnectDiscovery(): void {
    if (this.homeQuickConnectDiscoveryStatus === 1) {
      return;
    }
    this.startHomeQuickConnectDiscovery();
  }

  private openHomeQuickConnectHostPort(endpoint: WirelessAdbEndpoint): void {
    this.prepareHomePairedDeviceSelection(endpoint.host, endpoint);
    this.showHomeQuickConnectSheet = false;
    this.homePairDeviceSheetFromQuickConnect = true;
    this.showHomePairDeviceSheet = true;
    this.stopHomeQuickConnectDiscovery();
    this.homeQuickConnectCandidates = [];
    this.homeQuickConnectInactiveCandidates = [];
    this.homeQuickConnectDiscoveryStatus = 0;
    this.homeQuickConnectErrorText = '';
    this.homeQuickConnectLastLogSignature = '';
  }

  private handleHomeQuickConnectSheetDisappear(): void {
    this.stopHomeQuickConnectDiscovery();
    this.homeQuickConnectCandidates = [];
    this.homeQuickConnectInactiveCandidates = [];
    this.homeQuickConnectDiscoveryStatus = 0;
    this.homeQuickConnectErrorText = '';
    this.homeQuickConnectLastLogSignature = '';
    this.showHomeQuickConnectSheet = false;
  }

  private handleHomeQrSheetDismiss(): void {
    this.cancelHomeQrPairing(true);
  }

  private cancelHomeQrPairing(clearDisplay: boolean): void {
    if (this.homeQrSessionId > 0) {
      try {
        this.adbKeyManager.stopQrPairingSession(this.homeQrSessionId);
      } catch (err) {
        LoggerIndex.error('[Index] Stop home QR pairing failed:', err);
      }
    }
    this.homeQrSessionId = 0;
    this.homeQrStarting = false;
    this.homeQrWaiting = false;
    if (clearDisplay) {
      this.homeQrPayload = '';
      this.homeQrCode = '';
      this.homeQrErrorText = '';
      this.showHomeQrPairSheet = false;
    }
  }

  private getHomeQrStatusText(): ResourceStr {
    if (this.homeQrErrorText) {
      return this.homeQrErrorText;
    }
    return this.homeQrWaiting ? $r('app.string.wireless_adb_pairing_qr_status_waiting') :
      $r('app.string.wireless_adb_pairing_qr_status_ready');
  }

  private connectHomePairedDevice(device: Device): void {
    const host = this.homeConnectHost.trim() || this.homePairedHost;
    const portText = this.homeConnectPort.trim();
    if (!portText) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_required'));
      return;
    }
    const port = Number(portText);
    if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_invalid'));
      return;
    }

    const quickConnectDevice = cloneDeviceForWirelessAdb(device);
    quickConnectDevice.address = host;
    quickConnectDevice.adbPort = port;
    this.homePairDeviceSheetFromQuickConnect = false;
    this.showHomePairDeviceSheet = false;
    this.connectDevice(quickConnectDevice);
  }

  private connectHomeWithDefaultConfig(): void {
    const host = this.homeConnectHost.trim() || this.homePairedHost;
    const portText = this.homeConnectPort.trim();
    if (!portText) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_required'));
      return;
    }
    const port = Number(portText);
    if (!host || !Number.isInteger(port) || port <= 0 || port > 65535) {
      this.showToast($r('app.string.wireless_adb_pairing_connect_port_invalid'));
      return;
    }

    const defaultDevice = new Device(`wireless-adb-${Date.now()}`, Device.TYPE_NETWORK);
    defaultDevice.name = this.getString($r('app.string.wireless_adb_pairing_default_device_name'));
    defaultDevice.address = host;
    defaultDevice.adbPort = port;
    this.homePairDeviceSheetFromQuickConnect = false;
    this.showHomePairDeviceSheet = false;
    this.connectDevice(defaultDevice);
  }

  private showToast(message: Resource): void {
    this.getUIContext().getPromptAction().showToast({ message });
  }

  private showTextToast(message: string): void {
    this.getUIContext().getPromptAction().showToast({ message });
  }

  private getString(resource: Resource): string {
    return this.getUIContext().getHostContext()!.resourceManager.getStringSync(resource.id);
  }

  private resolvePairErrorMessage(rawMessage: string): string {
    const lowerMessage = rawMessage.toLowerCase();
    let detail = this.getString($r('app.string.adb_pair_failed_generic'));
    if (lowerMessage.includes('pairing address is empty') || lowerMessage.includes('must be host:port') ||
      lowerMessage.includes('invalid ipv6 pairing address')) {
      detail = this.getString($r('app.string.adb_pair_failed_invalid_address'));
    } else if (lowerMessage.includes('failed to resolve pairing address')) {
      detail = this.getString($r('app.string.adb_pair_failed_resolve'));
    } else if (lowerMessage.includes('connection refused')) {
      detail = this.getString($r('app.string.adb_pair_failed_refused'));
    } else if (lowerMessage.includes('connect timeout')) {
      detail = this.getString($r('app.string.adb_pair_failed_timeout'));
    } else if (lowerMessage.includes('tls')) {
      detail = this.getString($r('app.string.adb_pair_failed_tls'));
    } else if (lowerMessage.includes('failed to initialize pairing cipher') ||
      lowerMessage.includes('failed to decrypt peer info')) {
      detail = this.getString($r('app.string.adb_pair_failed_code_or_expired'));
    } else if (lowerMessage.includes('failed to connect pairing socket')) {
      detail = this.getString($r('app.string.adb_pair_failed_connect'));
    }
    return this.getString($r('app.string.adb_pair_failed_prefix')) + detail;
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
  
  async connectDevice(device: Device) {
    try {
      LoggerIndex.debug('[Index] Navigating to ControlPage, Worker will handle connection');

      let homeDisplayOrientation: number = -1;
      try {
        homeDisplayOrientation = display.getDefaultDisplaySync().orientation;
        LoggerIndex.info(`[Index] connectDevice capture homeDisplayOrientation=${homeDisplayOrientation} (${this.describeDisplayOrientation(homeDisplayOrientation)})`);
      } catch (err) {
        LoggerIndex.error('Capture home display orientation failed:', err);
      }
      
      // 直接跳转到控制页面
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/ControlPage',
        params: {
          device: device,
          clientReady: true,
          homeDisplayOrientation: homeDisplayOrientation
        }
      }).catch((err: Error) => {
        LoggerIndex.error('Navigate failed:', err);
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.navigate_failed') });
      });
      
    } catch (err) {
      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerIndex.error('Connect device failed:', errMsg);
      this.getUIContext().getPromptAction().showToast({ message: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.connect_error_prefix').id) + errMsg });
    }
  }

  private describeDisplayOrientation(orientation: number): string {
    switch (orientation) {
      case display.Orientation.PORTRAIT:
        return 'PORTRAIT';
      case display.Orientation.LANDSCAPE:
        return 'LANDSCAPE';
      case display.Orientation.PORTRAIT_INVERTED:
        return 'PORTRAIT_INVERTED';
      case display.Orientation.LANDSCAPE_INVERTED:
        return 'LANDSCAPE_INVERTED';
      default:
        return `UNKNOWN(${orientation})`;
    }
  }

  @Builder
  ItemEnd(device: Device) {
    Row({ space: 12 }) {
      Column() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(20)
            .fontColor([$r('app.color.icon_blue')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.bg_action_blue'))
        .onClick(() => {
          this.editDevice(device);
        })
      }
      .justifyContent(FlexAlign.Center)
      .height('100%')

      Column() {
        Button({ type: ButtonType.Circle, stateEffect: true }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(20)
            .fontColor([$r('app.color.icon_red')])
        }
        .width(40)
        .height(40)
        .backgroundColor($r('app.color.bg_action_red'))
        .onClick(() => {
          this.deleteDevice(device);
        })
      }
      .justifyContent(FlexAlign.Center)
      .height('100%')
    }
    .padding({ left: 16, right: 16 })
    .height('100%')
    .backgroundColor(Color.Transparent)
  }

  editDevice(device: Device) {
    this.getUIContext().getRouter().pushUrl({
      url: 'pages/DeviceDetail',
      params: { device: device }
    }).catch((err: Error) => {
      LoggerIndex.error('Navigate to edit page failed:', err);
    });
  }

  async deleteDevice(device: Device) {
    try {
      await this.preferencesHelper.delete(device.uuid);
      await this.loadDevices();
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.delete_success') });
      } catch (e) {
        LoggerIndex.error('Show toast failed:', e);
      }
    } catch (err) {
      LoggerIndex.error('Delete device failed:', err);
      try {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.delete_failed') });
      } catch (e) {
        LoggerIndex.error('Show toast failed:', e);
      }
    }
  }

  async showLocalIp() {
    try {
      const netHandle = await connection.getDefaultNet();
      if (!netHandle || netHandle.netId === 0) {
         this.getUIContext().getPromptAction().showToast({ message: $r('app.string.no_default_net') });
         return;
      }

      const connectionProperties = await connection.getConnectionProperties(netHandle);
      const linkAddresses = connectionProperties.linkAddresses;

      if (linkAddresses && linkAddresses.length > 0) {
        // 收集所有 IP 地址
        const ipList: string[] = [];
        for (const address of linkAddresses) {
           if (address.address.address) {
             ipList.push(address.address.address);
           }
        }
        
        if (ipList.length > 0) {
          // 更新数据并显示弹窗
          this.localIpList = ipList;
          this.ipListDialogController.open();
        } else {
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.no_valid_ip') });
        }
      } else {
        this.getUIContext().getPromptAction().showToast({ message: $r('app.string.no_net_info') });
      }
    } catch (err) {
      LoggerIndex.error('Get network info failed:', err);
      const errMsg = err instanceof Error ? err.message : String(err);
      this.getUIContext().getPromptAction().showToast({ message: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.get_ip_failed_prefix').id) + errMsg });
    }
  }

  private copyTextToClipboard(text: string): void {
    try {
      const systemPasteboard = pasteboard.getSystemPasteboard();
      const pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      systemPasteboard.setData(pasteData).then(() => {
        this.getUIContext().getPromptAction().showToast({ message: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.copy_prefix').id) + text });
      });
    } catch (e) {
      LoggerIndex.error('Copy to clipboard failed:', e);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.copy_fail') });
    }
  }
}

@CustomDialog
struct WirelessPairHelpDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  steps: ResourceStr[] = [];

  @Builder
  private HelpSteps() {
    Column({ space: 12 }) {
      ForEach(this.steps, (step: ResourceStr) => {
        Text(step)
          .width('100%')
          .fontSize(13)
          .lineHeight(20)
          .fontColor($r('app.color.text_secondary'))
      })
    }
    .width('100%')
  }

  build() {
    Column({ space: 16 }) {
      Row() {
        Text(this.title)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(18)
            .fontColor([$r('app.color.text_secondary')])
        }
        .width(36)
        .height(36)
        .backgroundColor($r('app.color.bg_primary'))
        .onClick(() => {
          this.controller?.close();
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Scroll() {
        Column() {
          this.HelpSteps()
        }
        .width('100%')
      }
      .width('100%')
      .constraintSize({ maxHeight: 420 })

      Button($r('app.string.confirm'))
        .width('100%')
        .height(44)
        .type(ButtonType.Capsule)
        .backgroundColor($r('app.color.btn_primary'))
        .onClick(() => {
          this.controller?.close();
        })
    }
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .shadow({ radius: 24, color: '#33000000', offsetY: 8 })
  }
}

@CustomDialog
struct IpListDialog {
  controller: CustomDialogController;
  @Link ipList: string[];
  onCopy: (ip: string) => void = () => {};

  build() {
    Column() {
      Text($r('app.string.local_ip_list'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 24, bottom: 8 })
      
      Text($r('app.string.click_to_copy'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 16 })

      List() {
        ForEach(this.ipList, (ip: string) => {
          ListItem() {
            Button({ type: ButtonType.Normal, stateEffect: true }) {
              Text(ip)
                .fontSize(18)
                .fontColor($r('app.color.text_primary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 16, bottom: 16 })
            }
            .backgroundColor(Color.Transparent)
            .width('100%')
            .onClick(() => {
              this.onCopy(ip);
              this.controller.close();
            })
          }
        })
      }
      .width('100%')
      .constraintSize({ maxHeight: '50%' })
      .edgeEffect(EdgeEffect.Spring)
      .divider({ strokeWidth: 0.5, color: '#1A000000', startMargin: 16, endMargin: 16 })

      Button($r('app.string.cancel'))
        .fontSize(16)
        .fontColor($r('app.color.btn_primary'))
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.controller.close();
        })
        .margin({ top: 16, bottom: 16 })
        .width('100%')
    }
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .width('80%')
    .shadow({ radius: 24, color: '#4d000000', offsetY: 8 })
  }
}

