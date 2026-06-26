import { LengthMetrics } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  DividerShowType,
  hdsMaterial,
  HdsNavigationTitleBarOptions,
  ScrollEffectType,
  SystemMaterialParams
} from '@kit.UIDesignKit';

export class HdsImmersiveHelper {
  static readonly MINI_TITLE_BAR_HEIGHT: number = 56;
  static readonly LEGACY_TOP_SAFE_INSET_VP: number = 44;
  static readonly LEGACY_BOTTOM_SAFE_INSET_VP: number = 0;
  static readonly TOP_SAFE_INSET_VP_KEY: string = 'hds_top_safe_inset_vp';
  static readonly BOTTOM_SAFE_INSET_VP_KEY: string = 'hds_bottom_safe_inset_vp';

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

  static publishSafeAreaInsets(topInsetVp: number, bottomInsetVp: number): void {
    AppStorage.setOrCreate(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY, topInsetVp);
    AppStorage.setOrCreate(HdsImmersiveHelper.BOTTOM_SAFE_INSET_VP_KEY, bottomInsetVp);
  }

  static topSafeInsetVp(): number {
    return (AppStorage.get<number>(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY) as number)
      ?? HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  }

  static bottomSafeInsetVp(): number {
    return (AppStorage.get<number>(HdsImmersiveHelper.BOTTOM_SAFE_INSET_VP_KEY) as number)
      ?? HdsImmersiveHelper.LEGACY_BOTTOM_SAFE_INSET_VP;
  }

  static getMiniTitleOverlayHeight(topInsetVp: number, bottomBuilderHeight: number = 0): number {
    return topInsetVp + HdsImmersiveHelper.MINI_TITLE_BAR_HEIGHT + bottomBuilderHeight;
  }

  static buildMiniTitleBarOptions(
    title: ResourceStr,
    originalBackgroundColor: string = '#0DFFFFFF',
    scrollBackgroundColor: string = '#14FFFFFF'
  ): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      padding: {
        start: LengthMetrics.vp(24),
        end: LengthMetrics.vp(24)
      },
      content: {
        title: {
          mainTitle: title,
          mainTitleSize: 20
        },
        divider: {
          showType: DividerShowType.OFF
        }
      },
      style: {
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: HdsImmersiveHelper.getScrollEffectType()
        },
        originalStyle: {
          backgroundStyle: {
            backgroundColor: originalBackgroundColor
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              backgroundColor: $r('sys.color.comp_background_tertiary'),
              iconColor: $r('sys.color.icon_primary')
            },
            dividerStyle: {
              dividerColor: Color.Transparent
            }
          }
        },
        scrollEffectStyle: {
          backgroundStyle: {
            backgroundColor: scrollBackgroundColor
          },
          contentStyle: {
            titleStyle: {
              mainTitleColor: $r('sys.color.font_primary')
            },
            backIconStyle: {
              backgroundColor: $r('sys.color.comp_background_tertiary'),
              iconColor: $r('sys.color.icon_primary')
            },
            dividerStyle: {
              dividerColor: Color.Transparent
            }
          }
        },
        systemMaterialEffect: HdsImmersiveHelper.buildHdsImmersiveSystemMaterialEffect()
      }
    };
  }
}
