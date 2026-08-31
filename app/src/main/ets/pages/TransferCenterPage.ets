import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import {
  TRANSFER_TASK_VERSION_KEY,
  TransferTaskManager,
  TransferTaskSnapshot,
  TransferTaskStatus,
  TransferTaskType
} from '../helper/TransferTaskManager';

@Entry
@Component
struct TransferCenterPage {
  @StorageLink(TRANSFER_TASK_VERSION_KEY)
  private taskVersion: number = 0;
  @StorageProp(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY)
  private systemTopInsetVp: number = HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  @StorageProp(HdsImmersiveHelper.BOTTOM_SAFE_INSET_VP_KEY)
  private systemBottomInsetVp: number = HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP;
  private readonly manager: TransferTaskManager = TransferTaskManager.getInstance();
  private readonly scroller: Scroller = new Scroller();

  private currentTasks(): Array<TransferTaskSnapshot> {
    const version = this.taskVersion;
    if (version < 0) return [];
    return this.manager.getTasks();
  }

  private isActive(task: TransferTaskSnapshot): boolean {
    return task.status === TransferTaskStatus.PREPARING || task.status === TransferTaskStatus.RUNNING;
  }

  private typeLabel(type: TransferTaskType): ResourceStr {
    if (type === TransferTaskType.SEND) return $r('app.string.transfer_type_send');
    if (type === TransferTaskType.PULL) return $r('app.string.transfer_type_pull');
    return $r('app.string.transfer_type_install');
  }

  private statusLabel(status: TransferTaskStatus): ResourceStr {
    if (status === TransferTaskStatus.PREPARING) return $r('app.string.transfer_status_preparing');
    if (status === TransferTaskStatus.RUNNING) return $r('app.string.transfer_status_running');
    if (status === TransferTaskStatus.COMPLETED) return $r('app.string.transfer_status_completed');
    if (status === TransferTaskStatus.CANCELLED) return $r('app.string.transfer_status_cancelled');
    return $r('app.string.transfer_status_failed');
  }

  private statusColor(status: TransferTaskStatus): ResourceColor {
    if (status === TransferTaskStatus.COMPLETED) return $r('app.color.icon_green');
    if (status === TransferTaskStatus.FAILED || status === TransferTaskStatus.CANCELLED) {
      return $r('app.color.btn_danger_text');
    }
    return $r('app.color.btn_primary');
  }

  private async confirmCancel(task: TransferTaskSnapshot): Promise<void> {
    const result = await this.getUIContext().getPromptAction().showDialog({
      title: $r('app.string.transfer_cancel_title'),
      message: `${task.deviceName} · ${task.fileName}`,
      buttons: [
        { text: $r('app.string.cancel'), color: $r('app.color.text_secondary') },
        { text: $r('app.string.transfer_cancel_confirm'), color: $r('app.color.btn_danger_text') }
      ]
    });
    if (result.index !== 1) return;
    const cancelledText = this.getUIContext().getHostContext()!.resourceManager.getStringSync(
      $r('app.string.transfer_status_cancelled').id
    );
    await this.manager.cancelTask(task.id, cancelledText);
  }

  @Builder
  private TaskCard(task: TransferTaskSnapshot) {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text(task.fileName)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('app.color.text_primary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')

          Text(`${task.deviceName} · ${task.deviceAddress}`)
            .fontSize(13)
            .fontColor($r('app.color.text_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.typeLabel(task.type))
          .fontSize(12)
          .fontColor($r('app.color.btn_primary'))
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .backgroundColor($r('app.color.bg_action_blue'))
          .borderRadius(12)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.isActive(task)) {
        Progress({ value: task.progress, total: 100, type: ProgressType.Linear })
          .width('100%')
          .height(6)
          .color($r('app.color.btn_primary'))
          .backgroundColor($r('app.color.btn_secondary'))
      }

      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(this.statusLabel(task.status))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.statusColor(task.status))

          Text(task.statusText)
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (this.isActive(task)) {
          Text(`${task.progress}%`)
            .fontSize(14)
            .fontColor($r('app.color.text_secondary'))

          Button($r('app.string.transfer_cancel_action'))
            .type(ButtonType.Capsule)
            .height(34)
            .fontSize(13)
            .fontColor($r('app.color.btn_danger_text'))
            .backgroundColor($r('app.color.btn_danger_bg'))
            .onClick((): void => {
              void this.confirmCancel(task);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
  }

  build() {
    Column() {
      Row() {
        Text($r('app.string.transfer_center'))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)

        Button() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(24)
            .fontColor([$r('app.color.text_primary')])
        }
        .type(ButtonType.Circle)
        .width(48)
        .height(48)
        .backgroundColor($r('app.color.bg_card'))
        .onClick((): void => {
          this.getUIContext().getRouter().back();
        })
      }
      .width('100%')
      .height(72)
      .padding({ left: 20, right: 20 })
      .margin({ top: this.systemTopInsetVp })

      if (this.currentTasks().length === 0) {
        Column({ space: 12 }) {
          SymbolGlyph($r('sys.symbol.link'))
            .fontSize(44)
            .fontColor([$r('app.color.text_tertiary')])

          Text($r('app.string.transfer_center_empty'))
            .fontSize(16)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .width('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll(this.scroller) {
          Column({ space: 12 }) {
            ForEach(this.currentTasks(), (task: TransferTaskSnapshot) => {
              this.TaskCard(task)
            }, (task: TransferTaskSnapshot): string => `${task.id}-${task.updatedAt}`)
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: this.systemBottomInsetVp + 16 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_primary'))
    .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
  }
}
