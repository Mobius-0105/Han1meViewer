import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppSettings, applyScreenOrientationLock } from '../logic/settings/AppSettings';
import { AppDb } from '../logic/db/AppDb';
import { AppState } from '../logic/state/AppState';
import { initNetwork } from '../logic/net/NetFacade';
import { HanimeApi } from '../logic/net/HanimeApi';
import { SiteFailover } from '../logic/net/SiteFailover';
import { Disclaimer } from '../common/Disclaimer';
import { Theme } from '../common/Theme';

const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  /** 启动初始化 Promise：页面加载会等它完成，避免首屏请求用到默认域名/空 cookie。 */
  private initPromise: Promise<void> = Promise.resolve();
  private mainWindow: window.Window | null = null;
  /** 上一次窗口是否横屏：只在横竖屏切换时兜底恢复系统栏，避免每次尺寸变化都重复设置 */
  private lastLandscape: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(0x0000, TAG, 'onCreate');
    // 年龄确认需要 context；同步注入，避免首屏 isConfirmed() 因 context 未就绪而误弹。
    Disclaimer.init(this.context);
    // 异步初始化；页面加载在 onWindowStageCreate 里等待它完成。
    this.initPromise = this.initApp();
  }

  private async initApp(): Promise<void> {
    const settings: AppSettings = AppSettings.getInstance();
    try {
      await settings.init(this.context);
    } catch (e) {
      hilog.error(0x0000, TAG, 'settings init failed');
    }
    try {
      await initNetwork(this.context);
    } catch (e) {
      hilog.error(0x0000, TAG, 'network init failed');
    }
    // 网络层参数必须在设置读取完成后应用，否则冷启动会退回默认站点 / UA。
    HanimeApi.getInstance().configure(settings.getBaseUrl(), settings.getUserAgent(), settings.getBackupCdn());
    // 站点加载失败自动切换备用站点：注册 HttpFailoverHook（必须在 configure 之后、首个请求之前）。
    SiteFailover.install();
    // 数据库初始化放在 finally 保障里：即使上面某步异常，也一定会执行（避免 AppDb.ready 永久 pending）。
    try {
      await AppDb.getInstance().init(this.context);
    } catch (e) {
      hilog.error(0x0000, TAG, 'db init failed');
    }
    try {
      AppState.init();
    } catch (e) {
      hilog.error(0x0000, TAG, 'app state init failed');
    }
    hilog.info(0x0000, TAG, 'app initialized, baseUrl=%{public}s', settings.getBaseUrl());
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    AppStorage.setOrCreate('systemDark',
      newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    if (this.mainWindow !== null) {
      this.updateInsets(this.mainWindow);
      // 深浅色 / 方向变化后兜底恢复系统栏与配色（非视频全屏时）
      this.syncSystemBarVisibility(this.mainWindow);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    AppStorage.setOrCreate('systemDark',
      this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    this.setupWindow(windowStage);
    // 等初始化完成后再加载页面；初始化异常也必须放行（catch 后备），避免白屏。
    this.initPromise.then(() => {
      this.loadIndex(windowStage);
    }).catch((err: Error) => {
      hilog.error(0x0000, TAG, 'initPromise failed: %{public}s', err.message);
      this.loadIndex(windowStage);
    });
  }

  /**
   * 开启沉浸式（内容延伸到状态栏/导航栏下方），并把系统栏高度写入 AppStorage，
   * 供页面头部做「玻璃模糊覆盖状态栏 + 内容下沉到安全区」。
   *
   * 同时把状态栏 / 导航条背景显式设为透明（否则浅色主题下窗口底部可能残留一条白 / 纯色导航条
   * 背景，「我的」页滚到底部时会挡住内容），并在窗口尺寸 / 方向变化时兜底恢复系统栏可见性。
   */
  private setupWindow(windowStage: window.WindowStage): void {
    try {
      const win: window.Window = windowStage.getMainWindowSync();
      this.mainWindow = win;
      win.setWindowLayoutFullScreen(true);
      this.updateInsets(win);
      // 启动即把系统栏背景设透明 + 图标颜色跟随主题；并确保状态栏 / 导航条可见
      this.syncSystemBarVisibility(win);
      try {
        const props: window.WindowProperties = win.getWindowProperties();
        this.lastLandscape = props.windowRect.width > props.windowRect.height;
      } catch (e) {
        this.lastLandscape = false;
      }
      // 窗口尺寸 / 方向变化（旋转 / 分屏）时：刷新 insets，并在横竖屏切换时恢复系统栏
      // （视频页全屏期间由 AppStorage['videoFullscreen'] 拦截，不会把全屏该隐藏的系统栏弹出来）
      try {
        win.on('windowSizeChange', (size: window.Size) => {
          if (this.mainWindow === null) {
            return;
          }
          this.updateInsets(this.mainWindow);
          const landscape: boolean = size.width > size.height;
          if (landscape !== this.lastLandscape) {
            this.lastLandscape = landscape;
            this.syncSystemBarVisibility(this.mainWindow);
          }
        });
      } catch (e) {
        hilog.warn(0x0000, TAG, 'windowSizeChange listener failed');
      }
      try {
        win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
          if (this.mainWindow !== null) {
            this.updateInsets(this.mainWindow);
          }
        });
      } catch (e) {
        hilog.warn(0x0000, TAG, 'avoidAreaChange listener failed');
      }
      // 键盘高度：评论输入框等贴在键盘上方的浮层用它做避让/保持底板可见
      try {
        win.on('keyboardHeightChange', (height: number) => {
          AppStorage.setOrCreate<number>('keyboardHeight', px2vp(height));
        });
        AppStorage.setOrCreate<number>('keyboardHeight', 0);
      } catch (e) {
        hilog.warn(0x0000, TAG, 'keyboardHeightChange listener failed');
      }
    } catch (e) {
      const error: Error = e as Error;
      hilog.error(0x0000, TAG, 'setupWindow failed: %{public}s', error.message);
    }
  }

  /**
   * 系统栏背景 / 图标配色：背景透明（状态栏、导航条区域透出页面底色，不出现整条白块），
   * 图标颜色跟随主题；视频页可见时保持白色（播放器上方是黑底），与 VideoPage 的约定一致。
   */
  private applySystemBarProperties(win: window.Window): void {
    const videoPages: number = AppStorage.get<number>('videoPageCount') ?? 0;
    const contentColor: string = videoPages > 0 ? '#FFFFFF' : (Theme.isDark() ? '#FFFFFF' : '#000000');
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        navigationBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarContentColor: contentColor
      }).catch(() => {
        // 忽略：部分设备 / 预览器不支持
      });
    } catch (e) {
      hilog.warn(0x0000, TAG, 'setWindowSystemBarProperties failed');
    }
    // 窗口自身底色跟随页面灰底：即使系统栏区域由系统绘制，也不会露出白 / 纯色底
    try {
      win.setWindowBackgroundColor(Theme.colors().background);
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 非视频全屏时主动恢复状态栏 / 导航条可见：
   * 视频页 enterFullscreen 会 setWindowSystemBarEnable([]) 隐藏系统栏；退出全屏 / 返回 / 旋转后
   * 若恢复链路异常（比如 aboutToDisappear 里拿不到窗口），这里在窗口尺寸变化 / 配置更新时兜底，
   * 保证横屏下系统状态栏一定显示。
   */
  private syncSystemBarVisibility(win: window.Window): void {
    const fullscreen: boolean = AppStorage.get<boolean>('videoFullscreen') === true;
    if (!fullscreen) {
      try {
        win.setWindowSystemBarEnable(['status', 'navigation']).catch(() => {
          // 忽略：部分设备 / 预览器不支持
        });
      } catch (e) {
        hilog.warn(0x0000, TAG, 'setWindowSystemBarEnable failed');
      }
    }
    this.applySystemBarProperties(win);
  }

  /**
   * 系统栏 / 内容安全区高度：状态栏取 TYPE_SYSTEM 顶部，导航条取
   * TYPE_NAVIGATION_INDICATOR 与 TYPE_SYSTEM 底部两者较大值。
   * 三键导航设备只有 TYPE_SYSTEM.bottomRect 有高度，旧实现只读 NAVIGATION_INDICATOR 会得到 0，
   * 导致页面底部预留不足 → 内容被系统导航条盖住（「我的」页底部白色块遮内容的根因之一）。
   */
  private updateInsets(win: window.Window): void {
    try {
      const systemArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const navArea: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const statusHeight: number = px2vp(systemArea.topRect.height);
      const systemBottom: number = px2vp(systemArea.bottomRect.height);
      const indicatorBottom: number = px2vp(navArea.bottomRect.height);
      const navHeight: number = Math.max(systemBottom, indicatorBottom);
      AppStorage.setOrCreate<number>('statusBarHeight', statusHeight > 0 ? statusHeight : 0);
      AppStorage.setOrCreate<number>('navBarHeight', navHeight > 0 ? navHeight : 0);
      hilog.info(0x0000, TAG, 'insets: status=%{public}f nav=%{public}f', statusHeight, navHeight);
    } catch (e) {
      hilog.warn(0x0000, TAG, 'updateInsets failed');
    }
  }

  private loadIndex(windowStage: window.WindowStage): void {
    // 设置已读完（调用方在 initPromise 完成后才走到这里）且主窗口已创建：
    // 启动时把「屏幕方向锁」应用一次，保证冷启动首屏方向就与设置一致。
    this.applyOrientationLock();
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(0x0000, TAG, 'loadContent failed: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(0x0000, TAG, 'loadContent succeeded');
    });
  }

  /**
   * 按 AppSettings.screenOrientationLock 应用主窗口方向（跟随系统 / 锁定竖屏 / 锁定横屏）。
   * 与 setupWindow 的沉浸式窗口初始化配合：方向只改窗口偏好，不动系统栏 / 布局。
   */
  private applyOrientationLock(): void {
    const win: window.Window | null = this.mainWindow;
    if (win === null) {
      hilog.warn(0x0000, TAG, 'main window not ready, skip orientation lock');
      return;
    }
    const lock: string = AppSettings.getInstance().getScreenOrientationLock();
    // applyScreenOrientationLock 内部已 try/catch，不会阻断启动流程
    applyScreenOrientationLock(win, lock).then(() => {
      hilog.info(0x0000, TAG, 'orientation lock applied: %{public}s', lock);
    }).catch(() => {
      hilog.warn(0x0000, TAG, 'orientation lock failed');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(0x0000, TAG, 'onWindowStageDestroy');
  }

  onDestroy(): void {
    hilog.info(0x0000, TAG, 'onDestroy');
  }
}
