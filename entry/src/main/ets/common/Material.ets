import { CommonModifier, uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { AppColors, Theme } from './Theme';
import { Glass } from './Glass';

/**
 * HarmonyOS 7.0（API 26）沉浸材质（system material）封装。
 *
 * 背景：API 26 新增 `uiMaterial.ImmersiveMaterial` + 组件通用属性 `.systemMaterial(material)`，
 * 由系统合成真正的「沉浸光感」玻璃（带光感反馈、按设备算力自适应），
 * 比手写「半透明色 + backgroundBlurStyle」更接近系统原生材质。
 *
 * 使用方式（组件级材质）：
 *  - `.systemMaterial()` 是 API 26 的**组件通用属性**：应用在 module.json5 里把
 *    metadata「ohos.arkui.UIMaterial.state」设为 enable 后，普通组件（Row/Column 等）
 *    显式挂 `uiMaterial.ImmersiveMaterial` 即可渲染沉浸材质，不需要 Navigation 标题栏等系统作用域。
 *  - ArkTS 里把属性挂到任意组件最稳的方式是 Bika 同款的 `CommonModifier` 子类：
 *    `applyNormalAttribute(instance)` 里调用 `instance.systemMaterial(material)`，
 *    再用 `.attributeModifier(new HeaderMaterialModifier(...))` 使用（见文件末尾）。
 *  - 材质可用性守卫：`Material.usable()`（API 26 + 设备支持 + 应用未 DISABLE），不可用时
 *    必须回退「主题实底 + 厚模糊」，否则会出现透明/无底板的顶栏。
 *  - 低算力设备/未开启沉浸光效时，系统会自动弱化材质，本类提供 supported() 供 UI 回退。
 */
export type MaterialKind = 'header' | 'composer' | 'panel' | 'tabbar';

export class Material {
  private static checked: boolean = false;
  private static available: boolean = false;

  /** 当前设备是否支持沉浸材质（API 26+ 且系统能力可用）。 */
  static supported(): boolean {
    if (Material.checked) {
      return Material.available;
    }
    Material.checked = true;
    try {
      Material.available = deviceInfo.apiAvailable('26.0.0') && uiMaterial.isImmersiveMaterialSupported();
    } catch (e) {
      Material.available = false;
    }
    return Material.available;
  }

  /** 重新检测（设置页切换/系统变更后可用）。 */
  static refresh(): boolean {
    Material.checked = false;
    return Material.supported();
  }

  /**
   * 读取应用级沉浸光感状态：
   *  - 0 = DEFAULT（默认，可能只对弹窗等系统组件开启）
   *  - 1 = ENABLE（应用已显式开启）
   *  - 2 = DISABLE（应用已显式禁用，此时任何 systemMaterial 都不会生效）
   * 状态来自 entry 模块 module.json5 的 metadata「ohos.arkui.UIMaterial.state」。
   */
  static state(): number {
    try {
      const info: uiMaterial.MaterialInfo = uiMaterial.getMaterialInfo();
      return info.state as number;
    } catch (e) {
      return -1;
    }
  }

  /**
   * 当前环境是否可以真正渲染系统材质：API 26+、系统支持、且应用未被配置为 DISABLE。
   * 直接按 Bika 同款守卫读 `getMaterialInfo().state !== MaterialState.DISABLE`，
   * 应用级状态来自 entry/module.json5 的 metadata「ohos.arkui.UIMaterial.state」。
   */
  static usable(): boolean {
    if (!Material.supported()) {
      return false;
    }
    try {
      return uiMaterial.getMaterialInfo().state !== uiMaterial.MaterialState.DISABLE;
    } catch (e) {
      return false;
    }
  }

  /**
   * 空材质：显式清掉组件上已有的系统材质（例如材质开关从开切到关、或从材质回退到实底时）。
   * 不支持材质的环境返回 undefined，调用方跳过即可。
   */
  static empty(): uiMaterial.Material | undefined {
    try {
      return uiMaterial.Material.empty;
    } catch (e) {
      return undefined;
    }
  }

  private static materialLevelChecked: boolean = false;
  private static materialLevelValue: uiMaterial.MaterialLevel = uiMaterial.MaterialLevel.EXQUISITE;

  /**
   * 设备算力档（决定沉浸材质的通透度：EXQUISITE 高 / GENTLE 中 / SMOOTH 低）。
   * 系统按算力档决定材质表现：高/中档有滤镜效果，低档主要表现为底色 + 描边。
   * 只查询一次并缓存；查询失败（低于 API 26 / 预览器）按高算力档处理。
   */
  static materialLevel(): uiMaterial.MaterialLevel {
    if (Material.materialLevelChecked) {
      return Material.materialLevelValue;
    }
    Material.materialLevelChecked = true;
    try {
      Material.materialLevelValue = uiMaterial.getGlobalMaterialLevel();
    } catch (e) {
      Material.materialLevelValue = uiMaterial.MaterialLevel.EXQUISITE;
    }
    return Material.materialLevelValue;
  }

  /**
   * 胶囊染色层：与 Bika 的胶囊染色同一思路（本工程独立实现）。
   *  - 高算力设备：材质本身有玻璃感与滤镜，只留 10% 极薄底色（兜底「材质没渲染出来」的极端情况，
   *    同时不把 systemMaterial 盖成实色）；
   *  - 中算力设备：20% 薄染色，维持胶囊轮廓与文字对比；
   *  - 低算力设备：材质退化为底色 + 描边，染色提高到 60%，保证胶囊在任何壁纸/视频画面上都可读。
   * 颜色取主题语义色（深色主题用深色底，浅色主题用白色），不写死品牌色。
   * 染色层是独立 Row（不在材质 Modifier 里），主题切换会随组件重建即时生效。
   */
  static capsuleTint(): string {
    const level: uiMaterial.MaterialLevel = Material.materialLevel();
    if (level === uiMaterial.MaterialLevel.EXQUISITE) {
      return Theme.isDark() ? '#1A20252E' : '#1AFFFFFF';
    }
    if (level === uiMaterial.MaterialLevel.GENTLE) {
      return Theme.isDark() ? '#3320252E' : '#33FFFFFF';
    }
    return Theme.isDark() ? '#9920252E' : '#99FFFFFF';
  }

  /** 状态的调试文案（设置页展示用）。 */
  static stateLabel(): string {
    const state: number = Material.state();
    if (state === 1) {
      return '已开启（ENABLE）';
    }
    if (state === 0) {
      return '系统默认（DEFAULT）';
    }
    if (state === 2) {
      return '已禁用（DISABLE）';
    }
    return '不可用';
  }

  /**
   * 材质表面染色：深色主题用**黑色低 alpha**（压暗玻璃，避免深色下顶栏/控件「透白」），
   * 浅色主题用白色低 alpha（提亮玻璃）——深/浅色各用同一套 alpha 梯度，只换色相。
   *
   * 为什么深色不能继续用白色染色：材质本身在深色场景下是一层透明玻璃，白染色叠在它上面
   * 会把顶栏/评论框提亮成灰白雾面；黑色染色叠上去才会得到「半透明深灰玻璃」，
   * 观感与悬浮底栏一致。
   *
   * 注意：`materialColor` 在创建 ImmersiveMaterial 的一刻就固化进实例（不是响应式属性），
   * 主题切换后必须重建材质实例（MaterialSurface / GlassCapsule 用 @Watch 监听
   * themeMode / systemDark 并 bump 版本号重建），仅改 Theme 不会让旧实例变色。
   */
  private static surfaceTint(dark: string, light: string): string {
    return Theme.isDark() ? dark : light;
  }

  /** 按用途取材质配方（MaterialSurface / 悬浮评论框 / 顶栏 / 底栏） */
  static create(kind: MaterialKind): uiMaterial.ImmersiveMaterial {
    if (kind === 'header') {
      return Material.headerMaterial();
    }
    if (kind === 'composer') {
      return Material.composerMaterial();
    }
    if (kind === 'tabbar') {
      return Material.tabBarMaterial();
    }
    return Material.panelMaterial();
  }

  /**
   * 底部悬浮 TabBar 的沉浸材质：极薄档，透出壁纸；交互光感开启。
   * 底栏是用户认可的「目标观感」，深色继续用 5% 极低白（它压在深色页面底上本来就发暗），
   * 不随顶栏/评论框一起换成黑染色，避免底栏变得比现在更沉。
   * 注意：每次调用返回新实例（材质实例与挂载表面绑定，不可跨表面复用）。
   */
  static tabBarMaterial(): uiMaterial.ImmersiveMaterial {
    const colors: AppColors = Theme.colors();
    const material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.ULTRA_THIN,
      materialColor: Material.surfaceTint('#0DFFFFFF', '#12FFFFFF'),
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: colors.primary }
    });
    return material;
  }

  /**
   * 页面顶部固定栏（含状态栏区域）的沉浸材质：与底栏同一套（THIN 档 + 交互光感），
   * 覆盖状态栏时仍透出壁纸。不可用时调用方回退 barTint + BAR_BLUR。
   *
   * 染色：深色用 10% 黑（深灰玻璃，不再发白）；浅色用 12% 白（保持现状）。
   * 各档 alpha 梯度沿用 顶栏 10% < 面板 12% < 评论框 15%（深色）/ 顶栏 12% < 面板 15% < 评论框 20%（浅色），
   * 越厚的材质越低透，保证文字可读。
   */
  static headerMaterial(): uiMaterial.ImmersiveMaterial {
    const colors: AppColors = Theme.colors();
    const material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.THIN,
      materialColor: Material.surfaceTint('#1A000000', '#1FFFFFFF'),
      colorInvert: false,
      applyShadow: false,
      interactive: true,
      lightEffect: { color: colors.primary }
    });
    return material;
  }

  /**
   * 悬浮评论输入框的沉浸材质：REGULAR 档，玻璃感更厚，浮在视频/评论列表上时文字更清晰。
   * 不可用时调用方回退 barTint + BAR_BLUR。
   *
   * 染色：深色用 15% 黑（与底栏同策略、按更厚材质略加深，保证浮在视频画面上时字面可读）；
   * 浅色用 20% 白（保持现状）。
   */
  static composerMaterial(): uiMaterial.ImmersiveMaterial {
    const colors: AppColors = Theme.colors();
    const material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: Material.surfaceTint('#26000000', '#33FFFFFF'),
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: colors.primary }
    });
    return material;
  }

  /**
   * 普通面板（悬浮评论框等）的材质：REGULAR 档，厚度适中。
   * 染色：深色用 12% 黑、浅色用 15% 白（保持原浅色档位），与顶栏/评论框 alpha 顺序一致。
   */
  static panelMaterial(): uiMaterial.ImmersiveMaterial {
    const colors: AppColors = Theme.colors();
    const material: uiMaterial.ImmersiveMaterial = new uiMaterial.ImmersiveMaterial({
      style: uiMaterial.ImmersiveStyle.REGULAR,
      materialColor: Material.surfaceTint('#1F000000', '#26FFFFFF'),
      colorInvert: false,
      applyShadow: true,
      interactive: true,
      lightEffect: { color: colors.primary }
    });
    return material;
  }
}

/**
 * 组件级沉浸材质宿主（Bika `GlassCapsuleMaterial` 同款做法，独立实现）。
 *
 * 为什么用 CommonModifier：`.systemMaterial()` 只能通过组件通用属性挂到具体组件上，
 * 而顶栏底板是「无内容的全尺寸 Row」，用 Modifier 可以把「系统材质 / 回退实底」的
 * 选择逻辑收在一个地方，多个页面（顶栏、评论胶囊、面板）共用同一套回退规则。
 *
 * 行为（applyNormalAttribute 每次重绘都会调用）：
 *  1. 材质可用且调用方允许（materialEnabled）：先铺一层很淡的回退底色（<20%，低算力设备上
 *     系统会把材质退化成这个底色），再 `instance.systemMaterial(THIN/REGULAR)`。
 *     ENABLE 态下系统会用材质覆盖 backgroundColor / backgroundBlurStyle（背景被透明化），
 *     所以这层淡底不会盖住材质，也不在材质分支重复设置 backgroundBlurStyle（官方建议开启
 *     材质后移除自定义背景模糊，避免两套模糊机制叠加出视觉异常）。
 *  2. 否则：`backgroundColor(fallbackTint)` + `backgroundBlurStyle(按用途)`，并清空可能残留的
 *     材质（`Material.empty()`），保证低版本/未开启光效设备也有一块可见玻璃。
 *
 * 回退透明度与兜底模糊（配合 MaterialSurface 的层序修复）：
 *  - 回退底色由调用方算好传进来：MaterialSurface 顶栏传「barTint 42%」、评论胶囊传
 *    「barTint 48%」—— 比旧版 69% / 88% 明显降低，避免把其上方/下方的模糊剥片压成纯色；
 *    材质可用时同参数传的是 barTint 14%~18% 的淡底。
 *  - 回退分支的 backgroundBlurStyle 按用途分档：顶栏 COMPONENT_THICK（BAR_BLUR）保证可读，
 *    胶囊/面板 COMPONENT_THIN（CARD_BLUR）保留玻璃透感。它与 MaterialSurface 最底层的
 *    backdropBlur 剥片形成「双重保险」：任何设备上至少有一层可见模糊。
 *
 * 用法：`Row().attributeModifier(new HeaderMaterialModifier('header', '#B0FFFFFF', true))`
 */
export class HeaderMaterialModifier extends CommonModifier {
  private readonly recipe: MaterialKind;
  private readonly fallbackTint: string;
  private readonly materialEnabled: boolean;

  constructor(recipe: MaterialKind, fallbackTint: string, materialEnabled: boolean) {
    super();
    this.recipe = recipe;
    this.fallbackTint = fallbackTint;
    this.materialEnabled = materialEnabled;
  }

  /** 材质不可用时的兜底背景模糊档位：顶栏厚、胶囊/面板薄（可见的渐变模糊由剥片负责） */
  private fallbackBlurStyle(): BlurStyle {
    return this.recipe === 'header' ? Glass.BAR_BLUR : Glass.CARD_BLUR;
  }

  applyNormalAttribute(instance: CommonAttribute): void {
    if (this.materialEnabled && Material.usable()) {
      try {
        instance.backgroundColor(this.fallbackTint);
        instance.systemMaterial(Material.create(this.recipe));
        return;
      } catch (e) {
        // 个别设备/预览环境创建材质会抛错：吞掉后走下面的实底回退
      }
    }
    const empty: uiMaterial.Material | undefined = Material.empty();
    if (empty !== undefined) {
      instance.systemMaterial(empty);
    }
    instance.backgroundColor(this.fallbackTint);
    instance.backgroundBlurStyle(this.fallbackBlurStyle());
  }
}
