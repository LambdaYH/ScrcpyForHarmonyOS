// ADB 半模态面板：命令输入、结果卡、全局快捷命令浏览/维护
import { common } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { HdsImmersiveHelper } from '../helper/HdsImmersiveHelper';
import { QuickAdbCommandStore } from '../helper/QuickAdbCommandStore';
import { AdbCommandUtils, TruncatedText } from '../helper/AdbCommandUtils';
import { LoggerAdbConsole } from '../helper/Logger';
import {
  AdbExecOutcome,
  QuickAdbCommand,
  QuickAdbCommandDraft,
  createEmptyAdbExecOutcome
} from '../entity/AdbCommand';

interface AdbCommandTemplate {
  label: Resource;
  command: string;
}

@Component
export struct AdbConsoleView {
  deviceName: string = '';
  deviceAddress: string = '';
  @Prop connected: boolean = false;
  @Link manageMode: boolean;
  onRequestClose: () => void = (): void => {};
  executeCommand: (command: string, timeoutSeconds: number) => Promise<AdbExecOutcome> =
    (): Promise<AdbExecOutcome> => Promise.resolve(createEmptyAdbExecOutcome());

  @StorageProp(HdsImmersiveHelper.BOTTOM_SAFE_INSET_VP_KEY)
  private bottomInset: number = HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP;

  @State private input: string = '';
  @State private selectedCommandId: string = '';
  @Prop executing: boolean = false;
  @State private result?: AdbExecOutcome = undefined;
  @State private resultCommand: string = '';
  @State private resultCollapsed: boolean = false;
  @State private commands: QuickAdbCommand[] = [];
  @State private history: string[] = [];
  @State private loaded: boolean = false;
  @State private searchText: string = '';
  private savingCommands: boolean = false;

  private readonly store: QuickAdbCommandStore = QuickAdbCommandStore.getInstance();
  private readonly searchThreshold: number = 8;
  private editorController?: CustomDialogController = undefined;
  private active: boolean = false;

  aboutToAppear(): void {
    this.active = true;
    void this.loadStoredCommands();
  }

  aboutToDisappear(): void {
    this.active = false;
    this.editorController?.close();
  }

  private async loadStoredCommands(): Promise<void> {
    try {
      const context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context !== undefined && context !== null) {
        await this.store.init(context);
        this.commands = this.store.getCommands();
        this.history = this.store.getHistory();
      }
    } catch (err) {
      LoggerAdbConsole.error('Failed to init adb console store:', err);
    } finally {
      this.loaded = this.store.isReady();
    }
  }

  private resourceText(res: Resource): string {
    try {
      const context: common.UIAbilityContext | undefined = this.getUIContext().getHostContext() as common.UIAbilityContext;
      if (context === undefined || context === null) {
        return '';
      }
      return context.resourceManager.getStringSync(res.id);
    } catch (err) {
      return '';
    }
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      LoggerAdbConsole.warn('Failed to show toast:', err);
    }
  }

  private canSend(): boolean {
    return this.connected && !this.executing && AdbCommandUtils.normalizeCommand(this.input).length > 0;
  }

  private filteredCommands(): QuickAdbCommand[] {
    const keyword: string = this.searchText.trim().toLowerCase();
    if (keyword.length === 0) {
      return this.commands;
    }
    return this.commands.filter((item: QuickAdbCommand): boolean => {
      return item.name.toLowerCase().indexOf(keyword) >= 0
        || item.command.toLowerCase().indexOf(keyword) >= 0;
    });
  }

  private templates(): AdbCommandTemplate[] {
    const list: AdbCommandTemplate[] = [
      { label: $r('app.string.adb_template_battery'), command: 'dumpsys battery' },
      { label: $r('app.string.adb_template_packages'), command: 'pm list packages -3' },
      { label: $r('app.string.adb_template_brightness'), command: 'settings get system screen_brightness' }
    ];
    return list;
  }

  private async send(): Promise<void> {
    const command: string = this.input.trim();
    if (!this.canSend()) {
      return;
    }
    this.dismissKeyboard();
    const selected: QuickAdbCommand | undefined = this.commands.find((item: QuickAdbCommand): boolean => {
      return item.id === this.selectedCommandId && item.command.trim() === command;
    });
    if (selected !== undefined) {
      await this.runCommand(selected.command, selected.timeoutSeconds, selected.confirmBeforeRun);
      return;
    }
    await this.runCommand(command, AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS, false);
  }

  private async runQuick(item: QuickAdbCommand): Promise<void> {
    if (!this.connected || this.executing) {
      return;
    }
    this.dismissKeyboard();
    await this.runCommand(item.command, item.timeoutSeconds, item.confirmBeforeRun);
  }

  private dismissKeyboard(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (err) {
      LoggerAdbConsole.warn('Failed to clear focus:', err);
    }
  }

  private async runCommand(command: string, timeoutSeconds: number, forceConfirm: boolean): Promise<void> {
    if (this.executing || !this.connected) {
      return;
    }
    this.executing = true;
    let confirmed: boolean = true;
    if (forceConfirm) {
      confirmed = await this.confirmDialog(
        $r('app.string.adb_console_confirm_run_title'),
        `${this.resourceText($r('app.string.adb_console_confirm_run_message'))}\n\n$ ${command}`,
        $r('app.color.btn_primary'),
        $r('app.string.adb_console_continue')
      );
    } else {
      const dangerKeyword: string = AdbCommandUtils.detectDanger(command);
      if (dangerKeyword.length > 0) {
        confirmed = await this.confirmDialog(
          $r('app.string.adb_console_danger_title'),
          `${this.resourceText($r('app.string.adb_console_danger_message'))}\n\n[${dangerKeyword}]\n$ ${command}`,
          $r('app.color.btn_danger_text'),
          $r('app.string.adb_console_continue')
        );
      }
    }
    if (!confirmed || !this.connected || !this.active) {
      this.executing = false;
      return;
    }

    this.resultCollapsed = false;
    this.resultCommand = command;
    try {
      const outcome: AdbExecOutcome = await this.executeCommand(
        command,
        AdbCommandUtils.normalizeTimeout(timeoutSeconds)
      );
      this.result = outcome;
    } catch (err) {
      const failure: AdbExecOutcome = createEmptyAdbExecOutcome();
      failure.errorMessage = `${err}`;
      this.result = failure;
      LoggerAdbConsole.error('Adb command execution failed:', err);
    } finally {
      this.executing = false;
    }
    try {
      await this.store.recordHistory(command);
      this.history = this.store.getHistory();
    } catch (err) {
      LoggerAdbConsole.warn('Failed to save command history:', err);
    }
  }

  private async confirmDialog(
    title: ResourceStr,
    message: string,
    confirmColor: ResourceStr,
    confirmText: ResourceStr
  ): Promise<boolean> {
    try {
      const response = await this.getUIContext().getPromptAction().showDialog({
        title: title,
        message: message,
        buttons: [
          { text: $r('app.string.cancel'), color: $r('app.color.text_secondary') },
          { text: confirmText, color: confirmColor }
        ]
      });
      return response.index === 1;
    } catch (err) {
      LoggerAdbConsole.error('Failed to show confirm dialog:', err);
      return false;
    }
  }

  private openEditor(existing?: QuickAdbCommand): void {
    const isEdit: boolean = existing !== undefined;
    this.editorController = new CustomDialogController({
      builder: QuickCommandEditorDialog({
        isEdit: isEdit,
        initialName: existing !== undefined ? existing.name : '',
        initialCommand: existing !== undefined ? existing.command : this.input,
        initialConfirm: existing !== undefined ? existing.confirmBeforeRun : false,
        initialTimeout: existing !== undefined ? existing.timeoutSeconds : AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS,
        onSave: (draft: QuickAdbCommandDraft): Promise<boolean> => {
          return this.saveCommand(existing, draft);
        }
      }),
      customStyle: true,
      alignment: DialogAlignment.Center,
      autoCancel: true
    });
    this.editorController.open();
  }

  private async saveCommand(existing: QuickAdbCommand | undefined, draft: QuickAdbCommandDraft): Promise<boolean> {
    if (this.savingCommands) {
      return false;
    }
    this.savingCommands = true;
    try {
      if (existing !== undefined) {
        await this.store.updateCommand(existing.id, draft);
      } else {
        const added: QuickAdbCommand | undefined = await this.store.addCommand(draft);
        if (added === undefined) {
          this.toast($r('app.string.adb_console_limit_reached'));
          return false;
        }
      }
      this.commands = this.store.getCommands();
      this.toast($r('app.string.adb_console_saved'));
      return true;
    } catch (err) {
      LoggerAdbConsole.error('Failed to save quick command:', err);
      this.toast($r('app.string.adb_console_save_failed'));
      return false;
    } finally {
      this.savingCommands = false;
    }
  }

  private async deleteCommand(item: QuickAdbCommand): Promise<void> {
    const confirmed: boolean = await this.confirmDialog(
      $r('app.string.adb_console_delete_title'),
      `${item.name}\n$ ${item.command}\n\n${this.resourceText($r('app.string.adb_console_delete_message'))}`,
      $r('app.color.btn_danger_text'),
      $r('app.string.adb_console_delete')
    );
    if (!confirmed || this.savingCommands) {
      return;
    }
    this.savingCommands = true;
    try {
      await this.store.removeCommand(item.id);
      this.commands = this.store.getCommands();
      this.toast($r('app.string.adb_console_deleted'));
    } catch (err) {
      this.toast($r('app.string.adb_console_save_failed'));
    } finally {
      this.savingCommands = false;
    }
  }

  private async applyTemplate(template: AdbCommandTemplate): Promise<void> {
    const draft: QuickAdbCommandDraft = {
      name: this.resourceText(template.label),
      command: template.command,
      confirmBeforeRun: false,
      timeoutSeconds: AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS
    };
    await this.saveCommand(undefined, draft);
  }

  private toggleManageMode(): void {
    this.manageMode = !this.manageMode;
    this.searchText = '';
  }

  private async reorderCommands(fromIndex: number, targetIndex: number): Promise<void> {
    if (this.savingCommands || targetIndex === fromIndex) {
      return;
    }
    this.savingCommands = true;
    // onMove 的索引是最终位置。同步调整列表数据，让系统完成落位动效。
    const moved: QuickAdbCommand[] = this.commands.splice(fromIndex, 1);
    this.commands.splice(targetIndex, 0, moved[0]);
    try {
      await this.store.moveCommand(fromIndex, targetIndex);
    } catch (err) {
      this.commands = this.store.getCommands();
      this.toast($r('app.string.adb_console_save_failed'));
    } finally {
      this.savingCommands = false;
    }
  }

  private resultOutput(): string {
    const result: AdbExecOutcome | undefined = this.result;
    if (result === undefined) {
      return '';
    }
    let text: string = result.stdout;
    if (result.stderr.length > 0) {
      text += (text.length > 0 ? '\n\n' : '') + '[stderr]\n' + result.stderr;
    }
    if (text.length === 0 && result.errorMessage.length > 0) {
      text = result.errorMessage;
    }
    return text;
  }

  private resultDisplay(): TruncatedText {
    const text: string = this.resultOutput();
    if (text.length === 0) {
      const empty: TruncatedText = { text: this.resourceText($r('app.string.adb_console_no_output')), truncated: false };
      return empty;
    }
    return AdbCommandUtils.truncate(text, AdbCommandUtils.MAX_DISPLAY_CHARS);
  }

  private resultOk(): boolean {
    return this.result !== undefined && this.result.ok;
  }

  private resultStatusText(): string {
    if (this.executing) {
      return this.resourceText($r('app.string.adb_console_executing'));
    }
    const result: AdbExecOutcome | undefined = this.result;
    if (result === undefined) {
      return '';
    }
    if (result.timedOut) {
      return `${this.resourceText($r('app.string.adb_console_timed_out'))} · ${result.elapsedMs} ms`;
    }
    if (result.errorMessage.length > 0) {
      return `${this.resourceText($r('app.string.adb_console_exec_failed'))} · ${result.errorMessage}`;
    }
    if (!result.exitCodeReliable) {
      return `${this.resourceText($r('app.string.adb_console_exit_unknown'))} · ${result.elapsedMs} ms`;
    }
    return `exit ${result.exitCode} · ${result.elapsedMs} ms`;
  }

  private async copyOutput(): Promise<void> {
    try {
      const text: string = this.resultDisplay().text;
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast($r('app.string.adb_console_copied'));
    } catch (err) {
      LoggerAdbConsole.error('Failed to copy adb output:', err);
    }
  }

  @Builder
  private HeaderBar() {
    Row() {
      Text($r('app.string.adb_console_title'))
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_title'))

      Blank()

      Button() {
        SymbolGlyph($r('sys.symbol.xmark'))
          .fontSize(18)
          .fontColor([$r('app.color.text_primary')])
      }
      .width(36)
      .height(36)
      .backgroundColor($r('app.color.sheet_close_bg'))
      .borderRadius(18)
      .onClick(() => {
        this.onRequestClose();
      })
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 8, bottom: 4 })
  }

  @Builder
  private DeviceRow() {
    Row({ space: 8 }) {
      Text(this.deviceName.length > 0 ? this.deviceName : this.deviceAddress)
        .fontSize(13)
        .fontColor($r('app.color.text_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '55%' })

      Text(this.deviceAddress)
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)

      Column()
        .width(7)
        .height(7)
        .borderRadius(3.5)
        .backgroundColor(this.connected ? $r('app.color.icon_green') : $r('app.color.text_tertiary'))

      Text(this.connected ? $r('app.string.adb_console_connected') : $r('app.string.adb_console_disconnected'))
        .fontSize(12)
        .fontColor(this.connected ? $r('app.color.icon_green') : $r('app.color.text_tertiary'))
    }
    .width('100%')
    .padding({ left: 20, right: 20, top: 4, bottom: 8 })
  }

  @Builder
  private InputCard() {
    Row({ space: 8 }) {
      Text('$')
        .fontSize(15)
        .fontFamily('monospace')
        .fontColor($r('app.color.text_tertiary'))

      TextInput({ text: this.input, placeholder: $r('app.string.adb_console_input_placeholder') })
        .layoutWeight(1)
        .height(42)
        .fontSize(14)
        .fontFamily('monospace')
        .backgroundColor(Color.Transparent)
        .padding({ left: 0, right: 0 })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string) => {
          this.input = value;
          const selected: QuickAdbCommand | undefined = this.commands.find((item: QuickAdbCommand): boolean => {
            return item.id === this.selectedCommandId;
          });
          // 程序填入快捷命令也会触发 onChange；仅用户改变命令内容时退出快捷命令模式。
          if (selected === undefined || value.trim() !== selected.command.trim()) {
            this.selectedCommandId = '';
          }
        })
        .onSubmit(() => {
          void this.send();
        })

      Button(this.executing ? $r('app.string.adb_console_executing') : $r('app.string.adb_console_send'))
        .type(ButtonType.Capsule)
        .height(36)
        .fontSize(13)
        .fontColor(Color.White)
        .backgroundColor($r('app.color.btn_primary'))
        .opacity(this.canSend() ? 1 : 0.45)
        .enabled(this.canSend())
        .onClick(() => {
          void this.send();
        })
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 6, bottom: 6 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
  }

  @Builder
  private HistoryRow() {
    Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
      Text($r('app.string.adb_console_recent'))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin(3)

      ForEach(this.history.slice(0, 6), (command: string) => {
        Text(command)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '30%' })
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .margin(3)
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(12)
          .onClick(() => {
            this.input = command;
            this.selectedCommandId = '';
          })
      }, (command: string) => command)
    }
    .width('100%')
  }

  @Builder
  private DisconnectedHint() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.exclamationmark_circle'))
        .fontSize(16)
        .fontColor([$r('app.color.btn_danger_text')])
      Text($r('app.string.adb_console_not_connected'))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding(12)
    .backgroundColor($r('app.color.btn_danger_bg'))
    .borderRadius(12)
  }

  @Builder
  private SectionHeader() {
    Row({ space: 8 }) {
      Row({ space: 6 }) {
        Text($r('app.string.adb_console_quick_commands'))
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: '85%' })

        Text(`${this.commands.length}`)
          .fontSize(12)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(1)

      Button($r('app.string.adb_console_new_command'))
        .type(ButtonType.Capsule)
        .height(36)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor(Color.White)
        .padding({ left: 14, right: 14 })
        .backgroundColor($r('app.color.btn_primary'))
        .enabled(this.loaded && this.commands.length < 50)
        .opacity(this.loaded && this.commands.length < 50 ? 1 : 0.4)
        .onClick(() => {
          this.openEditor(undefined);
        })

      Button(this.manageMode ? $r('app.string.adb_console_done') : $r('app.string.adb_console_manage'))
        .type(ButtonType.Capsule)
        .height(36)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.btn_primary'))
        .padding({ left: 14, right: 14 })
        .backgroundColor($r('app.color.bg_card'))
        .border({ width: 1, color: $r('app.color.btn_primary') })
        .onClick(() => {
          this.toggleManageMode();
        })
    }
    .width('100%')
  }

  @Builder
  private SearchField() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(16)
        .fontColor([$r('app.color.text_tertiary')])

      TextInput({ text: this.searchText, placeholder: $r('app.string.adb_console_search_placeholder') })
        .layoutWeight(1)
        .height(36)
        .fontSize(13)
        .backgroundColor(Color.Transparent)
        .onChange((value: string) => {
          this.searchText = value;
        })
    }
    .width('100%')
    .padding({ left: 12, right: 12 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(12)
  }

  @Builder
  private QuickRow(item: QuickAdbCommand) {
    Row({ space: 10 }) {
      Column({ space: 3 }) {
        Text(item.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(item.command)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .onClick(() => {
        this.input = item.command;
        this.selectedCommandId = item.id;
      })

      Button() {
        SymbolGlyph($r('sys.symbol.play_circle'))
          .fontSize(22)
          .fontColor([$r('app.color.btn_primary')])
      }
      .width(36)
      .height(36)
      .backgroundColor(Color.Transparent)
      .borderRadius(18)
      .enabled(this.connected && !this.executing)
      .opacity(this.connected && !this.executing ? 1 : 0.35)
      .onClick(() => {
        void this.runQuick(item);
      })
    }
    .width('100%')
    .padding({ left: 14, right: 6, top: 10, bottom: 10 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
  }

  @Builder
  private QuickList() {
    Column({ space: 8 }) {
      ForEach(this.filteredCommands(), (item: QuickAdbCommand) => {
        this.QuickRow(item)
      }, (item: QuickAdbCommand) => `${item.id}:${item.updatedAt}`)
    }
    .width('100%')
  }

  @Builder
  private EmptyState() {
    Column({ space: 10 }) {
      Text($r('app.string.adb_console_empty_title'))
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))

      Text($r('app.string.adb_console_empty_desc'))
        .fontSize(12)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)

      Text($r('app.string.adb_console_templates'))
        .fontSize(12)
        .fontColor($r('app.color.text_tertiary'))
        .margin({ top: 6 })

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center }) {
        ForEach(this.templates(), (template: AdbCommandTemplate) => {
          Text(template.label)
            .fontSize(12)
            .fontColor($r('app.color.btn_primary'))
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor($r('app.color.bg_primary'))
            .borderRadius(12)
            .margin(4)
            .onClick(() => {
              void this.applyTemplate(template);
            })
        }, (template: AdbCommandTemplate) => template.command)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(16)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  private ResultCard() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        if (this.executing) {
          LoadingProgress()
            .width(16)
            .height(16)
            .color($r('app.color.btn_primary'))
        } else {
          Column()
            .width(8)
            .height(8)
            .borderRadius(4)
            .backgroundColor(this.resultOk() ? $r('app.color.icon_green') : $r('app.color.btn_danger_text'))
        }

        Text(this.resultStatusText())
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        if (!this.executing) {
          Text($r('app.string.adb_console_copy'))
            .fontSize(12)
            .fontColor($r('app.color.btn_primary'))
            .onClick(() => {
              void this.copyOutput();
            })

          Text(this.resultCollapsed ? $r('app.string.adb_console_expand') : $r('app.string.adb_console_collapse'))
            .fontSize(12)
            .fontColor($r('app.color.text_secondary'))
            .margin({ left: 10 })
            .onClick(() => {
              this.resultCollapsed = !this.resultCollapsed;
            })
        }
      }
      .width('100%')

      if (!this.executing && this.resultCommand.length > 0) {
        Text(`$ ${this.resultCommand}`)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (!this.executing && !this.resultCollapsed) {
        Text(this.resultDisplay().text)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_primary'))
          .lineHeight(18)
          .maxLines(6)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .copyOption(CopyOptions.LocalDevice)

        if (this.resultDisplay().truncated) {
          Text($r('app.string.adb_console_output_truncated'))
            .fontSize(11)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(14)
  }

  @Builder
  private BrowseView() {
    Column({ space: 10 }) {
      this.InputCard()
      if (this.executing || this.result !== undefined) {
        this.ResultCard()
      }
      if (!this.connected) {
        this.DisconnectedHint()
      }
      this.SectionHeader()
      if (this.commands.length > this.searchThreshold) {
        this.SearchField()
      }
      if (this.history.length > 0) {
        this.HistoryRow()
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 4, bottom: 6 })

    Scroll() {
      Column() {
        if (!this.loaded) {
          Button($r('app.string.adb_console_retry_load'))
            .onClick(() => {
              void this.loadStoredCommands();
            })
        } else if (this.commands.length === 0) {
          this.EmptyState()
        } else if (this.filteredCommands().length === 0) {
          Text($r('app.string.adb_console_empty_search'))
            .fontSize(12)
            .fontColor($r('app.color.text_tertiary'))
            .width('100%')
            .textAlign(TextAlign.Center)
            .padding({ top: 12, bottom: 12 })
        } else {
          this.QuickList()
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .justifyContent(FlexAlign.Start)
      .padding({ left: 16, right: 16, top: 4, bottom: this.bottomInset + 24 })
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.TopStart)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring)
  }

  @Builder
  private ManageRow(item: QuickAdbCommand) {
    Row({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.line_3_horizontal'))
        .fontSize(18)
        .fontColor([$r('app.color.text_tertiary')])

      Column({ space: 3 }) {
        Text(item.name)
          .fontSize(14)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(item.command)
          .fontSize(12)
          .fontFamily('monospace')
          .fontColor($r('app.color.text_secondary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Button() {
        SymbolGlyph($r('sys.symbol.square_and_pencil'))
          .fontSize(18)
          .fontColor([$r('app.color.btn_primary')])
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .borderRadius(17)
      .onClick(() => {
        this.openEditor(item);
      })

      Button() {
        SymbolGlyph($r('sys.symbol.trash'))
          .fontSize(18)
          .fontColor([$r('app.color.btn_danger_text')])
      }
      .width(34)
      .height(34)
      .backgroundColor(Color.Transparent)
      .borderRadius(17)
      .onClick(() => {
        void this.deleteCommand(item);
      })
    }
    .width('100%')
    .padding({ left: 12, right: 4, top: 10, bottom: 10 })
  }

  @Builder
  private ManageView() {
    Column() {
      Column() {
        this.SectionHeader()
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 4 })

      List({ space: 10 }) {
        ForEach(this.commands, (item: QuickAdbCommand) => {
          ListItem() {
            this.ManageRow(item)
          }
          .backgroundColor($r('app.color.bg_card'))
          .borderRadius(14)
        }, (item: QuickAdbCommand) => `${item.id}:${item.updatedAt}`)
          .onMove((from: number, to: number) => {
            void this.reorderCommands(from, to);
          })
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .clipContent(ContentClipMode.BOUNDARY)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      Text($r('app.string.adb_console_shell_warning'))
        .fontSize(11)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .padding({ left: 20, right: 20, bottom: this.bottomInset + 12 })
    }
    .width('100%')
    .layoutWeight(1)
  }

  build() {
    Column() {
      this.HeaderBar()
      this.DeviceRow()

      if (this.manageMode) {
        this.ManageView()
      } else {
        this.BrowseView()
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Start)
    .backgroundColor($r('app.color.bg_primary'))
  }
}

@CustomDialog
struct QuickCommandEditorDialog {
  controller?: CustomDialogController = undefined;
  isEdit: boolean = false;
  initialName: string = '';
  initialCommand: string = '';
  initialConfirm: boolean = false;
  initialTimeout: number = AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS;
  onSave: (draft: QuickAdbCommandDraft) => Promise<boolean> = (): Promise<boolean> => Promise.resolve(false);

  @State private name: string = '';
  @State private command: string = '';
  @State private confirmBeforeRun: boolean = false;
  @State private timeoutText: string = '15';
  @State private saving: boolean = false;

  aboutToAppear(): void {
    this.name = this.initialName;
    this.command = this.initialCommand;
    this.confirmBeforeRun = this.initialConfirm;
    this.timeoutText = `${AdbCommandUtils.normalizeTimeout(this.initialTimeout)}`;
  }

  private async submit(): Promise<void> {
    if (this.saving) {
      return;
    }
    const name: string = this.name.trim();
    const command: string = this.command.trim();
    if (name.length === 0) {
      this.toast($r('app.string.adb_console_name_required'));
      return;
    }
    if (command.length === 0) {
      this.toast($r('app.string.adb_console_command_required'));
      return;
    }
    const parsed: number = Number.parseInt(this.timeoutText, 10);
    const seconds: number = Number.isFinite(parsed) ? parsed : AdbCommandUtils.DEFAULT_TIMEOUT_SECONDS;
    const draft: QuickAdbCommandDraft = {
      name: name,
      command: command,
      confirmBeforeRun: this.confirmBeforeRun,
      timeoutSeconds: AdbCommandUtils.normalizeTimeout(seconds)
    };
    this.saving = true;
    try {
      if (await this.onSave(draft)) {
        this.controller?.close();
      }
    } finally {
      this.saving = false;
    }
  }

  private toast(message: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      LoggerAdbConsole.warn('Failed to show editor toast:', err);
    }
  }

  build() {
    Scroll() {
      Column({ space: 10 }) {
        Text(this.isEdit ? $r('app.string.adb_console_editor_edit') : $r('app.string.adb_console_editor_new'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .width('100%')
          .textAlign(TextAlign.Start)

        Text($r('app.string.adb_console_name_label'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        TextInput({ text: this.name, placeholder: $r('app.string.adb_console_name_placeholder') })
          .height(42)
          .fontSize(14)
          .onChange((value: string) => {
            this.name = value;
          })

        Text($r('app.string.adb_console_command_label'))
          .fontSize(12)
          .fontColor($r('app.color.text_secondary'))
          .width('100%')

        TextArea({ text: this.command, placeholder: $r('app.string.adb_console_command_placeholder') })
          .height(96)
          .fontSize(13)
          .fontFamily('monospace')
          .onChange((value: string) => {
            this.command = value;
          })

        Row() {
          Text($r('app.string.adb_console_timeout_label'))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          TextInput({ text: this.timeoutText })
            .type(InputType.Number)
            .width(76)
            .height(36)
            .fontSize(13)
            .textAlign(TextAlign.Center)
            .onChange((value: string) => {
              this.timeoutText = value;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Row() {
          Text($r('app.string.adb_console_confirm_before_run'))
            .fontSize(13)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.confirmBeforeRun })
            .selectedColor($r('app.color.btn_primary'))
            .onChange((isOn: boolean) => {
              this.confirmBeforeRun = isOn;
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        Text($r('app.string.adb_console_shell_warning'))
          .fontSize(11)
          .fontColor($r('app.color.text_tertiary'))
          .width('100%')

        Row({ space: 12 }) {
          Button($r('app.string.cancel'))
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor($r('app.color.text_primary'))
            .backgroundColor($r('app.color.bg_primary'))
            .onClick(() => {
              this.controller?.close();
            })

          Button($r('app.string.adb_console_save'))
            .layoutWeight(1)
            .height(40)
            .fontSize(14)
            .fontColor(Color.White)
            .backgroundColor($r('app.color.btn_primary'))
            .enabled(!this.saving)
            .onClick(() => {
              void this.submit();
            })
        }
        .width('100%')
        .margin({ top: 6 })
      }
      .width('100%')
      .padding(20)
    }
    .width('90%')
    .constraintSize({ maxHeight: '85%' })
    .scrollBar(BarState.Off)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(20)
  }
}
