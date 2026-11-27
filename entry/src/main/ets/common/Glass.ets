/**
 * 玻璃材质的轻量封装。
 *
 * 设计基线（PuraPily 风格）：
 *  - 卡片用「70% 不透明卡片色 + 薄模糊 + 1vp 25% 描边 + 柔和阴影」，壁纸透出但不影响阅读；
 *  - 顶栏用「渐变模糊剥片 + 低透明度染色渐变 + 可选系统沉浸材质」，材质不可用时回退到
 *    「barTint 降透明度 + 厚模糊」（BAR_BLUR）保证任何设备都有玻璃底板；
 *  - 悬浮底栏用更不透明的 barTint + 厚模糊；
 *  - 胶囊/标签用半透明 chipTint；
 *  - 只使用公开 API（backdropBlur / backgroundBlurStyle / systemMaterial 组件级材质）。
 */

export class Glass {
  /** 卡片/区块的模糊档位 */
  static readonly CARD_BLUR: BlurStyle = BlurStyle.COMPONENT_THIN;
  /** 顶栏/悬浮底栏的模糊档位 */
  static readonly BAR_BLUR: BlurStyle = BlurStyle.COMPONENT_THICK;
  /** 标签/胶囊的模糊档位 */
  static readonly CHIP_BLUR: BlurStyle = BlurStyle.COMPONENT_ULTRA_THIN;

  /** 卡片阴影：柔和、低透明 */
  static cardShadow(color: string): ShadowOptions {
    const options: ShadowOptions = {
      radius: 16,
      color: color,
      offsetX: 0,
      offsetY: 6
    };
    return options;
  }

  /** 悬浮底栏阴影 */
  static barShadow(color: string): ShadowOptions {
    const options: ShadowOptions = {
      radius: 28,
      color: color,
      offsetX: 0,
      offsetY: 12
    };
    return options;
  }

  /** 1vp 高光/暗部描边 */
  static borderWidth(): number {
    return 1;
  }

  /**
   * 把颜色改写成指定不透明度，返回 `#AARRGGBB`。
   *
   * 顶栏的「染色渐变 / 材质回退底色」都要求同一个 barTint 在不同层用不同透明度：
   * 材质可用时染色层压到 20%~35%（否则会把材质盖住），材质不可用时才提高到 ~70% 兜底。
   * 支持 `#RRGGBB` 与 `#AARRGGBB` 两种输入（本工程的语义色都是这两种）。
   */
  static withAlpha(color: string, alpha: number): string {
    const clamped: number = Math.max(0, Math.min(1, alpha));
    let hex: string = Math.round(clamped * 255).toString(16).toUpperCase();
    if (hex.length < 2) {
      hex = '0' + hex;
    }
    const body: string = color.length === 9 ? color.substring(3) : color.substring(1);
    return '#' + hex + body;
  }
}
