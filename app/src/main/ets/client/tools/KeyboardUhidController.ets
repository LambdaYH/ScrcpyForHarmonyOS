import { KeyCode as OhosKeyCode } from '@kit.InputKit';
import { ControlPacket } from './ControlPacket';

type ControlSender = (data: ArrayBuffer) => boolean;

const HID_ID_KEYBOARD = 1;
const HID_INPUT_SIZE = 8;
const HID_KEYBOARD_MAX_KEYS = 6;
const HID_ERROR_ROLL_OVER = 0x01;

const HID_MOD_LEFT_CONTROL = 1 << 0;
const HID_MOD_LEFT_SHIFT = 1 << 1;
const HID_MOD_LEFT_ALT = 1 << 2;
const HID_MOD_LEFT_GUI = 1 << 3;
const HID_MOD_RIGHT_CONTROL = 1 << 4;
const HID_MOD_RIGHT_SHIFT = 1 << 5;
const HID_MOD_RIGHT_ALT = 1 << 6;
const HID_MOD_RIGHT_GUI = 1 << 7;

interface ParsedUhidOutput {
  id: number;
  data: Uint8Array;
}

export class KeyboardUhidController {
  static readonly HID_ID_KEYBOARD: number = HID_ID_KEYBOARD;
  static readonly DEVICE_NAME: string = 'Scrcpy Keyboard';

  static readonly REPORT_DESC: Uint8Array = new Uint8Array([
    0x05, 0x01,
    0x09, 0x06,
    0xA1, 0x01,
    0x05, 0x07,
    0x19, 0xE0,
    0x29, 0xE7,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x08,
    0x81, 0x02,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x01,
    0x05, 0x08,
    0x19, 0x01,
    0x29, 0x05,
    0x75, 0x01,
    0x95, 0x05,
    0x91, 0x02,
    0x75, 0x03,
    0x95, 0x01,
    0x91, 0x01,
    0x05, 0x07,
    0x19, 0x00,
    0x29, 0x65,
    0x15, 0x00,
    0x25, 0x65,
    0x75, 0x08,
    0x95, 0x06,
    0x81, 0x00,
    0xC0
  ]);

  private static readonly HID_BY_OHOS_KEY: Map<number, number> = new Map<number, number>([
    [OhosKeyCode.KEYCODE_A, 0x04],
    [OhosKeyCode.KEYCODE_B, 0x05],
    [OhosKeyCode.KEYCODE_C, 0x06],
    [OhosKeyCode.KEYCODE_D, 0x07],
    [OhosKeyCode.KEYCODE_E, 0x08],
    [OhosKeyCode.KEYCODE_F, 0x09],
    [OhosKeyCode.KEYCODE_G, 0x0A],
    [OhosKeyCode.KEYCODE_H, 0x0B],
    [OhosKeyCode.KEYCODE_I, 0x0C],
    [OhosKeyCode.KEYCODE_J, 0x0D],
    [OhosKeyCode.KEYCODE_K, 0x0E],
    [OhosKeyCode.KEYCODE_L, 0x0F],
    [OhosKeyCode.KEYCODE_M, 0x10],
    [OhosKeyCode.KEYCODE_N, 0x11],
    [OhosKeyCode.KEYCODE_O, 0x12],
    [OhosKeyCode.KEYCODE_P, 0x13],
    [OhosKeyCode.KEYCODE_Q, 0x14],
    [OhosKeyCode.KEYCODE_R, 0x15],
    [OhosKeyCode.KEYCODE_S, 0x16],
    [OhosKeyCode.KEYCODE_T, 0x17],
    [OhosKeyCode.KEYCODE_U, 0x18],
    [OhosKeyCode.KEYCODE_V, 0x19],
    [OhosKeyCode.KEYCODE_W, 0x1A],
    [OhosKeyCode.KEYCODE_X, 0x1B],
    [OhosKeyCode.KEYCODE_Y, 0x1C],
    [OhosKeyCode.KEYCODE_Z, 0x1D],
    [OhosKeyCode.KEYCODE_1, 0x1E],
    [OhosKeyCode.KEYCODE_2, 0x1F],
    [OhosKeyCode.KEYCODE_3, 0x20],
    [OhosKeyCode.KEYCODE_4, 0x21],
    [OhosKeyCode.KEYCODE_5, 0x22],
    [OhosKeyCode.KEYCODE_6, 0x23],
    [OhosKeyCode.KEYCODE_7, 0x24],
    [OhosKeyCode.KEYCODE_8, 0x25],
    [OhosKeyCode.KEYCODE_9, 0x26],
    [OhosKeyCode.KEYCODE_0, 0x27],
    [OhosKeyCode.KEYCODE_ENTER, 0x28],
    [OhosKeyCode.KEYCODE_ESCAPE, 0x29],
    [OhosKeyCode.KEYCODE_DEL, 0x2A],
    [OhosKeyCode.KEYCODE_TAB, 0x2B],
    [OhosKeyCode.KEYCODE_SPACE, 0x2C],
    [OhosKeyCode.KEYCODE_MINUS, 0x2D],
    [OhosKeyCode.KEYCODE_EQUALS, 0x2E],
    [OhosKeyCode.KEYCODE_LEFT_BRACKET, 0x2F],
    [OhosKeyCode.KEYCODE_RIGHT_BRACKET, 0x30],
    [OhosKeyCode.KEYCODE_BACKSLASH, 0x31],
    [OhosKeyCode.KEYCODE_SEMICOLON, 0x33],
    [OhosKeyCode.KEYCODE_APOSTROPHE, 0x34],
    [OhosKeyCode.KEYCODE_GRAVE, 0x35],
    [OhosKeyCode.KEYCODE_COMMA, 0x36],
    [OhosKeyCode.KEYCODE_PERIOD, 0x37],
    [OhosKeyCode.KEYCODE_SLASH, 0x38],
    [OhosKeyCode.KEYCODE_CAPS_LOCK, 0x39],
    [OhosKeyCode.KEYCODE_F1, 0x3A],
    [OhosKeyCode.KEYCODE_F2, 0x3B],
    [OhosKeyCode.KEYCODE_F3, 0x3C],
    [OhosKeyCode.KEYCODE_F4, 0x3D],
    [OhosKeyCode.KEYCODE_F5, 0x3E],
    [OhosKeyCode.KEYCODE_F6, 0x3F],
    [OhosKeyCode.KEYCODE_F7, 0x40],
    [OhosKeyCode.KEYCODE_F8, 0x41],
    [OhosKeyCode.KEYCODE_F9, 0x42],
    [OhosKeyCode.KEYCODE_F10, 0x43],
    [OhosKeyCode.KEYCODE_F11, 0x44],
    [OhosKeyCode.KEYCODE_F12, 0x45],
    [OhosKeyCode.KEYCODE_SYSRQ, 0x46],
    [OhosKeyCode.KEYCODE_SCROLL_LOCK, 0x47],
    [OhosKeyCode.KEYCODE_BREAK, 0x48],
    [OhosKeyCode.KEYCODE_INSERT, 0x49],
    [OhosKeyCode.KEYCODE_MOVE_HOME, 0x4A],
    [OhosKeyCode.KEYCODE_PAGE_UP, 0x4B],
    [OhosKeyCode.KEYCODE_FORWARD_DEL, 0x4C],
    [OhosKeyCode.KEYCODE_MOVE_END, 0x4D],
    [OhosKeyCode.KEYCODE_PAGE_DOWN, 0x4E],
    [OhosKeyCode.KEYCODE_DPAD_RIGHT, 0x4F],
    [OhosKeyCode.KEYCODE_DPAD_LEFT, 0x50],
    [OhosKeyCode.KEYCODE_DPAD_DOWN, 0x51],
    [OhosKeyCode.KEYCODE_DPAD_UP, 0x52],
    [OhosKeyCode.KEYCODE_NUM_LOCK, 0x53],
    [OhosKeyCode.KEYCODE_NUMPAD_DIVIDE, 0x54],
    [OhosKeyCode.KEYCODE_NUMPAD_MULTIPLY, 0x55],
    [OhosKeyCode.KEYCODE_NUMPAD_SUBTRACT, 0x56],
    [OhosKeyCode.KEYCODE_NUMPAD_ADD, 0x57],
    [OhosKeyCode.KEYCODE_NUMPAD_ENTER, 0x58],
    [OhosKeyCode.KEYCODE_NUMPAD_1, 0x59],
    [OhosKeyCode.KEYCODE_NUMPAD_2, 0x5A],
    [OhosKeyCode.KEYCODE_NUMPAD_3, 0x5B],
    [OhosKeyCode.KEYCODE_NUMPAD_4, 0x5C],
    [OhosKeyCode.KEYCODE_NUMPAD_5, 0x5D],
    [OhosKeyCode.KEYCODE_NUMPAD_6, 0x5E],
    [OhosKeyCode.KEYCODE_NUMPAD_7, 0x5F],
    [OhosKeyCode.KEYCODE_NUMPAD_8, 0x60],
    [OhosKeyCode.KEYCODE_NUMPAD_9, 0x61],
    [OhosKeyCode.KEYCODE_NUMPAD_0, 0x62],
    [OhosKeyCode.KEYCODE_NUMPAD_DOT, 0x63],
    [OhosKeyCode.KEYCODE_NUMPAD_EQUALS, 0x67],
    [OhosKeyCode.KEYCODE_F13, 0x68],
    [OhosKeyCode.KEYCODE_F14, 0x69],
    [OhosKeyCode.KEYCODE_F15, 0x6A],
    [OhosKeyCode.KEYCODE_F16, 0x6B],
    [OhosKeyCode.KEYCODE_F17, 0x6C],
    [OhosKeyCode.KEYCODE_F18, 0x6D],
    [OhosKeyCode.KEYCODE_F19, 0x6E],
    [OhosKeyCode.KEYCODE_F20, 0x6F],
    [OhosKeyCode.KEYCODE_F21, 0x70],
    [OhosKeyCode.KEYCODE_F22, 0x71],
    [OhosKeyCode.KEYCODE_F23, 0x72],
    [OhosKeyCode.KEYCODE_F24, 0x73]
  ]);

  private static readonly MOD_BY_OHOS_KEY: Map<number, number> = new Map<number, number>([
    [OhosKeyCode.KEYCODE_CTRL_LEFT, HID_MOD_LEFT_CONTROL],
    [OhosKeyCode.KEYCODE_CTRL_RIGHT, HID_MOD_RIGHT_CONTROL],
    [OhosKeyCode.KEYCODE_SHIFT_LEFT, HID_MOD_LEFT_SHIFT],
    [OhosKeyCode.KEYCODE_SHIFT_RIGHT, HID_MOD_RIGHT_SHIFT],
    [OhosKeyCode.KEYCODE_ALT_LEFT, HID_MOD_LEFT_ALT],
    [OhosKeyCode.KEYCODE_ALT_RIGHT, HID_MOD_RIGHT_ALT],
    [OhosKeyCode.KEYCODE_META_LEFT, HID_MOD_LEFT_GUI],
    [OhosKeyCode.KEYCODE_META_RIGHT, HID_MOD_RIGHT_GUI]
  ]);

  private readonly sendControl: ControlSender;
  private pressedKeys: Set<number> = new Set<number>();
  private modifierState: number = 0;
  private created: boolean = false;
  private capsLockOn: boolean = false;
  private numLockOn: boolean = false;

  constructor(sendControl: ControlSender) {
    this.sendControl = sendControl;
  }

  isCreated(): boolean {
    return this.created;
  }

  create(): boolean {
    if (this.created) {
      return true;
    }
    const accepted = this.sendControl(ControlPacket.createUhidCreate(
      HID_ID_KEYBOARD,
      0,
      0,
      KeyboardUhidController.DEVICE_NAME,
      KeyboardUhidController.REPORT_DESC
    ));
    this.created = accepted;
    return accepted;
  }

  destroy(): void {
    if (!this.created) {
      return;
    }
    this.resetAll();
    this.sendControl(ControlPacket.createUhidDestroy(HID_ID_KEYBOARD));
    this.created = false;
  }

  resetAll(): void {
    const hadState = this.modifierState !== 0 || this.pressedKeys.size > 0;
    this.modifierState = 0;
    this.pressedKeys.clear();
    if (this.created && hadState) {
      this.sendReport();
    }
  }

  handleKeyCode(keyCode: number, isDown: boolean): boolean {
    if (!this.created) {
      return false;
    }

    const modifier = KeyboardUhidController.MOD_BY_OHOS_KEY.get(keyCode);
    if (modifier !== undefined) {
      const nextModifierState = isDown ? (this.modifierState | modifier) : (this.modifierState & ~modifier);
      if (nextModifierState === this.modifierState) {
        return true;
      }
      this.modifierState = nextModifierState;
      this.sendReport();
      return true;
    }

    const usage = KeyboardUhidController.HID_BY_OHOS_KEY.get(keyCode);
    if (usage === undefined) {
      return false;
    }

    const hadKey = this.pressedKeys.has(usage);
    if (isDown) {
      if (hadKey) {
        return true;
      }
      this.pressedKeys.add(usage);
    } else {
      if (!hadKey) {
        return true;
      }
      this.pressedKeys.delete(usage);
    }

    this.sendReport();
    return true;
  }

  handleUhidOutput(raw: string): void {
    const output = KeyboardUhidController.parseUhidOutput(raw);
    if (!output || output.id !== HID_ID_KEYBOARD || output.data.byteLength === 0) {
      return;
    }

    const ledState = output.data[0];
    this.numLockOn = (ledState & 0x01) !== 0;
    this.capsLockOn = (ledState & 0x02) !== 0;
  }

  getCapsLockOn(): boolean {
    return this.capsLockOn;
  }

  getNumLockOn(): boolean {
    return this.numLockOn;
  }

  getCurrentReportForTest(): Uint8Array {
    return this.buildReport();
  }

  private sendReport(): void {
    this.sendControl(ControlPacket.createUhidInput(HID_ID_KEYBOARD, this.buildReport()));
  }

  private buildReport(): Uint8Array {
    const report = new Uint8Array(HID_INPUT_SIZE);
    report[0] = this.modifierState;

    if (this.pressedKeys.size > HID_KEYBOARD_MAX_KEYS) {
      report.fill(HID_ERROR_ROLL_OVER, 2);
      return report;
    }

    let index = 2;
    this.pressedKeys.forEach((usage: number) => {
      if (index < HID_INPUT_SIZE) {
        report[index] = usage;
        index++;
      }
    });
    return report;
  }

  private static parseUhidOutput(raw: string): ParsedUhidOutput | undefined {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const id = Number(parsed['id']);
      const rawData = parsed['data'];
      const hex = rawData === undefined || rawData === null ? '' : String(rawData);
      if (!Number.isFinite(id) || hex.length % 2 !== 0) {
        return undefined;
      }

      const data = new Uint8Array(hex.length / 2);
      for (let i = 0; i < data.byteLength; i++) {
        const value = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
        if (!Number.isFinite(value)) {
          return undefined;
        }
        data[i] = value;
      }

      return { id, data };
    } catch (_) {
      return undefined;
    }
  }
}
