import { abilityDelegatorRegistry, Driver, ON } from '@kit.TestKit';
import { describe, beforeAll, it, expect } from '@ohos/hypium';

export default function sessionSettingsUiTest() {
  describe('SessionSettingsUi', () => {
    beforeAll(async () => {
      await abilityDelegatorRegistry.getAbilityDelegator().startAbility({
        bundleName: 'com.lambdayh.scrcpyHmos',
        abilityName: 'ScrcpyHmosAbility'
      });
    });

    it('enforcesCounterBoundariesAndRestoresDefaults', 0, async () => {
      const driver = Driver.create();
      await driver.delayMs(800);
      await (await driver.findComponent(ON.text('更多'))).click();
      await driver.delayMs(300);
      await (await driver.findComponent(ON.text('会话保活'))).click();
      await driver.delayMs(500);

      expect((await driver.findComponent(ON.text('后台保持连接'))) !== null).assertTrue();

      for (let index = 0; index < 8; index++) {
        const plusButtons = await driver.findComponents(ON.text('+'));
        await plusButtons[0].click();
        await driver.delayMs(50);
      }
      expect((await driver.findComponent(ON.text('6'))) !== null).assertTrue();

      for (let index = 0; index < 8; index++) {
        const minusButtons = await driver.findComponents(ON.text('-'));
        await minusButtons[0].click();
        await driver.delayMs(50);
      }
      expect((await driver.findComponent(ON.text('1'))) !== null).assertTrue();

      for (let index = 0; index < 2; index++) {
        const plusButtons = await driver.findComponents(ON.text('+'));
        await plusButtons[0].click();
        await driver.delayMs(50);
      }
      expect((await driver.findComponent(ON.text('3'))) !== null).assertTrue();
    });
  });
}
