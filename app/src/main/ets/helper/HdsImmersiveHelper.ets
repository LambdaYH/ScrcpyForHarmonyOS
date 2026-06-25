import { common } from '@kit.AbilityKit';
import { LengthMetrics, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import {
  DividerShowType,
  hdsMaterial,
  HdsNavigationTitleBarOptions,
  ScrollEffectType,
  SystemMaterialParams
} from '@kit.UIDesignKit';

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
