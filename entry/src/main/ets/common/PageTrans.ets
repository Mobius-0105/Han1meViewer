/**
 * 页面转场动画注册表 + NavDestination 自定义转场协议构造。
 *
 * 观感（对齐 PuraPily）：每个 push 页面都是一块**不透明画布**（PageFade 根容器铺
 * Theme.colors().background），转场做系统式「推拉」，曲线统一 Curve.FastOutSlowIn；
 * 按窗口方向分两套参数（横屏转场优化）：
 *  - 竖屏（窗口宽 <= 高）：全宽推拉，320ms —— PUSH：新页 translateX 100% → 0，
 *    被压住的旧页 0 → -22%（scale 1 → 0.98）；POP 反向：退出页 0 → 100%，
 *    露出的下层页 -22% / 0.98 → 0 / 1；四个角色 opacity 恒为 1（实心画布，不淡变）；
 *  - 横屏（窗口宽 > 高）：位移收小 + 淡变，270ms —— PUSH：新页 translateX 40% → 0、
 *    opacity 0.92 → 1，旧页 0 → -12%（scale 1 → 0.99，不淡出）；POP 反向：
 *    退出页 0 → 40% / opacity 1 → 0（淡出到全透明，见 LANDSCAPE_EXIT_ALPHA 说明），
 *    露出页 -12% / 0.99 → 0 / 1。横屏窗口很宽，整页从屏外横滑进来观感笨重，
 *    缩到 40% + 淡变更轻快，两页仍有足够重叠，转场中途不会露出 Index 灰底。
 *
 * 为什么竖屏不能淡变：
 *  - NavDestination / PageFade 以前都是透明底，页面本体浮在 Index 的 pageBackground 灰底上；
 *    两页叠加时任何 alpha < 1 都会让「下层页面 + 灰底」透出来，观感就是背景透明、上一页残留；
 *  - 给 PageFade 加不透明背景后如果在竖屏再叠 alpha 动画，两块实心画布会互相透出，等于又把
 *    背景变回半透明，所以竖屏在协议层保持 opacity 恒为 1：只摆位移 / 缩放；
 *  - 横屏的淡变只作用在「进入页盖在旧页上 / 退出页盖在露出页上」的瞬间：进入页 40% 起点时与
 *    旧页仍有 47%+ 的重叠区（旧页右缘 ≈ 87.5%），轻微透明透出的是已经铺满屏的旧页，不会透出灰底。
 *
 * 为什么横屏可以淡变：
 *  - 横屏两页始终大幅重叠：进入页从 40% 起滑入、被压住的旧页只左移 12%（右缘 ≈ 87.5%），
 *    重叠区铺满整个窗口，alpha < 1 透出的是已经铺满屏的旧页 / 露出页，不会透出 Index 灰底；
 *  - 退出页淡到 0 再被系统移除（而不是停在 0.92），避免横屏 POP 结束时窗口右侧仍被盖着造成硬切。
 *
 * 四角色分别由谁驱动（避免双动画的唯一分工）：
 *  - PUSH 进入页：delegate 只返回「原地不动」占位，压掉系统默认整页横滑；进入由
 *    PageFade.onAppear 自己 animateTo（首帧即进入起点，不会先完整闪现）；
 *  - PUSH 旧页：本页 delegate 摆起点（归位）→ transition.event 摆终点（竖屏 -22% / 0.98、
 *    横屏 -12% / 0.99），由系统按 duration/curve 生成动画；
 *  - POP 退出页：delegate 摆起点（归位）→ event 摆终点（竖屏 100% / 1、横屏 40% / alpha 0），系统驱动；
 *  - POP 露出页：delegate 摆起点（被压住状态）→ event 摆终点（归位 / alpha 1），系统驱动。
 *  每个 transition 的 onTransitionEnd 都补写一次终点状态：框架随后才会隐藏 / 移除该
 *  destination，此时旧页已被新页完全遮住、退出页已淡出/滑出屏幕，收尾时不会出现硬切。
 *
 * 几何校验（位移 / 缩放都用相对页面自身宽度的百分比，单栏下即屏宽；t ∈ [0, 1]）：
 *  - PUSH（竖屏）：新页左缘 = 100% - 100%·t（从 100% 移到 0），旧页右缘 = 100% - 23%·t
 *    （从 100% 移到 77%），任一时刻旧页右缘都在新页左缘右侧；旧页左缘 = -21%·t ≤ 0。
 *    即旧页始终把新页左侧未覆盖的区域填满，两页之间不会露出 Index 灰底；
 *  - POP（竖屏）：退出页左缘 = 100%·t（从 0 移到 100%），露出页右缘 = 77% + 23%·t，任一
 *    时刻都在退出页左缘右侧；露出页左缘 = -21%·(1 - t) ≤ 0。即退出页右滑让出的左侧区域
 *    始终由露出页填满，同样不会露出背景灰底；
 *  - PUSH（横屏）：新页左缘 = 40%·(1 - t)（从 40% 移到 0），旧页右缘 = 87.5% - 12.5%·t
 *    （scale 0.99 单边让出 0.5% + 左移 12%，从 87.5% 移到 75%），任一时刻旧页右缘都在
 *    新页左缘右侧；旧页左缘 ≈ -12.5% ≤ 0。两页重叠区始终铺满屏幕；
 *  - POP（横屏）：退出页左缘 = 40%·t，露出页从 -12% / 0.99 长回 0 / 1；退出页右滑让出的
 *    左侧区域由露出页填满，同样不会露出背景灰底。
 *
 * 兜底（delegate 拿不到实例时不能让页面停在半路的偏移状态）：
 *  - PUSH 进入页在 PageFade.onAppear 里调用 pushOutBelow(自己)：遍历注册表，把所有「可见但
 *    没有被 delegate 接管（covered = false）」的实例用 app 侧 animateTo 推到 -22% / 0.98。
 *    旧页 delegate 接管时会把它标成 covered = true，这里会跳过，所以正常路径下是幂等 no-op，
 *    不会双动画；
 *  - POP 退出页 delegate 调用 restoreBelowAfterPop(退出页)：下一轮事件循环（此时露出页的
 *    delegate 已同步执行完）检查退出页下面那一页 —— 如果它仍然是 covered（露出页 delegate
 *    因实例缺失没接管），就用 app 侧 animateTo 把它从 -22% / 0.98 归位到 0 / 1，避免返回后
 *    页面停在偏移状态；正常路径下露出页已被 beginPopIn 标成 covered = false，这里是 no-op。
 *
 * 时序依据（API 26 ace_engine NavigationGroupNode::TransitionWithPush / TransitionWithPop）：
 *  - 一次导航的 delegate 调用顺序是先 pre（退出 / 被压住页）后 cur（进入 / 露出页）；
 *  - 两页都返回自定义转场时框架直接 return，把收尾（隐藏 / 移除）交给各自的 onTransitionEnd；
 *  - 只有一页返回自定义转场时框架会自己收尾，并用系统默认动画处理另一页 —— 所以四角色都尽量
 *    返回本文件的 transition，且取不到实例时返回 stillTransition 占位（而不是 undefined），
 *    以免系统默认整页动画和 PageFade 自身状态打架。
 *
 * 同一路由多实例（视频 → 推荐 → 视频）：
 *  - 注册表按创建顺序保存全部实例，并记录各自 NavPathInfo.param 的对象引用；
 *    delegate 闭包里持有「本 destination」的 param，可精确命中自己那一层的 PageFade；
 *  - 兜底再按 covered 状态 + 注册顺序（LIFO，栈内顺序）定位：PUSH 旧页 = 最近一个可见实例，
 *    POP 露出页 = 最近一个被压住实例。
 *
 * 动画状态（位移 / 缩放 / 透明度）只存在各 PageFade 实例里，因此只会动参与本次转场的两层页面；
 * 是否横屏只在「调用转场 / 开始动画」的瞬间从 AppStorage['windowIsLandscape']
 * （Index 根容器 onAreaChange 维护）读一次，不在 AppStorage 里保存任何动画状态。
 * 根 Tab 页不在 PageFade 里，注册表里也没有它们，不会被本文件的任何逻辑碰到。
 */

/** 单个页面实例的动画回调（PageFade 注册；闭包捕获该组件实例，只改它自己的视觉状态） */
export interface PageAnimTarget {
  /**
   * 立即把内容层摆到指定视觉状态（不启动动画）：
   *  - delegate 里用来摆起点，下一次系统动画从该状态开始；
   *  - transition.event / onTransitionEnd 里用来摆终点，由系统按 duration/curve 生成过渡。
   * 竖屏下 alpha 恒为 1（不透明页面推拉）；横屏进入页 0.92 → 1、退出页 1 → 0（淡出到全透明），
   * 露出 / 被压住的页面 alpha 保持 1，避免整屏发灰。
   */
  setTransform: (transX: string, scale: number, alpha: number) => void;
  /**
   * 由本进程直接播一段转场动画（不经过系统转场；时长随窗口方向取 320ms / 270ms）：
   * 只在「delegate 拿不到页面实例」的兜底路径里用（pushOutBelow / restoreBelowAfterPop），
   * 正常路径下 delegate 已接管该实例，不会走到这里，因此不会和系统动画双驱动。
   */
  animateTransform: (transX: string, scale: number, alpha: number) => void;
}

/** 注册表条目：一个已构建的 PageFade 实例（所属路由、NavPathInfo.param 引用、是否被压住） */
class PageEntry {
  routeName: string;
  pageKey: object | undefined;
  target: PageAnimTarget;
  /** 是否已被上层页压住 / 已退场（true = 不可见；delegate 接管或兜底推出都会置 true） */
  covered: boolean = false;

  constructor(routeName: string, pageKey: object | undefined, target: PageAnimTarget) {
    this.routeName = routeName;
    this.pageKey = pageKey;
    this.target = target;
  }
}

export class PageTrans {
  /** 竖屏转场时长：320ms，与 PuraPily 的页面转场时长对齐 */
  static readonly DURATION: number = 320;
  /** 横屏转场时长：270ms（位移更小 + 轻微淡变，短一点更轻快） */
  static readonly LANDSCAPE_DURATION: number = 270;
  /** 转场曲线：系统常规页面转场曲线 */
  static readonly CURVE: Curve = Curve.FastOutSlowIn;

  /** 归位状态（可见页的最终状态：不位移、不缩放、不透明） */
  static readonly REST_SCALE: number = 1;
  static readonly REST_X: string = '0%';
  static readonly REST_ALPHA: number = 1;

  /** 竖屏：新页进入起点 / 退出页终点 = 右侧一屏宽（完全在屏幕外） */
  static readonly OFFSCREEN_X: string = '100%';
  /** 竖屏：被压住的下层页左移幅度：屏宽 22% */
  static readonly UNDER_X: string = '-22%';
  /**
   * 竖屏：被压住的下层页缩放 0.98（轻微缩小形成纵深）。
   * 22% 的位移大于 0.98 缩放单边让出的 1%：终态时下层页左缘在 -21%（已滑出屏幕左侧），
   * 右缘在 77%，而被压在它上面的新页铺满 0~100%，所以下层页不会在屏幕边缘露出背景灰底。
   */
  static readonly UNDER_SCALE: number = 0.98;

  /**
   * 横屏：进入 / 退出页的位移（相对页面自身宽度 = 窗口宽）。
   * 不再从 100% 屏外整块滑入，只推 40% + 淡变；旧页 / 露出页只退 -12% / 缩放 0.99，
   * 两页重叠区始终铺满窗口（见文件头几何校验）。
   */
  static readonly LANDSCAPE_ENTER_X: string = '40%';
  static readonly LANDSCAPE_EXIT_X: string = '40%';
  static readonly LANDSCAPE_UNDER_X: string = '-12%';
  static readonly LANDSCAPE_UNDER_SCALE: number = 0.99;
  /** 横屏进入页的淡变起点：0.92 → 1（被压住 / 露出的页面 alpha 恒为 1） */
  static readonly LANDSCAPE_ENTER_ALPHA: number = 0.92;
  /**
   * 横屏退出页的淡变终点：1 → 0（淡到全透明）。
   * 不取 0.92：横屏 POP 结束时退出页只右推 40%，窗口右侧 60% 仍被它盖着，
   * 若此时 alpha 还是 0.92，系统在转场结束后移除退出页会出现「右侧 60% 硬切」；
   * 淡到 0 后移除不可见，观感才是真正的「小位移 + 淡出」。
   */
  static readonly LANDSCAPE_EXIT_ALPHA: number = 0;

  /** 已注册的 PageFade 实例（创建顺序 = 路由栈内顺序，末尾为最近创建的实例） */
  private static entries: PageEntry[] = [];

  /**
   * 当前 Navigation 的路由栈（Index.aboutToAppear 里绑定）。
   * 只用于返回键拦截时判断「哪个页面才是真正的栈顶」，不参与动画。
   */
  private static stack: NavPathStack | undefined = undefined;

  static bindStack(stack: NavPathStack): void {
    PageTrans.stack = stack;
  }

  // ---------------------------------------------------------------------------
  // 窗口方向（决定用竖屏全宽推拉还是横屏小位移 + 淡变）
  // ---------------------------------------------------------------------------

  /**
   * 当前窗口是否横屏（宽 > 高）。
   * 由 Index 根容器的 onAreaChange 写入 AppStorage['windowIsLandscape']；取不到时按竖屏处理，
   * 保证普通竖屏设备 / 首帧还没测量到窗口时仍是原来的全宽推拉行为。
   */
  static isLandscape(): boolean {
    return AppStorage.get<boolean>('windowIsLandscape') === true;
  }

  /** 当前窗口方向对应的转场时长（竖屏 320ms / 横屏 270ms） */
  static duration(): number {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_DURATION : PageTrans.DURATION;
  }

  /** PUSH 进入页起点：竖屏屏外 100%，横屏只从 40% 处推入（配合淡变） */
  static enterStartX(): string {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_ENTER_X : PageTrans.OFFSCREEN_X;
  }

  /** PUSH 进入页起点透明度：竖屏恒 1（不透明画布），横屏 0.92 → 1 轻微淡入 */
  static enterStartAlpha(): number {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_ENTER_ALPHA : PageTrans.REST_ALPHA;
  }

  /** 被压住 / 露出的下层页左移幅度：竖屏 -22%，横屏只退 -12% */
  private static underX(): string {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_UNDER_X : PageTrans.UNDER_X;
  }

  /** 被压住 / 露出的下层页缩放：竖屏 0.98，横屏 0.99 */
  private static underScale(): number {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_UNDER_SCALE : PageTrans.UNDER_SCALE;
  }

  /** POP 退出页终点：竖屏滑到屏外 100%，横屏只右推 40% 并淡出到全透明 */
  private static exitEndX(): string {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_EXIT_X : PageTrans.OFFSCREEN_X;
  }

  /** POP 退出页终点透明度：竖屏恒 1，横屏 1 → 0（淡出，系统移除时无硬切） */
  private static exitEndAlpha(): number {
    return PageTrans.isLandscape() ? PageTrans.LANDSCAPE_EXIT_ALPHA : PageTrans.REST_ALPHA;
  }

  /**
   * 该路由是否当前位于栈顶。
   * 系统返回键的回调是挂在每个 NavDestination 上的，取不到栈时保守返回 true（交给调用方继续判断），
   * 取到栈时严格比对栈顶页名，避免下层页面（如视频页）误消费上层页面（如网页页）的返回。
   */
  static isTopRoute(routeName: string): boolean {
    const stack: NavPathStack | undefined = PageTrans.stack;
    if (stack === undefined) {
      return true;
    }
    const names: Array<string> = stack.getAllPathName();
    if (names.length === 0) {
      return false;
    }
    return names[names.length - 1] === routeName;
  }

  /** PageFade 构建完成后注册（记录 param 引用，delegate 据此精确找实例） */
  static register(routeName: string, pageKey: object | undefined, target: PageAnimTarget): void {
    if (routeName.length === 0) {
      return;
    }
    PageTrans.entries.push(new PageEntry(routeName, pageKey, target));
  }

  /** PageFade 销毁时注销（按回调对象引用精确移除，避免误删同路由的其它实例） */
  static unregister(target: PageAnimTarget): void {
    const next: PageEntry[] = [];
    for (let i = 0; i < PageTrans.entries.length; i++) {
      const entry: PageEntry = PageTrans.entries[i];
      if (entry.target !== target) {
        next.push(entry);
      }
    }
    PageTrans.entries = next;
  }

  /**
   * 取「可见页」的动画目标：PUSH 的旧页（即将被压住）、POP 的退出页（正在退出）。
   * 先按 param 引用精确命中本 destination 的实例；命中不到时退回最近一个可见的同路由实例。
   */
  static findVisible(routeName: string, pageKey: object | undefined): PageAnimTarget | undefined {
    const exact: PageEntry | undefined = PageTrans.exact(pageKey);
    if (exact !== undefined) {
      return exact.target;
    }
    const entry: PageEntry | undefined = PageTrans.latest(routeName, false);
    if (entry !== undefined) {
      return entry.target;
    }
    return undefined;
  }

  /**
   * 取「被压住的下层页」的动画目标：POP 时露出来的那一页。
   * 先按 param 引用精确命中；命中不到时取最近一个 covered = true 的同路由实例
   * （视频 → 视频 这种同路由连压多层时，最近压下去的就是要露出的那一层）。
   */
  static findCovered(routeName: string, pageKey: object | undefined): PageAnimTarget | undefined {
    const exact: PageEntry | undefined = PageTrans.exact(pageKey);
    if (exact !== undefined) {
      return exact.target;
    }
    const entry: PageEntry | undefined = PageTrans.latest(routeName, true);
    if (entry !== undefined) {
      return entry.target;
    }
    return undefined;
  }

  /** 该实例是否已经被压住 / 已推出（兜底逻辑据此判断「是否已有驱动方」，避免双动画） */
  static isCovered(target: PageAnimTarget): boolean {
    const index: number = PageTrans.indexOf(target);
    if (index < 0) {
      return false;
    }
    return PageTrans.entries[index].covered;
  }

  /**
   * PUSH 旧页开始：先摆回归位状态（上一次转场被中断也不会从偏移状态起播），并标记被压住。
   * 返回 false 表示该实例已经被进入页 onAppear 的兜底 pushOutBelow 接管，调用方不要再返回
   * 系统转场（否则 app 侧 animateTo 和系统转场会同时驱动位移/缩放，出现双动画/跳变）。
   */
  static beginPushOut(target: PageAnimTarget): boolean {
    if (PageTrans.isCovered(target)) {
      return false;
    }
    target.setTransform(PageTrans.REST_X, PageTrans.REST_SCALE, PageTrans.REST_ALPHA);
    PageTrans.markCovered(target, true);
    return true;
  }

  /** PUSH 旧页的动画：竖屏左移 -22% + 缩到 0.98；横屏只退 -12% + 0.99（不淡出），被新页逐渐盖住 */
  static pushOutTransition(target: PageAnimTarget): NavDestinationTransition {
    return PageTrans.makeTransition(target, PageTrans.underX(), PageTrans.underScale(), PageTrans.REST_ALPHA);
  }

  /**
   * POP 露出页开始：先摆到「被压住」状态（竖屏 -22% / 0.98、横屏 -12% / 0.99）。
   * 此刻退出页还铺满全屏，这次瞬时归位不可见；从该状态收回 0 / 1 才和 PUSH 结束时连贯。
   */
  static beginPopIn(target: PageAnimTarget): void {
    target.setTransform(PageTrans.underX(), PageTrans.underScale(), PageTrans.REST_ALPHA);
    PageTrans.markCovered(target, false);
  }

  /** POP 露出页的动画：从被压住状态归位到 0 / 1（alpha 恒 1），由系统驱动推回 */
  static popInTransition(target: PageAnimTarget): NavDestinationTransition {
    return PageTrans.makeTransition(target, PageTrans.REST_X, PageTrans.REST_SCALE, PageTrans.REST_ALPHA);
  }

  /** POP 退出页开始：确认从归位状态开始右滑（避免从偏移状态直接滑出） */
  static beginPopOut(target: PageAnimTarget): void {
    target.setTransform(PageTrans.REST_X, PageTrans.REST_SCALE, PageTrans.REST_ALPHA);
  }

  /**
   * POP 退出页的动画：竖屏右滑到 translateX 100% 完全出屏（alpha 恒 1）；
   * 横屏只右推 40% 并淡到全透明（alpha 1 → 0），随后由系统移除该 destination，
   * 移除瞬间退出页已不可见，不会出现右侧 60% 硬切。
   */
  static popOutTransition(target: PageAnimTarget): NavDestinationTransition {
    return PageTrans.makeTransition(target, PageTrans.exitEndX(), PageTrans.REST_SCALE,
      PageTrans.exitEndAlpha());
  }

  /**
   * PUSH 兜底：把注册表里所有「可见但还没有被 delegate 接管」的实例推到被压住状态
   * （竖屏 -22% / 0.98、横屏 -12% / 0.99，alpha 恒 1）。
   *
   * 由进入页 PageFade.onAppear 调用（exclude = 进入页自己）。旧页 delegate 正常会先把它标成
   * covered = true 并返回系统转场，此时这里会跳过，不会双动画；只有 delegate 拿不到实例
   * （注册表里没有它 / 命中错页）时才由这里用 app 侧 animateTo 保证旧页也做推拉位移，
   * 别让旧页一直停在原地等系统转场结束时被直接隐藏。
   */
  static pushOutBelow(exclude: PageAnimTarget): void {
    for (let i = 0; i < PageTrans.entries.length; i++) {
      const entry: PageEntry = PageTrans.entries[i];
      if (entry.target === exclude) {
        continue;
      }
      if (entry.covered) {
        continue;
      }
      entry.covered = true;
      entry.target.animateTransform(PageTrans.underX(), PageTrans.underScale(), PageTrans.REST_ALPHA);
    }
  }

  /**
   * POP 兜底：延迟到下一轮事件循环再检查「退出页下面那一页」是否仍处于 covered。
   * delegate 调用顺序是 pre（退出页）→ cur（露出页），所以退出页 delegate 里同步调用本方法、
   * 下一轮事件循环执行时露出页的 delegate 一定已经跑完：
   *  - 露出页 delegate 正常接管 → beginPopIn 已把 covered 置 false，这里 no-op；
   *  - 露出页 delegate 因实例缺失没接管 → 这里把 -22% / 0.98 归位补上，避免返回后页面停在偏移状态。
   * 用 setTimeout(0) 而不是立刻执行，是为了避免和还没执行的露出页 delegate 抢同一个实例。
   */
  static restoreBelowAfterPop(exiting: PageAnimTarget): void {
    setTimeout((): void => {
      PageTrans.restoreBelow(exiting);
    }, 0);
  }

  /** 立即归位：若退出页下面那一页仍然是 covered（露出页没被 delegate 接管），把它从偏移状态收回归位 */
  static restoreBelow(exiting: PageAnimTarget): void {
    const index: number = PageTrans.indexOf(exiting);
    if (index <= 0) {
      return;
    }
    const below: PageEntry = PageTrans.entries[index - 1];
    if (!below.covered) {
      return;
    }
    below.covered = false;
    below.target.animateTransform(PageTrans.REST_X, PageTrans.REST_SCALE, PageTrans.REST_ALPHA);
  }

  /**
   * 「原地不动」的占位转场：压掉系统默认的整页横滑（进入动画由 PageFade 自己播时用）。
   * duration 与本次主转场取相同值，保证两边转场同时结束（避免不同步导致动画被提前收尾）。
   */
  static stillTransition(duration: number): NavDestinationTransition {
    const still: NavDestinationTransition = {
      duration: duration,
      delay: 0,
      curve: PageTrans.CURVE,
      event: (): void => {
        // 空实现：页面不做任何属性变化，因此不会产生动画
      }
    };
    return still;
  }

  /**
   * 构造一个由系统动画驱动的转场：event 里只把状态改到终点，
   * onTransitionEnd 再兜底写一次同样的终点状态（动画被中断时也不会停在半路）。
   * 时长取当前窗口方向对应值（竖屏 320ms / 横屏 270ms），与 PageFade 自播的进入动画一致。
   */
  private static makeTransition(target: PageAnimTarget, endTransX: string,
    endScale: number, endAlpha: number): NavDestinationTransition {
    const transition: NavDestinationTransition = {
      duration: PageTrans.duration(),
      delay: 0,
      curve: PageTrans.CURVE,
      event: (): void => {
        target.setTransform(endTransX, endScale, endAlpha);
      },
      onTransitionEnd: (): void => {
        // 系统在 onTransitionEnd 之后才隐藏/移除本页，所以这里先写终点状态，收尾时无可见硬切
        target.setTransform(endTransX, endScale, endAlpha);
      }
    };
    return transition;
  }

  /** 按 NavPathInfo.param 的对象引用精确找实例（param 未传或找不到时返回 undefined） */
  private static exact(pageKey: object | undefined): PageEntry | undefined {
    if (pageKey === undefined) {
      return undefined;
    }
    for (let i = PageTrans.entries.length - 1; i >= 0; i--) {
      const entry: PageEntry = PageTrans.entries[i];
      if (entry.pageKey === pageKey) {
        return entry;
      }
    }
    return undefined;
  }

  /** 取最近一个可见（covered = false）或被压住（covered = true）的同路由实例 */
  private static latest(routeName: string, covered: boolean): PageEntry | undefined {
    for (let i = PageTrans.entries.length - 1; i >= 0; i--) {
      const entry: PageEntry = PageTrans.entries[i];
      if (entry.routeName === routeName && entry.covered === covered) {
        return entry;
      }
    }
    return undefined;
  }

  /** 实例在注册表里的下标（找不到返回 -1）；注册顺序 ≈ 栈内顺序，用于定位「下面一页」 */
  private static indexOf(target: PageAnimTarget): number {
    for (let i = PageTrans.entries.length - 1; i >= 0; i--) {
      if (PageTrans.entries[i].target === target) {
        return i;
      }
    }
    return -1;
  }

  /** 更新实例的「被压住」标记（用于同路由多实例的兜底定位与双动画去重） */
  private static markCovered(target: PageAnimTarget, covered: boolean): void {
    const index: number = PageTrans.indexOf(target);
    if (index >= 0) {
      PageTrans.entries[index].covered = covered;
    }
  }
}
