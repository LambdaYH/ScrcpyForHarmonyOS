import { describe, it, expect } from '@ohos/hypium';
import { KeyCode as OhosKeyCode } from '@kit.InputKit';
import { ControlMessageType, ControlPacket } from '../main/ets/client/tools/ControlPacket';
import { KeyboardUhidController } from '../main/ets/client/tools/KeyboardUhidController';

function bytesOf(buffer: ArrayBuffer): number[] {
  return Array.from(new Uint8Array(buffer));
}

function hexOf(buffer: ArrayBuffer): string {
  return bytesOf(buffer)
    .map((value: number) => value.toString(16).padStart(2, '0'))
    .join('');
}

function packetType(buffer: ArrayBuffer): number {
  return new Uint8Array(buffer)[0];
}

export default function keyboardUhidControllerTest() {
  describe('KeyboardUhidController', () => {
    it('serializesUhidCreateInputDestroy', 0, () => {
      const create = ControlPacket.createUhidCreate(1, 0x1234, 0x5678, 'kb', new Uint8Array([0x05, 0x01]));
      expect(bytesOf(create).join(',')).assertEqual('12,0,1,18,52,86,120,2,107,98,0,2,5,1');

      const input = ControlPacket.createUhidInput(1, new Uint8Array([0x02, 0x00, 0x04]));
      expect(bytesOf(input).join(',')).assertEqual('13,0,1,0,3,2,0,4');

      const destroy = ControlPacket.createUhidDestroy(1);
      expect(bytesOf(destroy).join(',')).assertEqual('14,0,1');
    });

    it('usesScrcpyKeyboardReportDescriptor', 0, () => {
      expect(KeyboardUhidController.REPORT_DESC.byteLength).assertEqual(63);
      expect(KeyboardUhidController.REPORT_DESC[0]).assertEqual(0x05);
      expect(KeyboardUhidController.REPORT_DESC[1]).assertEqual(0x01);
      expect(KeyboardUhidController.REPORT_DESC[62]).assertEqual(0xC0);
    });

    it('sendsSingleKeyReports', 0, () => {
      const packets: ArrayBuffer[] = [];
      const keyboard = new KeyboardUhidController((data: ArrayBuffer): boolean => {
        packets.push(data);
        return true;
      });

      expect(keyboard.create()).assertTrue();
      expect(packetType(packets[0])).assertEqual(ControlMessageType.TYPE_UHID_CREATE);

      expect(keyboard.handleKeyCode(OhosKeyCode.KEYCODE_A, true)).assertTrue();
      expect(hexOf(packets[1])).assertEqual('0d000100080000040000000000');

      expect(keyboard.handleKeyCode(OhosKeyCode.KEYCODE_A, false)).assertTrue();
      expect(hexOf(packets[2])).assertEqual('0d000100080000000000000000');
    });

    it('combinesModifiersAndIgnoresRepeat', 0, () => {
      const packets: ArrayBuffer[] = [];
      const keyboard = new KeyboardUhidController((data: ArrayBuffer): boolean => {
        packets.push(data);
        return true;
      });

      keyboard.create();
      expect(keyboard.handleKeyCode(OhosKeyCode.KEYCODE_CTRL_LEFT, true)).assertTrue();
      expect(keyboard.handleKeyCode(OhosKeyCode.KEYCODE_A, true)).assertTrue();
      expect(keyboard.handleKeyCode(OhosKeyCode.KEYCODE_A, true)).assertTrue();

      expect(hexOf(packets[1])).assertEqual('0d000100080100000000000000');
      expect(hexOf(packets[2])).assertEqual('0d000100080100040000000000');
      expect(packets.length).assertEqual(3);
    });

    it('reportsRolloverForMoreThanSixKeys', 0, () => {
      const keyboard = new KeyboardUhidController((_: ArrayBuffer): boolean => true);
      keyboard.create();
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_A, true);
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_B, true);
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_C, true);
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_D, true);
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_E, true);
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_F, true);
      keyboard.handleKeyCode(OhosKeyCode.KEYCODE_G, true);

      expect(Array.from(keyboard.getCurrentReportForTest()).join(',')).assertEqual('0,0,1,1,1,1,1,1');
    });

    it('syncsLedOutputState', 0, () => {
      const keyboard = new KeyboardUhidController((_: ArrayBuffer): boolean => true);
      keyboard.handleUhidOutput('{"id":1,"data":"03"}');
      expect(keyboard.getCapsLockOn()).assertTrue();
      expect(keyboard.getNumLockOn()).assertTrue();
    });
  });
}
