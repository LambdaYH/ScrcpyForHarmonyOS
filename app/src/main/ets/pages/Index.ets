import { Device } from '../entity/Device';
import { PreferencesHelper } from '../helper/PreferencesHelper';
import { ClientSessionManager } from '../helper/ClientSessionManager';

import { Logger, LoggerIndex } from '../helper/Logger';

import { common, Want } from '@kit.AbilityKit';
import { connection } from '@kit.NetworkKit';
import pasteboard from '@ohos.pasteboard';
import { curves } from '@kit.ArkUI';

@Entry
@Component
struct Index {
  @State devicesList: Device[] = [];
  @State currentIndex: number = 0;
  @State isConnecting: boolean = false;
  @State connectionStatus: string = '';
  private preferencesHelper: PreferencesHelper = PreferencesHelper.getInstance();
  private tabsController: TabsController = new TabsController();
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
  }
  
  onPageShow() {
    // 每次显示首页时，确保清理掉可能存在的后台会话
    ClientSessionManager.getInstance().stopAll();
    this.loadDevices();
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

  @Builder
  CustomTabBar() {
    Row() {
      // Tab 1: Home
      Column() {
        SymbolGlyph($r('sys.symbol.house'))
          .fontSize(24)
          .fontColor([this.currentIndex === 0 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary')])
        Text($r('app.string.tab_devices'))
          .fontSize(10)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.currentIndex === 0 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary'))
          .margin({ top: 4 })
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .stateStyles({
        pressed: {
          .scale({ x: 0.8, y: 0.8 })
        },
        normal: {
          .scale({ x: 1.0, y: 1.0 })
        }
      })
      .animation({ curve: curves.responsiveSpringMotion(0.15, 0.86) })
      .onClick(() => {
        this.currentIndex = 0;
        this.tabsController.changeIndex(0);
      })

      // Tab 2: Add Device (Floating Action Button Style)
      Column() {
        Column() {
          SymbolGlyph($r('sys.symbol.plus'))
            .fontSize(28)
            .fontColor([Color.White])
        }
        .width(48)
        .height(48)
        .borderRadius(24)
        .backgroundColor($r('app.color.btn_primary'))
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .shadow({
          radius: 8,
          color: '#40007AFF',
          offsetX: 0,
          offsetY: 4
        })
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .stateStyles({
        pressed: {
          .scale({ x: 0.9, y: 0.9 })
        },
        normal: {
          .scale({ x: 1.0, y: 1.0 })
        }
      })
      .animation({ curve: curves.responsiveSpringMotion(0.15, 0.86) })
      .onClick(() => {
        // Direct action
        this.getUIContext().getRouter().pushUrl({ url: 'pages/DeviceDetail' }).catch((err: Error) => {
          LoggerIndex.error('Navigate failed:', err);
        });
      })

      // Tab 3: More
      Column() {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(24) // Standard 24vp
          .fontColor([this.currentIndex === 2 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary')])
        Text($r('app.string.tab_more'))
          .fontSize(10) // Standard 10fp
          .fontWeight(FontWeight.Medium)
          .fontColor(this.currentIndex === 2 ? $r('app.color.btn_primary') : $r('app.color.text_tertiary'))
          .margin({ top: 4 }) // Standard 4vp spacing
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .stateStyles({
        pressed: {
          .scale({ x: 0.9, y: 0.9 })
        },
        normal: {
          .scale({ x: 1.0, y: 1.0 })
        }
      })
      .animation({ curve: curves.responsiveSpringMotion(0.15, 0.86) })
      .onClick(() => {
        this.currentIndex = 2;
        this.tabsController.changeIndex(2);
      })
    }
    .width('100%')
    .height(56 + 12)
    .padding({ bottom: 12 })
    .backgroundColor(Color.Transparent)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK)
    .border({ width: { top: 0.5 }, color: '#1A000000' })
  }

  build() {
    Stack({ alignContent: Alignment.Bottom }) {
      // Layer 1: Tabs Content (Bar hidden)
      Tabs({ barPosition: BarPosition.End, controller: this.tabsController }) {
        // Tab 1: Devices
        TabContent() {
          this.DeviceListPage()
        }
        .tabBar(null) // Hide default bar

        // Tab 2: Placeholder for index alignment (Add Button)
        TabContent() {
        }
        .tabBar(null)

        // Tab 3: More
        TabContent() {
          this.MorePage()
        }
        .tabBar(null)
      }
      .width('100%')
      .height('100%')
      .barHeight(0) // Hide default bar
      .scrollable(false)
      .onChange((index: number) => {
        if (index === 1) {
             this.tabsController.changeIndex(this.currentIndex);
        } else {
             this.currentIndex = index;
        }
      })
      .backgroundColor($r('app.color.bg_primary'))
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // Layer 2: Custom Floating Navigation Bar
      this.CustomTabBar()
      
      // Layer 3: Connection Loading Overlay
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
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(16)
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('sys.color.mask_secondary'))
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
        .zIndex(999)
        .onClick(() => {
          // 点击遮罩层不做任何事，阻止点击穿透到下层
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  // --- Page Content Builders ---

  @Builder
  DeviceListPage() {
    Column() {
      // Title
      Row() {
        Text($r('app.string.scrcpy_devices'))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 24, right: 24, top: 38 })
      .alignItems(VerticalAlign.Center)

      // Device List
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
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 12 }) {
          ForEach(this.devicesList, (device: Device) => {
            ListItem() {
              this.DeviceItemView(device)
            }
            .swipeAction({ end: this.ItemEnd(device) })
          })
        }
        .width('100%')
        .height('100%')
        .layoutWeight(1)
        .padding({ left: 16, right: 16, top: 0, bottom: 0 })
        .edgeEffect(EdgeEffect.Spring) // 添加回弹效果
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MorePage() {
    Column() {
      // Title
      Row() {
        Text($r('app.string.more_title'))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 24, right: 24, top: 38 })
      .alignItems(VerticalAlign.Center)

      Column() {
        List() {
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
        }
        .width('100%')
        .height('100%')
        .padding(16)
        .edgeEffect(EdgeEffect.Spring) // 添加回弹效果
      }
      .layoutWeight(1)

    }
    .width('100%')
    .height('100%')
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
      
      // 直接跳转到控制页面
      this.getUIContext().getRouter().pushUrl({
        url: 'pages/ControlPage',
        params: { device: device, clientReady: true }
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
