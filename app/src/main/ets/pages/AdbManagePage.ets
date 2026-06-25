import { LengthMetrics } from '@kit.ArkUI';
import { DividerShowType, HdsNavigation, HdsNavigationTitleMode } from '@kit.UIDesignKit';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { AdbKeyManager } from '../helper/AdbKeyManager';
import { LoggerAdbManage } from '../helper/Logger';

@Entry
@Component
struct AdbManagePage {
  @State commonKeyInfo: string = '';
  @State publicKeyDisplay: string = '';
  @State privateKeyDisplay: string = '';
  @State private systemTopInsetVp: number = 0;
  private adbKeyManager: AdbKeyManager = AdbKeyManager.getInstance();

  aboutToAppear() {
    HdsImmersiveHelper.syncSystemTopInsetVp(this, (value: number): void => {
      this.systemTopInsetVp = value;
    });
    this.refreshData();
  }

  async refreshData() {
    // 加载公共密钥信息
    const info = this.adbKeyManager.getCommonKeyInfo();
    if (info.hasKey) {
      // this.commonKeyInfo = `当前公共密钥版本: v${info.generation}`;
      this.publicKeyDisplay = this.adbKeyManager.getPublicKey();
      this.privateKeyDisplay = this.adbKeyManager.getPrivateKey();
    } else {
      // this.commonKeyInfo = '未检测到有效密钥 (如果不重新生成，将自动创建)';
      this.publicKeyDisplay = '';
      this.privateKeyDisplay = '';
    }
  }

  private adbManageTitleOverlayHeight(): number {
    return HdsImmersiveHelper.getMiniTitleOverlayHeight(this.systemTopInsetVp);
  }

  build() {
    HdsNavigation() {
      Column() {
        Column() {
          Blank()
            .height(this.adbManageTitleOverlayHeight())
            .width('100%')

          Text($r('app.string.global_adb_key'))
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 24 })

          Text($r('app.string.public_key'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .alignSelf(ItemAlign.Start)
            .margin({ left: 32, bottom: 4 })

          TextArea({ text: this.publicKeyDisplay })
            .width('85%')
            .height(100)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_card'))
            .margin({ bottom: 16 })
            .focusable(false)
            .copyOption(CopyOptions.LocalDevice)

          Text($r('app.string.private_key'))
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .alignSelf(ItemAlign.Start)
            .margin({ left: 32, bottom: 4 })

          TextArea({ text: this.privateKeyDisplay })
            .width('85%')
            .height(100)
            .fontSize(12)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_card'))
            .margin({ bottom: 24 })
            .focusable(false)
            .copyOption(CopyOptions.LocalDevice)

          Button($r('app.string.regenerate_keys'))
            .width('80%')
            .height(48)
            .fontSize(16)
            .type(ButtonType.Capsule)
            .backgroundColor($r('app.color.btn_primary'))
            .onClick(() => {
              this.regenerateKey();
            })

          Button($r('app.string.custom_keys'))
            .width('80%')
            .height(48)
            .fontSize(16)
            .type(ButtonType.Capsule)
            .backgroundColor($r('app.color.btn_secondary'))
            .margin({ top: 12 })
            .onClick(() => {
              this.showCustomKeyDialog();
            })

          Text($r('app.string.regenerate_note'))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ top: 24 })
            .padding({ left: 32, right: 32 })
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .backgroundColor($r('app.color.bg_primary'))
      .width('100%')
      .height('100%')
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    }
    .width('100%')
    .height('100%')
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
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
          mainTitle: $r('app.string.key_management'),
          mainTitleSize: 20
        },
        divider: {
          showType: DividerShowType.OFF
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: HdsImmersiveHelper.getScrollEffectType()
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
        systemMaterialEffect: HdsImmersiveHelper.buildHdsImmersiveSystemMaterialEffect()
      }
    })
  }

  // 自定义密钥弹框

  // 自定义密钥弹框
  @State inputPublicKey: string = '';
  @State inputPrivateKey: string = '';

  private customKeyDialog: CustomDialogController = new CustomDialogController({
    builder: CustomKeyDialog({
      onConfirm: (pub: string, pri: string) => this.handleImportKey(pub, pri)
    }),
    autoCancel: true,
    customStyle: true
  })

  showCustomKeyDialog(): void {
    this.customKeyDialog.open();
  }

  async handleImportKey(pub: string, pri: string): Promise<void> {
    try {
      await this.adbKeyManager.importCustomKey(pri, pub);
      this.getUIContext().getPromptAction().showToast({ message: $r('app.string.adb_key_import_success') });
      this.refreshData();
    } catch (err) {
      const error = err instanceof Error ? err : new Error(String(err));
      LoggerAdbManage.error('Import custom key failed:', error);
      
      let friendMsg: Resource = $r('app.string.adb_key_import_fail_format');

      if (error.message.includes('empty')) {
        friendMsg = $r('app.string.adb_key_import_fail_empty');
      } else if (error.message.includes('Base64')) {
        friendMsg = $r('app.string.adb_key_import_fail_format');
      }
      
      this.getUIContext().getPromptAction().showToast({ message: friendMsg });
    }
  }

  regenerateKey() {
    try {
      this.getUIContext().getPromptAction().showDialog({
        title: this.getUIContext().getHostContext()?.resourceManager.getStringSync($r('app.string.adb_key_regenerate_confirm_title').id),
        message: this.getUIContext().getHostContext()?.resourceManager.getStringSync($r('app.string.adb_key_regenerate_confirm_msg').id),
        buttons: [
          { text: this.getUIContext().getHostContext()?.resourceManager.getStringSync($r('app.string.cancel').id), color: $r('app.color.text_secondary') },
          { text: this.getUIContext().getHostContext()?.resourceManager.getStringSync($r('app.string.confirm').id), color: $r('app.color.btn_primary') }
        ]
      }, async (err, data) => {
        if (err) {
          LoggerAdbManage.error('Show dialog error :' + JSON.stringify(err));
          return;
        }
        if (data.index === 1) {
          try {
            await this.adbKeyManager.regenerateCommonKey();
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.adb_key_regen_success') });
            this.refreshData();
          } catch (e) {
            LoggerAdbManage.error('Regenerate key failed:', e);
            this.getUIContext().getPromptAction().showToast({ message: $r('app.string.toast_fail') });
          }
        }
      });
    } catch (err) {
      LoggerAdbManage.error('Show dialog exception:', err);
    }
  }
}

@CustomDialog
struct CustomKeyDialog {
  controller?: CustomDialogController;
  onConfirm?: (pub: string, pri: string) => void;
  @State publicKey: string = '';
  @State privateKey: string = '';

  build() {
    Column() {
      Text($r('app.string.custom_keys'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ bottom: 16 })
      
      Text($r('app.string.private_key'))
        .fontSize(12)
        .alignSelf(ItemAlign.Start)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 4 })
      TextArea({ placeholder: $r('app.string.adb_key_placeholder_priv') })
        .height(100)
        .fontSize(12)
        .onChange((val) => this.privateKey = val)
        .margin({ bottom: 12 })
        
      Text($r('app.string.public_key'))
        .fontSize(12)
        .alignSelf(ItemAlign.Start)
        .fontColor($r('app.color.text_secondary'))
        .margin({ bottom: 4 })
      TextArea({ placeholder: $r('app.string.adb_key_placeholder_pub') })
        .height(100)
        .fontSize(12)
        .onChange((val) => this.publicKey = val)
        .margin({ bottom: 24 })
        
      Row() {
        Button($r('app.string.cancel'))
          .width('40%')
          .backgroundColor($r('app.color.bg_card'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.controller?.close();
          })
          
        Button($r('app.string.adb_key_save_apply'))
          .width('40%')
          .backgroundColor($r('app.color.btn_primary'))
          .onClick(() => {
            if (this.onConfirm) {
              this.onConfirm(this.publicKey, this.privateKey);
            }
            this.controller?.close();
          })
      }
      .width('100%')
      .justifyContent(FlexAlign.SpaceBetween)
    }
    .width('90%')
    .padding(24)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }
}
