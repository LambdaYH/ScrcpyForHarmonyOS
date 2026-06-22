import { ServerManager } from '../helper/ServerManager';
import { LoggerDeviceDetail } from '../helper/Logger';
import { common, Want } from '@kit.AbilityKit';

@Entry
@Component
struct AboutPage {
  private thisProjectRepo: string = 'https://github.com/LambdaYH/scrcpyHmos';

  private licenseDialogController: CustomDialogController = new CustomDialogController({
    builder: LicenseDialog(),
    alignment: DialogAlignment.Center,
    customStyle: true,
    maskColor: '#80000000'
  });

  private openUrl(url: string) {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    let want: Want = {
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
      // Title Bar
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
        
        Text($r('app.string.about_page_title'))
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56 + 38)
      .padding({ left: 16, right: 16, top: 38 })
      
      Scroll() {
        Column() {
          Image($r('app.media.icon_startwindow'))
            .width(80)
            .height(80)
            .borderRadius(16) // Rounded corners
            .margin({ top: 24, bottom: 16 })
            
          Text($r('app.string.about_scrcpy_name'))
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .margin({ bottom: 8 })
            
          Text('v1.0.15')
            .fontSize(14)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: 4 })
            
          Text() {
             Span($r('app.string.about_server_builtin'))
             Span(` v${ServerManager.getVersion()}`)
          }
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .margin({ bottom: 32 })


          Column() {
            // App Info (GPL-3.0)
            Text($r('app.string.about_client_section'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })
              
            Text($r('app.string.about_src_code'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .margin({ bottom: 4 })
              .alignSelf(ItemAlign.Start)

            Text(this.thisProjectRepo)
              .fontSize(14)
              .fontColor($r('app.color.btn_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 12 })
              .onClick(() => {
                this.openUrl(this.thisProjectRepo);
              })

            Text() {
              Span($r('app.string.about_license_label'))
              Span(': GPL-3.0')
            }
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 4 })

            Text($r('app.string.about_client_desc'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 24 })
              
            Divider().color($r('app.color.text_tertiary')).margin({ bottom: 24 })

            // Server Info (Apache-2.0)
            Text($r('app.string.about_server_section'))
              .fontSize(16)
              .fontWeight(FontWeight.Bold)
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 8 })
              
            Text() {
              Span($r('app.string.about_server_builtin'))
              Span(` v${ServerManager.getVersion()}`)
            }
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 4 })
              
            Text('Copyright (C) 2018 Genymobile')
              .fontSize(12)
              .fontColor($r('app.color.text_secondary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 4 })

            Text() {
              Span($r('app.string.about_license_label'))
              Span(': Apache-2.0')
            }
              .fontSize(14)
              .fontColor($r('app.color.text_primary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 12 })
              
            Text($r('app.string.about_server_desc'))
              .fontSize(14)
              .fontColor($r('app.color.text_secondary'))
              .alignSelf(ItemAlign.Start)
              .margin({ bottom: 24 })
              
            Divider().color($r('app.color.text_tertiary')).margin({ bottom: 24 })
              
            // License Link
            Row() {
              Text($r('app.string.about_view_license'))
                .fontSize(14)
                .fontColor($r('app.color.text_primary'))
              
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(16)
                .fontColor([$r('app.color.text_tertiary')])
                .margin({ left: 4 })
            }
            .width('100%')
            .justifyContent(FlexAlign.SpaceBetween)
            .padding({ top: 12, bottom: 12 })
            .onClick(() => {
              this.licenseDialogController.open();
            })
            .margin({ bottom: 8 })
          }
          .width('90%')
          .padding(16)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
        }
        .width('100%')
        .padding({ bottom: 32 })
      }
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}

@CustomDialog
struct LicenseDialog {
  controller: CustomDialogController;
  
  private licenseText: string = `=== CLIENT LICENSE (GPL-3.0) ===
GNU GENERAL PUBLIC LICENSE
Version 3, 29 June 2007

Copyright (C) 2007 Free Software Foundation, Inc. <https://fsf.org/>

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

=== SERVER LICENSE (Apache-2.0) ===
Copyright (C) 2018 Genymobile

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.`;

  build() {
    Column() {
      Text($r('app.string.about_license_dialog_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .margin({ top: 24, bottom: 16 })
        
      Scroll() {
        Text(this.licenseText)
          .fontSize(12)
          .fontColor($r('app.color.text_primary'))
          .lineHeight(18)
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16 })
      .align(Alignment.TopStart)
      
      Button($r('app.string.about_close'))
        .width('80%')
        .margin({ top: 16, bottom: 16 })
        .onClick(() => {
          this.controller.close();
        })
    }
    .width('90%')
    .height('80%')
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }
}
