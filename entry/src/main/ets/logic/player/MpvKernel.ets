/**
 * mpv 播放内核封装（`@mpv-ohos/mpv-arkts` 1.0.0，本地 HAR 依赖）。
 *
 * 职责：把 mpv 那套「Player（本身是 XComponentController）→ open(Media) →
 * 读 player.state / 订阅 player.stream」的声明式 API，收敛成与
 * {@link ../player/IjkKernel} 完全同构的小内核：上层（InlinePlayer）只做
 * create/play/pause/seek/setSpeed/setVolume/setLooping/reload/release，
 * 并通过一组回调拿到状态 / 进度 / 缓冲 / 画幅 / 错误。对外类型名统一换成 Mpv 前缀，
 * 但字段、方法签名、状态字符串与 IJK 版本逐一对齐，便于整段替换。
 *
 * 关键事实（以解包后的 HAR 声明为准，见 mpvhar/package 下这些文件）：
 *  - `src/main/ets/Player.d.ets`：`Player extends XComponentController`，所以**播放器实例本身就是
 *    XComponent 的 controller**——页面把它交给 `XComponent({ controller })` 即可，不需要
 *    IJK 那种 `libraryname + setContext + native_setup` 的手工通路；surface 的生死由
 *    `onSurfaceCreated/onSurfaceChanged/onSurfaceDestroyed` 驱动，不能手动调。
 *  - `src/main/ets/models/PlayerState.d.ets`：`position / duration` 单位是**秒**，
 *    `volume` 域是 **0~130**；本封装对外的单位仍是**毫秒**和 **0~1**（换算集中在
 *    pollOnce() / setVolume() / seekInternal() 三处，见行内注释）。
 *  - `src/main/ets/models/PlaylistMode.d.ets`：枚举只有 `None / File / Playlist / Random`，
 *    **没有** `Loop` / `Single`；单视频循环对应 `PlaylistMode.File`。
 *  - mpv 没有「seek 完成」回调：seek 只下发目标，完成与否要靠轮询实测位置判断
 *    （±400ms 内或 1.5s 超时），见 pollOnce() 的 seeking 分支。
 *  - `player.state` 是 `@ObservedV2` 对象，但本内核只做 300ms 轮询读取（不依赖 @State 刷新），
 *    因为上层需要的是「周期性 onPosition 上报」来落盘播放进度，与 IJK 版本保持一致。
 *
 * 生命周期：create → (等待 surface) → preparing → prepared → playing ⇄ paused → completed；
 * 页面销毁调 release()；切换清晰度调 reload()（同一个 Player 重新 open + 旧进度 seek）。
 */

import { Media, MediaOptions, Player, PlayerConfig, PlaylistMode, PlayerState } from '@mpv-ohos/mpv-arkts';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'MpvKernel';

/** 状态 / 进度轮询间隔（毫秒）：mpv 事件流不带可靠进度，上层落盘进度依赖周期上报 */
const POLL_INTERVAL_MS: number = 300;
/** seek 判定阈值（毫秒）：实测位置与目标相差在此范围内即认为 seek 完成 */
const SEEK_TOLERANCE_MS: number = 400;
/** seek 等待上限（毫秒）：超时直接收尾，避免 UI 一直停在 seeking（mpv 无 seekComplete 回调） */
const SEEK_TIMEOUT_MS: number = 1500;
/** 音量换算系数：对外 0~1，mpv 是 0~130 */
const VOLUME_SCALE: number = 100;

/** 内核状态机（字符串字面量联合：ArkTS 禁止 enum，与 IjkKernelState 逐字一致） */
export type MpvKernelState = 'idle' | 'waitingSurface' | 'preparing' | 'prepared' |
  'playing' | 'paused' | 'completed' | 'error';

/** 创建内核时的行为参数（一次性快照；运行中通过 setSpeed/setVolume/setLooping 修改） */
export interface MpvPlaybackOptions {
  /** 硬解：构造 PlayerConfig 时给 hwdec（config 只能在构造时下发，见 buildPlayer） */
  hardDecode: boolean;
  /** 起播倍速（1.0 = 原速；mpv 自带音调保持） */
  speed: number;
  /** 播放器自身增益 0~1（mpv 侧是 0~130，下发时 ×100） */
  volume: number;
  /** 单视频循环（PlaylistMode.File） */
  looping: boolean;
  /** 起播位置（毫秒；0 = 从头） */
  startPositionMs: number;
  /** prepared 后是否自动起播 */
  autoplay: boolean;
  /**
   * 续播「接近结尾」保护：> 0 且起播点距结尾小于该值时回退到 0，避免一进页面就 completed。
   * 只在「从观看历史续播」时由调用方传非 0，切换清晰度保位置时不传。
   */
  resumeEndGuardMs: number;
}

function defaultMpvPlaybackOptions(): MpvPlaybackOptions {
  const options: MpvPlaybackOptions = {
    hardDecode: true,
    speed: 1,
    volume: 1,
    looping: false,
    startPositionMs: 0,
    autoplay: true,
    resumeEndGuardMs: 0
  };
  return options;
}

/** catch 里拿错误文案（ArkTS 不允许 catch 参数标注类型，统一在这里收口） */
function messageOf(error: Error): string {
  if (error.message !== undefined && error.message.length > 0) {
    return error.message;
  }
  return '未知错误';
}

/** 毫秒位置归一化：负数 / NaN / Infinity 一律归 0 */
function normalizeMs(value: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return 0;
  }
  return Math.round(value);
}

/** 数值夹取（音量 0~1、缓冲百分比 0~100 共用） */
function clampRange(value: number, min: number, max: number): number {
  if (!Number.isFinite(value)) {
    return min;
  }
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

export class MpvKernel {
  // ---------------------------------------------------------------------------
  // 对外状态（InlinePlayer 直接读这几个字段）
  // ---------------------------------------------------------------------------
  /** 内核状态机：idle → waitingSurface → preparing → prepared → playing ⇄ paused → completed / error */
  state: MpvKernelState = 'idle';
  /** 当前播放位置（毫秒；轮询 / seek 目标同步更新） */
  positionMs: number = 0;
  /** 视频总时长（毫秒；prepared 后从 state.duration 秒换算） */
  durationMs: number = 0;
  /** 是否正在缓冲（player.state.buffering） */
  buffering: boolean = false;
  /** 已缓冲百分比 0~100（player.state.bufferingPercentage；只做诊断 / 预留） */
  bufferedPercent: number = 0;
  /** 视频宽（state.videoParams.w；未知时 0） */
  videoWidth: number = 0;
  /** 视频高（state.videoParams.h；未知时 0） */
  videoHeight: number = 0;
  /** 最近一次错误文案（error 状态时有效） */
  errorMessage: string = '';
  /** 是否已经出过第一帧（mpv 无「首帧」事件，用「在播且位置 > 0」近似） */
  hasRenderedFrame: boolean = false;

  // ---------------------------------------------------------------------------
  // 回调（由 InlinePlayer 在创建后赋值）
  // ---------------------------------------------------------------------------
  /** 状态变化（含 error；UI 侧据此映射 @State） */
  onStateChange: (state: MpvKernelState) => void = () => {
  };
  /** 进度 / 时长更新（300ms 轮询；seeking 期间上报 seek 目标而不是旧位置） */
  onPosition: (positionMs: number, durationMs: number) => void = () => {
  };
  /** 缓冲开始 / 结束 */
  onBufferingChange: (buffering: boolean) => void = () => {
  };
  /** 解码画幅（父页面据此做容器比例自适应 + 画面 letterbox） */
  onVideoSizeChange: (width: number, height: number) => void = () => {
  };
  /** 错误（上层据此做自动重试 / 降级 AVPlayer） */
  onError: (message: string) => void = () => {
  };

  // ---------------------------------------------------------------------------
  // 内部字段
  // ---------------------------------------------------------------------------
  /** 当前 mpv 播放器实例（同时是 XComponent 的 controller；release / 重建后为 null） */
  private player: Player | null = null;
  /** XComponent onLoad 给的 context（mpv 不需要它建 surface，只用来判断 surface 是否就绪） */
  private surfaceContext: object | null = null;
  /** XComponent 的 id（契约保留字段；mpv 由 onSurfaceCreated 直接给 surfaceId，不依赖它） */
  private xcomponentId: string = '';
  /** 当前视频源（reload / hasSource 用） */
  private sourceUrl: string = '';
  /** 当前请求头（reload 用；mpv 通过 Media(httpHeaders) 下发） */
  private headers: Map<string, string> | null = null;
  /** 创建参数快照 */
  private options: MpvPlaybackOptions = defaultMpvPlaybackOptions();
  /** 尚未消费的起播 / seek 目标（prepared 后统一 seek） */
  private pendingStartPositionMs: number = 0;
  /** 倍速（明文保存，prepared 后重新下发，避免 open 之后被 mpv 复位） */
  private playbackSpeed: number = 1;
  /** 播放器自身增益 0~1 */
  private playbackVolume: number = 1;
  /** 是否循环（mpv 侧 PlaylistMode.File） */
  private looping: boolean = false;
  /** 是否正在等待 seek 落地（期间轮询不覆盖 seek 目标） */
  private seeking: boolean = false;
  /** 本次 seek 的目标 / 起始时间（mpv 无 seekComplete，只能靠实测位置或超时收尾） */
  private seekTargetMs: number = 0;
  private seekStartedAt: number = 0;
  /** 轮询定时器 id（-1 = 无） */
  private pollTimerId: number = -1;
  /** 是否已经发过 prepared（duration 先到、playing 后到时也只发一次） */
  private preparedEmitted: boolean = false;
  /** 本次加载是否已经报过错（同一次失败只发一次 onError） */
  private lastErrorEmitted: boolean = false;
  /** 是否已 release（释放后所有控制方法静默返回） */
  private released: boolean = false;

  // ---------------------------------------------------------------------------
  // 创建 / 重新绑定 surface
  // ---------------------------------------------------------------------------

  /**
   * 供页面把 XComponent 的 controller 绑定到内核。
   *
   * mpv 的 `Player extends XComponentController`（见 Player.d.ets），所以这里直接返回播放器实例；
   * XComponent 用 `controller` 变体创建后，surface 由框架回调到 Player.onSurfaceCreated，
   * 内核不需要也无法手动介入。
   *
   * 注意：**必须先 create() 再取 controller()**——create 之前返回 null（页面需要据此决定
   * 何时构建 XComponent，构建之后再换 controller 不会被框架接受）。
   */
  controller(): XComponentController | null {
    const player: Player | null = this.player;
    if (player === null) {
      return null;
    }
    return player;
  }

  /**
   * 创建并开始加载视频源。
   *
   * @param context XComponent onLoad 回调拿到的 context；页面刚创建时可能还没拿到（传 null，
   *                内核停在 waitingSurface，等 {@link attachSurface} 后自动 open）
   * @param xcomponentId XComponent 的 id（契约保留；mpv 不需要）
   * @param url 视频地址（http/https/m3u8 等）
   * @param headers HTTP 请求头（Referer / UA / Cookie）
   * @param options 起播参数快照
   * @returns false 表示同步初始化失败（已回调 onError）
   */
  create(context: object | null, xcomponentId: string, url: string,
    headers: Map<string, string>, options: MpvPlaybackOptions): boolean {
    this.teardown();
    this.released = false;
    this.lastErrorEmitted = false;
    this.surfaceContext = context;
    this.xcomponentId = xcomponentId;
    this.sourceUrl = url;
    this.headers = headers;
    this.options = options;
    this.playbackSpeed = options.speed > 0 ? options.speed : 1;
    this.playbackVolume = clampRange(options.volume, 0, 1);
    this.looping = options.looping;
    this.pendingStartPositionMs = normalizeMs(options.startPositionMs);
    this.positionMs = this.pendingStartPositionMs;
    this.durationMs = 0;
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.bufferedPercent = 0;
    this.hasRenderedFrame = false;
    this.errorMessage = '';
    this.seeking = false;
    this.preparedEmitted = false;
    // 播放器必须在这一步就建出来：页面的 XComponent 要拿 controller() 绑定，
    // 而 PlayerConfig（hwdec）只能在构造时下发，所以这里一次性建好。
    const player: Player | null = this.buildPlayer(options.hardDecode);
    if (player === null) {
      return false;
    }
    if (context === null) {
      // 同 IJK 语义：surface 还没到，先挂起；attachSurface 后再 open
      this.state = 'waitingSurface';
      this.emitState();
      return true;
    }
    return this.openSource();
  }

  /**
   * XComponent onLoad 后绑定 context（surface 就绪）。
   *
   *  - 内核还在 waitingSurface（页面先 create、surface 后 ready）：立刻 open；
   *  - 已经在播放（surface 被重建，如窗口旋转）：mpv 内部会自己接新 surface，
   *    这里只更新 context，不做重建。
   */
  attachSurface(context: object): void {
    if (this.released) {
      return;
    }
    this.surfaceContext = context;
    if (this.player === null) {
      return;
    }
    if (this.state === 'waitingSurface') {
      this.openSource();
    }
  }

  /** 是否已经指定过视频源（上层据此决定 create / reload） */
  hasSource(): boolean {
    return !this.released && this.sourceUrl.length > 0;
  }

  // ---------------------------------------------------------------------------
  // 播放控制
  // ---------------------------------------------------------------------------

  /** 播放 / 恢复（completed 后调用会先回到 0 再播） */
  play(): void {
    if (this.released) {
      return;
    }
    const player: Player | null = this.player;
    if (player === null || !this.isOperable()) {
      return;
    }
    try {
      if (this.state === 'completed') {
        // 播完重播：mpv 在 eof 状态下 play() 不会自动回卷，先 seek(0) 再 play
        this.seekInternal(0);
      }
      player.play();
      this.buffering = false;
      this.state = 'playing';
      this.startPolling();
      this.emitState();
      this.emitBuffering();
    } catch (e) {
      this.failWith('mpv 播放失败：' + messageOf(e as Error));
    }
  }

  /** 暂停 */
  pause(): void {
    if (this.released) {
      return;
    }
    const player: Player | null = this.player;
    if (player === null || this.state !== 'playing') {
      return;
    }
    try {
      player.pause();
      this.state = 'paused';
      this.buffering = false;
      this.emitState();
      this.emitBuffering();
    } catch (e) {
      this.failWith('mpv 暂停失败：' + messageOf(e as Error));
    }
  }

  /** 是否正在播放（以本封装的状态为准，避免读取 native 时的时序抖动） */
  isPlaying(): boolean {
    return this.state === 'playing';
  }

  /** 是否正在等待 seek 落地（上层据此避免把 UI 的 seeking 状态误清掉） */
  isSeeking(): boolean {
    return this.seeking;
  }

  /**
   * seek 到指定毫秒。
   *
   *  - 未 prepared：先记成起播位置，prepared 后统一下发；
   *  - prepared 之后：clamp 到 [0, duration] 后下发 player.seek(秒)，
   *    并把 seeking 置 true、positionMs 钉在目标值，等轮询实测到位（或 1.5s 超时）收尾。
   */
  seek(positionMs: number): void {
    if (this.released) {
      return;
    }
    const target: number = this.clampTarget(positionMs);
    this.positionMs = target;
    const player: Player | null = this.player;
    if (player === null || !this.isOperable()) {
      this.pendingStartPositionMs = target;
      return;
    }
    this.seekInternal(target);
  }

  /** 设置倍速（mpv 自带音调保持，n<=0 忽略） */
  setSpeed(speed: number): void {
    if (this.released || !Number.isFinite(speed) || speed <= 0) {
      return;
    }
    this.playbackSpeed = speed;
    const player: Player | null = this.player;
    if (player === null || !this.isOperable()) {
      return;
    }
    this.applySpeed(player);
  }

  /** 设置播放器自身增益（0~1；mpv 侧是 0~130，见 setVolume 的 ×100 换算） */
  setVolume(volume: number): void {
    if (this.released || !Number.isFinite(volume)) {
      return;
    }
    this.playbackVolume = clampRange(volume, 0, 1);
    const player: Player | null = this.player;
    if (player === null || !this.isOperable()) {
      return;
    }
    this.applyVolume(player);
  }

  /** 设置单视频循环（mpv 内部循环，不回调 completed） */
  setLooping(looping: boolean): void {
    if (this.released) {
      return;
    }
    this.looping = looping;
    const player: Player | null = this.player;
    if (player === null || !this.isOperable()) {
      return;
    }
    this.applyLoopMode(player);
  }

  /**
   * 重新加载新的视频源（切换清晰度 / 自动重试兜底）：沿用同一个 Player 实例重新 open，
   * 起播位置在 prepared 后统一 seek，保持旧进度。
   *
   * @returns false 表示同步失败（已回调 onError）
   */
  reload(url: string, headers: Map<string, string>, positionMs: number): boolean {
    if (this.released) {
      return false;
    }
    this.sourceUrl = url;
    this.headers = headers;
    this.pendingStartPositionMs = normalizeMs(positionMs);
    this.positionMs = this.pendingStartPositionMs;
    this.durationMs = 0;
    this.bufferedPercent = 0;
    this.hasRenderedFrame = false;
    this.seeking = false;
    this.preparedEmitted = false;
    this.lastErrorEmitted = false;
    this.errorMessage = '';
    const player: Player | null = this.player;
    if (player === null || this.state === 'error') {
      // 播放器还没建 / 已进入 error（native 侧可能已不可用）：重建最稳
      this.destroyPlayer();
      const created: Player | null = this.buildPlayer(this.options.hardDecode);
      if (created === null) {
        return false;
      }
      if (this.surfaceContext === null) {
        this.state = 'waitingSurface';
        this.emitState();
        return true;
      }
      return this.openSource();
    }
    // mpv 的 open 会替换当前播放列表，不需要 stop / 重建
    return this.openSource();
  }

  /** 释放播放器与轮询（幂等；页面销毁 / 降级 AVPlayer 前调用） */
  release(): void {
    if (this.released) {
      return;
    }
    this.released = true;
    this.stopPolling();
    this.destroyPlayer();
    this.surfaceContext = null;
    this.sourceUrl = '';
    this.headers = null;
    this.options = defaultMpvPlaybackOptions();
    this.state = 'idle';
    this.positionMs = 0;
    this.durationMs = 0;
    this.buffering = false;
    this.bufferedPercent = 0;
    this.videoWidth = 0;
    this.videoHeight = 0;
    this.hasRenderedFrame = false;
    this.errorMessage = '';
    this.seeking = false;
    this.seekTargetMs = 0;
    this.preparedEmitted = false;
    this.pendingStartPositionMs = 0;
    this.lastErrorEmitted = false;
    this.emitState();
  }

  // ---------------------------------------------------------------------------
  // 内部：构造 / 打开 / 选项下发
  // ---------------------------------------------------------------------------

  /** 按 hardDecode 构造 Player（PlayerConfig 只能在构造时给，见 PlayerConfig.d.ets） */
  private buildPlayer(hardDecode: boolean): Player | null {
    try {
      // hwdec：硬解开关；osc 关掉——播放器自带控制层（InlinePlayer），
      // 不需要 mpv 的 on-screen-controller 再画一套
      const config: PlayerConfig = new PlayerConfig({ hwdec: hardDecode, osc: false });
      const player: Player = new Player(config);
      player.stream.error.listen((message: string): void => {
        this.handleNativeError(message);
      });
      this.player = player;
      return player;
    } catch (e) {
      this.failWith('mpv 播放器初始化失败：' + messageOf(e as Error));
      return null;
    }
  }

  /** 用当前 sourceUrl / headers 打开媒体（play=false，起播由 prepared 后统一控制） */
  private openSource(): boolean {
    const player: Player | null = this.player;
    if (player === null) {
      return false;
    }
    if (this.sourceUrl.length === 0) {
      this.state = 'waitingSurface';
      this.emitState();
      return false;
    }
    try {
      const mediaOptions: MediaOptions = {};
      const headers: Map<string, string> | null = this.headers;
      if (headers !== null && headers.size > 0) {
        mediaOptions.httpHeaders = headers;
      }
      // play=false：先只解析，prepared 后按 options.autoplay 决定是否起播，
      // 这样「续播 seek → 倍速 / 音量 / 循环 → 起播」的顺序是确定的
      player.open(new Media(this.sourceUrl, mediaOptions), false);
      this.state = 'preparing';
      this.buffering = true;
      this.preparedEmitted = false;
      this.positionMs = this.pendingStartPositionMs;
      this.durationMs = 0;
      this.hasRenderedFrame = false;
      this.startPolling();
      this.emitState();
      this.emitBuffering();
      // 倍速 / 音量 / 循环尽早下发（mpv 允许在 open 之后、起播之前设置）
      this.applySpeed(player);
      this.applyVolume(player);
      this.applyLoopMode(player);
      return true;
    } catch (e) {
      this.failWith('mpv 重新加载失败：' + messageOf(e as Error));
      return false;
    }
  }

  /** 下发倍速（失败只告警，不影响播放） */
  private applySpeed(player: Player): void {
    try {
      player.setSpeed(this.playbackSpeed);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setSpeed 失败: %{public}s', messageOf(e as Error));
    }
  }

  /**
   * 下发音量：对外 0~1 → mpv 0~130（×100）。
   *
   * 静音统一用 setVolume(0)（上层传 0），不引入 mute 相关 API——包内 Player 也没有 mute 方法
   * （见 Player.d.ets）。
   */
  private applyVolume(player: Player): void {
    try {
      player.setVolume(this.playbackVolume * VOLUME_SCALE);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setVolume 失败: %{public}s', messageOf(e as Error));
    }
  }

  /**
   * 下发循环模式：mpv 没有 Loop/Single，单视频循环是 PlaylistMode.File
   * （见 PlaylistMode.d.ets：None / File / Playlist / Random）。
   */
  private applyLoopMode(player: Player): void {
    try {
      player.setPlaylistMode(this.looping ? PlaylistMode.File : PlaylistMode.None);
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'setPlaylistMode 失败: %{public}s', messageOf(e as Error));
    }
  }

  // ---------------------------------------------------------------------------
  // 内部：seek（mpv 无 seekComplete，靠轮询实测位置收尾）
  // ---------------------------------------------------------------------------

  /** seek 目标夹取：duration 已知时限制在 [0, duration]，未知时只做下界保护 */
  private clampTarget(positionMs: number): number {
    let target: number = normalizeMs(positionMs);
    if (this.durationMs > 0 && target > this.durationMs) {
      target = this.durationMs;
    }
    return target;
  }

  /** 下发 seek（毫秒 → 秒）并进入「等待落地」状态 */
  private seekInternal(target: number): void {
    const player: Player | null = this.player;
    if (player === null) {
      this.pendingStartPositionMs = target;
      return;
    }
    this.seekTargetMs = target;
    this.seekStartedAt = Date.now();
    this.seeking = true;
    // 单位换算：对外毫秒 → mpv 秒（Player.seek 的参数是绝对秒，见 Player.d.ets）
    this.positionMs = target;
    try {
      player.seek(target / 1000);
    } catch (e) {
      this.seeking = false;
      this.failWith('mpv 跳转失败：' + messageOf(e as Error));
    }
  }

  /** seek 收尾：到位则采用实测位置，超时则保留目标值（避免 UI 进度条回跳） */
  private finishSeek(nativeMs: number, reached: boolean): void {
    this.seeking = false;
    if (reached) {
      this.positionMs = this.clampPosition(nativeMs);
    } else {
      this.positionMs = this.seekTargetMs;
    }
  }

  // ---------------------------------------------------------------------------
  // 内部：轮询 / 状态同步
  // ---------------------------------------------------------------------------

  /** 启动 300ms 轮询（重复调用会先清掉旧的） */
  private startPolling(): void {
    this.stopPolling();
    this.pollTimerId = setInterval(() => {
      this.pollOnce();
    }, POLL_INTERVAL_MS);
  }

  private stopPolling(): void {
    if (this.pollTimerId !== -1) {
      clearInterval(this.pollTimerId);
      this.pollTimerId = -1;
    }
  }

  /**
   * 轮询一次：读 player.state，换算单位 → 同步画幅 / 缓冲 / 位置 → 推进状态机 → 上报进度。
   *
   * 位置**必须**每轮都上报（哪怕 native 没有进度事件）：上层靠 onPosition 落盘观看进度。
   */
  private pollOnce(): void {
    const player: Player | null = this.player;
    if (player === null || this.released) {
      return;
    }
    let native: PlayerState;
    try {
      native = player.state;
    } catch (e) {
      // 状态切换中读取失败不改变状态机，下一轮重试
      return;
    }
    // 时长：mpv 秒 → 对外毫秒
    const durationSec: number = native.duration;
    if (Number.isFinite(durationSec) && durationSec > 0) {
      this.durationMs = Math.round(durationSec * 1000);
    }
    if (native.buffering !== this.buffering) {
      this.buffering = native.buffering;
      this.emitBuffering();
    }
    this.bufferedPercent = clampRange(native.bufferingPercentage, 0, 100);
    this.syncVideoSize(native);
    // 位置：mpv 秒 → 对外毫秒（seek 期间保持目标值，不被旧位置覆盖）
    const nativeMs: number = Number.isFinite(native.position) ? Math.round(native.position * 1000) : 0;
    if (this.seeking) {
      const reached: boolean = Math.abs(nativeMs - this.seekTargetMs) <= SEEK_TOLERANCE_MS;
      const timedOut: boolean = Date.now() - this.seekStartedAt >= SEEK_TIMEOUT_MS;
      if (reached || timedOut) {
        this.finishSeek(nativeMs, reached);
      }
    } else if (this.state !== 'completed') {
      this.positionMs = this.clampPosition(nativeMs);
    }
    this.syncState(native);
    if (!this.hasRenderedFrame && native.playing && this.positionMs > 0) {
      this.hasRenderedFrame = true;
    }
    this.onPosition(this.positionMs, this.durationMs);
  }

  /**
   * 状态映射（上层只认这 5 个状态）：
   *  - 首次拿到时长 / 位置 → prepared（只发一次，覆盖「duration 先到、playing 后到」）
   *  - playing=true → playing；false → paused
   *  - eof=true 且非循环 → completed（循环时 mpv 自己续播，不能报 completed）
   */
  private syncState(native: PlayerState): void {
    if (!this.preparedEmitted) {
      const ready: boolean = this.durationMs > 0 || this.positionMs > 0;
      if (!ready) {
        if (this.state !== 'preparing') {
          this.state = 'preparing';
          this.emitState();
        }
        return;
      }
      this.preparedEmitted = true;
      this.state = 'prepared';
      this.emitState();
      // prepared 之后立刻套用起播位置 / 倍速 / 音量 / 循环与自动起播（同 IJK handlePrepared）
      this.applyPendingStart();
    }
    if (native.eof && !this.looping) {
      this.state = 'completed';
      if (this.durationMs > 0) {
        this.positionMs = this.durationMs;
      }
      this.buffering = false;
      this.stopPolling();
      this.emitState();
      this.emitBuffering();
      return;
    }
    const next: MpvKernelState = native.playing ? 'playing' : 'paused';
    if (next !== this.state) {
      this.state = next;
      this.emitState();
    }
  }

  /** prepared 后的统一收口：续播点（含结尾保护）→ seek → 自动起播 */
  private applyPendingStart(): void {
    const player: Player | null = this.player;
    if (player === null) {
      return;
    }
    this.applySpeed(player);
    this.applyVolume(player);
    this.applyLoopMode(player);
    let target: number = normalizeMs(this.pendingStartPositionMs);
    this.pendingStartPositionMs = 0;
    // 续播点接近结尾：回退到 0，避免 seek 到末尾后立刻 completed
    if (target > 0 && this.durationMs > 0 && this.options.resumeEndGuardMs > 0 &&
      target >= this.durationMs - this.options.resumeEndGuardMs) {
      target = 0;
    }
    if (target > 0) {
      this.seekInternal(this.clampTarget(target));
    } else {
      this.positionMs = 0;
    }
    if (this.options.autoplay) {
      this.play();
    }
  }

  /** 画幅同步（只在变化时回调，避免每轮重置父容器布局） */
  private syncVideoSize(native: PlayerState): void {
    let width: number = 0;
    let height: number = 0;
    try {
      // videoParams 在媒体解析完成前可能还没有值，读取失败就跳过本轮
      // （见 VideoParams.d.ets：w/h 为未做宽高比修正的像素尺寸）
      width = native.videoParams.w;
      height = native.videoParams.h;
    } catch (e) {
      return;
    }
    if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
      return;
    }
    if (width === this.videoWidth && height === this.videoHeight) {
      return;
    }
    this.videoWidth = width;
    this.videoHeight = height;
    this.onVideoSizeChange(width, height);
  }

  /** 位置夹取：限制在 [0, duration]（duration 未知时只做下界保护） */
  private clampPosition(positionMs: number): number {
    let value: number = normalizeMs(positionMs);
    if (this.durationMs > 0 && value > this.durationMs) {
      value = this.durationMs;
    }
    return value;
  }

  /**
   * native 错误流（player.stream.error，见 PlayerStream.d.ets）。
   *
   * 只在「还没 prepared」时视为致命：mpv 的 error 级别日志包含不少可恢复的信息
   * （分片 404 后重试、解码器回退等），播放中一律不据此中断，交给轮询 / 上层超时判断。
   */
  private handleNativeError(message: string): void {
    if (this.released || this.lastErrorEmitted) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'mpv native error: %{public}s', message);
    if (this.state === 'preparing' || this.state === 'waitingSurface') {
      this.failWith('mpv 加载失败：' + message);
    }
  }

  /** 进入 error：停轮询 + 收掉在途 seek + 通知上层（同一次失败只发一次） */
  private failWith(message: string): void {
    if (this.released || this.lastErrorEmitted) {
      return;
    }
    hilog.warn(DOMAIN, TAG, 'mpv 内核失败: %{public}s', message);
    this.lastErrorEmitted = true;
    this.errorMessage = message;
    this.state = 'error';
    this.buffering = false;
    this.seeking = false;
    this.stopPolling();
    this.emitState();
    this.emitBuffering();
    this.onError(message);
  }

  /** 销毁 native 播放器（不改变对外状态，供 create / reload / release 复用） */
  private destroyPlayer(): void {
    const player: Player | null = this.player;
    this.player = null;
    if (player === null) {
      return;
    }
    try {
      player.destroy();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'destroy 失败: %{public}s', messageOf(e as Error));
    }
  }

  /** create 复用的清理：停轮询 + 销毁旧实例 + 清在途 seek（不动 url / source 字段） */
  private teardown(): void {
    this.stopPolling();
    this.destroyPlayer();
    this.seeking = false;
    this.seekTargetMs = 0;
    this.preparedEmitted = false;
  }

  /** prepared 之后才允许设置倍速 / 音量 / 循环 / seek 的状态集合 */
  private isOperable(): boolean {
    return this.state === 'prepared' || this.state === 'playing' ||
      this.state === 'paused' || this.state === 'completed';
  }

  private emitState(): void {
    this.onStateChange(this.state);
  }

  private emitBuffering(): void {
    this.onBufferingChange(this.buffering);
  }
}
