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

interface HdsUiContext {
  px2vp(value: number): number;
  getHostContext(): Object;
}

interface UiContextOwner {
  getUIContext(): HdsUiContext;
}

export interface HdsSystemAvoidAreaBinding {
  callback: (info: window.AvoidAreaOptions) => void;
  win: window.Window;
}

export class HdsImmersiveHelper {
  static readonly MINI_TITLE_BAR_HEIGHT: number = 56;
  static readonly LEGACY_TOP_SAFE_INSET_VP: number = 44;
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

  static pxToVp(owner: Object, value: number): number {
    try {
      return (owner as UiContextOwner).getUIContext().px2vp(value);
    } catch (_err) {
      return value;
    }
  }

  static syncSystemTopInsetVp(owner: Object, onResolved: (value: number) => void): void {
    HdsImmersiveHelper.syncSystemInsetsVp(owner, (topInsetVp: number): void => {
      onResolved(topInsetVp);
    });
  }

  static syncSystemInsetsVp(owner: Object, onResolved: (topInsetVp: number, bottomInsetVp: number) => void): void {
    try {
      const ctx = (owner as UiContextOwner).getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window): void => {
        HdsImmersiveHelper.syncSystemInsetsByWindow(owner, win, onResolved);
      }).catch((_err: Error): void => {
        onResolved(HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP, 0);
      });
    } catch (_err) {
      onResolved(HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP, 0);
    }
  }

  static syncSystemInsetsByWindow(
    owner: Object,
    win: window.Window,
    onResolved: (topInsetVp: number, bottomInsetVp: number) => void
  ): void {
    try {
      const area = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      onResolved(
        Math.max(0, HdsImmersiveHelper.pxToVp(owner, area.topRect.height)),
        Math.max(0, HdsImmersiveHelper.pxToVp(owner, area.bottomRect.height))
      );
    } catch (_err) {
      onResolved(HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP, 0);
    }
  }

  static bindSystemAvoidAreaChange(
    owner: Object,
    onResolved: (topInsetVp: number, bottomInsetVp: number) => void,
    onBound: (binding: HdsSystemAvoidAreaBinding) => void,
    onFailed?: () => void
  ): void {
    try {
      const ctx = (owner as UiContextOwner).getUIContext().getHostContext() as common.UIAbilityContext;
      window.getLastWindow(ctx).then((win: window.Window): void => {
        HdsImmersiveHelper.syncSystemInsetsByWindow(owner, win, onResolved);
        const callback = (info: window.AvoidAreaOptions): void => {
          if (info.type !== window.AvoidAreaType.TYPE_SYSTEM) {
            return;
          }
          onResolved(
            Math.max(0, HdsImmersiveHelper.pxToVp(owner, info.area.topRect.height)),
            Math.max(0, HdsImmersiveHelper.pxToVp(owner, info.area.bottomRect.height))
          );
        };
        try {
          win.on('avoidAreaChange', callback);
          onBound({ win, callback });
        } catch (_err) {
          onFailed?.();
        }
      }).catch((_err: Error): void => {
        onFailed?.();
      });
    } catch (_err) {
      onFailed?.();
    }
  }

  static unbindSystemAvoidAreaChange(binding?: HdsSystemAvoidAreaBinding): void {
    if (binding === undefined) {
      return;
    }
    try {
      binding.win.off('avoidAreaChange', binding.callback);
    } catch (_err) {
    }
  }

  static topSafeInsetVp(): number {
    return (AppStorage.get<number>(HdsImmersiveHelper.TOP_SAFE_INSET_VP_KEY) as number)
      ?? HdsImmersiveHelper.LEGACY_TOP_SAFE_INSET_VP;
  }

  static bottomSafeInsetVp(): number {
    return (AppStorage.get<number>(HdsImmersiveHelper.BOTTOM_SAFE_INSET_VP_KEY) as number) ?? 0;
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
