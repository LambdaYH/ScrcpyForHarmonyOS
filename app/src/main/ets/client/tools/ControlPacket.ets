import { buffer } from '@kit.ArkTS';

// Scrcpy Control Message Types - 匹配 ControlMessage.java
export class ControlMessageType {
  static readonly TYPE_INJECT_KEYCODE = 0;
  static readonly TYPE_INJECT_TEXT = 1;
  static readonly TYPE_INJECT_TOUCH_EVENT = 2;
  static readonly TYPE_INJECT_SCROLL_EVENT = 3;
  static readonly TYPE_BACK_OR_SCREEN_ON = 4;
  static readonly TYPE_EXPAND_NOTIFICATION_PANEL = 5;
  static readonly TYPE_EXPAND_SETTINGS_PANEL = 6;
  static readonly TYPE_COLLAPSE_PANELS = 7;
  static readonly TYPE_GET_CLIPBOARD = 8;
  static readonly TYPE_SET_CLIPBOARD = 9;
  static readonly TYPE_SET_DISPLAY_POWER = 10;
  static readonly TYPE_ROTATE_DEVICE = 11;
  static readonly TYPE_UHID_CREATE = 12;
  static readonly TYPE_UHID_INPUT = 13;
  static readonly TYPE_UHID_DESTROY = 14;
  static readonly TYPE_OPEN_HARD_KEYBOARD_SETTINGS = 15;
  static readonly TYPE_START_APP = 16;
  static readonly TYPE_RESET_VIDEO = 17;
}

// Action 常量 - 用于 handleAction 分发
export class Action {
  // 界面切换
  static readonly CHANGE_TO_SMALL = "changeToSmall";
  static readonly CHANGE_TO_FULL = "changeToFull";
  static readonly CHANGE_TO_MINI = "changeToMini";
  static readonly CHANGE_TO_APP = "changeToApp";

  // 按钮操作
  static readonly BUTTON_POWER = "buttonPower";
  static readonly BUTTON_WAKE = "buttonWake";
  static readonly BUTTON_LOCK = "buttonLock";
  static readonly BUTTON_LIGHT = "buttonLight";
  static readonly BUTTON_LIGHT_OFF = "buttonLightOff";
  static readonly BUTTON_BACK = "buttonBack";
  static readonly BUTTON_HOME = "buttonHome";
  static readonly BUTTON_SWITCH = "buttonSwitch";
  static readonly BUTTON_ROTATE = "buttonRotate";

  // 系统操作
  static readonly KEEP_ALIVE = "keepAlive";
  static readonly CHECK_SIZE_AND_SITE = "checkSizeAndSite";
  static readonly CHECK_CLIP_BOARD = "checkClipBoard";
  static readonly UPDATE_SITE = "updateSite";
  static readonly WRITE_BYTE_BUFFER = "writeByteBuffer";
  static readonly UPDATE_MAX_SIZE = "updateMaxSize";
  static readonly UPDATE_VIDEO_SIZE = "updateVideoSize";
  static readonly RUN_SHELL = "runShell";
  static readonly SET_CLIP_BOARD = "setClipBoard";
  static readonly CLOSE = "close";
}

// Scrcpy控制包工具类 - 匹配 ControlMessageReader.java 格式
// 注意：Scrcpy 使用大端序(big-endian)
export class ControlPacket {
  
  // ============ TYPE_INJECT_KEYCODE (0) ============
  // 格式: type(1) + action(1) + keycode(4) + repeat(4) + metaState(4) = 14 bytes
  static createInjectKeycode(action: number, keycode: number, repeat: number = 0, metaState: number = 0): ArrayBuffer {
    const buf = new ArrayBuffer(14);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_INJECT_KEYCODE);
    view.setUint8(1, action);  // ACTION_DOWN=0, ACTION_UP=1
    view.setInt32(2, keycode, false);  // big-endian
    view.setInt32(6, repeat, false);   // big-endian
    view.setInt32(10, metaState, false); // big-endian
    return buf;
  }

  // 发送按键事件 (按下+抬起)
  static createKeyEventPair(keycode: number, metaState: number = 0): ArrayBuffer[] {
    return [
      ControlPacket.createInjectKeycode(KeyAction.ACTION_DOWN, keycode, 0, metaState),
      ControlPacket.createInjectKeycode(KeyAction.ACTION_UP, keycode, 0, metaState)
    ];
  }

  // ============ TYPE_INJECT_TEXT (1) ============
  // 格式: type(1) + length(4) + text(N) = 5+N bytes
  static createInjectText(text: string): ArrayBuffer {
    const textBytes = buffer.from(text, 'utf-8');
    const textLen = textBytes.buffer.byteLength;
    const buf = new ArrayBuffer(5 + textLen);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_INJECT_TEXT);
    view.setInt32(1, textLen, false);  // big-endian
    
    const result = new Uint8Array(buf);
    result.set(new Uint8Array(textBytes.buffer), 5);
    return buf;
  }

  // ============ TYPE_INJECT_TOUCH_EVENT (2) ============
  // 格式: type(1) + action(1) + pointerId(8) + x(4) + y(4) + screenWidth(2) + screenHeight(2) + pressure(2) + actionButton(4) + buttons(4) = 32 bytes
  static createInjectTouchEvent(
    action: number, 
    pointerId: bigint, 
    x: number, 
    y: number, 
    screenWidth: number, 
    screenHeight: number,
    pressure: number = 1.0,
    actionButton: number = 0,
    buttons: number = 0
  ): ArrayBuffer {
    const buf = new ArrayBuffer(32);
    const view = new DataView(buf);
    
    view.setUint8(0, ControlMessageType.TYPE_INJECT_TOUCH_EVENT);
    view.setUint8(1, action);
    view.setBigInt64(2, pointerId, false);  // big-endian
    view.setInt32(10, x, false);            // big-endian
    view.setInt32(14, y, false);            // big-endian
    view.setUint16(18, screenWidth, false); // big-endian
    view.setUint16(20, screenHeight, false);// big-endian
    
    // pressure: u16 fixed-point (0-65535 maps to 0.0-1.0)
    const pressureU16 = Math.round(Math.min(1.0, Math.max(0, pressure)) * 0xFFFF);
    view.setUint16(22, pressureU16, false);
    
    view.setInt32(24, actionButton, false); // big-endian
    view.setInt32(28, buttons, false);      // big-endian
    
    return buf;
  }

  // ============ TYPE_INJECT_SCROLL_EVENT (3) ============
  // 格式: type(1) + x(4) + y(4) + screenWidth(2) + screenHeight(2) + hScroll(2) + vScroll(2) + buttons(4) = 21 bytes
  static createInjectScrollEvent(
    x: number, 
    y: number, 
    screenWidth: number, 
    screenHeight: number,
    hScroll: number,
    vScroll: number,
    buttons: number = 0
  ): ArrayBuffer {
    const buf = new ArrayBuffer(21);
    const view = new DataView(buf);
    
    view.setUint8(0, ControlMessageType.TYPE_INJECT_SCROLL_EVENT);
    view.setInt32(1, x, false);             // big-endian
    view.setInt32(5, y, false);             // big-endian
    view.setUint16(9, screenWidth, false);  // big-endian
    view.setUint16(11, screenHeight, false);// big-endian
    
    // hScroll/vScroll: i16 fixed-point, range [-16, 16] mapped to [-32768, 32767]
    const hScrollI16 = Math.round((hScroll / 16) * 32767);
    const vScrollI16 = Math.round((vScroll / 16) * 32767);
    view.setInt16(13, hScrollI16, false);
    view.setInt16(15, vScrollI16, false);
    
    view.setInt32(17, buttons, false);
    
    return buf;
  }

  // ============ TYPE_BACK_OR_SCREEN_ON (4) ============
  // 格式: type(1) + action(1) = 2 bytes
  static createBackOrScreenOn(action: number): ArrayBuffer {
    const buf = new ArrayBuffer(2);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_BACK_OR_SCREEN_ON);
    view.setUint8(1, action);  // ACTION_DOWN=0 triggers back, ACTION_UP=1 does nothing
    return buf;
  }

  // ============ TYPE_GET_CLIPBOARD (8) ============
  // 格式: type(1) + copyKey(1) = 2 bytes
  static createGetClipboard(copyKey: number = 0): ArrayBuffer {
    const buf = new ArrayBuffer(2);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_GET_CLIPBOARD);
    view.setUint8(1, copyKey);  // COPY_KEY_NONE=0, COPY_KEY_COPY=1, COPY_KEY_CUT=2
    return buf;
  }

  // ============ TYPE_SET_CLIPBOARD (9) ============
  // 格式: type(1) + sequence(8) + paste(1) + length(4) + text(N) = 14+N bytes
  static createSetClipboard(text: string, sequence: bigint = 0n, paste: boolean = false): ArrayBuffer {
    const textBytes = buffer.from(text, 'utf-8');
    const textLen = textBytes.buffer.byteLength;
    const buf = new ArrayBuffer(14 + textLen);
    const view = new DataView(buf);
    
    view.setUint8(0, ControlMessageType.TYPE_SET_CLIPBOARD);
    view.setBigInt64(1, sequence, false);  // big-endian
    view.setUint8(9, paste ? 1 : 0);
    view.setInt32(10, textLen, false);     // big-endian
    
    const result = new Uint8Array(buf);
    result.set(new Uint8Array(textBytes.buffer), 14);
    return buf;
  }

  // ============ TYPE_SET_DISPLAY_POWER (10) ============
  // 格式: type(1) + on(1) = 2 bytes
  static createSetDisplayPower(on: boolean): ArrayBuffer {
    const buf = new ArrayBuffer(2);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_SET_DISPLAY_POWER);
    view.setUint8(1, on ? 1 : 0);
    return buf;
  }

  // ============ TYPE_ROTATE_DEVICE (11) ============
  // 格式: type(1) = 1 byte
  static createRotateDevice(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_ROTATE_DEVICE);
    return buf;
  }

  // ============ TYPE_UHID_CREATE (12) ============
  // 格式: type(1) + id(2) + vendorId(2) + productId(2) + nameLen(1) + name(N) + reportDescLen(2) + reportDesc(M)
  static createUhidCreate(
    id: number,
    vendorId: number,
    productId: number,
    name: string,
    reportDesc: Uint8Array
  ): ArrayBuffer {
    const nameBytes = buffer.from(name, 'utf-8');
    const nameData = new Uint8Array(nameBytes.buffer);
    const nameLen = Math.min(nameData.byteLength, 127);
    const reportDescLen = reportDesc.byteLength;
    const buf = new ArrayBuffer(10 + nameLen + reportDescLen);
    const view = new DataView(buf);
    const result = new Uint8Array(buf);

    view.setUint8(0, ControlMessageType.TYPE_UHID_CREATE);
    view.setUint16(1, id, false);
    view.setUint16(3, vendorId, false);
    view.setUint16(5, productId, false);
    view.setUint8(7, nameLen);
    result.set(nameData.slice(0, nameLen), 8);
    const reportLenOffset = 8 + nameLen;
    view.setUint16(reportLenOffset, reportDescLen, false);
    result.set(reportDesc, reportLenOffset + 2);
    return buf;
  }

  // ============ TYPE_UHID_INPUT (13) ============
  // 格式: type(1) + id(2) + dataLen(2) + data(N)
  static createUhidInput(id: number, data: Uint8Array): ArrayBuffer {
    const buf = new ArrayBuffer(5 + data.byteLength);
    const view = new DataView(buf);
    const result = new Uint8Array(buf);

    view.setUint8(0, ControlMessageType.TYPE_UHID_INPUT);
    view.setUint16(1, id, false);
    view.setUint16(3, data.byteLength, false);
    result.set(data, 5);
    return buf;
  }

  // ============ TYPE_UHID_DESTROY (14) ============
  // 格式: type(1) + id(2)
  static createUhidDestroy(id: number): ArrayBuffer {
    const buf = new ArrayBuffer(3);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_UHID_DESTROY);
    view.setUint16(1, id, false);
    return buf;
  }

  // ============ TYPE_OPEN_HARD_KEYBOARD_SETTINGS (15) ============
  static createOpenHardKeyboardSettings(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_OPEN_HARD_KEYBOARD_SETTINGS);
    return buf;
  }

  // ============ TYPE_EXPAND_NOTIFICATION_PANEL (5) ============
  static createExpandNotificationPanel(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_EXPAND_NOTIFICATION_PANEL);
    return buf;
  }

  // ============ TYPE_EXPAND_SETTINGS_PANEL (6) ============
  static createExpandSettingsPanel(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_EXPAND_SETTINGS_PANEL);
    return buf;
  }

  // ============ TYPE_COLLAPSE_PANELS (7) ============
  static createCollapsePanels(): ArrayBuffer {
    const buf = new ArrayBuffer(1);
    const view = new DataView(buf);
    view.setUint8(0, ControlMessageType.TYPE_COLLAPSE_PANELS);
    return buf;
  }

  // ============ 便捷方法 ============
  
  // 发送Back键 (使用 BACK_OR_SCREEN_ON)
  static createBackKey(): ArrayBuffer {
    return ControlPacket.createBackOrScreenOn(KeyAction.ACTION_DOWN);
  }

  // 发送Home键
  static createHomeKey(): ArrayBuffer[] {
    return ControlPacket.createKeyEventPair(KeyCode.KEYCODE_HOME);
  }

  // 发送App Switch键
  static createAppSwitchKey(): ArrayBuffer[] {
    return ControlPacket.createKeyEventPair(KeyCode.KEYCODE_APP_SWITCH);
  }

  // 发送电源键
  static createPowerKey(): ArrayBuffer[] {
    return ControlPacket.createKeyEventPair(KeyCode.KEYCODE_POWER);
  }

  // 打开屏幕
  static createScreenOn(): ArrayBuffer {
    return ControlPacket.createSetDisplayPower(true);
  }

  // 关闭屏幕
  static createScreenOff(): ArrayBuffer {
    return ControlPacket.createSetDisplayPower(false);
  }
}

// 按键动作常量
export enum KeyAction {
  ACTION_DOWN = 0,
  ACTION_UP = 1
}

// 触摸动作常量 - 对应Android MotionEvent
export enum TouchAction {
  ACTION_DOWN = 0,
  ACTION_UP = 1,
  ACTION_MOVE = 2,
  ACTION_CANCEL = 3,
  ACTION_OUTSIDE = 4,
  ACTION_POINTER_DOWN = 5,
  ACTION_POINTER_UP = 6
}

// 按键码常量 - 对应Android KeyEvent
export enum KeyCode {
  KEYCODE_UNKNOWN = 0,
  KEYCODE_HOME = 3,
  KEYCODE_BACK = 4,
  KEYCODE_CALL = 5,
  KEYCODE_ENDCALL = 6,
  KEYCODE_VOLUME_UP = 24,
  KEYCODE_VOLUME_DOWN = 25,
  KEYCODE_POWER = 26,
  KEYCODE_CAMERA = 27,
  KEYCODE_DPAD_UP = 19,
  KEYCODE_DPAD_DOWN = 20,
  KEYCODE_DPAD_LEFT = 21,
  KEYCODE_DPAD_RIGHT = 22,
  KEYCODE_DPAD_CENTER = 23,
  KEYCODE_ENTER = 66,
  KEYCODE_DEL = 67,
  KEYCODE_MENU = 82,
  KEYCODE_SEARCH = 84,
  KEYCODE_APP_SWITCH = 187
}

// 元键状态
export enum MetaState {
  META_NONE = 0,
  META_ALT_ON = 0x02,
  META_SHIFT_ON = 0x01,
  META_CTRL_ON = 0x1000
}

// 鼠标按钮
export enum MouseButton {
  BUTTON_PRIMARY = 1,
  BUTTON_SECONDARY = 2,
  BUTTON_TERTIARY = 4
}
