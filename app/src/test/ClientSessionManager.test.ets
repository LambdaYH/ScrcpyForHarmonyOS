import { describe, it, expect } from '@ohos/hypium';
import { ClientSessionManager } from '../main/ets/helper/ClientSessionManager';
import { Device } from '../main/ets/entity/Device';

function createDevice(uuid: string): Device {
  const device = new Device(uuid, Device.TYPE_NETWORK);
  device.name = uuid;
  device.address = '127.0.0.1';
  device.adbPort = 5555;
  return device;
}

export default function clientSessionManagerTest() {
  describe('ClientSessionManager', () => {
    it('enforcesConfiguredSessionLimit', 0, () => {
      const manager = ClientSessionManager.getInstance();
      manager.stopAll();
      manager.configure(2);
      expect(manager.createSession(createDevice('a')).limitReached).assertFalse();
      expect(manager.createSession(createDevice('b')).limitReached).assertFalse();
      expect(manager.createSession(createDevice('c')).limitReached).assertTrue();
      expect(manager.listSessions().length).assertEqual(2);
      manager.stopAll();
    });

    it('deduplicatesSessionsByDeviceUuid', 0, () => {
      const manager = ClientSessionManager.getInstance();
      manager.stopAll();
      manager.configure(3);
      const first = manager.createSession(createDevice('same-device'));
      const second = manager.createSession(createDevice('same-device'));
      expect(second.existing).assertTrue();
      expect(second.sessionId).assertEqual(first.sessionId);
      expect(manager.listSessions().length).assertEqual(1);
      manager.stopAll();
    });

    it('clampsSessionSettings', 0, () => {
      const manager = ClientSessionManager.getInstance();
      manager.stopAll();
      manager.configure(99);
      expect(manager.getMaxRetainedSessions()).assertEqual(6);
      manager.configure(0);
      expect(manager.getMaxRetainedSessions()).assertEqual(1);
      manager.configure(3);
    });
  });
}
