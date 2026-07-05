@CustomDialog
export struct WirelessAdbPickerHelpDialog {
  controller?: CustomDialogController;
  title: ResourceStr = '';
  steps: ResourceStr[] = [];

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
