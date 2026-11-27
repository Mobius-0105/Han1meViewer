import { CommonModifier } from '@kit.ArkUI';
import { Material, MaterialKind } from '../../common/Material';
import { Theme } from '../../common/Theme';
import { Glass } from '../../common/Glass';

/**
 * 顶栏 / 悬浮评论输入框 / 面板的「系统沉浸材质」宿主。
 *
 * ## 材质路径：Bika `DetailGlassCapsule` 同款 Navigation + title builder（不再是 Tabs）
 * Bika 的实物质感来自一条真实存在的系统栏作用域：
 *
 *   Navigation() {}
 *     .backgroundColor(Color.Transparent).borderRadius(r).clip(r > 0)
 *     .mode(NavigationMode.Stack)
 *     .hideBackButton(true).hideToolBar(true)
 *     .hideTitleBar(false)                              // 关键：标题栏必须可见
 *     .title({ builder: materialContent, height: surfaceHeight }, {
 *       barStyle: BarStyle.STACK,
 *       backgroundColor: Color.Transparent,
 *       backgroundBlurStyle: BlurStyle.NONE,
 *       systemMaterial: Material.empty()                // 宿主整条材质清空，只留我们自己的材质 Row
 *     })
 *
 * 材质 Row 放在标题栏 builder 里，`attributeModifier(CommonModifier.systemMaterial(ImmersiveMaterial))`
 * 由系统按设备算力合成玻璃；标题栏作用域本身是一块「系统栏」，所以 systemMaterial 不会被降级成纯染色。
 * 对 header 用通栏矩形（radius 0、高度 = 状态栏 + 标题行），对 composer/panel 用胶囊圆角；
 * 材质只画在目标尺寸内，Navigation 宿主自身始终透明，不会出现整条背板。
 *
 * 之前为什么不行（与旧实现的两条路对比）：
 *  - 旧版用「只有一个空 Tab 的 Tabs」当材质画布，再靠 `barFloatingStyle` 把 bar 缩成胶囊：
 *    空 Tabs 的 floating bar 不与真实 TabContent 关联，barWidth / mask / barModifier 互相覆盖，
 *    并没有产生真正参与合成的系统栏表面，所以顶栏和评论框都看不到材质（悬浮底栏是真实 TabBar 才有）。
 *  - 更早的「隐藏 Navigation 标题作用域」方案：hideTitleBar(true) / 0 高度会让作用域根本不创建，
 *    systemMaterial 同样退化。Bika 的 `hideTitleBar(false)` + `title({height})` 才是让作用域存在且
 *    尺寸精确可控的关键。
 *
 * ## 保留的单层模糊
 * Navigation 材质之外，仍保留一层 `backdropBlur` 作为「模糊感」来源（任何设备、材质被关闭时都有玻璃观感），
 * 放在材质层下方；它命中穿透、不盖内容。
 *
 * ## 顶栏背景层：无白色遮罩
 * 顶栏只保留三类背景层：系统沉浸材质 + 单层 backdropBlur + 中性底色染色。
 *  - 去掉旧的顶栏顶部白色高光（`topHighlight`，8% 白 → 透明），它会在材质上盖出一层白色渐变；
 *  - 去掉旧的跨边界下边缘渐隐遮罩（`bottomFade`，页面底色 80% 峰值，还要求溢出顶栏边界绘制）；
 *  - 下边缘改由一条 0.5vp 的 `Theme.colors().divider` 发丝线表达：贴底、整宽、命中穿透，
 *    作为「模糊/材质在这里结束」的分割；
 *  - 染色层只用中性页面底色（`Theme.colors().background`）的低透明度纵向渐变，材质可渲染时
 *    压到 10% / 4%，不再叠任何白色高光。
 *
 * ## 降级
 * 材质不可用（API < 26 / 系统不支持 / 应用级 DISABLE / active = false）时，退回「barTint + 厚模糊」底板，
 * 顶栏仍由单层 backdropBlur + 底板 + 略强的中性底色染色 + 下边缘发丝线组成，不会出现透明顶栏。
 *
 * ## 深浅色切换即时重建
 * `ImmersiveMaterial.materialColor` 在创建实例时就固化（不是响应式属性），所以切换深/浅色后旧材质仍带浅色参数，
 * 顶栏会继续发白。这里用 `@Watch('onThemeChanged')` 同时监听 `themeMode` / `systemDark`：
 * 回调里重新 `Material.create(kind)` + 新建 `CommonModifier`，并 bump `@State materialRevision`；
 * build() 用版本号作材质宿主 `ForEach` 的 key —— 版本号一变（深色 ⇄ 浅色）材质宿主整块重建，
 * 重新执行标题栏 builder，把按新主题染色创建的材质实例挂到新表面（不重启 App、不重进页面）。
 * 内容层（顶栏标题/输入框/圆钮）在独立的兄弟层里，不随材质重建而重建，输入焦点与状态不受影响。
 *
 * 对外参数与旧版完全一致：`surfaceHeight / radius / kind / active / @BuilderParam content`。
 */

/** 单层均匀模糊半径（不用多条剥片，避免分层/错位） */
const HEADER_BLUR_RADIUS: number = 24;
const COMPOSER_BLUR_RADIUS: number = 16;
/** 顶栏下边缘发丝分割线高度（vp）：0.5 = 半像素，深浅色下都是一条细线 */
const HEADER_HAIRLINE: number = 0.5;

@Component
export struct MaterialSurface {
  /** 目标平面高度（必填，调用方给出精确高度，含状态栏区域） */
  surfaceHeight: number = 52;
  /** 圆角；0 = 直角（通栏顶栏），评论胶囊传 24 */
  radius: number = 0;
  /** 材质配方：header / composer / panel / tabbar */
  kind: MaterialKind = 'header';
  /** 外部可强制关闭系统材质（例如用户设置关闭）；关闭时退回渐变模糊玻璃 */
  active: boolean = true;

  @BuilderParam content: () => void;

  @StorageLink('themeMode') @Watch('onThemeChanged') themeMode: string = 'system';
  @StorageLink('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;

  /** 系统沉浸材质是否可用 */
  @State private materialReady: boolean = false;
  /**
   * 材质版本号：`materialColor` 在创建材质时固化，切换深浅色后必须换新实例才会变暗/变亮。
   * 它参与 build（材质宿主 ForEach 的 key）：版本号一变材质宿主整块重建，
   * 让按新主题染色创建的 ImmersiveMaterial 真正替换掉旧实例。
   */
  @State private materialRevision: number = 0;
  /** 材质层通用属性（每次重建材质时新建：材质对象与挂载表面绑定，不能跨表面复用） */
  private materialModifier: CommonModifier = new CommonModifier();
  /** 上次建材质时实际是否深色：用户强制浅/深色时系统深浅变化不影响主题，跳过重建避免无意义闪烁 */
  private appliedDark: boolean = Theme.isDark();

  aboutToAppear(): void {
    this.appliedDark = Theme.isDark();
    this.rebuildMaterial();
  }

  /** 深浅色切换：重建材质实例与 modifier，并 bump 版本号触发材质宿主重建 */
  onThemeChanged(): void {
    const dark: boolean = Theme.isDark();
    if (dark === this.appliedDark) {
      return;
    }
    this.appliedDark = dark;
    this.rebuildMaterial();
    this.materialRevision = this.materialRevision + 1;
  }

  /** 创建/重建材质：可用时新建 CommonModifier + 按当前主题染色的 ImmersiveMaterial，否则清空 modifier */
  private rebuildMaterial(): void {
    this.materialReady = this.active && Material.usable();
    if (this.materialReady) {
      const modifier: CommonModifier = new CommonModifier();
      modifier.borderRadius(this.radius).clip(this.radius > 0).backgroundColor(Color.Transparent);
      modifier.systemMaterial(Material.create(this.kind));
      this.materialModifier = modifier;
    } else {
      this.materialModifier = new CommonModifier();
    }
  }

  private safeHeight(): number {
    return this.surfaceHeight > 0 ? this.surfaceHeight : 1;
  }

  private isHeader(): boolean {
    return this.kind === 'header';
  }

  /** 单层均匀模糊半径：整块只模糊一次 */
  private blurRadius(): number {
    return this.isHeader() ? HEADER_BLUR_RADIUS : COMPOSER_BLUR_RADIUS;
  }

  private fallbackTint(): string {
    return Glass.withAlpha(Theme.colors().barTint, this.isHeader() ? 0.42 : 0.48);
  }

  /**
   * 顶栏中性底色染色（页面底色，不是白色高光）：材质可渲染时压淡，避免把 systemMaterial 盖成实色板；
   * 材质不可用时略强，保证降级底板上标题/状态栏内容仍可读。
   */
  private tintTop(): string {
    return Glass.withAlpha(Theme.colors().background, this.materialReady ? 0.10 : 0.28);
  }

  private tintMid(): string {
    return Glass.withAlpha(Theme.colors().background, this.materialReady ? 0.04 : 0.14);
  }

  // ---------------------------------------------------------------------------
  // 材质路径：Navigation 标题栏作用域里的「材质 Row + 染色层」
  // ---------------------------------------------------------------------------

  /**
   * 标题栏 builder：材质 Row（systemMaterial）+ 非 header 的染色层。
   *
   * 用 @LocalBuilder 而不是 @Builder：Navigation 的 `title({ builder })`（NavigationCustomTitle）会把
   * builder 放到 Navigation 内部作用域执行，普通 @Builder 在此场景下 `this`/状态归属可能丢失
   * （表现为标题内容不刷新或不生效）；@LocalBuilder 保证 builder 中的 `this` 始终指向本组件，
   * 组件状态（materialRevision / materialReady）变化时标题栏内容才会正常刷新/重建。
   */
  @LocalBuilder
  materialContent() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 材质层：component 级 systemMaterial 挂在 Row 上，由 Navigation 标题栏这条系统栏作用域合成
      Row()
        .width('100%')
        .height(this.safeHeight())
        .borderRadius(this.radius)
        .attributeModifier(this.materialModifier)
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants');
      // 染色层（header 的纵向染色由外层 tintLayer 负责，避免同一位置叠两次）
      if (!this.isHeader()) {
        Row()
          .width('100%')
          .height(this.safeHeight())
          .borderRadius(this.radius)
          .backgroundColor(Material.capsuleTint())
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no-hide-descendants');
      }
    }
    .width('100%')
    .height(this.safeHeight())
    .borderRadius(this.radius);
  }

  /**
   * 材质宿主：一个只有标题栏、没有内容的 Navigation。
   * 整层命中穿透（只负责画材质），真实控件在外部内容层，永远在最上面。
   */
  @Builder
  materialHost() {
    Navigation() {
    }
    .width('100%')
    .height(this.safeHeight())
    .backgroundColor(Color.Transparent)
    .borderRadius(this.radius)
    .clip(this.radius > 0)
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title({ builder: this.materialContent, height: this.safeHeight() }, {
      barStyle: BarStyle.STACK,
      backgroundColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      systemMaterial: Material.empty()
    })
    .hideTitleBar(false)
    .ignoreLayoutSafeArea([], [])
    .hitTestBehavior(HitTestMode.None)
    .accessibilityLevel('no-hide-descendants');
  }

  // ---------------------------------------------------------------------------
  // 模糊 / 回退底板 / 中性染色 / 下边缘发丝线
  // ---------------------------------------------------------------------------

  /**
   * 单层均匀 backdropBlur：不管材质是否可用都先画，滚动内容从顶栏下方经过时一定有毛玻璃模糊。
   * 放在材质层下方（采样的是页面内容，不是材质本身），命中穿透、不盖内容。
   */
  @Builder
  blurBase() {
    Row()
      .width('100%')
      .height(this.safeHeight())
      .borderRadius(this.radius)
      .clip(this.radius > 0)
      .backdropBlur(this.blurRadius())
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants');
  }

  /** 材质不可用时的兜底底板：主题底 + 厚模糊（与最底层 backdropBlur 形成双保险） */
  @Builder
  fallbackBase() {
    Row()
      .width('100%')
      .height(this.safeHeight())
      .borderRadius(this.radius)
      .backgroundColor(this.fallbackTint())
      .backgroundBlurStyle(Glass.BAR_BLUR)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants');
  }

  /**
   * 染色层：header 只保留「中性页面底色 → 透明」的纵向染色（无白色高光）；其它形态降级时补一层轻底色。
   * 降级轻底色取 `barTint` 的 5%：浅色主题 = 白 5%（原写死 '#0DFFFFFF' 的效果），
   * 深色主题 = 深色 barTint 5%，不再给深色面板/评论框叠白。
   */
  @Builder
  tintLayer() {
    if (this.isHeader()) {
      Row()
        .width('100%')
        .height(this.safeHeight())
        .linearGradient({
          angle: 180,
          colors: [
            [this.tintTop(), 0.0],
            [this.tintMid(), 0.55],
            [Glass.withAlpha(Theme.colors().background, 0), 1.0]
          ]
        })
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants');
    } else if (!this.materialReady) {
      Row()
        .width('100%')
        .height(this.safeHeight())
        .borderRadius(this.radius)
        .backgroundColor(Glass.withAlpha(Theme.colors().barTint, 0.05))
        .hitTestBehavior(HitTestMode.None)
        .accessibilityLevel('no-hide-descendants');
    }
  }

  /**
   * 顶栏下边缘的 0.5vp 发丝分割线：贴底、整宽、命中穿透。
   * 它是「模糊/材质在这里结束」的边界表达，替代此前会溢出边界、把材质压成白雾的下边缘渐隐遮罩。
   */
  @Builder
  bottomHairline() {
    Row()
      .width('100%')
      .height(HEADER_HAIRLINE)
      .position({ x: 0, y: this.safeHeight() - HEADER_HAIRLINE })
      .backgroundColor(Theme.colors().divider)
      .hitTestBehavior(HitTestMode.None)
      .accessibilityLevel('no-hide-descendants');
  }

  // ---------------------------------------------------------------------------
  // 内容层
  // ---------------------------------------------------------------------------

  @Builder
  contentLayer() {
    Column() {
      this.content();
    }
    .width('100%')
    .height(this.safeHeight())
    .borderRadius(this.radius);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 层 1：单层 backdropBlur（模糊感来源，任何设备都在）
      this.blurBase();
      // 层 2：材质宿主 / 降级底板。以材质版本号作 ForEach 的 key（两条分支都读版本号）：
      //  - 材质可渲染：版本号变化 → Navigation 材质宿主整块重建，标题栏 builder 重新执行，
      //    按新主题染色（深色黑 / 浅色白）创建的 ImmersiveMaterial 才会替换掉旧实例；
      //  - 材质不可用：同样按新主题重建降级底板，深色下不再发白。
      if (this.materialReady) {
        ForEach([this.materialRevision], (revision: number) => {
          this.materialHost();
        }, (revision: number) => revision.toString());
      } else {
        ForEach([this.materialRevision], (revision: number) => {
          this.fallbackBase();
        }, (revision: number) => revision.toString());
      }
      // 层 3：中性底色染色（无白色高光，全部命中穿透）
      this.tintLayer();
      if (this.isHeader()) {
        // 层 3.5：顶栏下边缘发丝分割线（贴底整宽、命中穿透）
        this.bottomHairline();
      }
      // 层 4：内容（控件/输入框）永远最上层
      this.contentLayer();
    }
    .width('100%')
    .height(this.safeHeight());
  }
}
