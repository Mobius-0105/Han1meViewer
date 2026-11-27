/**
 * 独立全屏播放页（原生 AVPlayer + 网页降级）。
 *
 * 说明：视频详情页（pages/video/VideoPage.ets）已把播放器内嵌到页面顶部，
 * 本页保留为「全屏播放」入口（详情页右上角悬浮全屏按钮 / 播放器控制条全屏按钮会
 * Router.openPlayer 进入这里），仍可独立加载视频、网页降级、保存进度；
 * 修改本页播放逻辑时请同步检查 pages/video/InlinePlayer.ets（那边是同一套逻辑的搬运版）。
 *
 * 原生播放实现（HarmonyOS NEXT / API 12）：
 *  1. media.createAVPlayer() 得到 AVPlayer（idle）；
 *  2. XComponent(SURFACE) 的 Surface 创建后拿 surfaceId
 *     （优先用自定义 XComponentController.onSurfaceCreated，onLoad 里
 *      getXComponentSurfaceId 作为兜底，两者时机不同）；
 *  3. 切源：idle 状态下用 media.createMediaSourceWithUrl(url, headers) +
 *     avPlayer.setMediaSource(src) 设置带请求头的媒体源；任何一步抛错就退回
 *     avPlayer.url = url（无法自定义头，但能播）；
 *  4. 状态机回调里：initialized → 设置 surfaceId + prepare()；prepared → 设置倍速、
 *     seek 到续播位置、play()；
 *  5. timeUpdate 更新进度条并每 5 秒写一次本地观看记录；durationUpdate 更新总时长。
 *
 * ⚠️ 接口版本说明：任务描述里写的是 createAVMediaSourceWithUrl / AVMediaSource，
 * 但 API 12 的 @kit.MediaKit 实际提供的是 `createMediaSourceWithUrl(): MediaSource`
 * （已按 API 12 官方文档核对；createAVMediaSourceWithUrl 属于更高版本 SDK 的名称）。
 * 因此这里按 API 12 签名实现，且始终保留 avPlayer.url 兜底路径。
 *
 * 降级：sources 为空、媒体地址非法或 AVPlayer 报错时，页内 Web 组件加载
 * `<base>/watch?v=<code>`，并给出「使用网页播放」提示与「重试原生播放」入口。
 * 全屏用本地 @State 切换布局，不改窗口方向（避免无真机时无法验证的方向问题）。
 */

import { Theme, Dimens } from '../../common/Theme';
import { Router, RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { Glass } from '../../common/Glass';
import { LoadingView } from '../../components/common/Widgets';
import { media } from '@kit.MediaKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { CloudflareChallengeError, describeError } from '../../logic/net/Errors';
import { CookieStore } from '../../logic/net/CookieStore';
import { AppSettings } from '../../logic/settings/AppSettings';
import { LocalRepo } from '../../logic/db/LocalRepo';
import { HanimeVideo, VideoSource, emptyHanimeVideo } from '../../core/model/Models';
import { buildWatchUrl } from '../../core/util/Urls';
import { formatMs } from '../../core/util/Format';
import {
  isPlayableUrl,
  resolveInitialQuality,
  sliderMaxMs,
  sourceBadge,
  sourceLabel
} from '../../viewmodel/video/VideoUiUtils';
import { ErrorStateView } from '../video/StateViews';
import { notifyLibraryChanged } from '../../viewmodel/library/LibraryViewModel';

const api: HanimeApi = HanimeApi.getInstance();

/** 进度记录节流间隔 */
const SAVE_INTERVAL_MS: number = 5000;
/** 媒体加载超时：超过该时间仍未进入 initialized/prepared，就换下一种播放方式 */
const LOAD_TIMEOUT_MS: number = 12000;

/** 一档倍速：ArkTS 不能把 enum 值直接写进对象字面量数组，用 class 承载 */
class SpeedOption {
  label: string = '1.0x';
  value: number = 1.0;
  speed: media.PlaybackSpeed = media.PlaybackSpeed.SPEED_FORWARD_1_00_X;

  constructor(label: string, value: number, speed: media.PlaybackSpeed) {
    this.label = label;
    this.value = value;
    this.speed = speed;
  }
}

/**
 * 倍速档位：只使用 API 12 已确认的 PlaybackSpeed 常量
 * （SPEED_FORWARD_0_75_X / 1_00_X / 1_25_X / 1_50_X(12+) / 2_00_X）。
 */
const SPEED_OPTIONS: SpeedOption[] = [
  new SpeedOption('0.75x', 0.75, media.PlaybackSpeed.SPEED_FORWARD_0_75_X),
  new SpeedOption('1.0x', 1.0, media.PlaybackSpeed.SPEED_FORWARD_1_00_X),
  new SpeedOption('1.25x', 1.25, media.PlaybackSpeed.SPEED_FORWARD_1_25_X),
  new SpeedOption('1.5x', 1.5, media.PlaybackSpeed.SPEED_FORWARD_1_50_X),
  new SpeedOption('2.0x', 2.0, media.PlaybackSpeed.SPEED_FORWARD_2_00_X)
];

/** 默认倍速下标 = 1.0x */
const DEFAULT_SPEED_INDEX: number = 1;

/**
 * 自定义 XComponentController：在 onSurfaceCreated 里拿 surfaceId。
 * 官方文档说明 onLoad 的触发时机可能早于 Surface 真正可用，用 onSurfaceCreated 更稳。
 */
class PlayerSurfaceController extends XComponentController {
  surfaceId: string = '';
  onReady: (surfaceId: string) => void = () => {
  };

  onSurfaceCreated(surfaceId: string): void {
    this.surfaceId = surfaceId;
    this.onReady(surfaceId);
  }

  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    this.surfaceId = surfaceId;
  }

  onSurfaceDestroyed(surfaceId: string): void {
    this.surfaceId = '';
  }
}

@Component
export struct PlayerPage {
  p: RouteParam = new RouteParam();
  @StorageLink('themeMode') themeMode: string = 'system';
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State cloudflare: boolean = false;
  @State video: HanimeVideo = emptyHanimeVideo();
  @State useWeb: boolean = false;
  @State watchUrl: string = '';
  @State mediaError: string = '';
  @State qualityIndex: number = 0;
  @State speedIndex: number = DEFAULT_SPEED_INDEX;
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State playing: boolean = false;
  @State buffering: boolean = true;
  @State isFullScreen: boolean = false;
  @State playerState: string = 'idle';
  private avPlayer: media.AVPlayer | null = null;
  private surfaceController: PlayerSurfaceController = new PlayerSurfaceController();
  private webController: webview.WebviewController = new webview.WebviewController();
  private surfaceId: string = '';
  private pendingSeekMs: number = 0;
  private prepareRequested: boolean = false;
  private seeking: boolean = false;
  private lastSavedMs: number = 0;
  private disposed: boolean = false;
  /** 当前尝试播放的媒体地址（用于失败后的"带头重试"） */
  private sourceUrl: string = '';
  /** 是否已经尝试过带 Referer/UA/Cookie 的 MediaSource */
  private headersTried: boolean = false;
  /** 媒体加载超时定时器 id（-1 表示无） */
  private loadTimerId: number = -1;

  aboutToAppear(): void {
    this.surfaceController.onReady = (surfaceId: string) => {
      this.surfaceId = surfaceId;
      this.applySurface();
    };
    this.init();
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.saveProgressNow();
    this.releasePlayer();
  }

  videoCode(): string {
    if (this.p.videoCode.length > 0) {
      return this.p.videoCode;
    }
    return this.video.videoCode;
  }

  displayTitle(): string {
    if (this.p.title.length > 0) {
      return this.p.title;
    }
    if (this.video.title.length > 0) {
      return this.video.title;
    }
    return '播放器';
  }

  // ---------------------------------------------------------------------------
  // 初始化 / 媒体源
  // ---------------------------------------------------------------------------

  async init(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    this.cloudflare = false;
    try {
      const video: HanimeVideo = await api.getVideo(this.videoCode());
      if (this.disposed) {
        return;
      }
      this.video = video;
      this.watchUrl = buildWatchUrl(AppSettings.getInstance().getBaseUrl(), video.videoCode);
      this.loading = false;
      if (video.sources.length === 0) {
        this.useWeb = true;
        this.mediaError = '未解析到可播放地址，已切换为网页播放';
        Toast.show('未解析到播放地址，已切换网页播放');
        return;
      }
      this.qualityIndex = resolveInitialQuality(video.sources,
        AppSettings.getInstance().getPlayerQualityIndex());
      this.speedIndex = this.resolveSpeedIndex(AppSettings.getInstance().getPlayerSpeed());
      this.pendingSeekMs = await this.resumePosition();
      await this.loadSource(this.qualityIndex, this.pendingSeekMs);
    } catch (e) {
      if (this.disposed) {
        return;
      }
      const err: Error = e as Error;
      this.loading = false;
      this.errorMsg = describeError(err);
      this.cloudflare = err instanceof CloudflareChallengeError;
    }
  }

  async resumePosition(): Promise<number> {
    try {
      return await LocalRepo.getInstance().getResumePosition(this.videoCode());
    } catch (e) {
      return 0;
    }
  }

  resolveSpeedIndex(speed: number): number {
    let best: number = DEFAULT_SPEED_INDEX;
    let bestDiff: number = Math.abs(SPEED_OPTIONS[DEFAULT_SPEED_INDEX].value - speed);
    for (let i = 0; i < SPEED_OPTIONS.length; i++) {
      const diff: number = Math.abs(SPEED_OPTIONS[i].value - speed);
      if (diff < bestDiff) {
        bestDiff = diff;
        best = i;
      }
    }
    return best;
  }

  /** 媒体请求头：Referer / UA / Cookie（m3u8 防盗链常校验 Referer 与 Cookie） */
  buildHeaders(mediaUrl: string): Record<string, string> {
    const headers: Record<string, string> = {};
    const settings: AppSettings = AppSettings.getInstance();
    headers['Referer'] = settings.getBaseUrl();
    headers['User-Agent'] = settings.getUserAgent();
    try {
      const cookie: string = CookieStore.getInstance().getCookieHeader(mediaUrl);
      if (cookie.length > 0) {
        headers['Cookie'] = cookie;
      }
    } catch (e) {
      // Cookie 未初始化时不影响播放
    }
    return headers;
  }

  async createPlayer(): Promise<void> {
    if (this.avPlayer !== null) {
      return;
    }
    // media.createAVPlayer() 声明为可能抛 5400101（内存不足/实例上限），
    // ArkTS 静态检查要求就地处理；失败直接降级网页播放。
    let created: media.AVPlayer | null = null;
    try {
      created = await media.createAVPlayer();
    } catch (rawError) {
      const error: Error = rawError as Error;
      this.handlePlayerError('创建播放器失败：' + error.message);
      return;
    }
    if (created === null) {
      this.handlePlayerError('创建播放器失败');
      return;
    }
    const player: media.AVPlayer = created;
    if (this.disposed) {
      this.releaseExternally(player);
      return;
    }
    this.avPlayer = player;
    // 监听必须在设置资源之前注册，否则可能漏掉 initialized/prepared 事件
    player.on('stateChange', (state: string, reason: media.StateChangeReason) => {
      this.handleStateChange(state);
    });
    player.on('error', (err: BusinessError) => {
      this.handlePlayerError('播放出错（' + err.code + '）：' + err.message);
    });
    player.on('timeUpdate', (time: number) => {
      this.handleTimeUpdate(time);
    });
    player.on('durationUpdate', (duration: number) => {
      this.handleDurationUpdate(duration);
    });
    player.on('seekDone', (time: number) => {
      this.seeking = false;
    });
  }

  async loadSource(index: number, seekMs: number): Promise<void> {
    const video: HanimeVideo = this.video;
    if (index < 0 || index >= video.sources.length) {
      return;
    }
    const source: VideoSource = video.sources[index];
    if (!isPlayableUrl(source.url)) {
      this.fallbackToWeb('播放地址无效（' + source.url + '）');
      return;
    }
    this.sourceUrl = source.url;
    this.headersTried = false;
    this.pendingSeekMs = seekMs > 0 ? seekMs : 0;
    this.prepareRequested = false;
    this.buffering = true;
    this.mediaError = '';
    try {
      await this.createPlayer();
      const player: media.AVPlayer | null = this.avPlayer;
      if (player === null) {
        return;
      }
      if (player.state !== 'idle') {
        await player.reset();
      }
      // 策略：先用最兼容的 `player.url` 直接起播（站点 mp4 地址本身带签名 secure token，
      // 实测 CDN 不校验 Referer；带自定义头反而可能被 CDN 拒绝）。失败/超时再换带头的 MediaSource。
      this.attachByUrl();
    } catch (e) {
      this.handlePlayerError(describeError(e as Error));
    }
  }

  /**
   * 方式一：直接设置 url（无自定义请求头），兼容性最好。
   * 失败（同步抛错）时标记已尝试并切到带头方式；异步失败由 error 事件 / 超时兜底。
   */
  private attachByUrl(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || this.sourceUrl.length === 0) {
      return;
    }
    try {
      player.url = this.sourceUrl;
      this.scheduleLoadTimeout();
    } catch (e) {
      this.headersTried = true;
      this.tryHeadersAttach();
    }
  }

  /**
   * 方式二：带 Referer / UA / Cookie 的 MediaSource（部分 CDN 防盗链时需要）。
   * 只在 url 方式失败时尝试一次。
   */
  private async tryHeadersAttach(): Promise<void> {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || this.sourceUrl.length === 0 || this.disposed) {
      return;
    }
    try {
      if (player.state !== 'idle') {
        await player.reset();
      }
      const headers: Record<string, string> = this.buildHeaders(this.sourceUrl);
      const mediaSource: media.MediaSource = media.createMediaSourceWithUrl(this.sourceUrl, headers);
      await player.setMediaSource(mediaSource);
      this.prepareRequested = false;
      this.scheduleLoadTimeout();
    } catch (e) {
      const err: Error = e as Error;
      this.fallbackToWeb('播放地址加载失败（' + err.message + '）');
    }
  }

  /** 12 秒内没有进入 initialized/prepared/playing 就认为该方式失败，继续尝试下一种 */
  private scheduleLoadTimeout(): void {
    this.clearLoadTimer();
    this.loadTimerId = setTimeout(() => {
      this.loadTimerId = -1;
      if (this.disposed) {
        return;
      }
      const player: media.AVPlayer | null = this.avPlayer;
      if (player === null) {
        return;
      }
      const state: string = player.state;
      if (state === 'initialized' || state === 'prepared' || state === 'playing' ||
        state === 'paused' || state === 'completed' || state === 'buffering') {
        return;
      }
      if (!this.headersTried) {
        this.headersTried = true;
        this.tryHeadersAttach();
      } else {
        this.fallbackToWeb('媒体加载超时：CDN 可能在当前网络不可达（已尝试带请求头方式）');
      }
    }, LOAD_TIMEOUT_MS);
  }

  private clearLoadTimer(): void {
    if (this.loadTimerId !== -1) {
      clearTimeout(this.loadTimerId);
      this.loadTimerId = -1;
    }
  }

  // ---------------------------------------------------------------------------
  // AVPlayer 事件
  // ---------------------------------------------------------------------------

  handleStateChange(state: string): void {
    this.playerState = state;
    if (state === 'initialized') {
      this.clearLoadTimer();
      this.applySurface();
      if (!this.prepareRequested) {
        this.prepareRequested = true;
        const player: media.AVPlayer | null = this.avPlayer;
        if (player !== null) {
          player.prepare().catch((err: BusinessError) => {
            this.handlePlayerError('准备播放失败：' + err.message);
          });
        }
      }
    } else if (state === 'prepared') {
      this.clearLoadTimer();
      this.buffering = false;
      const player: media.AVPlayer | null = this.avPlayer;
      if (player === null) {
        return;
      }
      if (player.duration > 0) {
        this.durationMs = player.duration;
      }
      this.applySpeed();
      const target: number = this.pendingSeekMs;
      this.pendingSeekMs = 0;
      if (target > 0) {
        try {
          player.seek(target, media.SeekMode.SEEK_PREV_SYNC);
        } catch (e) {
          // seek 失败不影响起播
        }
      }
      player.play().catch((err: BusinessError) => {
        this.handlePlayerError('播放失败：' + err.message);
      });
    } else if (state === 'playing') {
      this.playing = true;
      this.buffering = false;
    } else if (state === 'paused') {
      this.playing = false;
    } else if (state === 'completed') {
      this.playing = false;
      this.positionMs = this.durationMs;
      this.saveProgressNow();
    } else if (state === 'error') {
      this.handlePlayerError('播放器进入错误状态');
    }
  }

  handleTimeUpdate(time: number): void {
    if (!this.seeking) {
      this.positionMs = time;
    }
    if (time - this.lastSavedMs >= SAVE_INTERVAL_MS || time < this.lastSavedMs) {
      this.lastSavedMs = time;
      this.saveProgress(time);
    }
  }

  handleDurationUpdate(duration: number): void {
    if (duration > 0) {
      this.durationMs = duration;
    }
  }

  handlePlayerError(message: string): void {
    if (this.disposed) {
      return;
    }
    this.clearLoadTimer();
    // 第一次失败（url 方式）：自动换成带 Referer/UA/Cookie 的 MediaSource 再试一次
    if (!this.headersTried && this.avPlayer !== null) {
      this.headersTried = true;
      this.tryHeadersAttach();
      return;
    }
    this.fallbackToWeb(message);
  }

  // ---------------------------------------------------------------------------
  // 窗口 / 播放控制
  // ---------------------------------------------------------------------------

  /** XComponent onLoad：getXComponentSurfaceId 兜底（部分设备 onSurfaceCreated 不回调） */
  onXComponentLoad(): void {
    try {
      const surfaceId: string = this.surfaceController.getXComponentSurfaceId();
      if (surfaceId.length > 0 && this.surfaceId.length === 0) {
        this.surfaceId = surfaceId;
        this.applySurface();
      }
    } catch (e) {
      // 拿不到 surfaceId 时等待 onSurfaceCreated
    }
  }

  applySurface(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null || this.surfaceId.length === 0) {
      return;
    }
    try {
      const state: string = player.state;
      if (state === 'initialized' || state === 'prepared' || state === 'playing' ||
        state === 'paused' || state === 'completed') {
        player.surfaceId = this.surfaceId;
      }
    } catch (e) {
      // surfaceId 设置失败时继续播放（可能只有声音）
    }
  }

  togglePlay(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const state: string = player.state;
      if (state === 'playing') {
        player.pause().catch((err: BusinessError) => {
          Toast.show('暂停失败：' + err.message);
        });
      } else if (state === 'paused' || state === 'prepared') {
        player.play().catch((err: BusinessError) => {
          Toast.show('播放失败：' + err.message);
        });
      } else if (state === 'completed') {
        player.seek(0, media.SeekMode.SEEK_PREV_SYNC);
        player.play().catch((err: BusinessError) => {
          Toast.show('播放失败：' + err.message);
        });
      }
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  seekTo(positionMs: number): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      player.seek(positionMs, media.SeekMode.SEEK_PREV_SYNC);
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  applySpeed(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const state: string = player.state;
      if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
        player.setSpeed(SPEED_OPTIONS[this.speedIndex].speed);
      }
    } catch (e) {
      // setSpeed 失败不阻断播放
    }
  }

  changeSpeed(index: number): void {
    if (index < 0 || index >= SPEED_OPTIONS.length || index === this.speedIndex) {
      return;
    }
    this.speedIndex = index;
    this.applySpeed();
    try {
      AppSettings.getInstance().setPlayerSpeed(SPEED_OPTIONS[index].value);
    } catch (e) {
      // 设置持久化失败可忽略
    }
    Toast.show('倍速 ' + SPEED_OPTIONS[index].label);
  }

  cycleSpeed(): void {
    this.changeSpeed((this.speedIndex + 1) % SPEED_OPTIONS.length);
  }

  changeQuality(index: number): void {
    if (index === this.qualityIndex || index < 0 || index >= this.video.sources.length) {
      return;
    }
    const position: number = this.positionMs;
    this.qualityIndex = index;
    Toast.show('切换到 ' + sourceLabel(this.video.sources[index], index));
    // 换 source 需要 reset → 重新 prepare，并把进度 seek 回原位置
    this.loadSource(index, position);
  }

  cycleQuality(): void {
    if (this.video.sources.length <= 1) {
      return;
    }
    this.changeQuality((this.qualityIndex + 1) % this.video.sources.length);
  }

  qualityLabel(): string {
    if (this.video.sources.length === 0) {
      return '自动';
    }
    return sourceBadge(this.video.sources[this.qualityIndex]);
  }

  fallbackToWeb(reason: string): void {
    if (this.disposed) {
      return;
    }
    this.mediaError = reason;
    this.useWeb = true;
    this.buffering = false;
    this.playing = false;
    this.releasePlayer();
    Toast.show('原生播放失败，已切换网页播放');
  }

  retryNative(): void {
    if (this.video.sources.length === 0) {
      Toast.show('没有可用的播放地址，只能网页播放');
      return;
    }
    this.useWeb = false;
    this.mediaError = '';
    this.loadSource(this.qualityIndex, this.positionMs);
  }

  /** 复制当前播放地址（排查原生播放失败是"地址/CDN 问题"还是"AVPlayer 兼容问题"） */
  copySourceUrl(): void {
    if (this.sourceUrl.length === 0) {
      Toast.show('暂无播放地址');
      return;
    }
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.sourceUrl);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        Toast.show('已复制播放地址');
      }).catch((err: BusinessError) => {
        Toast.show('复制失败：' + err.message);
      });
    } catch (e) {
      Toast.show('复制失败');
    }
  }

  /** 用应用内网页直接打开媒体地址（能加载 m3u8/mp4 说明地址与网络可用，问题在 AVPlayer） */
  openSourceUrl(): void {
    if (this.sourceUrl.length === 0) {
      Toast.show('暂无播放地址');
      return;
    }
    Router.openWeb(this.sourceUrl, '直接播放地址');
  }

  releaseExternally(player: media.AVPlayer): void {
    try {
      player.release().catch((err: BusinessError) => {
        // 释放在页面销毁后无需提示
      });
    } catch (e) {
      // 已释放
    }
  }

  releasePlayer(): void {
    this.clearLoadTimer();
    const player: media.AVPlayer | null = this.avPlayer;
    this.avPlayer = null;
    this.prepareRequested = false;
    if (player !== null) {
      this.releaseExternally(player);
    }
  }

  // ---------------------------------------------------------------------------
  // 观看进度
  // ---------------------------------------------------------------------------

  saveProgress(positionMs: number): void {
    const video: HanimeVideo = this.video;
    if (video.videoCode.length === 0) {
      return;
    }
    LocalRepo.getInstance().recordWatch(video.videoCode, video.title, video.coverUrl,
      positionMs, this.durationMs).catch((err: Error) => {
      // 进度写失败不影响播放
    });
  }

  saveProgressNow(): void {
    const video: HanimeVideo = this.video;
    if (video.videoCode.length === 0 || this.positionMs <= 0) {
      return;
    }
    LocalRepo.getInstance().recordWatch(video.videoCode, video.title, video.coverUrl,
      this.positionMs, this.durationMs).then(() => {
      // 退出时写进度成功后刷新「我的」Tab 的历史计数
      notifyLibraryChanged();
    }).catch((err: Error) => {
      // 退出时的进度写失败忽略
    });
  }

  openWebPage(): void {
    if (this.watchUrl.length === 0) {
      return;
    }
    Router.openWeb(this.watchUrl, this.displayTitle());
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @Builder
  playerContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      if (this.useWeb) {
        Web({ src: this.watchUrl, controller: this.webController })
          .domStorageAccess(true)
          .javaScriptAccess(true)
          .mixedMode(MixedMode.All)
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black);
      } else {
        XComponent({
          id: 'hanime_player',
          type: XComponentType.SURFACE,
          controller: this.surfaceController
        })
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
          .onLoad(() => {
            this.onXComponentLoad();
          });
      }

      if (!this.useWeb && this.buffering && this.playerState !== 'playing') {
        Column() {
          LoadingProgress()
            .width(36)
            .height(36)
            .color('#FFFFFF');
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      }

      // 顶部深色渐变：让悬浮返回按钮/状态条在亮画面上也有足够对比度
      Column()
        .width('100%')
        .height(84)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['#66000000', 0.0], ['#00000000', 1.0]]
        })
        .align(Alignment.Top)
        .hitTestBehavior(HitTestMode.None);

      this.controlBar();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black);
  }

  @Builder
  controlBar() {
    Column() {
      Row() {
        Text(formatMs(this.positionMs))
          .fontSize(11)
          .fontColor('#E6FFFFFF');
        Slider({
          value: this.positionMs,
          min: 0,
          max: sliderMaxMs(this.durationMs),
          step: 1,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .margin({ left: 10, right: 10 })
          .selectedColor(Theme.colors().primary)
          .trackColor('#4DFFFFFF')
          .blockColor('#FFFFFF')
          .trackThickness(3)
          .onChange((value: number, mode: SliderChangeMode) => {
            if (mode === SliderChangeMode.Begin) {
              this.seeking = true;
              this.positionMs = value;
            } else if (mode === SliderChangeMode.Moving) {
              this.positionMs = value;
            } else {
              this.positionMs = value;
              this.seeking = false;
              this.seekTo(value);
            }
          });
        Text(formatMs(this.durationMs))
          .fontSize(11)
          .fontColor('#E6FFFFFF');
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10 })
      .alignItems(VerticalAlign.Center);

      Row() {
        Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
          .width(22)
          .height(22)
          .fillColor('#FFFFFF')
          .margin({ right: 6 })
          .onClick(() => {
            this.togglePlay();
          });
        Text(SPEED_OPTIONS[this.speedIndex].label)
          .fontSize(12)
          .fontColor('#FFFFFF')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(12)
          .backgroundColor('#26FFFFFF')
          .onClick(() => {
            this.cycleSpeed();
          });
        Text(this.qualityLabel())
          .fontSize(12)
          .fontColor('#FFFFFF')
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(12)
          .backgroundColor('#26FFFFFF')
          .margin({ left: 8 })
          .onClick(() => {
            this.cycleQuality();
          });
        Blank();
        if (!this.useWeb) {
          Text('网页')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 8, right: 8, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor('#26FFFFFF')
            .onClick(() => {
              this.openWebPage();
            });
        }
        Image($r('app.media.ic_fullscreen'))
          .width(20)
          .height(20)
          .fillColor('#FFFFFF')
          .margin({ left: 10 })
          .onClick(() => {
            this.isFullScreen = !this.isFullScreen;
          });
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 12 })
      .alignItems(VerticalAlign.Center);
    }
    .width('100%')
    .linearGradient({
      direction: GradientDirection.Top,
      colors: [['#E6000000', 0.0], ['#00000000', 1.0]]
    });
  }

  @Builder
  infoPanel() {
    Scroll() {
      Column() {
        Column() {
          Text(this.displayTitle())
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');

          if (this.useWeb) {
            Column() {
              Row() {
                Text('使用网页播放：' + (this.mediaError.length > 0 ? this.mediaError : '原生播放器不可用'))
                  .fontSize(12)
                  .fontColor('#E6FFFFFF')
                  .layoutWeight(1)
                  .maxLines(3);
                Button('重试原生')
                  .fontSize(12)
                  .height(30)
                  .borderRadius(15)
                  .margin({ left: 8 })
                  .backgroundColor('#1AFFFFFF')
                  .fontColor('#FFFFFF')
                  .border({ width: 0.8, color: '#4DFFFFFF' })
                  .onClick(() => {
                    this.retryNative();
                  });
              }
              .width('100%')
              .alignItems(VerticalAlign.Center);
              // 排查入口：复制/打开当前媒体地址（判断是 CDN/地址问题还是 AVPlayer 解码问题）
              if (this.sourceUrl.length > 0) {
                Row() {
                  Button('复制播放地址')
                    .fontSize(12)
                    .height(30)
                    .borderRadius(15)
                    .backgroundColor('#1AFFFFFF')
                    .fontColor('#FFFFFF')
                    .border({ width: 0.8, color: '#4DFFFFFF' })
                    .onClick(() => {
                      this.copySourceUrl();
                    });
                  Button('浏览器打开')
                    .fontSize(12)
                    .height(30)
                    .borderRadius(15)
                    .margin({ left: 8 })
                    .backgroundColor('#1AFFFFFF')
                    .fontColor('#FFFFFF')
                    .border({ width: 0.8, color: '#4DFFFFFF' })
                    .onClick(() => {
                      this.openSourceUrl();
                    });
                }
                .width('100%')
                .margin({ top: 8 });
              }
            }
            .width('100%')
            .margin({ top: 10 })
            .padding(10)
            .borderRadius(16)
            .backgroundColor('#99000000')
            .backgroundBlurStyle(Glass.CHIP_BLUR)
            .border({ width: 0.8, color: '#4DFFFFFF' });
          } else if (this.mediaError.length > 0) {
            Text(this.mediaError)
              .fontSize(Dimens.captionSize)
              .fontColor('#FF6B60')
              .width('100%')
              .padding({ top: 8 });
          }

          if (this.video.sources.length > 0) {
            Text('清晰度')
              .fontSize(12)
              .fontColor('#B3FFFFFF')
              .width('100%')
              .margin({ top: 14 });
            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.video.sources, (source: VideoSource, index: number) => {
                Text(sourceLabel(source, index))
                  .fontSize(12)
                  .fontColor(index === this.qualityIndex ? Theme.colors().onPrimary : '#E6FFFFFF')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(12)
                  .backgroundColor(index === this.qualityIndex ? Theme.colors().primary : '#26FFFFFF')
                  .border({
                    width: index === this.qualityIndex ? 0 : 0.8,
                    color: '#33FFFFFF'
                  })
                  .margin({ right: 8, bottom: 8 })
                  .onClick(() => {
                    this.changeQuality(index);
                  });
              }, (source: VideoSource, index: number) => source.url + index);
            }
            .width('100%');
          }

          Text('倍速')
            .fontSize(12)
            .fontColor('#B3FFFFFF')
            .width('100%')
            .margin({ top: 4 });
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(SPEED_OPTIONS, (option: SpeedOption, index: number) => {
              Text(option.label)
                .fontSize(12)
                .fontColor(index === this.speedIndex ? Theme.colors().onPrimary : '#E6FFFFFF')
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(12)
                .backgroundColor(index === this.speedIndex ? Theme.colors().primary : '#26FFFFFF')
                .border({
                  width: index === this.speedIndex ? 0 : 0.8,
                  color: '#33FFFFFF'
                })
                .margin({ right: 8, bottom: 8 })
                .onClick(() => {
                  this.changeSpeed(index);
                });
            }, (option: SpeedOption) => option.label);
          }
          .width('100%');

          Text('提示：原生播放失败或没有解析到播放地址时，会自动改用站点网页播放器；' +
            '网页播放可完成登录、评论等站点操作。')
            .fontSize(Dimens.captionSize)
            .fontColor('#8CFFFFFF')
            .width('100%')
            .margin({ top: 8 });
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .borderRadius(16)
        .backgroundColor('#B3000000')
        .backgroundBlurStyle(Glass.BAR_BLUR)
        .border({ width: 0.8, color: '#4DFFFFFF' })
        .shadow({ radius: 20, color: '#66000000', offsetX: 0, offsetY: 8 });
      }
      .width('100%')
      .padding({
        left: Dimens.pagePadding,
        right: Dimens.pagePadding,
        top: 12,
        bottom: 24
      });
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Off);
  }

  /** 顶部悬浮返回按钮：圆形深色玻璃，盖在视频画面上 */
  @Builder
  floatingBack() {
    Row() {
      Image($r('app.media.ic_back'))
        .width(18)
        .height(18)
        .fillColor('#FFFFFF');
    }
    .width(38)
    .height(38)
    .borderRadius(19)
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#66000000')
    .backgroundBlurStyle(Glass.CHIP_BLUR)
    .border({ width: 0.8, color: '#66FFFFFF' })
    .margin({ left: 12, top: 10 })
    .onClick(() => {
      Router.pop();
    });
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.loading) {
          Column() {
            LoadingView({ text: '加载播放信息…' });
          }
          .width('100%')
          .layoutWeight(1);
        } else if (this.errorMsg.length > 0) {
          Column() {
            ErrorStateView({
              message: this.errorMsg,
              cloudflare: this.cloudflare,
              baseUrl: AppSettings.getInstance().getBaseUrl(),
              onRetry: () => {
                this.init();
              }
            });
          }
          .width('100%')
          .layoutWeight(1);
        } else {
          if (this.isFullScreen) {
            Column() {
              this.playerContent();
            }
            .width('100%')
            .layoutWeight(1);
          } else {
            Column() {
              this.playerContent();
            }
            .width('100%')
            .aspectRatio(16 / 9);
          }

          if (!this.isFullScreen) {
            this.infoPanel();
          }
        }
      }
      .width('100%')
      .height('100%');

      this.floatingBack();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.colors().playerBg);
  }
}
