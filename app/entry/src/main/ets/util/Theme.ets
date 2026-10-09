import { common, ConfigurationConstant } from '@kit.AbilityKit';

/**
 * 图表取色（Canvas 只能吃颜色字符串，没法直接用资源色板）。
 * 页面在 aboutToAppear 里读一次系统深浅色，绘制时按需取色。
 */
export class Theme {
  static isDark(ctx: common.UIAbilityContext): boolean {
    try {
      return ctx.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return false;
    }
  }

  static grid(dark: boolean): string {
    return dark ? '#26FFFFFF' : '#EDEFF2';
  }

  static axis(dark: boolean): string {
    return dark ? '#80FFFFFF' : '#9AA0A8';
  }

  static text(dark: boolean): string {
    return dark ? '#E6FDFDFD' : '#1B1F26';
  }

  static ctl(dark: boolean): string {
    return dark ? '#7FA8FF' : '#2F6FED';
  }

  static atl(dark: boolean): string {
    return dark ? '#FFB27A' : '#E8833A';
  }

  static tsb(dark: boolean): string {
    return dark ? '#B3FFFFFF' : '#8A8F99';
  }

  static zeroLine(dark: boolean): string {
    return dark ? '#4DFFFFFF' : '#D6DAE0';
  }

  static fill(dark: boolean): string {
    return dark ? 'rgba(127,168,255,0.16)' : 'rgba(47,111,237,0.10)';
  }

  static accent(dark: boolean): string {
    return dark ? '#7FA8FF' : '#2F6FED';
  }
}
