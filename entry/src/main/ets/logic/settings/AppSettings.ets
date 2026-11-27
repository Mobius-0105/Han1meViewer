/**
 * 应用设置（Preferences 持久化 + AppStorage 镜像）。
 *
 * 设计：
 *  - 单例；`init(ctx)` 一次读入内存，之后所有 getter/setter 都是**同步**的，
 *    UI / 网络层可以随意调用；
 *  - setter 立即更新内存 + `AppStorage.setOrCreate`（带 `@StorageLink/@StorageProp`
 *    的页面自动刷新），再 `putSync` + `flush()` 异步落盘。putSync 只写内存缓存，
 *    必须 flush 才会真正写文件；
 *  - 关键 UI 项固定使用下面这些 AppStorage 键（与根 agent 约定）：
 *    baseUrl / backupCdn / themeMode / userId / username / avatarUrl / loggedIn /
 *    qualityIndex / playerSpeed / playerBottomProgress / playerKernel /
 *    screenOrientationLock（'system' | 'portrait' | 'landscape'）。
 *
 * 默认值对齐 Android Preferences：站点 https://hanime1.me/、默认 UA、备用 CDN 关闭、
 * 主题跟随系统、清晰度 -1（自动）、倍速 1.0、记录观看历史开启、
 * 播放内核 exo（ExoPlayer 位，底层是系统 AVPlayer）、屏幕方向跟随系统。屏幕方向锁由本文件提供 preferredOrientationOf / applyScreenOrientationLock，
 * EntryAbility 启动与设置页切换时直接调用（PuraPily 风格的方向设置项）。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_BASE_URL, DEFAULT_USER_AGENT } from '../../core/util/Constants';

const DOMAIN: number = 0x0001;
const TAG: string = 'AppSettings';

const PREF_NAME: string = 'hanime_settings';

const KEY_BASE_URL: string = 'baseUrl';
const KEY_USER_AGENT: string = 'userAgent';
const KEY_BACKUP_CDN: string = 'backupCdn';
const KEY_THEME_MODE: string = 'themeMode';
const KEY_COOKIE_STRING: string = 'cookieString';
const KEY_USER_ID: string = 'userId';
const KEY_USERNAME: string = 'username';
const KEY_AVATAR_URL: string = 'avatarUrl';
const KEY_LOGGED_IN: string = 'loggedIn';
const KEY_QUALITY_INDEX: string = 'qualityIndex';
const KEY_PLAYER_SPEED: string = 'playerSpeed';
const KEY_WATCH_HISTORY_ENABLED: string = 'watchHistoryEnabled';
/** 是否启用 HarmonyOS 7.0 系统沉浸材质底栏（关闭后使用手写毛玻璃） */
const KEY_USE_IMMERSIVE_MATERIAL: string = 'useImmersiveMaterial';
/** 是否在播放器最底部常显一条细进度条（不随控制层显隐，默认开启） */
const KEY_PLAYER_BOTTOM_PROGRESS: string = 'playerBottomProgress';
/**
 * 播放内核：'exo' = ExoPlayer 位（底层系统 AVPlayer，默认）；'mpv' = libmpv。
 * 键名保持 playerKernel 不变，老版本写入的 'av' / 'ijk' 在读取时迁移（见 normalizePlayerKernel）。
 */
const KEY_PLAYER_KERNEL: string = 'playerKernel';
/** 主题强调色（PuraPily 风格：默认 #007DFF，可切换） */
const KEY_THEME_COLOR: string = 'themeColor';
const DEFAULT_THEME_COLOR: string = '#007DFF';
/**
 * 屏幕方向锁（PuraPily 风格设置项）：
 *  - 'system'    跟随系统（默认；窗口允许自动旋转，但由系统 / 传感器决定）
 *  - 'portrait'  锁定竖屏
 *  - 'landscape' 锁定横屏（播放页自动左右分栏，其它页面按宽屏多列布局）
 * 存 Preferences 并镜像到 AppStorage 同键，EntryAbility 启动时 / 设置页切换时立即应用。
 */
const KEY_SCREEN_ORIENTATION_LOCK: string = 'screenOrientationLock';
const SCREEN_ORIENTATION_SYSTEM: string = 'system';
const SCREEN_ORIENTATION_PORTRAIT: string = 'portrait';
const SCREEN_ORIENTATION_LANDSCAPE: string = 'landscape';

/**
 * 播放内核取值：
 *  - 'exo'：ExoPlayer 位。名字沿用上游 Android 的设置项语义（两端设置项含义一一对应），
 *    底层实现是 HarmonyOS 系统 AVPlayer + XComponent(SURFACE)——HarmonyOS 上并没有
 *    ExoPlayer / Media3，这里**不是** Android 的 ExoPlayer；
 *  - 'mpv'：libmpv（@mpv-ohos/mpv-arkts，内含 FFmpeg），失败时上层回退 'exo'。
 */
const PLAYER_KERNEL_EXO: string = 'exo';
const PLAYER_KERNEL_MPV: string = 'mpv';

/**
 * 历史遗留取值，只用于升级迁移、不再写入：
 *  - 'av'：旧版默认（系统 AVPlayer），语义等同现在的 'exo'；
 *  - 'ijk'：旧版可选内核 @ohos/ijkplayer，已被 mpv 内核取代，语义归入 'mpv'。
 */
const LEGACY_PLAYER_KERNEL_AV: string = 'av';
const LEGACY_PLAYER_KERNEL_IJK: string = 'ijk';

/** -1 = 自动（跟随视频源顺序）；>=0 时是清晰度列表下标。 */
const QUALITY_AUTO: number = -1;
const DEFAULT_PLAYER_SPEED: number = 1.0;
const MIN_PLAYER_SPEED: number = 0.25;
const MAX_PLAYER_SPEED: number = 4.0;

export type ThemeMode = 'system' | 'light' | 'dark';

const THEME_SYSTEM: ThemeMode = 'system';

/** 屏幕方向锁取值：跟随系统 / 锁定竖屏 / 锁定横屏 */
export type ScreenOrientationLock = 'system' | 'portrait' | 'landscape';

/** 仅接受已知方向锁值，历史脏数据回退 system。 */
function normalizeScreenOrientationLock(raw: string): ScreenOrientationLock {
  if (raw === SCREEN_ORIENTATION_PORTRAIT) {
    return 'portrait';
  }
  if (raw === SCREEN_ORIENTATION_LANDSCAPE) {
    return 'landscape';
  }
  return 'system';
}

/**
 * 屏幕方向锁设置值 → 系统窗口方向常量。
 *
 * 'system' 用 AUTO_ROTATION（跟随传感器自动旋转，且受控制中心「旋转锁定」开关约束）；
 * 不再使用 AUTO_ROTATION_RESTRICTED —— 它在部分窗口 / 设备组合下会让方向切换与系统栏
 * 恢复时序互相干扰（横屏后状态栏不回来）。另外两档为硬锁。
 */
export function preferredOrientationOf(lock: string): window.Orientation {
  if (lock === SCREEN_ORIENTATION_PORTRAIT) {
    return window.Orientation.PORTRAIT;
  }
  if (lock === SCREEN_ORIENTATION_LANDSCAPE) {
    return window.Orientation.LANDSCAPE;
  }
  return window.Orientation.AUTO_ROTATION;
}

/**
 * 立即把方向锁应用到指定窗口（EntryAbility 启动 / 设置页切换 / 播放页退出全屏共用）。
 * 失败只记一条 warn：部分设备 / 窗口模式不支持强制方向，不应影响调用方流程。
 */
export async function applyScreenOrientationLock(win: window.Window, lock: string): Promise<void> {
  try {
    await win.setPreferredOrientation(preferredOrientationOf(lock));
  } catch (err) {
    const error: BusinessError = err as BusinessError;
    hilog.warn(DOMAIN, TAG, `应用屏幕方向锁失败: ${error.message}`);
  }
}

/** 仅接受已知主题值，历史脏数据（如 'always_off'）回退 system。 */
function normalizeThemeMode(raw: string): ThemeMode {
  if (raw === 'light') {
    return 'light';
  }
  if (raw === 'dark') {
    return 'dark';
  }
  return THEME_SYSTEM;
}

/** 倍速夹到 [0.25, 4.0]；非法值回退 1.0。 */
function normalizePlayerSpeed(raw: number): number {
  if (!Number.isFinite(raw) || raw <= 0) {
    return DEFAULT_PLAYER_SPEED;
  }
  if (raw < MIN_PLAYER_SPEED) {
    return MIN_PLAYER_SPEED;
  }
  if (raw > MAX_PLAYER_SPEED) {
    return MAX_PLAYER_SPEED;
  }
  return raw;
}

/**
 * 播放内核归一：只接受 'exo' / 'mpv'。
 * 历史值走迁移而不是丢弃——'av'（旧默认）→ 'exo'，'ijk'（已移除的 IJK 内核）→ 'mpv'，
 * 让老用户升级后原来的选择仍然生效；其余脏数据 / 空值统一回退默认 'exo'（兼容性最好）。
 */
function normalizePlayerKernel(raw: string): string {
  if (raw === PLAYER_KERNEL_MPV || raw === LEGACY_PLAYER_KERNEL_IJK) {
    return PLAYER_KERNEL_MPV;
  }
  return PLAYER_KERNEL_EXO;
}

export class AppSettings {
  private static instance: AppSettings | null = null;

  private pref: preferences.Preferences | null = null;

  private baseUrl: string = DEFAULT_BASE_URL;
  private userAgent: string = DEFAULT_USER_AGENT;
  private backupCdn: boolean = false;
  private themeMode: ThemeMode = THEME_SYSTEM;
  private cookieString: string = '';
  private userId: string = '';
  private username: string = '';
  private avatarUrl: string = '';
  private loggedIn: boolean = false;
  private playerQualityIndex: number = QUALITY_AUTO;
  private playerSpeed: number = DEFAULT_PLAYER_SPEED;
  private watchHistoryEnabled: boolean = true;
  private useImmersiveMaterial: boolean = true;
  private playerBottomProgress: boolean = true;
  /** 'exo' = 系统 AVPlayer（默认，沿用上游 ExoPlayer 语义）；'mpv' = libmpv（失败回退 exo） */
  private playerKernel: string = PLAYER_KERNEL_EXO;
  private themeColor: string = DEFAULT_THEME_COLOR;
  /** 屏幕方向锁：'system'（默认）/ 'portrait' / 'landscape' */
  private screenOrientationLock: ScreenOrientationLock = 'system';

  private constructor() {
    // 先同步写入默认值：EntryAbility 在 onCreate 里调用 initApp()，异步读盘完成前
    // 首屏就可能渲染，AppStorage 里必须先有值（主题/登录态等）可读。
    this.syncAppStorage();
  }

  static getInstance(): AppSettings {
    if (AppSettings.instance === null) {
      AppSettings.instance = new AppSettings();
    }
    return AppSettings.instance;
  }

  /**
   * 读取 Preferences 并把值镜像到 AppStorage。幂等；读取失败时保留默认值继续启动
   * （设置读不出来不应该阻断 App 启动）。
   */
  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.pref !== null) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(ctx, PREF_NAME);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `设置初始化失败，使用默认值: code=${error.code}, message=${error.message}`);
      this.syncAppStorage();
      return;
    }
    this.loadFromPreferences();
    this.syncAppStorage();
    hilog.info(DOMAIN, TAG, '设置初始化完成');
  }

  // ---------------------------------------------------------------------------
  // 站点 / 网络
  // ---------------------------------------------------------------------------

  getBaseUrl(): string {
    return this.baseUrl;
  }

  setBaseUrl(value: string): void {
    const trimmed: string = value.trim();
    this.baseUrl = trimmed.length > 0 ? trimmed : DEFAULT_BASE_URL;
    AppStorage.setOrCreate<string>('baseUrl', this.baseUrl);
    this.persist(KEY_BASE_URL, this.baseUrl);
  }

  getUserAgent(): string {
    return this.userAgent;
  }

  setUserAgent(value: string): void {
    const trimmed: string = value.trim();
    this.userAgent = trimmed.length > 0 ? trimmed : DEFAULT_USER_AGENT;
    this.persist(KEY_USER_AGENT, this.userAgent);
  }

  getBackupCdn(): boolean {
    return this.backupCdn;
  }

  setBackupCdn(value: boolean): void {
    this.backupCdn = value;
    AppStorage.setOrCreate<boolean>('backupCdn', this.backupCdn);
    this.persist(KEY_BACKUP_CDN, this.backupCdn);
  }

  // ---------------------------------------------------------------------------
  // 外观
  // ---------------------------------------------------------------------------

  getThemeMode(): ThemeMode {
    return this.themeMode;
  }

  setThemeMode(value: ThemeMode): void {
    this.themeMode = normalizeThemeMode(value);
    AppStorage.setOrCreate<string>('themeMode', this.themeMode);
    this.persist(KEY_THEME_MODE, this.themeMode);
  }

  // ---------------------------------------------------------------------------
  // 外观：屏幕方向锁
  // ---------------------------------------------------------------------------

  /** 屏幕方向锁（'system' 跟随系统 / 'portrait' 锁竖屏 / 'landscape' 锁横屏） */
  getScreenOrientationLock(): ScreenOrientationLock {
    return this.screenOrientationLock;
  }

  /** 写设置 + AppStorage 镜像（带 @StorageLink 的设置页会即时刷新），窗口方向由调用方立即应用 */
  setScreenOrientationLock(value: string): void {
    this.screenOrientationLock = normalizeScreenOrientationLock(value);
    AppStorage.setOrCreate<string>('screenOrientationLock', this.screenOrientationLock);
    this.persist(KEY_SCREEN_ORIENTATION_LOCK, this.screenOrientationLock);
  }

  // ---------------------------------------------------------------------------
  // 登录态
  // ---------------------------------------------------------------------------

  getCookieString(): string {
    return this.cookieString;
  }

  setCookieString(value: string): void {
    this.cookieString = value;
    this.persist(KEY_COOKIE_STRING, this.cookieString);
  }

  getUserId(): string {
    return this.userId;
  }

  setUserId(value: string): void {
    this.userId = value;
    AppStorage.setOrCreate<string>('userId', this.userId);
    this.persist(KEY_USER_ID, this.userId);
  }

  getUsername(): string {
    return this.username;
  }

  setUsername(value: string): void {
    this.username = value;
    AppStorage.setOrCreate<string>('username', this.username);
    this.persist(KEY_USERNAME, this.username);
  }

  getAvatarUrl(): string {
    return this.avatarUrl;
  }

  setAvatarUrl(value: string): void {
    this.avatarUrl = value;
    AppStorage.setOrCreate<string>('avatarUrl', this.avatarUrl);
    this.persist(KEY_AVATAR_URL, this.avatarUrl);
  }

  isLoggedIn(): boolean {
    return this.loggedIn;
  }

  setLoggedIn(value: boolean): void {
    this.loggedIn = value;
    AppStorage.setOrCreate<boolean>('loggedIn', this.loggedIn);
    this.persist(KEY_LOGGED_IN, this.loggedIn);
  }

  // ---------------------------------------------------------------------------
  // 播放器
  // ---------------------------------------------------------------------------

  getPlayerQualityIndex(): number {
    return this.playerQualityIndex;
  }

  setPlayerQualityIndex(value: number): void {
    // 只接受 -1（自动）或非负下标；NaN / 其他负数统一记为自动
    const index: number = Number.isFinite(value) ? Math.floor(value) : QUALITY_AUTO;
    this.playerQualityIndex = index >= 0 ? index : QUALITY_AUTO;
    AppStorage.setOrCreate<number>('qualityIndex', this.playerQualityIndex);
    this.persist(KEY_QUALITY_INDEX, this.playerQualityIndex);
  }

  getPlayerSpeed(): number {
    return this.playerSpeed;
  }

  setPlayerSpeed(value: number): void {
    this.playerSpeed = normalizePlayerSpeed(value);
    AppStorage.setOrCreate<number>('playerSpeed', this.playerSpeed);
    this.persist(KEY_PLAYER_SPEED, this.playerSpeed);
  }

  /**
   * 播放器最底部是否常显一条细进度条（不随控制层显隐）。
   * 默认开启；关闭后播放器底部不再绘制常显进度条（控制层内的 Slider 不受影响）。
   */
  getPlayerBottomProgress(): boolean {
    return this.playerBottomProgress;
  }

  setPlayerBottomProgress(value: boolean): void {
    this.playerBottomProgress = value;
    AppStorage.setOrCreate<boolean>('playerBottomProgress', this.playerBottomProgress);
    this.persist(KEY_PLAYER_BOTTOM_PROGRESS, this.playerBottomProgress);
  }

  /** 播放内核：'exo'（默认，系统 AVPlayer）/ 'mpv'（libmpv）。 */
  getPlayerKernel(): string {
    return this.playerKernel;
  }

  setPlayerKernel(value: string): void {
    this.playerKernel = normalizePlayerKernel(value);
    AppStorage.setOrCreate<string>('playerKernel', this.playerKernel);
    this.persist(KEY_PLAYER_KERNEL, this.playerKernel);
  }

  // ---------------------------------------------------------------------------
  // 隐私
  // ---------------------------------------------------------------------------

  getWatchHistoryEnabled(): boolean {
    return this.watchHistoryEnabled;
  }

  setWatchHistoryEnabled(value: boolean): void {
    this.watchHistoryEnabled = value;
    this.persist(KEY_WATCH_HISTORY_ENABLED, this.watchHistoryEnabled);
  }

  // ---------------------------------------------------------------------------
  // 外观 / 沉浸材质
  // ---------------------------------------------------------------------------

  getUseImmersiveMaterial(): boolean {
    return this.useImmersiveMaterial;
  }

  setUseImmersiveMaterial(value: boolean): void {
    this.useImmersiveMaterial = value;
    AppStorage.setOrCreate<boolean>('useImmersiveMaterial', this.useImmersiveMaterial);
    this.persist(KEY_USE_IMMERSIVE_MATERIAL, this.useImmersiveMaterial);
  }

  getThemeColor(): string {
    return this.themeColor;
  }

  setThemeColor(value: string): void {
    this.themeColor = value.length > 0 ? value : DEFAULT_THEME_COLOR;
    AppStorage.setOrCreate<string>('themeColor', this.themeColor);
    this.persist(KEY_THEME_COLOR, this.themeColor);
  }

  // ---------------------------------------------------------------------------
  // 内部：Preferences 读写 / AppStorage 同步
  // ---------------------------------------------------------------------------

  private loadFromPreferences(): void {
    this.baseUrl = this.readString(KEY_BASE_URL, DEFAULT_BASE_URL);
    this.userAgent = this.readString(KEY_USER_AGENT, DEFAULT_USER_AGENT);
    this.backupCdn = this.readBoolean(KEY_BACKUP_CDN, false);
    this.themeMode = normalizeThemeMode(this.readString(KEY_THEME_MODE, THEME_SYSTEM));
    this.cookieString = this.readString(KEY_COOKIE_STRING, '');
    this.userId = this.readString(KEY_USER_ID, '');
    this.username = this.readString(KEY_USERNAME, '');
    this.avatarUrl = this.readString(KEY_AVATAR_URL, '');
    this.loggedIn = this.readBoolean(KEY_LOGGED_IN, false);
    this.playerQualityIndex = this.readNumber(KEY_QUALITY_INDEX, QUALITY_AUTO);
    if (this.playerQualityIndex < 0) {
      this.playerQualityIndex = QUALITY_AUTO;
    }
    this.playerSpeed = normalizePlayerSpeed(this.readNumber(KEY_PLAYER_SPEED, DEFAULT_PLAYER_SPEED));
    this.watchHistoryEnabled = this.readBoolean(KEY_WATCH_HISTORY_ENABLED, true);
    this.useImmersiveMaterial = this.readBoolean(KEY_USE_IMMERSIVE_MATERIAL, true);
    this.playerBottomProgress = this.readBoolean(KEY_PLAYER_BOTTOM_PROGRESS, true);
    this.playerKernel = normalizePlayerKernel(this.readString(KEY_PLAYER_KERNEL, PLAYER_KERNEL_EXO));
    this.themeColor = this.readString(KEY_THEME_COLOR, DEFAULT_THEME_COLOR);
    this.screenOrientationLock =
      normalizeScreenOrientationLock(this.readString(KEY_SCREEN_ORIENTATION_LOCK, SCREEN_ORIENTATION_SYSTEM));
  }

  /** 把设置值灌入 AppStorage（供 @StorageLink/@StorageProp 使用）。 */
  private syncAppStorage(): void {
    AppStorage.setOrCreate<string>('baseUrl', this.baseUrl);
    AppStorage.setOrCreate<boolean>('backupCdn', this.backupCdn);
    AppStorage.setOrCreate<string>('themeMode', this.themeMode);
    AppStorage.setOrCreate<string>('userId', this.userId);
    AppStorage.setOrCreate<string>('username', this.username);
    AppStorage.setOrCreate<string>('avatarUrl', this.avatarUrl);
    AppStorage.setOrCreate<boolean>('loggedIn', this.loggedIn);
    AppStorage.setOrCreate<number>('qualityIndex', this.playerQualityIndex);
    AppStorage.setOrCreate<number>('playerSpeed', this.playerSpeed);
    AppStorage.setOrCreate<boolean>('useImmersiveMaterial', this.useImmersiveMaterial);
    AppStorage.setOrCreate<boolean>('playerBottomProgress', this.playerBottomProgress);
    AppStorage.setOrCreate<string>('playerKernel', this.playerKernel);
    AppStorage.setOrCreate<string>('themeColor', this.themeColor);
    AppStorage.setOrCreate<string>('screenOrientationLock', this.screenOrientationLock);
  }

  private readString(key: string, defValue: string): string {
    const pref: preferences.Preferences | null = this.pref;
    if (pref === null) {
      return defValue;
    }
    try {
      const value: preferences.ValueType = pref.getSync(key, defValue);
      if (typeof value === 'string') {
        return value;
      }
      return defValue;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `读取设置 ${key} 失败: ${error.message}`);
      return defValue;
    }
  }

  private readBoolean(key: string, defValue: boolean): boolean {
    const pref: preferences.Preferences | null = this.pref;
    if (pref === null) {
      return defValue;
    }
    try {
      const value: preferences.ValueType = pref.getSync(key, defValue);
      if (typeof value === 'boolean') {
        return value;
      }
      return defValue;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `读取设置 ${key} 失败: ${error.message}`);
      return defValue;
    }
  }

  private readNumber(key: string, defValue: number): number {
    const pref: preferences.Preferences | null = this.pref;
    if (pref === null) {
      return defValue;
    }
    try {
      const value: preferences.ValueType = pref.getSync(key, defValue);
      if (typeof value === 'number') {
        return value;
      }
      return defValue;
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, `读取设置 ${key} 失败: ${error.message}`);
      return defValue;
    }
  }

  /**
   * 写入 Preferences：putSync 只进内存缓存，随后 flush 异步落盘。
   * flush 失败只记日志，不回滚内存值（下一次 setter 会再尝试）。
   */
  private persist(key: string, value: preferences.ValueType): void {
    const pref: preferences.Preferences | null = this.pref;
    if (pref === null) {
      hilog.warn(DOMAIN, TAG, `设置未初始化，${key} 仅保存在内存`);
      return;
    }
    try {
      pref.putSync(key, value);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `写入设置 ${key} 失败: ${error.message}`);
      return;
    }
    pref.flush().then(() => {
    }).catch((err: BusinessError) => {
      hilog.error(DOMAIN, TAG, `设置落盘失败 ${key}: ${err.message}`);
    });
  }
}
