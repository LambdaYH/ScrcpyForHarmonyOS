import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { ClientSessionManager } from '../helper/ClientSessionManager';

import { Logger, LoggerIndex } from '../helper/Logger';

import { common, Want } from '@kit.AbilityKit';
import { LengthMetrics, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { connection } from '@kit.NetworkKit';
import pasteboard from '@ohos.pasteboard';
import display from '@ohos.display';
import { DeviceDetail } from './DeviceDetail';
import {
  DividerShowType,
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  hdsMaterial,
  ScrollEffectType,
  SystemMaterialParams
} from '@kit.UIDesignKit';

@Entry
@Component
struct Index {
  @State devicesList: Device[] = [];
  @State currentIndex: number = 0;
  @State isConnecting: boolean = false;
  @State connectionStatus: string = '';
  @State showAddDeviceSheet: boolean = false;
  @State private systemTopInsetVp: number = 0;
  @State private systemBottomInsetVp: number = 0;
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private homeTabsController: HdsTabsController = new HdsTabsController();
  private deviceListScroller: Scroller = new Scroller();
  private moreListScroller: Scroller = new Scroller();
  private readonly bottomDockHeightVp: number = 54;
  private readonly bottomDockRadiusVp: number = 27;
  private readonly bottomDockSideButtonSizeVp: number = 48;
  private readonly bottomDockCenterButtonHitSizeVp: number = 72;
  private readonly bottomDockBarBottomMarginVp: number = 28;
  private feedbackIssueUrl: string = 'https://github.com/LambdaYH/scrcpyHmos/issues/new';
  private feedbackEmailUri: string = 'mailto:scrcpyHmos@outlook.com';

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

  private feedbackDialogController: CustomDialogController = new CustomDialogController({
    builder: FeedbackDialog({
      onOpenIssue: (): void => this.openFeedbackIssue(),
      onSendEmail: (): void => this.sendFeedbackEmail()
    }),
    alignment: DialogAlignment.Center,
    autoCancel: true,
    customStyle: true
  });

  aboutToAppear() {
    this.initPreferences();
    this.applySystemBarTheme();
  }
  
  onPageShow() {
    // 每次显示首页时，确保清理掉可能存在的后台会话
    ClientSessionManager.getInstance().stopAll();
    this.loadDevices();
    this.applySystemBarTheme();
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

  private pxToVp(value: number): number {
    try {
      return this.getUIContext().px2vp(value);
    } catch (_err) {
      return value;
    }
  }

  private syncSystemAvoidArea(win: window.Window): void {
    try {
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      this.systemTopInsetVp = Math.max(0, this.pxToVp(area.topRect.height));
      this.systemBottomInsetVp = Math.max(0, this.pxToVp(area.bottomRect.height));
    } catch (_err) {
      this.systemTopInsetVp = 0;
      this.systemBottomInsetVp = 0;
    }
  }

  private applySystemBarTheme(): void {
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window): void => {
        win.setWindowLayoutFullScreen(true).catch((_err: Error): void => {});
        this.syncSystemAvoidArea(win);
        win.setWindowSystemBarProperties({
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#1A1A1A',
          navigationBarContentColor: '#1A1A1A'
        }).catch((_err: Error): void => {});
      }).catch((_err: Error): void => {});
    } catch (_err) {
      this.systemTopInsetVp = 0;
      this.systemBottomInsetVp = 0;
    }
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
    return this.systemTopInsetVp + 56;
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
    LoggerIndex.info(`[HomeTabs] openDeviceDetailPage() currentIndex=${this.currentIndex}`);
    this.showAddDeviceSheet = true;
  }

  private isHdsImmersiveEnhancedAvailable(): boolean {
    try {
      return deviceInfo.sdkApiVersion >= 23;
    } catch (_err) {
      return false;
    }
  }

  private buildHdsImmersiveSystemMaterialEffect(): SystemMaterialParams | undefined {
    if (!this.isHdsImmersiveEnhancedAvailable()) {
      return undefined;
    }
    let materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;
    let materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
    try {
      const materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
        materialType = hdsMaterial.MaterialType.ADAPTIVE;
        materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
      }
    } catch (_err) {
      materialType = hdsMaterial.MaterialType.ADAPTIVE;
      materialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
    }
    return {
      materialType: materialType,
      materialLevel: materialLevel
    };
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
        menu: undefined,
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
      LoggerIndex.info(`[HomeTabs] onContentWillChange current=${this.currentIndex} coming=${comingIndex}`);
      if (comingIndex === 1) {
        this.openDeviceDetailPage();
        return false;
      }
      return true;
    })
    .onTabBarClick((index: number) => {
      LoggerIndex.info(`[HomeTabs] onTabBarClick index=${index} current=${this.currentIndex}`);
    })
    .onAnimationStart((_from: number, target: number) => {
      LoggerIndex.info(`[HomeTabs] onAnimationStart from=${this.currentIndex} target=${target}`);
      if (target !== 1) {
        this.currentIndex = target;
      }
    })
    .onChange((index: number) => {
      LoggerIndex.info(`[HomeTabs] onChange index=${index}`);
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
      LoggerIndex.info(`[HomeTabs] onContentWillChange current=${this.currentIndex} coming=${comingIndex}`);
      if (comingIndex === 1) {
        this.openDeviceDetailPage();
        return false;
      }
      return true;
    })
    .onTabBarClick((index: number) => {
      LoggerIndex.info(`[HomeTabs] onTabBarClick index=${index} current=${this.currentIndex}`);
    })
    .onAnimationStart((_from: number, target: number) => {
      LoggerIndex.info(`[HomeTabs] onAnimationStart from=${this.currentIndex} target=${target}`);
      if (target !== 1) {
        this.currentIndex = target;
      }
    })
    .onChange((index: number) => {
      LoggerIndex.info(`[HomeTabs] onChange index=${index}`);
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
      onFinish: (): void => {
        this.showAddDeviceSheet = false;
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

      if (this.isConnecting) {
        Column() {
          Column() {
            Row() {
              Text($r('app.string.connecting'))
                .fontSize(20)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))

              if (this.connectionTime >= 0) {
                Text(` (${this.connectionTime}s)`)
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
              }
            }
            .alignItems(VerticalAlign.Center)
            .justifyContent(FlexAlign.Center)
            .margin({ bottom: 8 })

            Text(this.connectionStatus)
              .fontSize(16)
              .fontColor($r('app.color.text_secondary'))
              .textAlign(TextAlign.Center)
              .margin({ bottom: 24 })

            Button($r('app.string.cancel'))
              .fontSize(16)
              .fontColor($r('app.color.btn_primary'))
              .backgroundColor(Color.Transparent)
              .padding({ left: 16, right: 16 })
              .height(40)
              .onClick(() => {
                LoggerIndex.info('[Index] Cancel button clicked');
                this.cancelConnect();
              })
          }
          .width('80%')
          .padding(24)
          .backgroundColor('#D9FFFFFF')
          .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THICK)
          .linearGradient(this.buildLiquidGlassGradient())
          .borderRadius(24)
          .borderWidth(1)
          .borderColor('#24FFFFFF')
          .shadow({ radius: 24, color: '#16002B55', offsetX: 0, offsetY: 10 })
          .clip(true)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.mask_secondary'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .zIndex(999)
        .onClick(() => {
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
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
        this.loadDevices();
      }
    })
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
              .height(this.systemTopInsetVp + 56)
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
                SymbolGlyph($r('sys.symbol.list_bullet'))
                  .fontSize(24)
                  .fontColor([$r('app.color.text_secondary')])
                  .margin({ right: 16 })
                
                Text($r('app.string.system_log'))
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
              this.getUIContext().getRouter().pushUrl({ url: 'pages/LogPage' }).catch((err: Error) => {
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
              this.feedbackDialogController.open();
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
  
  @State connectionTime: number = 0;
  private connectionTimer: number = -1;

  private authDialogController: CustomDialogController = new CustomDialogController({
    builder: AuthDialog(),
    alignment: DialogAlignment.Center,
    autoCancel: false, // Don't allow clicking outside to dismiss easily, wait for auth
    customStyle: true
  });

  async connectDevice(device: Device) {
    if (this.isConnecting) return;
    
    this.isConnecting = true;
    
    try {
      LoggerIndex.debug('[Index] Navigating to ControlPage, Worker will handle connection');
      this.isConnecting = false;

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
      this.isConnecting = false;

      const errMsg = err instanceof Error ? err.message : String(err);
      LoggerIndex.error('Connect device failed:', errMsg);
      this.getUIContext().getPromptAction().showToast({ message: this.getUIContext().getHostContext()!.resourceManager.getStringSync($r('app.string.connect_error_prefix').id) + errMsg });
    } finally {
       // Ensure dialog is closed in case of error
       this.authDialogController.close();
    }
  }
  
  // 取消连接
  cancelConnect() {
    if (this.connectionTimer !== -1) {
      clearInterval(this.connectionTimer);
      this.connectionTimer = -1;
    }

    this.isConnecting = false;
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

  private openFeedbackIssue(): void {
    this.openExternalUri(this.feedbackIssueUrl, 'Open feedback issue failed:');
  }

  private sendFeedbackEmail(): void {
    this.openExternalUri(this.feedbackEmailUri, 'Open feedback email failed:');
  }

  private openExternalUri(uri: string, logMessage: string): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      entities: ['entity.system.browsable'],
      uri: uri
    };
    context.startAbility(want).catch((err: Error) => {
      LoggerIndex.error(logMessage, err);
    });
  }
}

@CustomDialog
struct FeedbackDialog {
  controller: CustomDialogController;
  onOpenIssue: () => void = () => {};
  onSendEmail: () => void = () => {};

  build() {
    Column() {
      Text($r('app.string.feedback_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ top: 24, bottom: 8 })

      Text($r('app.string.feedback_desc'))
        .fontSize(14)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .margin({ left: 24, right: 24, bottom: 16 })

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row() {
          Text($r('app.string.feedback_github_issue'))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%')
        .height(52)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.controller.close();
        this.onOpenIssue();
      })

      Divider().color($r('app.color.text_tertiary')).opacity(0.35)

      Button({ type: ButtonType.Normal, stateEffect: true }) {
        Row() {
          Text($r('app.string.feedback_email'))
            .fontSize(16)
            .fontColor($r('app.color.text_primary'))

          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(18)
            .fontColor([$r('app.color.text_tertiary')])
        }
        .width('100%')
        .height(52)
        .justifyContent(FlexAlign.SpaceBetween)
        .padding({ left: 16, right: 16 })
      }
      .width('100%')
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.controller.close();
        this.onSendEmail();
      })

      Button($r('app.string.cancel'))
        .fontSize(16)
        .fontColor($r('app.color.btn_primary'))
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.controller.close();
        })
        .margin({ top: 8, bottom: 16 })
        .width('100%')
    }
    .width('82%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .shadow({ radius: 24, color: '#4d000000', offsetY: 8 })
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

@CustomDialog
struct AuthDialog {
  controller: CustomDialogController;

  build() {
    Column() {
      // 图标
      Text($r('app.string.adb_auth_title'))
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 12 })
      
      Text($r('app.string.adb_auth_message'))
        .fontSize(16)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .opacity(0.8)
        .margin({ bottom: 32 })
      
      // 等待动画
      LoadingProgress()
        .width(32)
        .height(32)
        .color($r('app.color.btn_primary'))
    }
    .width('80%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(24)
    .padding(32)
    .shadow({ radius: 24, color: '#4d000000', offsetY: 8 })
  }
}
