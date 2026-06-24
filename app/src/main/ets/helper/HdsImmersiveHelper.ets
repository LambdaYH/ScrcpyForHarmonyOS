import { deviceInfo } from '@kit.BasicServicesKit';
import { hdsMaterial, ScrollEffectType, SystemMaterialParams } from '@kit.UIDesignKit';

export class HdsImmersiveHelper {
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
}
