/**
 * 设置页（PuraPily 风格分组卡片；分组：通用 / 外观 / 网络 / 播放 / 隐私 / 存储 / 关于）。
 *
 * 视觉规范（参考 docs/UI_STYLE.md，独立实现）：
 *  - 根容器透明（壁纸透出），顶部悬浮顶栏（MaterialSurface 渐变模糊底板 + 沉浸材质返回圆钮），
 *    内容在 Stack 里铺满整页、滚动时从顶栏下方经过；
 *  - 每个分组 = 13 号 textHint 组标题 + 一张卡片（圆角 24，与「我的」页大卡统一、
 *    cardBg 纯色、1vp glassBorder，无阴影、无模糊）；行与行之间 0.5 发丝线；
 *  - 行 NavRow / SwitchRow：行高 52、图标块 30×30 圆角 10（primaryContainer 底 + primary 图标）、
 *    标题 14 / 副标题 12 / 右侧值 12；分段用 SegmentRow 胶囊；危险操作文字用 error 色；
 *  - 交互动画：可点击行/按钮按下缩放 0.97，主题色块选中弹簧放大 1→1.12→1，
 *    页面内容进入淡入 + 上移（240ms Curve.Friction）；
 *
 * 逻辑约定（与本页重做前完全一致）：
 *  - 每个开关/选择立即持久化（AppSettings 内部 putSync + flush）；
 *  - 主题用 @StorageLink('themeMode') 驱动，主题色用 @StorageLink('themeColor') 驱动；
 *  - 播放内核用 @StorageLink('playerKernel') 驱动，切换写 AppSettings，视频页下次进入时读取；
 *  - 站点域名 / UA / 备用 CDN 修改后必须调用 NetworkConfigurator.apply()
 *    （内部 HanimeApi.configure），并提示“重新加载”才会用新配置请求；
 *  - 破坏性操作（清空历史 / 清空搜索历史 / 清空缓存）用 AlertDialog.show 二次确认。
 */

import { bundleManager, common, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { AppSettings, applyScreenOrientationLock } from '../../logic/settings/AppSettings';
import { AppDb } from '../../logic/db/AppDb';
import { LocalRepo } from '../../logic/db/LocalRepo';
import { describeError } from '../../logic/net/Errors';
import { HistoryRecord } from '../../core/model/Models';
import {
  BASE_URL_OPTIONS,
  DEFAULT_BASE_URL,
  DEFAULT_USER_AGENT,
  GITHUB_REPO_URL
} from '../../core/util/Constants';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Material } from '../../common/Material';
import { RouteParam, Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar } from '../../components/common/Widgets';
import { GroupCard, GroupTitle, NavRow, RowDivider, SegmentRow, SwitchRow } from '../library/LibraryComponents';
import { CacheManager } from '../../viewmodel/settings/CacheManager';
import {
  NetworkConfigurator,
  QUALITY_LABELS,
  SPEED_LABELS,
  THEME_LABELS,
  formatBytes,
  qualityIndex,
  qualitySelection,
  speedSelection,
  speedValue,
  themeSelection
} from '../../viewmodel/settings/SettingsViewModel';
import { notifyLibraryChanged } from '../../viewmodel/library/LibraryViewModel';
import {
  UPDATE_LATEST,
  UPDATE_NEW,
  UPDATE_PRIVATE,
  UpdateChecker,
  UpdateCheckResult
} from '../../logic/net/UpdateChecker';

/** 协议 / 许可证地址 */
const APACHE_LICENSE_URL: string = 'https://www.apache.org/licenses/LICENSE-2.0';

/** 设置页输入框圆角（比分组卡 24 小，保持输入框独立的圆角观感；不随分组卡圆角放大而变） */
const SETTINGS_INPUT_RADIUS: number = 14;

/** 主题强调色预设（PuraPily 设置页观感：蓝 / 粉 / 绿 / 紫 / 橙） */
const THEME_COLOR_OPTIONS: string[] = ['#007DFF', '#FB7299', '#00B578', '#8A2BFF', '#FF8F1F'];

/** 播放内核分段选项（下标 0 = ExoPlayer，1 = MPV；与 AppSettings 的 'exo' / 'mpv' 对应） */
const PLAYER_KERNEL_OPTIONS: string[] = ['ExoPlayer', 'MPV'];

/** 屏幕方向锁分段选项（下标 0 = 跟随系统，1 = 锁定竖屏，2 = 锁定横屏） */
const SCREEN_ORIENTATION_LABELS: string[] = ['跟随系统', '锁定竖屏', '锁定横屏'];

/** AppSettings 屏幕方向锁值 → SegmentRow 下标（非法值按默认「跟随系统」显示） */
function screenOrientationSelection(lock: string): number {
  if (lock === 'portrait') {
    return 1;
  }
  if (lock === 'landscape') {
    return 2;
  }
  return 0;
}

/** AppSettings 播放内核值 → SegmentRow 下标（非法值按默认 ExoPlayer 显示） */
function playerKernelSelection(kernel: string): number {
  return kernel === 'mpv' ? 1 : 0;
}

@Component
export struct SettingsPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('themeColor') themeColor: string = '#007DFF';
  @StorageLink('systemDark') systemDark: boolean = false;
  @StorageLink('baseUrl') baseUrl: string = DEFAULT_BASE_URL;
  @StorageLink('backupCdn') backupCdn: boolean = false;
  @StorageLink('qualityIndex') qualitySetting: number = -1;
  @StorageLink('playerSpeed') playerSpeed: number = 1.0;
  @StorageLink('useImmersiveMaterial') useImmersiveMaterial: boolean = true;
  /** 播放器底部常显细进度条（即时生效：InlinePlayer / VideoPage 都用 @StorageProp 读同一键） */
  @StorageLink('playerBottomProgress') playerBottomProgress: boolean = true;
  /** 播放内核 'exo'（ExoPlayer 位，底层系统 AVPlayer，默认）/ 'mpv'（libmpv）；切换后重新进入视频页生效 */
  @StorageLink('playerKernel') playerKernel: string = 'exo';
  /** 屏幕方向锁 'system'（跟随系统，默认）/ 'portrait'（锁竖屏）/ 'landscape'（锁横屏）；切换立即应用 */
  @StorageLink('screenOrientationLock') screenOrientationLock: string = 'system';
  /** 全屏窗口下底部导航条高度（EntryAbility 写入），用于内容底部留白 */
  @StorageLink('navBarHeight') navBarHeight: number = 0;
  /** 状态栏高度：悬浮顶栏覆盖状态栏，内容顶部 spacer 用 statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  @State uaDraft: string = '';
  @State watchHistoryEnabled: boolean = true;
  @State cacheSizeText: string = '…';
  @State historyCount: number = 0;
  /** 页面内容进入动画：opacity 0→1 + 垂直 10→0（animateTo 240ms Curve.Friction） */
  @State contentOpacity: number = 0;
  @State contentOffsetY: number = 10;
  /** 主题色色块按下的弹簧缩放值（与 THEME_COLOR_OPTIONS 一一对应，整体重赋值触发动画） */
  @State colorScales: number[] = [1, 1, 1, 1, 1];
  /** 关于分区的版本号文本（运行时读 bundleManager，格式 versionName (versionCode)） */
  @State versionText: string = '…';
  /** 检查更新请求进行中：右侧显示「检查中…」并阻止重复点击 */
  @State checking: boolean = false;

  private disposed: boolean = false;
  private pulseTimers: number[] = [];

  aboutToAppear(): void {
    const settings: AppSettings = AppSettings.getInstance();
    this.uaDraft = settings.getUserAgent();
    this.watchHistoryEnabled = settings.getWatchHistoryEnabled();
    this.refreshCacheSize();
    this.loadHistoryCount();
    this.versionText = this.readVersionText();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    for (let i = 0; i < this.pulseTimers.length; i++) {
      clearTimeout(this.pulseTimers[i]);
    }
    this.pulseTimers = [];
  }

  // ---------------------------------------------------------------------------
  // 数据
  // ---------------------------------------------------------------------------

  private abilityContext(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private refreshCacheSize(): void {
    const bytes: number = CacheManager.sizeBytes(this.abilityContext());
    this.cacheSizeText = formatBytes(bytes);
  }

  async loadHistoryCount(): Promise<void> {
    try {
      const list: HistoryRecord[] = await LocalRepo.getInstance().listHistorySorted();
      if (this.disposed) {
        return;
      }
      this.historyCount = list.length;
    } catch (e) {
      // 本地库未就绪时忽略
    }
  }

  // ---------------------------------------------------------------------------
  // 通用：主题 / 主题色
  // ---------------------------------------------------------------------------

  private onThemeSelect(index: number): void {
    const settings: AppSettings = AppSettings.getInstance();
    if (index === 1) {
      settings.setThemeMode('light');
    } else if (index === 2) {
      settings.setThemeMode('dark');
    } else {
      settings.setThemeMode('system');
    }
  }

  /** 当前主题色对应的中文名（用于分组行的右侧值） */
  private themeColorLabel(): string {
    if (this.themeColor === '#007DFF') {
      return '默认蓝';
    }
    if (this.themeColor === '#FB7299') {
      return '樱花粉';
    }
    if (this.themeColor === '#00B578') {
      return '青竹绿';
    }
    if (this.themeColor === '#8A2BFF') {
      return '丁香紫';
    }
    if (this.themeColor === '#FF8F1F') {
      return '暖橙';
    }
    return '自定义';
  }

  private onThemeColorSelect(color: string): void {
    if (color === this.themeColor) {
      return;
    }
    AppSettings.getInstance().setThemeColor(color);
    this.pulseThemeSwatch(THEME_COLOR_OPTIONS.indexOf(color));
    Toast.show('主题色已更新（部分页面重新进入后生效）');
  }

  /** 页面内容进入：淡入 + 轻微上移（Scroll 首次出现时播放） */
  private playEnterAnimation(): void {
    animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.contentOpacity = 1;
      this.contentOffsetY = 0;
    });
  }

  /** 主题色块选中反馈：1 → 1.12（80ms）→ 1（140ms 回弹），总时长 220ms */
  private pulseThemeSwatch(index: number): void {
    if (index < 0 || index >= this.colorScales.length) {
      return;
    }
    this.animateSwatchScale(index, 1.12, 80, Curve.EaseOut);
    const timer: number = setTimeout(() => {
      this.animateSwatchScale(index, 1, 140, Curve.Friction);
    }, 80);
    this.pulseTimers.push(timer);
  }

  private animateSwatchScale(index: number, scale: number, duration: number, curve: Curve): void {
    animateTo({ duration: duration, curve: curve }, () => {
      const next: number[] = this.colorScales.slice();
      next[index] = scale;
      this.colorScales = next;
    });
  }

  // ---------------------------------------------------------------------------
  // 网络
  // ---------------------------------------------------------------------------

  private onBaseUrlSelect(url: string): void {
    if (url === this.baseUrl) {
      return;
    }
    const settings: AppSettings = AppSettings.getInstance();
    settings.setBaseUrl(url);
    NetworkConfigurator.apply();
    Toast.show('站点已切换，请重新加载首页');
  }

  private saveUserAgent(): void {
    const ua: string = this.uaDraft.trim();
    if (ua.length === 0) {
      Toast.show('User-Agent 不能为空；如需恢复默认请点“恢复默认”');
      return;
    }
    AppSettings.getInstance().setUserAgent(ua);
    this.uaDraft = AppSettings.getInstance().getUserAgent();
    NetworkConfigurator.apply();
    Toast.show('User-Agent 已保存，请重新加载页面');
  }

  private resetUserAgent(): void {
    AppSettings.getInstance().setUserAgent(DEFAULT_USER_AGENT);
    this.uaDraft = AppSettings.getInstance().getUserAgent();
    NetworkConfigurator.apply();
    Toast.show('已恢复默认 User-Agent');
  }

  private onBackupCdnToggle(value: boolean): void {
    AppSettings.getInstance().setBackupCdn(value);
    NetworkConfigurator.apply();
    Toast.show(value ? '已开启备用媒体 CDN，请重新加载视频' : '已关闭备用媒体 CDN');
  }

  // ---------------------------------------------------------------------------
  // 播放 / 隐私
  // ---------------------------------------------------------------------------

  private onQualitySelect(index: number): void {
    AppSettings.getInstance().setPlayerQualityIndex(qualityIndex(index));
    Toast.show('默认清晰度已更新');
  }

  private onSpeedSelect(index: number): void {
    AppSettings.getInstance().setPlayerSpeed(speedValue(index));
  }

  /** 常显播放进度条开关：写入 AppSettings（AppStorage 镜像 → 播放器 @StorageProp 即时刷新） */
  private onBottomProgressToggle(value: boolean): void {
    AppSettings.getInstance().setPlayerBottomProgress(value);
    Toast.show(value ? '已开启底部常显进度条' : '已关闭底部常显进度条');
  }

  /** 播放内核切换：写 AppSettings（AppStorage 镜像），视频页下次进入时读取生效 */
  private onPlayerKernelSelect(index: number): void {
    const next: string = index === 1 ? 'mpv' : 'exo';
    if (next === this.playerKernel) {
      return;
    }
    AppSettings.getInstance().setPlayerKernel(next);
    Toast.show('已切换播放内核，重新进入视频页生效');
  }

  private onWatchHistoryToggle(value: boolean): void {
    this.watchHistoryEnabled = value;
    AppSettings.getInstance().setWatchHistoryEnabled(value);
    Toast.show(value ? '已开启观看历史记录' : '已关闭观看历史记录（不再写入新记录）');
  }

  // ---------------------------------------------------------------------------
  // 外观：沉浸材质底栏
  // ---------------------------------------------------------------------------

  private onImmersiveMaterialToggle(value: boolean): void {
    if (!Material.supported()) {
      Toast.show('当前系统不支持沉浸材质（需要 HarmonyOS 7.0 / API 26）');
      return;
    }
    AppSettings.getInstance().setUseImmersiveMaterial(value);
    Toast.show(value ? '已开启沉浸材质底栏' : '已关闭，改用毛玻璃底栏');
  }

  // ---------------------------------------------------------------------------
  // 外观：屏幕方向锁（跟随系统 / 锁定竖屏 / 锁定横屏）
  // ---------------------------------------------------------------------------

  /**
   * 切换屏幕方向锁：
   *  1. 先写 AppSettings（Preferences 持久化 + AppStorage 同键镜像）；
   *  2. 立即对主窗口应用 setPreferredOrientation（system → AUTO_ROTATION_RESTRICTED，
   *     portrait → PORTRAIT，landscape → LANDSCAPE），失败只 Toast 提示、不回滚设置。
   * 锁定横屏后：播放页自动左右分栏、首页 / 搜索 / 内容库等网格横屏固定 4 列。
   */
  private onScreenOrientationSelect(index: number): void {
    const next: string = index === 1 ? 'portrait' : (index === 2 ? 'landscape' : 'system');
    AppSettings.getInstance().setScreenOrientationLock(next);
    this.applyOrientationLockNow();
    if (next === 'landscape') {
      Toast.show('已锁定横屏：播放页左右分栏，网格自动多列');
    } else if (next === 'portrait') {
      Toast.show('已锁定竖屏');
    } else {
      Toast.show('已恢复跟随系统方向');
    }
  }

  /** 立即把当前方向锁应用到主窗口（拿不到窗口 / 设备不支持时静默，不影响设置保存） */
  private async applyOrientationLockNow(): Promise<void> {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return;
    }
    try {
      const win: window.Window = await window.getLastWindow(context);
      await applyScreenOrientationLock(win, AppSettings.getInstance().getScreenOrientationLock());
    } catch (e) {
      // 部分设备 / 窗口模式不支持强制方向：设置已保存，下次启动继续生效
    }
  }

  // ---------------------------------------------------------------------------
  // 存储
  // ---------------------------------------------------------------------------

  private confirmClearHistory(): void {
    AlertDialog.show({
      title: '清空本地观看历史',
      message: '将删除本机全部观看记录与播放进度，无法恢复。是否继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.colors().error,
        action: () => {
          this.clearHistory();
        }
      }
    });
  }

  async clearHistory(): Promise<void> {
    try {
      await LocalRepo.getInstance().clearHistory();
      if (this.disposed) {
        return;
      }
      this.historyCount = 0;
      notifyLibraryChanged();
      Toast.show('本地观看历史已清空');
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  private confirmClearSearchHistory(): void {
    AlertDialog.show({
      title: '清空搜索历史',
      message: '将删除本机保存的全部搜索关键词，无法恢复。是否继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.colors().error,
        action: () => {
          this.clearSearchHistory();
        }
      }
    });
  }

  async clearSearchHistory(): Promise<void> {
    try {
      await AppDb.getInstance().clearSearchHistory();
      Toast.show('搜索历史已清空');
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  private confirmClearCache(): void {
    AlertDialog.show({
      title: '清空缓存目录',
      message: '将删除应用缓存目录下的文件（登录状态、收藏、观看历史等数据不会丢失）。是否继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.colors().error,
        action: () => {
          this.clearCache();
        }
      }
    });
  }

  private clearCache(): void {
    try {
      CacheManager.clear(this.abilityContext());
      this.refreshCacheSize();
      Toast.show('缓存已清空');
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  // ---------------------------------------------------------------------------
  // 关于
  // ---------------------------------------------------------------------------

  /** 版本号文本：versionName (versionCode)，运行时读安装包信息，不写死常量 */
  private readVersionText(): string {
    try {
      const info: bundleManager.BundleInfo =
        bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      return info.versionName + ' (' + info.versionCode + ')';
    } catch (e) {
      // 读不到时退回占位符，不影响其它设置项
      return '未知版本';
    }
  }

  /**
   * 检查更新：请求 GitHub latest release，按结果分四种表现：
   *  - 有新版本 → 弹窗（标题带版本号、正文 800 字内、「去下载」/「稍后」）；
   *  - 已最新 → toast；
   *  - 404 → 仓库未公开；
   *  - 其它 → 通用失败提示。
   * 请求期间 checking=true，行右侧显示「检查中…」并禁止重复点击。
   */
  private async checkUpdate(): Promise<void> {
    if (this.checking) {
      return;
    }
    this.checking = true;
    try {
      const result: UpdateCheckResult = await UpdateChecker.checkLatest();
      if (this.disposed) {
        return;
      }
      if (result.status === UPDATE_NEW) {
        this.showUpdateDialog(result);
      } else if (result.status === UPDATE_LATEST) {
        Toast.show('已是最新版本');
      } else if (result.status === UPDATE_PRIVATE) {
        Toast.show('仓库未公开，无法检查更新');
      } else {
        Toast.show('检查更新失败，请稍后重试');
      }
    } finally {
      this.checking = false;
    }
  }

  /**
   * 新版本弹窗：用 UIContext.showAlertDialog（全局 AlertDialog.show 在 API 26 已废弃）。
   * 按钮用 buttons 数组（primaryButton/secondaryButton 同样已废弃），顺序：去下载 / 稍后。
   */
  private showUpdateDialog(info: UpdateCheckResult): void {
    this.getUIContext().showAlertDialog({
      title: '发现新版本 ' + info.version,
      message: info.body,
      buttons: [
        {
          value: '去下载',
          fontColor: Theme.colors().primary,
          action: () => {
            this.openExternalUrl(info.url);
          }
        },
        {
          value: '稍后',
          action: () => {
          }
        }
      ]
    });
  }

  /** 用系统浏览器打开链接；链接为空或拉起失败时只 toast，不抛到 UI 层 */
  private openExternalUrl(url: string): void {
    if (url.length === 0) {
      Toast.show('没有可用的下载地址');
      return;
    }
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    try {
      this.abilityContext().startAbility(want).catch(() => {
        Toast.show('无法打开链接');
      });
    } catch (e) {
      Toast.show('无法打开链接');
    }
  }

  private showLicense(): void {
    AlertDialog.show({
      title: '开源许可证',
      message: '本应用以 Apache License 2.0 许可发布。\n\n' +
        '你可以自由使用、修改与分发，但需保留版权与许可声明；' +
        '本软件按“原样”提供，不附带任何明示或暗示的担保。',
      confirm: {
        value: '关闭',
        action: () => {
        }
      }
    });
  }

  private showDisclaimer(): void {
    AlertDialog.show({
      title: '免责声明',
      message: '本应用为 hanime1.me 的第三方客户端，仅用于技术研究与学习交流，' +
        '与站点无任何隶属或合作关系。\n\n' +
        '应用内可能包含仅限成年人浏览的内容（R18）。请确认您已年满 18 周岁，' +
        '并遵守所在地区法律法规，自行承担使用本应用产生的一切后果。',
      confirm: {
        value: '关闭',
        action: () => {
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // 卡片内的小节标题行（图标块 + 标题 + 右侧辅助说明）
  // ---------------------------------------------------------------------------

  @Builder
  cardHeader(icon: Resource, title: string, trailing: string) {
    Row() {
      Row() {
        Image(icon)
          .width(18)
          .height(18)
          .fillColor(Theme.colors().primary);
      }
      .width(30)
      .height(30)
      .borderRadius(10)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(Theme.colors().primaryContainer)
      .margin({ right: 12 });

      Text(title)
        .fontSize(Dimens.bodySize)
        .fontColor(Theme.colors().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1);

      if (trailing.length > 0) {
        Text(trailing)
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .maxLines(1);
      }
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 10, bottom: 2 });
  }

  // ---------------------------------------------------------------------------
  // 通用分组：深色模式 + 主题色
  // ---------------------------------------------------------------------------

  @Builder
  generalGroup() {
    GroupCard() {
      this.cardHeader($r('app.media.ic_settings'), '深色模式', '切换立即生效');

      Row() {
        SegmentRow({
          options: THEME_LABELS,
          selectedIndex: themeSelection(this.themeMode),
          onSelect: (index: number) => {
            this.onThemeSelect(index);
          }
        });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 10 });

      RowDivider();

      this.cardHeader($r('app.media.ic_star'), '主题色', this.themeColorLabel());

      Row() {
        ForEach(THEME_COLOR_OPTIONS, (color: string, index: number) => {
          Stack({ alignContent: Alignment.Center }) {
            // 色块本体 28 圆
            Row()
              .width(28)
              .height(28)
              .borderRadius(14)
              .backgroundColor(color);
            // 内侧白/深色描边（与卡片同色，制造色块与选中圈之间的留白）
            Row()
              .width(34)
              .height(34)
              .borderRadius(17)
              .border({ width: 2, color: Theme.colors().cardBg });
            // 选中项 2vp 主色外圈
            Row()
              .width(40)
              .height(40)
              .borderRadius(20)
              .border({
                width: 2,
                color: this.themeColor === color ? color : Color.Transparent
              });
          }
          .width(44)
          .height(44)
          .scale({ x: this.colorScales[index], y: this.colorScales[index] })
          .margin({ right: 10 })
          .onClick(() => {
            this.onThemeColorSelect(color);
          });
        }, (color: string, index: number) => color + index);
        Blank();
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 4, bottom: 10 });
    }
  }

  // ---------------------------------------------------------------------------
  // 外观分组：屏幕方向锁 + 沉浸材质底栏 + 首页轮播说明
  // ---------------------------------------------------------------------------

  @Builder
  appearanceGroup() {
    GroupCard() {
      // 屏幕方向锁（PuraPily 风格）：跟随系统 / 锁定竖屏 / 锁定横屏。
      // 切换即写 AppSettings 并对主窗口 setPreferredOrientation；锁定横屏后播放页左右分栏、
      // 首页 / 搜索 / 内容库等网格横屏固定 4 列（竖屏按宽度 2~4 列），其它列表页保持单列。
      this.cardHeader($r('app.media.ic_fullscreen'), '屏幕方向', '切换立即生效');

      Row() {
        SegmentRow({
          options: SCREEN_ORIENTATION_LABELS,
          selectedIndex: screenOrientationSelection(this.screenOrientationLock),
          onSelect: (index: number) => {
            this.onScreenOrientationSelect(index);
          }
        });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 10 });

      Text('锁定横屏后：视频详情页自动左右分栏（播放器 + 简介 / 评论 / 相关推荐），' +
        '首页 / 搜索 / 内容库等网格横屏固定 4 列（竖屏按宽度切分）；跟随系统则由设备方向决定。')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .lineHeight(16)
        .width('100%')
        .padding({ left: 12, right: 12, top: 2, bottom: 12 });

      RowDivider();

      // HarmonyOS 7.0（API 26）系统沉浸材质底栏开关：
      // 系统材质在某些系统版本/主题下可能显示异常（例如底栏透明），关闭后回退手写毛玻璃。
      SwitchRow({
        icon: $r('app.media.ic_settings'),
        title: '沉浸材质底栏',
        subtitle: 'HarmonyOS 7.0 系统材质（' + Material.stateLabel() + '）；显示异常可关闭改用毛玻璃',
        isOn: this.useImmersiveMaterial && Material.supported(),
        onToggle: (value: boolean) => {
          this.onImmersiveMaterialToggle(value);
        }
      });

      RowDivider();

      NavRow({
        icon: $r('app.media.ic_play'),
        title: '首页轮播',
        subtitle: '首页顶部自动轮播推荐内容，暂不提供开关',
        valueText: '自动',
        showArrow: false,
        onTap: () => {
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 网络分组：站点域名 + 备用 CDN + 自定义 UA
  // ---------------------------------------------------------------------------

  @Builder
  networkGroup() {
    GroupCard() {
      this.cardHeader($r('app.media.ic_home'), '站点域名', '切换后需重新加载');

      ForEach(BASE_URL_OPTIONS, (url: string) => {
        Column() {
          NavRow({
            showIcon: false,
            showArrow: false,
            title: url,
            subtitle: url === DEFAULT_BASE_URL ? '默认站点' : '备用站点',
            valueText: url === this.baseUrl ? '✓ 当前' : '',
            onTap: () => {
              this.onBaseUrlSelect(url);
            }
          });
          RowDivider();
        }
        .width('100%');
      }, (url: string) => url)

      SwitchRow({
        icon: $r('app.media.ic_download'),
        title: '备用媒体 CDN',
        subtitle: '直连 vdownload.hembed.com 失败时改用 cdn77 备用源',
        isOn: this.backupCdn,
        onToggle: (value: boolean) => {
          this.onBackupCdnToggle(value);
        }
      });

      RowDivider();

      this.cardHeader($r('app.media.ic_login'), '自定义 User-Agent', '修改后需保存');

      TextInput({ text: $$this.uaDraft, placeholder: DEFAULT_USER_AGENT })
        .fontSize(Dimens.bodySize)
        .fontColor(Theme.colors().textPrimary)
        .placeholderColor(Theme.colors().textHint)
        .height(44)
        .backgroundColor(Theme.colors().chipTint)
        .borderRadius(SETTINGS_INPUT_RADIUS)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .margin({ left: 12, right: 12, top: 6 })
        .onChange((value: string) => {
          this.uaDraft = value;
        });

      Row() {
        Button('恢复默认')
          .fontSize(Dimens.bodySize)
          .height(44)
          .layoutWeight(1)
          .backgroundColor(Theme.colors().chipTint)
          .fontColor(Theme.colors().textPrimary)
          .borderRadius(999)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
          .onClick(() => {
            this.resetUserAgent();
          });
        Button('保存')
          .fontSize(Dimens.bodySize)
          .height(44)
          .layoutWeight(1)
          .margin({ left: 10 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
          .onClick(() => {
            this.saveUserAgent();
          });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 6 });

      Text('默认 UA 与 Android 版一致；部分站点校验 UA，请谨慎修改。')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .lineHeight(16)
        .width('100%')
        .padding({ left: 12, right: 12, top: 4, bottom: 12 });
    }
  }

  // ---------------------------------------------------------------------------
  // 播放分组：默认清晰度 + 默认倍速 + 播放内核 + 常显进度条
  // ---------------------------------------------------------------------------

  @Builder
  playerGroup() {
    GroupCard() {
      this.cardHeader($r('app.media.ic_fullscreen'), '默认清晰度', '自动 = 站点最高');

      Row() {
        SegmentRow({
          options: QUALITY_LABELS,
          selectedIndex: qualitySelection(this.qualitySetting),
          onSelect: (index: number) => {
            this.onQualitySelect(index);
          }
        });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 10 });

      RowDivider();

      this.cardHeader($r('app.media.ic_play'), '默认倍速', '播放器首帧生效');

      Row() {
        SegmentRow({
          options: SPEED_LABELS,
          selectedIndex: speedSelection(this.playerSpeed),
          onSelect: (index: number) => {
            this.onSpeedSelect(index);
          }
        });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 10 });

      Text('清晰度按站点源的顺序匹配；自动 = 使用站点第一个（最高）清晰度。')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .lineHeight(16)
        .width('100%')
        .padding({ left: 12, right: 12, top: 2, bottom: 12 });

      RowDivider();

      // 播放内核：ExoPlayer 位（底层 HarmonyOS 系统 AVPlayer，默认）/ MPV（libmpv，FFmpeg）。
      // 注意 exo 只是沿用了上游 Android 设置项的语义，本平台没有 ExoPlayer/Media3 组件。
      // 写入 AppSettings 后由 AppStorage 镜像同步，视频页下次进入时读取。
      this.cardHeader($r('app.media.ic_play'), '播放内核', '重新进入视频页生效');

      Row() {
        SegmentRow({
          options: PLAYER_KERNEL_OPTIONS,
          selectedIndex: playerKernelSelection(this.playerKernel),
          onSelect: (index: number) => {
            this.onPlayerKernelSelect(index);
          }
        });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 6, bottom: 10 });

      Text('ExoPlayer：系统 AVPlayer 内核（默认，兼容性最好，支持 HLS/MP4，硬件解码）\n' +
        'MPV：libmpv 内核（FFmpeg 全家桶，支持更多编码/容器与高级渲染，仅 arm64）\n' +
        'MPV 播放失败会自动回退 ExoPlayer。')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .lineHeight(16)
        .width('100%')
        .padding({ left: 12, right: 12, top: 2, bottom: 12 });

      RowDivider();

      // 播放器底部常显进度条：不随控制层自动隐藏而消失，任何方向 / 全屏状态下都能看到播放进度
      SwitchRow({
        icon: $r('app.media.ic_play'),
        title: '常显播放进度条',
        subtitle: '在视频底部始终显示一条进度条',
        isOn: this.playerBottomProgress,
        onToggle: (value: boolean) => {
          this.onBottomProgressToggle(value);
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 隐私分组
  // ---------------------------------------------------------------------------

  @Builder
  privacyGroup() {
    GroupCard() {
      SwitchRow({
        icon: $r('app.media.ic_clock'),
        title: '记录观看历史',
        subtitle: '关闭后不再写入新的观看历史（已有记录仍保留）',
        isOn: this.watchHistoryEnabled,
        onToggle: (value: boolean) => {
          this.onWatchHistoryToggle(value);
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 存储分组：危险操作文字用 error 色
  // ---------------------------------------------------------------------------

  @Builder
  storageGroup() {
    GroupCard() {
      NavRow({
        icon: $r('app.media.ic_clock'),
        title: '清空本地观看历史',
        subtitle: '当前共 ' + this.historyCount + ' 条记录',
        danger: true,
        onTap: () => {
          this.confirmClearHistory();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_search'),
        title: '清空搜索历史',
        subtitle: '删除本机保存的搜索关键词',
        danger: true,
        onTap: () => {
          this.confirmClearSearchHistory();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_download'),
        title: '清空缓存目录',
        subtitle: '当前缓存 ' + this.cacheSizeText,
        danger: true,
        onTap: () => {
          this.confirmClearCache();
        }
      });
    }
  }

  // ---------------------------------------------------------------------------
  // 关于分组
  // ---------------------------------------------------------------------------

  @Builder
  aboutGroup() {
    GroupCard() {
      NavRow({
        icon: $r('app.media.ic_settings'),
        title: '版本',
        subtitle: 'Han1meViewer（HarmonyOS 客户端）',
        valueText: this.versionText,
        showArrow: false,
        onTap: () => {
        }
      });
      RowDivider();
      // 检查更新：请求期间整行禁用，右侧显示进度文案；分组里只有检查中才出现该文案
      Row() {
        NavRow({
          icon: $r('app.media.ic_download'),
          title: '检查更新',
          subtitle: '从 GitHub Releases 获取最新版本',
          valueText: this.checking ? '检查中…' : '',
          showArrow: !this.checking,
          onTap: () => {
            this.checkUpdate();
          }
        });
      }
      .width('100%')
      .enabled(!this.checking);
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_share'),
        title: '上游项目（GitHub）',
        subtitle: '查看上游 Android 源码与许可证',
        onTap: () => {
          Router.openWeb(GITHUB_REPO_URL, 'Han1meViewer 上游项目');
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_star'),
        title: '开源许可证（Apache-2.0）',
        subtitle: '查看许可证说明',
        onTap: () => {
          this.showLicense();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_star'),
        title: '免责声明',
        subtitle: 'R18 内容提示与使用条款',
        onTap: () => {
          this.showDisclaimer();
        }
      });
      RowDivider();
      NavRow({
        showIcon: false,
        showArrow: false,
        title: '许可证原文',
        subtitle: '在浏览器中打开 Apache-2.0 全文',
        valueText: 'Apache-2.0',
        onTap: () => {
          Router.openWeb(APACHE_LICENSE_URL, 'Apache License 2.0');
        }
      });
    }
  }

  build() {
    // 悬浮顶栏：Scroll 铺满整页并在顶部用 spacer 让出状态栏 + 顶栏高度，
    // 滚动时内容从悬浮的渐变模糊顶栏下方经过；AppTopBar 作为 Stack 覆盖层最后绘制。
    Stack({ alignContent: Alignment.TopStart }) {
      Scroll() {
        Column() {
          // 顶栏让位 spacer：随内容一起滚走（Bika 式悬浮顶栏的关键）
          Row()
            .width('100%')
            .height(this.statusBarHeight + Dimens.topBarHeight);

          GroupTitle({ text: '通用' });
          this.generalGroup();

          GroupTitle({ text: '外观' });
          this.appearanceGroup();

          GroupTitle({ text: '网络' });
          this.networkGroup();

          GroupTitle({ text: '播放' });
          this.playerGroup();

          GroupTitle({ text: '隐私' });
          this.privacyGroup();

          GroupTitle({ text: '存储' });
          this.storageGroup();

          GroupTitle({ text: '关于' });
          this.aboutGroup();
        }
        .width('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          top: 4,
          bottom: 24 + this.navBarHeight
        });
      }
      .width('100%')
      .height('100%')
      .opacity(this.contentOpacity)
      .translate({ y: this.contentOffsetY })
      .onAppear(() => {
        this.playEnterAnimation();
      })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);

      // 悬浮覆盖层：渐变模糊顶栏 + 沉浸材质圆钮
      AppTopBar({ title: '设置', showBack: true });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
