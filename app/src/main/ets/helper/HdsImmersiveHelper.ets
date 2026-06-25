import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial, ScrollEffectType, SystemMaterialParams } from '@kit.UIDesignKit';

interface UiContextOwner {
  getUIContext(): Object;
}

interface VpConverter {
  px2vp(px: number): number;
}

interface HostContextProvider {
  getHostContext(): Object;
}

export class HdsImmersiveHelper {
  static readonly MINI_TITLE_BAR_HEIGHT: number = 56;

  static isHdsImmersiveEnhancedAvailable(): boolean {
    try {
      return deviceInfo.sdkApiVersion >= 23;
    } catch (_err) {
      return false;
    }
  }

  static buildHdsImmersiveSystemMaterialEffect(): SystemMaterialParams | undefined {
    if (!HdsImmersiveHelper.isHdsImmersiveEnhancedAvailable()) {
      return undefined;
    }
    let materialType: hdsMaterial.MaterialType = hdsMaterial.MaterialType.IMMERSIVE;
    let materialLevel: hdsMaterial.MaterialLevel = hdsMaterial.MaterialLevel.EXQUISITE;
    try {
      const materialTypes: Array<hdsMaterial.MaterialType> = hdsMaterial.getSystemMaterialTypes();
      if (materialTypes.indexOf(hdsMaterial.MaterialType.IMMERSIVE) < 0) {
        materialType = hdsMaterial.MaterialType.ADAPTIVE;
        materialLevel = hdsMaterial.MaterialLevel.SMOOTH;
      }
    } catch (_err) {
      materialType = hdsMaterial.MaterialType.ADAPTIVE;
      materialLevel = hdsMaterial.MaterialLevel.ADAPTIVE;
    }
    return {
      materialType: materialType,
      materialLevel: materialLevel
    };
  }

  static getScrollEffectType(): ScrollEffectType {
    return HdsImmersiveHelper.buildHdsImmersiveSystemMaterialEffect() === undefined
      ? ScrollEffectType.GRADIENT_BLUR
      : ScrollEffectType.IMMERSIVE_GRADIENT_BLUR;
  }

  static pxToVp(owner: Object, value: number): number {
    try {
      const uiContext = (owner as UiContextOwner).getUIContext() as VpConverter;
      return uiContext.px2vp(value);
    } catch (_err) {
      return value;
    }
  }

  static syncSystemTopInsetVp(owner: Object, onResolved: (value: number) => void): void {
    try {
      const uiContext = (owner as UiContextOwner).getUIContext() as HostContextProvider;
      const ctx = uiContext.getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window): void => {
        try {
          const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
          onResolved(Math.max(0, HdsImmersiveHelper.pxToVp(owner, area.topRect.height)));
        } catch (_err) {
          onResolved(0);
        }
      }).catch((_err: Error): void => {
        onResolved(0);
      });
    } catch (_err) {
      onResolved(0);
    }
  }

  static getMiniTitleOverlayHeight(systemTopInsetVp: number, bottomBuilderHeight: number = 0): number {
    return systemTopInsetVp + HdsImmersiveHelper.MINI_TITLE_BAR_HEIGHT + bottomBuilderHeight;
  }
}
