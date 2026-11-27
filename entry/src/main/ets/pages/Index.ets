import { common } from '@kit.AbilityKit';
import { CommonModifier, window } from '@kit.ArkUI';
import { Theme } from '../common/Theme';
import { Glass } from '../common/Glass';
import { Material } from '../common/Material';
import {
  Router,
  RouteParam,
  ROUTE_VIDEO,
  ROUTE_PLAYER,
  ROUTE_SETTINGS,
  ROUTE_LOGIN,
  ROUTE_WEB,
  ROUTE_FAVORITES,
  ROUTE_HISTORY,
  ROUTE_ADVANCED_SEARCH,
  ROUTE_PLAYLISTS,
  ROUTE_PLAYLIST_DETAIL,
  ROUTE_USER_ACCOUNT,
  ROUTE_SEARCH_RESULT,
  ROUTE_SEARCH
} from '../common/Router';
import { Disclaimer } from '../common/Disclaimer';
import { PageTrans, PageAnimTarget } from '../common/PageTrans';
import { HomePage } from './home/HomePage';
import { SubscriptionPage } from './subscription/SubscriptionPage';
import { ContentLibraryPage } from './library/ContentLibraryPage';
import { ProfilePage } from './profile/ProfilePage';
import { SearchPage } from './search/SearchPage';
import { SearchResultPage } from './search/SearchResultPage';
import { AdvancedSearchPage } from './search/AdvancedSearchPage';
import { FavoritesPage } from './library/FavoritesPage';
import { HistoryPage } from './library/HistoryPage';
import { PlaylistsPage } from './library/PlaylistsPage';
import { PlaylistDetailPage } from './library/PlaylistDetailPage';
import { UserAccountPage } from './library/UserAccountPage';
import { VideoPage } from './video/VideoPage';
import { PlayerPage } from './player/PlayerPage';
import { SettingsPage } from './settings/SettingsPage';
import { LoginPage } from './login/LoginPage';
import { WebPage } from './web/WebPage';

/**
 * 悬浮底栏（恢复 v1.25.x~v1.26.0 的「系统沉浸材质悬浮 TabBar」方案）：
 *  - 材质可用且设置开启：底栏就是系统 Tabs 的 TabBar 本体，用
 *    `barModifier`（CommonModifier 挂 `uiMaterial.ImmersiveMaterial`）+ `barFloatingStyle`
 *    （三档宽度 / 边距 / 蒙层）把系统 TabBar 变成底部悬浮胶囊；页签内容仍是
 *    `TabContent().tabBar(BarItem(...))` 的图标 + 文字（图标 22、文字 11、选中 primary、选中缩放 1.08）。
 *    这是 v1.25.x~v1.26.0 的原始实现，真材质由系统合成并带光感交互。
 *  - 材质不可用 / 用户关闭材质：系统 TabBar 用 `barHeight(0)` 彻底隐藏，改由
 *    floatingBar() 自绘 v1.25 的手写毛玻璃（barTint + Glass.BAR_BLUR + 0.8 描边 + Glass.barShadow），
 *    几何：高 56、圆角 30、宽 86%/70%（max 300/420）、底边距导航条 4vp，4 个 Tab 均分。
 *  - 显隐：材质分支只动画系统栏高度 `barHeightValue`（56 ↔ 0，200ms Curve.Friction），
 *    柱体材质 / 圆角 / 宽度不变；回退分支由节点挂载 + TransitionEffect.asymmetric 播
 *    「下方 18vp 上滑 + 淡入 200ms / 反向下滑 + 淡出 180ms」。
 *  - 已知且接受的观感：系统悬浮样式 host 会在底栏区域铺一层浅色蒙层（maskColor 默认
 *    #CCF1F3F5），`maskColor: Color.Transparent` + `maskHeight: 0` 只是尽量收掉它；
 *    这是系统栏原观感，用户已确认接受，不再为它改回自绘柱体。
 */
/** 系统悬浮 TabBar 高度（vp）：二级页覆盖时动画到 0 */
const BAR_HEIGHT: number = 56;
/** 悬浮柱体圆角（v1.25 系统栏 barModifier 与回退毛玻璃一致） */
const BAR_RADIUS: number = 30;
/** 柱体底边距系统导航条的距离（系统悬浮栏为 navBarHeight + 4） */
const BAR_BOTTOM_GAP: number = 4;
/**
 * `barFloatingStyle.barWidth` 的三档宽度（vp）：由系统按设备断点自行选择 small / medium / large。
 * 竖屏 264/280/296、横屏 320/336/352（4 个 Tab 均分，避免文字挤压）。
 */
const BAR_WIDTH_PORTRAIT_SMALL: number = 264;
const BAR_WIDTH_PORTRAIT_MEDIUM: number = 280;
const BAR_WIDTH_PORTRAIT_LARGE: number = 296;
const BAR_WIDTH_LANDSCAPE_SMALL: number = 320;
const BAR_WIDTH_LANDSCAPE_MEDIUM: number = 336;
const BAR_WIDTH_LANDSCAPE_LARGE: number = 352;
const BAR_SHOW_MS: number = 200;
const BAR_HIDE_MS: number = 180;
const BAR_SHOW_CURVE: Curve = Curve.Friction;
const BAR_HIDE_CURVE: Curve = Curve.FastOutSlowIn;
/** 回退底栏出现 / 消失时的竖直位移（vp）：从下方 18 上滑进入，消失反向下滑 */
const BAR_SLIDE_OFFSET: number = 18;

/**
 * 页面内容过渡层：整页的水平位移 + 缩放（竖屏），横屏时位移收小 + 轻微淡变。
 * 对齐 PuraPily：不透明页面推拉，竖屏不做透明度淡变。
 *
 * 不透明背景（页面转场的关键）：根容器铺 Theme.colors().background，和 Index 的
 * pageBackground 是同一个灰底。这样每个 push 页面都是**实心画布**：转场时新页整块
 * 推入、把旧页逐步盖住，而不是「两张透明页交叉淡变、灰底从中间透出来」。
 * 播放器页 / 网页页等内部自带黑/白底的页面会把灰底完全盖住，观感不受影响。
 *
 * PUSH（进入）由 PageFade 自己播：组件首帧状态就是进入起点，onAppear 里 animateTo 到归位。
 * 起点 / 时长 / 曲线全部由 PageTrans 按窗口方向给出：
 *  - 竖屏：translateX 100% → 0，320ms，Curve.FastOutSlowIn，页面恒不透明；
 *  - 横屏：translateX 40% → 0、opacity 0.92 → 1，270ms（横屏宽屏整页从屏外横滑太笨重）。
 * 不能依赖 customTransition 的进入 delegate 来播进入动画：它在页面布局完成后才被调用，
 * 首帧可能已经渲染，会先完整闪现一帧。
 *
 * 同一帧的 onAppear 还要兜底把下层可见页一起推到被压住状态（PageTrans.pushOutBelow）：
 * 旧页的「左移 + 缩小」正常情况下由旧页自己的 delegate 驱动（系统转场），此时旧页已被标成
 * covered，这里会跳过；只有 delegate 拿不到旧页实例时才由这里接管，保证上一页也做推拉。
 *
 * POP（返回）两页都由各自 delegate 驱动：退出页右滑（竖屏到屏外 100% / 横屏 40% 并淡出到全透明），
 * 露出页从被压住状态（竖屏 -22% / 0.98、横屏 -12% / 0.99）收回归位，与 PUSH 结束时的状态连贯。
 *
 * 位移用百分比字符串（相对页面自身宽度，单栏下即屏宽），不需要 onAreaChange 量宽，
 * 也与官方 NavDestination.customTransition 示例的写法一致（delegate 里摆起点、
 * transition.event 里摆终点，由系统按 duration/curve 生成过渡）。
 * 竖屏页面透明度恒为 1；横屏只在「进入 / 退出页」上做淡变（进入 0.92 → 1、退出 1 → 0），
 * 被压住 / 露出的页面 alpha 恒为 1，避免整屏发灰或透出 Index 灰底。
 */
@Component
struct PageFade {
  /** 当前页面路由名：PageTrans 注册表的 key */
  routeName: string = '';
  /**
   * 本 NavDestination 的 NavPathInfo.param 对象引用（PageMap 原样传入）。
   * 同一路由多实例时（视频 → 推荐 → 视频），转场 delegate 用它精确找到「自己这一层」的
   * PageFade，而不是退回「同路由最后创建的实例」，避免动画打到错误的页面实例上。
   */
  pageKey: object | undefined = undefined;
  @BuilderParam content: () => void;
  /**
   * 主题状态：只为「主题切换时重建本组件、让根容器的不透明背景色跟上」而声明，值本身不参与
   * 布局（背景色在 build 里用 Theme.colors() 读取）。与各页面里的同名 @StorageLink 一致。
   */
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 内容层水平位移（百分比字符串，相对页面自身宽度）；首帧即进入起点，避免页面完整闪现一帧 */
  @State private transX: string = PageTrans.OFFSCREEN_X;
  /** 内容层缩放：被压住时 0.98 / 0.99，可见时 1 */
  @State private pageScale: number = PageTrans.REST_SCALE;
  /**
   * 内容层透明度：竖屏恒为 1（实心画布推拉，不淡变）；
   * 横屏进入页 0.92 → 1、退出页 1 → 0（PageTrans 给出的起点 / 终点），其余页面恒为 1。
   */
  @State private pageAlpha: number = PageTrans.REST_ALPHA;
  /** 注册到 PageTrans 的动画回调对象（保留引用，便于 aboutToDisappear 时精确注销） */
  private target: PageAnimTarget | undefined = undefined;
  /** 进入动画只播一次（页面被压到下层再露出时 onAppear 不会重复触发，这里再兜一层） */
  private enterPlayed: boolean = false;
  /** 下层兜底推出只做一次（正常路径下旧页已被自己的 delegate 接管，此时为幂等 no-op） */
  private pushOutBelowDone: boolean = false;

  aboutToAppear(): void {
    // 首帧前摆好进入起点：此时还没有布局，直接 animateTo 不会产生动画，等 onAppear 再播。
    // 起点按窗口方向取（竖屏屏外 100% / 横屏 40% + 0.92），横屏进入首帧就不会先闪一张满屏实页。
    this.transX = PageTrans.enterStartX();
    this.pageScale = PageTrans.REST_SCALE;
    this.pageAlpha = PageTrans.enterStartAlpha();
    const target: PageAnimTarget = {
      // 立即置位（不启动动画）：delegate 摆起点 / transition.event 摆终点时由系统生成过渡
      setTransform: (transX: string, scale: number, alpha: number): void => {
        this.transX = transX;
        this.pageScale = scale;
        this.pageAlpha = alpha;
      },
      // app 侧直接播转场动画：只在 delegate 拿不到下层实例时兜底使用（见 PageTrans.pushOutBelow）
      animateTransform: (transX: string, scale: number, alpha: number): void => {
        this.getUIContext().animateTo({
          duration: PageTrans.duration(),
          curve: PageTrans.CURVE
        }, (): void => {
          this.transX = transX;
          this.pageScale = scale;
          this.pageAlpha = alpha;
        });
      }
    };
    this.target = target;
    PageTrans.register(this.routeName, this.pageKey, target);
  }

  aboutToDisappear(): void {
    const target: PageAnimTarget | undefined = this.target;
    if (target !== undefined) {
      PageTrans.unregister(target);
      this.target = undefined;
    }
  }

  /** PUSH 进入动画：从 PageTrans 给出的进入起点滑入归位（首帧挂载后触发） */
  private playEnter(): void {
    if (this.enterPlayed) {
      return;
    }
    this.enterPlayed = true;
    animateTo({ duration: PageTrans.duration(), curve: PageTrans.CURVE }, (): void => {
      this.transX = PageTrans.REST_X;
      this.pageScale = PageTrans.REST_SCALE;
      this.pageAlpha = PageTrans.REST_ALPHA;
    });
  }

  /**
   * PUSH 兜底：把「下面的可见页」一起推到被压住状态（竖屏 -22% / 0.98、横屏 -12% / 0.99），排除自己。
   * 本页正常是刚被 push 的进入页，注册表里唯一还 visible 的下层实例就是上一页；
   * 上一页 delegate 若已接管会把它标记 covered，PageTrans.pushOutBelow 会跳过 —— 单驱动，无双动画。
   */
  private pushOutBelowOnEnter(): void {
    if (this.pushOutBelowDone) {
      return;
    }
    this.pushOutBelowDone = true;
    const target: PageAnimTarget | undefined = this.target;
    if (target !== undefined) {
      PageTrans.pushOutBelow(target);
    }
  }

  build() {
    Column() {
      this.content();
    }
    .width('100%')
    .height('100%')
    // 不透明页面背景（与 Index 的 pageBackground 同一灰底）：转场中本页是一块实心画布，
    // 推拉时完全盖住下层页面，不会透出灰底；播放器/网页等内部自带底色的页面会把它盖住。
    .backgroundColor(Theme.colors().background)
    // 透明度由 PageTrans 决定：竖屏恒 1（实心页面推拉）；横屏进入/退出页 0.92↔1 轻微淡变
    .opacity(this.pageAlpha)
    .translate({ x: this.transX })
    .scale({ x: this.pageScale, y: this.pageScale })
    .onAppear(() => {
      this.playEnter();
      this.pushOutBelowOnEnter();
    });
  }
}

/**
 * NavDestination 自定义转场代理（API 15+ customTransition），按四个角色分别返回转场。
 * 具体位移 / 缩放 / 透明度 / 时长由 PageTrans 按窗口方向决定（竖屏全宽推拉、横屏小位移 + 淡变）：
 *  - PUSH + isEnter：新页进入。返回「原地不动」占位压掉系统整页横滑，进入由
 *    PageFade.onAppear 自播（首帧已在进入起点，不会闪）；同帧 onAppear 还会兜底推出下层旧页。
 *  - PUSH + !isEnter：旧页被压住。竖屏左移 -22% + scale 0.98、横屏 -12% + 0.99（保持不透明，
 *    不淡出），交系统动画驱动；若实例已经被进入页 onAppear 的兜底接管（beginPushOut 返回 false），
 *    返回占位转场让 app 侧 animateTo 单独驱动，避免双动画。
 *  - POP + !isEnter：退出页。竖屏右滑到屏外（translateX 100%）、横屏右推 40% 并淡出到全透明，
 *    交系统动画驱动；同时安排一次 restoreBelowAfterPop 兜底（露出页 delegate 没接管时归位）。
 *  - POP + isEnter：露出的下层页。从被压住状态（竖屏 -22% / 0.98、横屏 -12% / 0.99）收回归位，
 *    交系统动画驱动推回。
 * 只有实例确实取不到时才返回 undefined 退化系统默认转场（不能把页面卡在偏移状态）。
 */
function pageTransitionDelegate(routeName: string, pageKey: object | undefined,
  operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined {
  if (operation === NavigationOperation.PUSH) {
    if (isEnter) {
      // 进入页实例此刻可能还没注册，动画交给 PageFade 自己播；这里只压掉系统默认横滑，
      // 避免「系统滑动 + 内容滑入」叠加成双重位移。
      return [PageTrans.stillTransition(PageTrans.duration())];
    }
    const oldPage: PageAnimTarget | undefined = PageTrans.findVisible(routeName, pageKey);
    if (oldPage === undefined || !PageTrans.beginPushOut(oldPage)) {
      // 取不到旧页实例（或已被进入页 onAppear 的 pushOutBelow 接管）：用静止占位压掉系统默认
      // 整页横滑，旧页的推拉由 app 侧 animateTo 单独驱动（保证不双动画）
      return [PageTrans.stillTransition(PageTrans.duration())];
    }
    return [PageTrans.pushOutTransition(oldPage)];
  }
  if (operation === NavigationOperation.POP) {
    if (isEnter) {
      const revealed: PageAnimTarget | undefined = PageTrans.findCovered(routeName, pageKey);
      if (revealed === undefined) {
        return undefined;
      }
      // 起点摆到被压住状态：上一次 PUSH 结束时它就在这个状态；此刻退出页还铺满全屏，归位不可见
      PageTrans.beginPopIn(revealed);
      return [PageTrans.popInTransition(revealed)];
    }
    const exiting: PageAnimTarget | undefined = PageTrans.findVisible(routeName, pageKey);
    if (exiting === undefined) {
      return undefined;
    }
    PageTrans.beginPopOut(exiting);
    // 兜底：若露出页 delegate 因实例缺失没接管（下一轮事件循环时仍是 covered），
    // 由 app 侧把露出页从被压住状态归位；正常路径下露出页已 beginPopIn，这里是 no-op。
    PageTrans.restoreBelowAfterPop(exiting);
    return [PageTrans.popOutTransition(exiting)];
  }
  return undefined;
}

/**
 * 系统返回键 / 返回手势拦截：视频详情页处于页内全屏时先退出全屏，不 pop 页面。
 * 视频页监听 AppStorage['exitVideoFullscreen'] 自增（每按一次返回 +1），自行退出全屏；
 * 非全屏 / 非视频页返回 false，走正常 POP（过渡动画由上面的 customTransition 负责）。
 */
function consumeBackWhenVideoFullscreen(routeName: string): boolean {
  // 只拦真正的栈顶视频详情页：视频页处于全屏时上面不会再有别的页；若从视频页 push 了网页页，
  // 网页页的返回应正常 pop，而不是被下层视频页消费（不同 ROM 的返回回调分发链可能多层触发）。
  if (routeName !== ROUTE_VIDEO || !PageTrans.isTopRoute(routeName)) {
    return false;
  }
  const fullscreen: boolean | undefined = AppStorage.get<boolean>('videoFullscreen');
  if (fullscreen !== true) {
    return false;
  }
  // 自增信号：视频页 @StorageLink 监听 exitVideoFullscreen，自己退出全屏（不 pop 页面）
  const tick: number = AppStorage.get<number>('exitVideoFullscreen') ?? 0;
  AppStorage.setOrCreate<number>('exitVideoFullscreen', tick + 1);
  return true;
}

/**
 * 路由分发。Index.ets 的 Navigation 通过 navDestination 调用它，
 * 每个分支返回一个 NavDestination 包裹的页面组件（统一套 PageFade 内容过渡层）。
 */
@Builder
function PageMap(name: string, param: object) {
  NavDestination() {
    // pageKey 原样传 NavPathInfo.param：同一路由多实例时供转场 delegate 精确命中本层实例
    PageFade({ routeName: name, pageKey: param }) {
      if (name === ROUTE_VIDEO) {
        VideoPage({ p: param as RouteParam });
      } else if (name === ROUTE_PLAYER) {
        PlayerPage({ p: param as RouteParam });
      } else if (name === ROUTE_SETTINGS) {
        SettingsPage({ p: param as RouteParam });
      } else if (name === ROUTE_LOGIN) {
        LoginPage({ p: param as RouteParam });
      } else if (name === ROUTE_WEB) {
        WebPage({ p: param as RouteParam });
      } else if (name === ROUTE_FAVORITES) {
        FavoritesPage({ p: param as RouteParam });
      } else if (name === ROUTE_HISTORY) {
        HistoryPage({ p: param as RouteParam });
      } else if (name === ROUTE_ADVANCED_SEARCH) {
        AdvancedSearchPage({ p: param as RouteParam });
      } else if (name === ROUTE_PLAYLISTS) {
        PlaylistsPage({ p: param as RouteParam });
      } else if (name === ROUTE_PLAYLIST_DETAIL) {
        PlaylistDetailPage({ p: param as RouteParam });
      } else if (name === ROUTE_USER_ACCOUNT) {
        UserAccountPage({ p: param as RouteParam });
      } else if (name === ROUTE_SEARCH_RESULT) {
        SearchResultPage({ p: param as RouteParam });
      } else if (name === ROUTE_SEARCH) {
        SearchPage({ p: param as RouteParam });
      }
    }
  }
  .hideTitleBar(true)
  .backgroundColor(Color.Transparent)
  // 所有 push 页面统一走「不透明页面滑入/滑出推拉」的自定义页面转场（PUSH/POP × 进入/退出 四个角色）
  .customTransition((operation: NavigationOperation, isEnter: boolean): Array<NavDestinationTransition> | undefined => {
    return pageTransitionDelegate(name, param, operation, isEnter);
  })
  // 系统返回键/手势：视频页全屏时先退出全屏，不 pop 页面
  .onBackPressed((): boolean => {
    return consumeBackWhenVideoFullscreen(name);
  })
  // 二级页显示时隐藏根 Tab 的悬浮底栏（系统 Tabs 底栏会盖在 push 页面底部，形成遮挡卡片的长条）
  .onShown(() => {
    AppStorage.setOrCreate<boolean>('hasPushedPage', true);
  })
  .onHidden(() => {
    AppStorage.setOrCreate<boolean>('hasPushedPage', false);
  });
}

@Entry
@Component
struct Index {
  private pathStack: NavPathStack = new NavPathStack();
  private tabsController: TabsController = new TabsController();
  @State currentTab: number = 0;
  @State showDisclaimer: boolean = false;
  @StorageLink('themeMode') @Watch('onThemeChanged') themeMode: string = 'system';
  @StorageLink('systemDark') @Watch('onThemeChanged') systemDark: boolean = false;
  /**
   * 跨页面切 Tab 的信号：任意页面写 AppStorage['requestTab'] = 0/1/2/3，
   * 根组件监听到后切换 Tabs 并复位为 -1。0=首页 1=我的订阅 2=内容库 3=我的。
   */
  @StorageLink('requestTab') @Watch('onRequestTab') requestTab: number = -1;
  /** 设置项：是否启用系统沉浸材质底栏 */
  @StorageLink('useImmersiveMaterial') @Watch('onMaterialSettingChanged') useImmersiveMaterial: boolean = true;
  /** 系统栏高度（EntryAbility 写入）：底栏要抬到导航条上方 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  /** 是否有二级页覆盖在根 Tab 上（有则把系统悬浮底栏高度动画到 0；回退分支卸载自绘底栏） */
  @StorageLink('hasPushedPage') @Watch('onPushedPageChanged') hasPushedPage: boolean = false;
  /** 系统悬浮底栏当前高度（vp）：56 = 显示，0 = 隐藏；只在 hasPushedPage 变化时用 animateTo 改动 */
  @State barHeightValue: number = BAR_HEIGHT;
  /**
   * 底栏是否走系统沉浸材质（= 材质可用 + 应用级未禁用 + 用户开启）。
   * true → 系统 Tabs 的 TabBar 本体作为悬浮栏（barModifier + barFloatingStyle）；
   * false → 系统 TabBar 隐藏（barHeight 0），改由手写毛玻璃 floatingBar() 兜底。
   */
  @State useMaterialBar: boolean = false;
  /** 根窗口尺寸（onAreaChange 更新）：横屏时底栏加宽 / 保持居中，Tab 页内容保持全宽滚动 */
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  /** 系统悬浮栏的通用属性修改器：真材质时挂 uiMaterial，回退分支不参与渲染 */
  private barModifier: CommonModifier = new CommonModifier();

  aboutToAppear(): void {
    Router.setStack(this.pathStack);
    // 返回键拦截需要判断「哪个页面是真正的栈顶」（见 consumeBackWhenVideoFullscreen）
    PageTrans.bindStack(this.pathStack);
    this.showDisclaimer = !Disclaimer.isConfirmed();
    this.setupMaterialBar();
    // 首帧高度与当前是否有二级页一致（正常启动为显示，避免从 0 起跳的假动画）
    this.barHeightValue = this.hasPushedPage ? 0 : BAR_HEIGHT;
    this.updateSystemBarStyle();
    // 启动兜底：上一次全屏链路异常可能留下被隐藏的系统栏，非视频全屏时必须让状态栏 / 导航条回来
    this.ensureSystemBarsVisible();
  }

  /** 深浅色切换：同步系统栏配色；材质色在创建时固化，必须重建材质实例才能跟随主题 */
  onThemeChanged(): void {
    this.updateSystemBarStyle();
    this.setupMaterialBar();
  }

  /**
   * 底栏材质选型（v1.25 原实现）：
   *  - 材质可用且用户开启 → 给 barModifier 挂 `uiMaterial.ImmersiveMaterial`（tabBarMaterial），
   *    系统 TabBar 由系统合成沉浸玻璃 / 光感；每次重建实例（材质与挂载表面绑定，且染色在创建时固化）；
   *  - 否则（API < 26 / 系统不支持 / 应用级 DISABLE / 设置里关闭）→ 空 CommonModifier，
   *    系统 TabBar 被 barHeight(0) 隐藏，改走手写毛玻璃回退。
   */
  private setupMaterialBar(): void {
    const usable: boolean = this.useImmersiveMaterial && Material.usable();
    this.useMaterialBar = usable;
    if (usable) {
      const modifier: CommonModifier = new CommonModifier();
      modifier.borderRadius(BAR_RADIUS).clip(false).backgroundColor(Color.Transparent);
      modifier.systemMaterial(Material.tabBarMaterial());
      this.barModifier = modifier;
    } else {
      this.barModifier = new CommonModifier();
    }
  }

  onMaterialSettingChanged(): void {
    this.setupMaterialBar();
    // 切换材质分支会重建 Tabs：把高度立刻对齐当前显隐状态，避免重建瞬间闪出 / 闪没底栏
    this.barHeightValue = this.hasPushedPage ? 0 : BAR_HEIGHT;
  }

  /**
   * 二级页显示 / 返回：只动画系统悬浮栏的高度（56 ↔ 0），柱体材质 / 圆角 / 宽度都不变。
   * 用 animateTo 而不是直接赋值，让 barHeight 的收起 / 展开有 200ms Curve.Friction 过渡。
   */
  onPushedPageChanged(): void {
    animateTo({ duration: BAR_SHOW_MS, curve: BAR_SHOW_CURVE }, (): void => {
      this.barHeightValue = this.hasPushedPage ? 0 : BAR_HEIGHT;
    });
  }

  /**
   * 系统栏配色：状态栏 / 导航条背景透明（区域透出页面底色，避免底部出现一条白 / 纯色块），
   * 图标颜色跟随主题。视频页进入全屏时会自行隐藏系统栏，这里只负责「非全屏时」的常态。
   */
  private applySystemBarProps(win: window.Window): void {
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: Theme.isDark() ? '#FFFFFF' : '#000000',
        navigationBarContentColor: Theme.isDark() ? '#FFFFFF' : '#000000'
      }).catch(() => {
        // 忽略：部分设备 / 预览器不支持
      });
    } catch (e) {
      // 忽略
    }
  }

  private updateSystemBarStyle(): void {
    try {
      window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
        this.applySystemBarProps(win);
      }).catch(() => {
        // 忽略：部分设备/预览器不支持
      });
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 确保系统状态栏 / 导航条可见（横竖屏切换、退出全屏、从播放页返回后的兜底）：
   * 只有视频页页内全屏（AppStorage['videoFullscreen']）期间才允许隐藏系统栏；
   * 其余任何时刻都主动 setWindowSystemBarEnable(['status','navigation'])，
   * 避免全屏恢复链路异常时横屏下状态栏一直不显示。
   */
  private ensureSystemBarsVisible(): void {
    if (AppStorage.get<boolean>('videoFullscreen') === true) {
      return;
    }
    try {
      window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
        win.setWindowSystemBarEnable(['status', 'navigation']).then(() => {
          this.applySystemBarProps(win);
        }).catch(() => {
          // 部分设备 / 预览器不支持：忽略
        });
      }).catch(() => {
        // 拿不到窗口时忽略，不影响页面
      });
    } catch (e) {
      // 忽略
    }
  }

  onRequestTab(): void {
    if (this.requestTab >= 0 && this.requestTab <= 3) {
      this.switchTab(this.requestTab);
      AppStorage.setOrCreate('requestTab', -1);
    }
  }

  /** 是否横屏窗口（宽 > 高）：只影响悬浮底栏宽度上限，Tab 页内容本身保持全宽 / 各自响应式列数 */
  private isLandscape(): boolean {
    return this.viewportWidth > 0 && this.viewportHeight > 0 && this.viewportWidth > this.viewportHeight;
  }

  private switchTab(index: number): void {
    if (this.currentTab === index) {
      return;
    }
    this.currentTab = index;
    try {
      this.tabsController.changeIndex(index);
    } catch (e) {
      // Tabs 尚未构建完成时忽略
    }
  }

  /**
   * 页面底色（PuraPily 默认观感：不铺壁纸的灰底——浅色 #F1F2F4、深色 #101114）。
   * 页面根容器透明，内容以白色/深色卡片浮在灰底上。
   */
  @Builder
  pageBackground() {
    Row()
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.colors().background);
  }

  /**
   * 系统悬浮 TabBar 的页签内容（v1.25 原样式）：材质分支直接由系统 TabBar 渲染，
   * 图标 22×22、文字 11、选中项 primary + 图标放大 1.08。
   */
  @Builder
  BarItem(index: number, label: string, icon: Resource) {
    Column() {
      Image(icon)
        .width(22)
        .height(22)
        .fillColor(this.currentTab === index ? Theme.colors().primary : Theme.colors().textHint)
        .scale({ x: this.currentTab === index ? 1.08 : 1.0, y: this.currentTab === index ? 1.08 : 1.0 })
        .animation({ duration: 220, curve: Curve.Smooth });
      Text(label)
        .fontSize(11)
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTab === index ? Theme.colors().primary : Theme.colors().textHint)
        .margin({ top: 2 })
        .animation({ duration: 220, curve: Curve.EaseOut });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Color.Transparent);
  }

  /**
   * 四个 Tab 的内容 + 页签定义。材质分支由系统 TabBar 直接渲染这些页签（图标 22 / 文字 11）；
   * 回退分支把系统 TabBar 彻底隐藏（barHeight 0），页签外观交给下方 floatingBar()。
   * 每个 TabContent 仍显式铺透明背景：默认背景不能保证一定透明，页面内容未铺满的地方
   * 会露出一条纯色 / 白色底（「我的」页底部最明显），统一去掉。
   */
  @Builder
  tabPages() {
    TabContent() {
      HomePage();
    }
    .tabBar(this.BarItem(0, '首页', $r('app.media.ic_home')))
    .backgroundColor(Color.Transparent);

    TabContent() {
      SubscriptionPage();
    }
    .tabBar(this.BarItem(1, '我的订阅', $r('app.media.ic_subscription')))
    .backgroundColor(Color.Transparent);

    TabContent() {
      ContentLibraryPage();
    }
    .tabBar(this.BarItem(2, '内容库', $r('app.media.ic_library')))
    .backgroundColor(Color.Transparent);

    TabContent() {
      ProfilePage();
    }
    .tabBar(this.BarItem(3, '我的', $r('app.media.ic_person')))
    .backgroundColor(Color.Transparent);
  }

  /**
   * 手写毛玻璃回退底栏的单个页签（v1.25 原样）：4 个均分宽度，
   * 选中项 chipTint 胶囊底 + 图标放大 1.08 动画。
   */
  @Builder
  FloatBarItem(index: number, label: string, icon: Resource) {
    Column() {
      Image(icon)
        .width(24)
        .height(24)
        .fillColor(this.currentTab === index ? Theme.colors().primary : Theme.colors().textHint)
        .scale({ x: this.currentTab === index ? 1.08 : 1.0, y: this.currentTab === index ? 1.08 : 1.0 })
        .animation({ duration: 220, curve: Curve.Smooth });
      Text(label)
        .fontSize(10)
        .fontColor(this.currentTab === index ? Theme.colors().primary : Theme.colors().textHint)
        .maxLines(1)
        .margin({ top: 3 })
        .animation({ duration: 220, curve: Curve.EaseOut });
    }
    .layoutWeight(1)
    .height(44)
    .borderRadius(23)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.currentTab === index ? Theme.colors().chipTint : Color.Transparent)
    .onClick(() => {
      // 底栏隐藏动画期间（二级页已经 push 上来）不再接受点击，避免误切 Tab
      if (this.hasPushedPage) {
        return;
      }
      this.switchTab(index);
    });
  }

  /**
   * 手写毛玻璃悬浮底栏（材质不可用 / 用户关闭材质时的回退，v1.25 原样）：
   * 宽 86%（横屏 70%）max 300（横屏 420），高 56、圆角 30，底边距系统导航条 4vp；
   * barTint + Glass.BAR_BLUR + 0.8 描边 + Glass.barShadow 阴影，4 个页签均分。
   *
   * 显隐：hasPushedPage 变化时节点插入 / 移除，TransitionEffect.asymmetric 播
   * 「下方 18vp 上滑 + 淡入 200ms / 反向下滑 + 淡出 180ms」，动画结束节点才卸载。
   */
  @Builder
  floatingBar() {
    Row() {
      this.FloatBarItem(0, '首页', $r('app.media.ic_home'));
      this.FloatBarItem(1, '我的订阅', $r('app.media.ic_subscription'));
      this.FloatBarItem(2, '内容库', $r('app.media.ic_library'));
      this.FloatBarItem(3, '我的', $r('app.media.ic_person'));
    }
    .width(this.isLandscape() ? '70%' : '86%')
    .constraintSize({ maxWidth: this.isLandscape() ? 420 : 300 })
    .height(BAR_HEIGHT)
    .padding({ left: 7, right: 7 })
    .borderRadius(BAR_RADIUS)
    .backgroundColor(Theme.colors().barTint)
    .backgroundBlurStyle(Glass.BAR_BLUR)
    .border({ width: 0.8, color: Theme.colors().glassBorder })
    .shadow(Glass.barShadow(Theme.colors().glassShadow))
    // 底边距系统导航条 4vp（navBarHeight 由 EntryAbility 写入）
    .margin({ bottom: this.navBarHeight + BAR_BOTTOM_GAP })
    // 显隐过渡（不对称：出现 200ms / 消失 180ms）：
    // 出现 = 从下方 18vp 上滑 + 淡入；消失 = 反向下滑 + 淡出，动画结束节点才卸载。
    .transition(TransitionEffect.asymmetric(
      TransitionEffect.OPACITY
        .animation({ duration: BAR_SHOW_MS, curve: BAR_SHOW_CURVE })
        .combine(TransitionEffect.translate({ y: BAR_SLIDE_OFFSET })
          .animation({ duration: BAR_SHOW_MS, curve: BAR_SHOW_CURVE })),
      TransitionEffect.OPACITY
        .animation({ duration: BAR_HIDE_MS, curve: BAR_HIDE_CURVE })
        .combine(TransitionEffect.translate({ y: BAR_SLIDE_OFFSET })
          .animation({ duration: BAR_HIDE_MS, curve: BAR_HIDE_CURVE }))
    ));
  }

  @Builder
  DisclaimerDialog() {
    Column() {
      Column() {
        Text('🔞 内容提示')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .margin({ bottom: 12 });
        Text('本应用为 hanime1.me 的第三方客户端，仅用于技术研究与学习交流。\n\n' +
          '应用内可能包含仅限成年人浏览的内容（R18）。请确认您已年满 18 周岁，' +
          '并遵守您所在地区的法律法规，且同意自行承担使用本应用产生的一切后果。')
          .fontSize(14)
          .lineHeight(21)
          .fontColor(Theme.colors().textSecondary)
          .textAlign(TextAlign.Start);
        Text('本应用与 hanime1.me 无任何隶属或合作关系。')
          .fontSize(12)
          .fontColor(Theme.colors().textHint)
          .margin({ top: 10 });
        Row() {
          Button('退出')
            .layoutWeight(1)
            .height(42)
            .fontSize(15)
            .backgroundColor(Theme.colors().chipTint)
            .fontColor(Theme.colors().textPrimary)
            .borderRadius(21)
            .onClick(() => {
              const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
              ctx.terminateSelf();
            });
          Button('我已满 18 岁，继续')
            .layoutWeight(1)
            .height(42)
            .fontSize(15)
            .margin({ left: 10 })
            .backgroundColor(Theme.colors().primary)
            .fontColor(Theme.colors().onPrimary)
            .borderRadius(21)
            .onClick(() => {
              Disclaimer.confirm();
              this.showDisclaimer = false;
            });
        }
        .width('100%')
        .margin({ top: 22 });
      }
      .width('88%')
      .padding(20)
      .borderRadius(26)
      .backgroundColor(Theme.colors().glassStrongTint)
      .backgroundBlurStyle(Glass.BAR_BLUR)
      .border({ width: 0.8, color: Theme.colors().glassBorder })
      .shadow(Glass.barShadow(Theme.colors().glassShadow));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(Theme.colors().overlay)
    .backgroundBlurStyle(BlurStyle.COMPONENT_ULTRA_THIN);
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      this.pageBackground();

      Navigation(this.pathStack) {
        // 悬浮底栏放在 Navigation 内容层里：push 二级页面时会被 NavDestination 覆盖。
        Stack({ alignContent: Alignment.Bottom }) {
          if (this.useMaterialBar) {
            // 系统沉浸材质悬浮底栏（v1.25 原实现）：由系统 TabBar 本体承担。
            //  - barModifier：CommonModifier 挂 uiMaterial.ImmersiveMaterial，圆角 30、透明底、不裁剪，
            //    材质由系统合成（带光感），按钮内容仍是 tabPages() 里的 BarItem；
            //  - barFloatingStyle：三档宽度 + 左右边距 0 + 底边距 navBarHeight+4 + 蒙层收掉；
            //  - barOverlap(true)：内容延伸到栏后，形成悬浮观感；
            //  - 不设置 barBackgroundColor：它会被 barModifier 的同名属性覆盖，且可能盖住材质。
            //  - barHeight 用 barHeightValue：二级页覆盖时 animateTo 收到 0，返回时展开到 56。
            Tabs({
              barPosition: BarPosition.End,
              index: this.currentTab,
              controller: this.tabsController,
              barModifier: this.barModifier
            }) {
              this.tabPages();
            }
            .scrollable(false)
            .barHeight(this.barHeightValue)
            .animationDuration(220)
            .barOverlap(true)
            .backgroundColor(Color.Transparent)
            .barFloatingStyle({
              // 系统按设备断点自行选 small / medium / large；横屏整体加宽一档，仍由系统居中
              barWidth: {
                smallBarWidth: this.isLandscape() ? BAR_WIDTH_LANDSCAPE_SMALL : BAR_WIDTH_PORTRAIT_SMALL,
                mediumBarWidth: this.isLandscape() ? BAR_WIDTH_LANDSCAPE_MEDIUM : BAR_WIDTH_PORTRAIT_MEDIUM,
                largeBarWidth: this.isLandscape() ? BAR_WIDTH_LANDSCAPE_LARGE : BAR_WIDTH_PORTRAIT_LARGE
              },
              barSideMargin: 0,
              barBottomMargin: this.navBarHeight + BAR_BOTTOM_GAP,
              maskColor: Color.Transparent,
              maskHeight: 0
            })
            .onChange((index: number) => {
              this.currentTab = index;
            })
            .width('100%')
            .height('100%');
          } else {
            // 回退：系统 TabBar 彻底隐藏（barHeight 0），改用手写毛玻璃悬浮底栏，保证低版本设备上
            // 底栏一定可见；它的出现 / 消失由 floatingBar() 的 TransitionEffect 播放。
            Tabs({ barPosition: BarPosition.End, index: this.currentTab, controller: this.tabsController }) {
              this.tabPages();
            }
            .scrollable(false)
            .barHeight(0)
            .animationDuration(0)
            .backgroundColor(Color.Transparent)
            .onChange((index: number) => {
              this.currentTab = index;
            })
            .width('100%')
            .height('100%');

            if (!this.hasPushedPage) {
              this.floatingBar();
            }
          }
        }
        .width('100%')
        .height('100%');
      }
      .navDestination(PageMap)
      .hideTitleBar(true)
      .mode(NavigationMode.Stack)
      .backgroundColor(Color.Transparent)
      .width('100%')
      .height('100%');

      if (this.showDisclaimer) {
        this.DisclaimerDialog();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.colors().background)
    .onAreaChange((_old: Area, area: Area) => {
      // 记录窗口宽高：横屏时把悬浮底栏加宽一档（仍底部居中），Tab 页内容保持全宽 / 各自响应式
      const width: number = Number(area.width);
      const height: number = Number(area.height);
      if (isNaN(width) || isNaN(height) || !(width > 0) || !(height > 0)) {
        return;
      }
      if (Math.abs(width - this.viewportWidth) >= 0.5 || Math.abs(height - this.viewportHeight) >= 0.5) {
        const landscape: boolean = width > height;
        const orientationChanged: boolean = this.viewportWidth > 0 && this.viewportHeight > 0 &&
          landscape !== (this.viewportWidth > this.viewportHeight);
        this.viewportWidth = width;
        this.viewportHeight = height;
        // 窗口尺寸 / 方向同步到 AppStorage，供两处拿不到自己 viewport 时兜底：
        //  - PageTrans：页面转场在 delegate / onAppear 阶段按横竖屏选参数（竖屏全宽推拉、横屏小位移 + 淡变）；
        //  - VideoPage：横屏 push 进视频页时首帧就按横屏分栏布局，避免先竖屏再重排的跳动。
        AppStorage.setOrCreate<number>('windowWidth', width);
        AppStorage.setOrCreate<number>('windowHeight', height);
        AppStorage.setOrCreate<boolean>('windowIsLandscape', landscape);
        if (orientationChanged) {
          // 横竖屏切换兜底：非视频全屏时确保状态栏 / 导航条可见（横屏下系统状态栏消失的修复）
          this.ensureSystemBarsVisible();
        }
      }
    });
  }
}
