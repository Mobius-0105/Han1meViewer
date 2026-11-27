import { CommonModifier } from '@kit.ArkUI';
import { Material, MaterialKind } from '../../common/Material';
import { Theme } from '../../common/Theme';
import { Glass } from '../../common/Glass';

/**
 * 与悬浮底栏同一档「系统沉浸材质」的玻璃胶囊 / 玻璃圆钮。
 *
 * ## 结构（照 Bika DetailGlassCapsule 的真实做法，本工程独立实现，不复制其代码）
 * Bika 的胶囊不是「普通 Row 直接挂 systemMaterial」，而是一个 **Navigation**：
 *
 *   Navigation() {}
 *     .width('100%').height(capsuleHeight)
 *     .backgroundColor(Color.Transparent).borderRadius(capsuleHeight/2).clip(true)
 *     .mode(NavigationMode.Stack)
 *     .hideBackButton(true).hideToolBar(true)
 *     .hideTitleBar(false)                              // 关键：标题栏必须可见
 *     .title({ builder: glassContent, height: capsuleHeight }, {
 *       barStyle: BarStyle.STACK,                       // 标题栏盖在内容区上
 *       backgroundColor: Color.Transparent,             // 宿主背板透明
 *       backgroundBlurStyle: BlurStyle.NONE,            // 不额外叠系统模糊
 *       systemMaterial: Material.empty()                // 清掉标题栏宿主的整条材质
 *     })
 *
 *   glassContent = Stack {
 *     材质层 Row  → attributeModifier(CommonModifier.systemMaterial(ImmersiveMaterial))
 *     染色层 Row  → backgroundColor(按设备算力的胶囊染色)
 *     内容层 Row  → this.content()
 *   }
 *
 * ## 为什么这样能出材质（与旧 Tabs / 隐藏作用域方案的差异）
 *  - 沉浸材质（`uiMaterial.ImmersiveMaterial`）由系统在「系统栏作用域」内合成：TabBar、Navigation 标题栏、
 *    系统弹窗等。挂普通内容层的 Row 上时，系统可能只回退成半透明染色（本工程旧实现即如此，
 *    所以顶栏/评论框一直没有材质，而真实 TabBar 的悬浮底栏有）。
 *  - 旧版用一个「只有一个空 Tab 的 Tabs」当材质画布，再靠 `barFloatingStyle` 把 bar 缩成胶囊：
 *    空 Tabs 的 bar 不与真实 TabContent 关联，floating bar 的宽度/边距/遮罩与 barModifier 相互覆盖，
 *    实际并没有产生一块真正参与合成的系统栏表面，所以看不到材质。
 *  - 「隐藏标题栏」方案（hideTitleBar(true) 或把标题栏尺寸压成 0）会让画材质的系统栏作用域根本不创建，
 *    作用域不存在时 systemMaterial 同样只会退化。
 *  - Navigation 标题栏是一条**真实存在、按我们给定高度布局**的系统栏：`hideTitleBar(false)` 保证作用域被创建，
 *    `title({height})` 给出精确胶囊高度，外层 `clip(true)` 把这条系统栏裁成胶囊形。材质只画在作用域内部的
 *    Row 上（标题栏自身的材质用 `Material.empty()` 清空），所以不会出现「整条通栏背板」。
 *
 * ## 降级
 * `Material.usable()` 为假（API < 26 / 系统不支持 / 应用级 DISABLE）时不挂 `systemMaterial`，
 * Navigation 只作为裁剪/布局宿主，标题栏里改画「chipTint + CHIP_BLUR + 1vp 描边」，
 * 保证任何设备上胶囊都有可见底板。
 *
 * ## 深浅色切换即时重建
 * `ImmersiveMaterial.materialColor` 在创建时固化，切换深/浅色后旧材质仍带浅色参数（深色下控件发白）。
 * `@Watch('onThemeChanged')` 监听 `themeMode` / `systemDark`：回调里重新 `Material.create(kind)` +
 * 新建 `CommonModifier`，并 bump `@State materialRevision`；build() 以版本号作外层 `ForEach` 的 key，
 * 版本号一变整个 Navigation 材质宿主（含标题栏 builder）重建，新染色的材质替换旧实例
 * （不重启 App、不重进页面）。
 * 注意：宿主重建会连带重建标题栏内由 `content` 生成的节点——胶囊内容都是图标/文字/头像（无状态），
 * 视觉无副作用；若将来在胶囊里放输入框，主题切换瞬间会失焦（输入的文本仍由父组件状态保存）。
 *
 * 对外参数与旧版完全一致，页面无需改动：
 *   GlassCapsule({ capsuleHeight: 40, capsuleRadius: 20, kind: 'composer' }) { ...内容... }
 */
@Component
export struct GlassCapsule {
  capsuleHeight: number = 40;
  capsuleRadius: number = 20;
  kind: MaterialKind = 'composer';

  @BuilderParam content: () => void;

  @StorageLink('themeMode') @Watch('onThemeChanged') themeMode: string = 'system';
  @StorageLink('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;

  /** 系统沉浸材质是否可用（创建/主题切换时重新检测；系统能力一般不会变，但回退分支要跟主题走） */
  @State private materialReady: boolean = false;
  /**
   * 材质版本号：`materialColor` 在创建材质时固化，切换深浅色后必须换新实例才会变暗/变亮。
   * 它参与 build（外层 ForEach 的 key）：版本号一变材质宿主整块重建，
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
    this.materialReady = Material.usable();
    if (this.materialReady) {
      const modifier: CommonModifier = new CommonModifier();
      modifier.borderRadius(this.capsuleRadius).clip(true).backgroundColor(Color.Transparent);
      modifier.systemMaterial(Material.create(this.kind));
      this.materialModifier = modifier;
    } else {
      this.materialModifier = new CommonModifier();
    }
  }

  /**
   * Navigation 标题栏里的三层：材质层 / 染色层 / 内容层。
   * 三层都做成「宽 100% × 胶囊高」，由最外层 Navigation 的 borderRadius + clip 统一裁成胶囊，
   * 避免各层自己裁圆角时在边缘切出硬边或半像素描边。
   *
   * 用 @LocalBuilder 而不是 @Builder：Navigation 的 `title({ builder })`（NavigationCustomTitle）会把
   * builder 放到 Navigation 内部作用域执行，普通 @Builder 在此场景下 `this`/状态归属可能丢失；
   * @LocalBuilder 保证 `this` 始终指向本组件，标题栏内的材质 / 主题染色才会跟随组件重建正确刷新。
   */
  @LocalBuilder
  glassContent() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.materialReady) {
        // 层 1：材质层。component 级 systemMaterial 挂在 Row 上，在标题栏这条系统栏作用域内由系统合成玻璃
        Row()
          .width('100%')
          .height(this.capsuleHeight)
          .borderRadius(this.capsuleRadius)
          .attributeModifier(this.materialModifier)
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no-hide-descendants');
        // 层 2：染色层。与悬浮底栏同源：高算力设备材质已经足够通透，不额外染色；中/低算力设备材质
        // 退化为「底色 + 描边」，用一层薄染色维持胶囊的可见度与文字对比。
        Row()
          .width('100%')
          .height(this.capsuleHeight)
          .borderRadius(this.capsuleRadius)
          .backgroundColor(Material.capsuleTint())
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no-hide-descendants');
      } else {
        // 降级层：chipTint + ULTRA_THIN 背景模糊 + 1vp 半透明描边
        Row()
          .width('100%')
          .height(this.capsuleHeight)
          .borderRadius(this.capsuleRadius)
          .backgroundColor(Theme.colors().chipTint)
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .hitTestBehavior(HitTestMode.None)
          .accessibilityLevel('no-hide-descendants');
      }
      // 层 3：内容层（图标 / 文字 / 头像），永远在材质与染色之上，且可点、可聚焦
      Row() {
        this.content();
      }
      .width('100%')
      .height(this.capsuleHeight)
      .borderRadius(this.capsuleRadius)
      .clip(true);
    }
    .width('100%')
    .height(this.capsuleHeight)
    .borderRadius(this.capsuleRadius);
  }

  /** 材质宿主：一个没有内容的 Navigation，只用来在标题栏这条系统栏作用域里合成材质 */
  @Builder
  navigationHost() {
    Navigation() {
    }
    .width('100%')
    .height(this.capsuleHeight)
    .backgroundColor(Color.Transparent)
    .borderRadius(this.capsuleRadius)
    .clip(true)
    .mode(NavigationMode.Stack)
    .hideBackButton(true)
    .hideToolBar(true)
    .title({ builder: this.glassContent, height: this.capsuleHeight }, {
      barStyle: BarStyle.STACK,
      backgroundColor: Color.Transparent,
      backgroundBlurStyle: BlurStyle.NONE,
      systemMaterial: Material.empty()
    })
    .hideTitleBar(false)
    .ignoreLayoutSafeArea([], []);
  }

  build() {
    // 外层 ForEach 以材质版本号作 key：深浅色切换时版本号变化 → 整个 Navigation 材质宿主重建，
    // 标题栏 builder 重新执行，按新主题染色创建的材质实例才会替换掉旧实例（不会重启 App / 重进页面）。
    // 包一层 Stack 只是给 ForEach 提供容器：尺寸与原来的 Navigation 完全一致（宽 100% × 胶囊高），
    // 页面在 GlassCapsule 上链式设置的通用属性依旧作用在自定义组件外层的隐藏容器上，布局不变。
    Stack() {
      ForEach([this.materialRevision], (revision: number) => {
        this.navigationHost();
      }, (revision: number) => revision.toString());
    }
    .width('100%')
    .height(this.capsuleHeight);
  }
}
