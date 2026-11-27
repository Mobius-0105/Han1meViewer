/**
 * 内嵌播放器（视频详情页顶部）。
 *
 * 由 `pages/player/PlayerPage.ets` 的播放逻辑「搬运 + 裁剪」而来，播放策略与状态机主体不变：
 *  - 保留：media.createAVPlayer() + XComponent(SURFACE) 拿 surfaceId、idle 下
 *    `url` 直连 → 失败/超时再换带 Referer/UA/Cookie 的 MediaSource 的两次尝试策略、
 *    12 秒加载超时、initialized→prepare→prepared 时 applySurface/seek 续播/play、
 *    倍速与清晰度切换、每 5 秒落盘观看进度、网页播放降级、重试原生、复制/打开播放地址；
 *  - 自动重试（本轮新增）：一种加载方式失败后先立即换另一种方式；仍失败则按
 *    800ms → 1500ms → 2500ms 的递增间隔自动重试 3 次。每次重试都会 reset AVPlayer 并重新
 *    loadSource（加载方式在 url / headers 之间轮换，起播位置取当前进度），重试期间浮层显示
 *    「正在重试（n/3）」；3 次全部失败才降级网页播放并给出提示。用户手动「重试原生」不占用
 *    自动重试次数（会先清空计数，重新从头走一遍）。
 *  - 裁掉：页面级 api.getVideo 加载与错误面板、AppTopBar、本页自己的窗口方向控制；
 *    全屏改为「页内横屏全屏」：本组件只通过 onToggleFullscreen 回调请求父页面切换，
 *    窗口方向 / 系统栏由父页面（VideoPage）统一管理。
 *
 * 播放内核：只有系统 AVPlayer（单一内核）。HarmonyOS 没有 ExoPlayer；之前接过的 libmpv
 * （@mpv-ohos/mpv-arkts）在真机上无法起播，已整体移除，不再提供「可切换内核」。
 *
 *  - 播放：media.createAVPlayer() + XComponent(controller) 拿 surfaceId；原有加载方式轮换 /
 *    12 秒加载超时 / 自动重试 / 网页降级策略完全不变；
 *  - 降级链只有两段：AVPlayer → 网页播放（不再有中间的内核切换）。
 *
 * 入参 video 由父页面（详情页）在 api.getVideo 成功后传入，本组件不再自己请求详情。
 * 播放区域尺寸由父容器决定（详情页结合 videoSizeChange 回调做比例自适应）；本组件内部再按
 * 视频真实画幅把画面居中 letterbox（全屏横屏 / 竖屏视频 / 窄窗口下不拉伸，多余区域纯黑底）。
 *
 * 控制层（PuraPily 式布局，纯 UI）：铺满播放器的全尺寸三段式 Column —— 顶部渐变条（返回 / 退出全屏、
 * 回首页、单行标题、更多）、中部 layoutWeight(1) 居中的 56 圆形播放/暂停大按钮（播放中显示暂停图标）、
 * 底部渐变条（当前时间 / Slider / 总时长、倍速 / 清晰度 / 循环 / 全屏玻璃胶囊）、缓冲 Loading、5 秒无操作自动隐藏；
 * 控制层显隐带 180ms 透明度 + 位移动画，网页降级时控制层常显并保留
 * 「重试原生 / 复制播放地址 / 浏览器打开」入口。
 *
 * 浮层（本轮重做，纯 UI）：
 *  - 底部条「清晰度 / 倍速」胶囊只负责**打开选项弹窗**（不再循环切换）：半透明遮罩 + 居中
 *    系统沉浸材质面板（与悬浮底栏同源：MaterialSurface → Tabs TabBar + CommonModifier.systemMaterial，
 *    高度取内容实测值；不可用时回退「渐变模糊 + barTint」玻璃），标题 + 选项列表，
 *    当前项主色高亮 + 勾选；点遮罩 / 点选项关闭，开合 200ms 淡入 + 缩放 + 上移；
 *  - 右上「更多」播放设置浮层：只保留非重复项（网页降级排查 / 只读播放信息 / 当前播放地址），
 *    清晰度与倍速的切换入口不再重复出现；同样使用沉浸材质面板 + 遮罩 + 开合动画。
 *  - 底部条的倍速 / 清晰度 / 全屏胶囊改用 GlassCapsule（Tabs TabBar 材质画布），
 *    与悬浮底栏同一条材质渲染路径。
 *
 * 手势层（对标 Android 原版 PlayerGestureLayer + 控制层）：
 *  - 位于 XComponent 之上、控制层之下的一层透明 Column，只在原生播放时挂载（网页播放不拦截网页交互）；
 *  - 单击：显示 / 隐藏控制层（300ms 双击窗口确认后再执行，避免与双击冲突）；
 *  - 双击：中间 1/3 播放 / 暂停；左 1/3 快退 10s、右 1/3 快进 10s（浮动提示 ±10s 与目标时间）；
 *  - 长按（500ms）：临时 2 倍速（AVPlayer.setSpeed(2.0)），松开恢复原倍速，按住期间显示「2x 倍速中」；
 *  - 水平拖动：进度预览（浮动提示「当前时间 / 总时长」）+ 松手 seek；
 *  - 右半屏垂直拖动：**系统媒体音量**（audio.getAudioManager().setVolume(AudioVolumeType.MEDIA)，
 *    手势开始时读取系统音量作为起点；系统音量 API 不可用时回退 AVPlayer.setVolume）；
 *    左半屏垂直拖动：**窗口亮度**（win.setWindowBrightness，进入页面时读取原亮度，
 *    退出全屏 / 离开页面时恢复原亮度，原值为 -1 则恢复跟随系统）；
 *  - 拖动 / 操作会重新开始自动隐藏计时（按下时一次、抬手 / 滑动结束时再一次），到点一定隐藏。
 *
 * 底部常显进度条（本轮新增）：
 *  - 播放器最底部（贴着播放器下边缘）常显一条 3vp 细进度条，不随控制层显隐，
 *    轨道半透明白 + 已播放部分主题色、圆角 2、hitTestBehavior(None) 不挡手势；
 *  - 由 AppSettings['playerBottomProgress'] 控制（默认开启），@StorageProp 监听切换即时生效；
 *    折叠隐藏播放器时由父页面 VideoPage 在把手区域顶部补一条（见 VideoPage）。
 *
 * 生命周期 / 系统行为（对标 Android 原版 HanimeVideoPlayer + VideoRouteHostScreen）：
 *  - 播放中（playing / buffering / prepared）窗口保持屏幕常亮（setWindowKeepScreenOn），
 *    暂停 / 播完 / 出错 / 离屏时关闭；
 *  - 监听窗口 windowEvent：后台（WINDOW_HIDDEN）落盘进度并暂停，回前台不自动播（与原版一致，
 *    需要用户手动点播放）；失焦（WINDOW_INACTIVE）只落盘进度；
 *  - 全屏 / 方向切换保护窗口（InlinePlayerHandle.beginOrientationChange）：父页面切换窗口方向 +
 *    系统栏（旋转动画 + 布局收敛，约 1s）期间，组件可见区域会短暂回调为 0、窗口事件也可能短暂
 *    失焦 / 隐藏；这段窗口内上述两种信号都**不暂停**（只落盘进度），窗口结束自动复位并补判
 *    真后台（HOME / 息屏仍会暂停），避免「退出全屏后视频停住、还要手动点播放」；
 *  - completed：落盘进度、显示重播（中央按钮下「重播」），不自动跳转；历史进度接近结尾时
 *    起播回退到 0，避免「一进页面就播完」；
 *  - 续播点超过 5s 时恢复后浮出「从头播放」胶囊 5s（对齐原版 ShowResumeButton）。
 *    胶囊位置本轮修正：不再居中叠在中央播放/暂停大按钮上（16:9 小画面里两者必然重合），
 *    改为**底部控制条上方、水平右对齐**，既不遮挡中央播放键，也不遮挡进度条 / 底栏胶囊，
 *    仍保留 5s 自动消失；控制层隐藏时胶囊同样跟随隐去（它渲染在控制层之外的独立浮层，
 *    保持始终可见即可，尺寸与位置不参与控制层显隐动画）。
 *
 * ⚠️ 这里是「搬运 + 裁剪」，不要顺手改播放策略；sourceUrl/headersTried/loadTimerId 等
 * 字段语义与 PlayerPage 保持一致。createPlayer / loadSource / attachByUrl / tryHeadersAttach /
 * 进度落盘等原有逻辑未改动，只在其上增加监听与 UI 控制。
 */

import { Theme } from '../../common/Theme';
import { Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { Glass } from '../../common/Glass';
import { common } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import { webview } from '@kit.ArkWeb';
import { describeError } from '../../logic/net/Errors';
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
import { notifyLibraryChanged } from '../../viewmodel/library/LibraryViewModel';

/** 播放进度记录节流间隔 */
const SAVE_INTERVAL_MS: number = 5000;
/** 媒体加载超时：超过该时间仍未进入 initialized/prepared，就换下一种播放方式 */
const LOAD_TIMEOUT_MS: number = 12000;
/**
 * 全屏 / 方向切换保护窗口时长（毫秒）。
 *
 * 进入 / 退出页内全屏会调用 window.setPreferredOrientation + setWindowSystemBarEnable，
 * 窗口旋转与系统栏切换期间布局尚未收敛：
 *  - onVisibleAreaChange 可能短暂回调「可见比例 0」（华为官方 FAQ 在「旋转窗口切换全屏」场景
 *    同样明确提到组件可见区域会短暂回调为 0）；
 *  - windowEvent 也可能短暂派发 WINDOW_INACTIVE（失焦）甚至 WINDOW_HIDDEN。
 * 保护窗口内这两种信号都不触发暂停（只落盘进度），窗口结束自动复位、恢复正常判定；
 * 真后台（HIDDEN 后没有回到前台）会在窗口结束时补一次暂停，不会漏暂停。
 */
const ORIENTATION_GUARD_MS: number = 1000;
/** 保护窗口结束后对「可见比例 0」的延迟确认时间：排除旋转收尾仍在回调的瞬态读数 */
const ORIENTATION_GUARD_RECHECK_MS: number = 400;
/** 控制层自动隐藏延迟：5 秒无操作 */
const CONTROLS_HIDE_MS: number = 5000;
/** 锁定按钮的独立自动隐藏时长（ms）：比控制层的 5s 更短，避免长时间挂在画面上挡视线 */
const LOCK_HIDE_MS: number = 3000;
/** 单击 / 双击判定：两次抬起间隔小于该值视为双击（毫秒） */
const DOUBLE_TAP_MS: number = 300;
/** 长按判定为「临时 2 倍速」的按住时长（毫秒，对齐原版长按手势） */
const LONG_PRESS_MS: number = 500;
/** 双击左 / 右半屏快退 / 快进时长（毫秒） */
const DOUBLE_TAP_SEEK_MS: number = 10000;
/** 续播阈值：历史进度超过该值才恢复并提示「从头播放」（对齐原版 RESUME_THRESHOLD_MS = 5s） */
const RESUME_THRESHOLD_MS: number = 5000;
/** 「从头播放」胶囊的保留时长（毫秒，对齐原版 5s 自动隐藏） */
const RESUME_CHIP_MS: number = 5000;
/** 续播点离结尾小于该值时视为「已看完」：起播回退到 0，避免一进页面立即 completed */
const RESUME_END_GUARD_MS: number = 1500;
/**
 * 续播 seek 的落地容差（毫秒）。
 *
 * AVPlayer 在 prepared 内 seek 之后不保证「立即生效」（先 seek 再立刻 play 的时序、
 * 上层 reset / surface 重建都可能把这次 seek 丢掉），播放器报回来的位置会短暂停在 0。
 * 只有播放位置进入 [续播点 - 容差, 续播点 + ∞) 才认为 seek 已落地；
 * 否则在播放开始后的首个进度回调里补一次 seek，并在此期间拒绝用 0 / 旧位置落盘。
 */
const RESUME_SEEK_TOLERANCE_MS: number = 2500;
/**
 * seekDone 看门狗（毫秒）：AVPlayer 偶发不回调 seekDone（seek 期间切换清晰度 / surface 重建 /
 * 部分流上直接失败），此时 seeking 锁不解除会让进度条永久停在拖动位置、也不再落盘。
 * 超时后主动解锁，交回 timeUpdate 驱动进度。
 */
const SEEK_DONE_TIMEOUT_MS: number = 1500;
/**
 * 原生播放失败后的自动重试次数（建议 3 次）。
 *
 * 失败判定来源：AVPlayer error 事件 / 状态机进入 error / 12 秒加载超时 / loadSource 抛错。
 * 每一次失败先按原有策略立即切换加载方式（url ↔ headers）；两种方式都失败后才进入自动重试。
 * 自动重试会 reset AVPlayer 再重新 loadSource，并在 url / headers 之间轮换；
 * 3 次重试全部失败才降级网页播放（显示错误面板 + 网页播放提示）。
 */
const AUTO_RETRY_MAX: number = 3;
/** 每次自动重试前的等待时间（毫秒，递增；数组长度即最大自动重试次数对应的间隔数） */
const AUTO_RETRY_DELAYS_MS: number[] = [800, 1500, 2500];
/** 双击判定允许的位置偏移（vp） */
const DOUBLE_TAP_SLOP: number = 44;
/** 单击显示 / 隐藏控制层的延迟执行时间（毫秒，等双击窗口过去再执行） */
const SINGLE_TAP_DELAY_MS: number = 300;
/** 手势提示（进度 / 音量 / 亮度）在松手后保留的时间 */
const GESTURE_HINT_MS: number = 700;
/** 判定为拖动的最小位移（vp） */
const GESTURE_SLOP: number = 10;
/** 水平拖动开始进度调节的最小横向位移（vp） */
const SEEK_SLOP: number = 24;
/** 垂直拖动开始音量 / 亮度调节的最小纵向位移（vp） */
const LEVEL_SLOP: number = 12;
/** 满屏垂直滑动对应的音量 / 亮度变化量（>1 让手感更灵敏，结果仍 clamp 到 0~1） */
const LEVEL_SENSITIVITY: number = 0.7;
/** 窗口亮度读取失败 / 原值为 -1（跟随系统）时的兜底起点（任务约定取 0.5） */
const DEFAULT_WINDOW_BRIGHTNESS: number = 0.5;
/** 系统媒体音量读取失败时的兜底起点（任务约定取 0.5） */
const DEFAULT_SYSTEM_VOLUME: number = 0.5;
/** 播放器底部常显进度条高度（vp）：细而不占画面，任何底色上都能看清 */
const BOTTOM_PROGRESS_HEIGHT: number = 3;
/** 常显进度条轨道颜色（半透明白；播放器底是黑底，白轨道在任何主题下都清晰） */
const BOTTOM_PROGRESS_TRACK: string = '#4DFFFFFF';
/** 选项弹窗（清晰度 / 倍速）开合动画时长：淡入 + 缩放 + 上移 */
const PICKER_ANIM_MS: number = 200;
/** 选项弹窗面板圆角（与播放器胶囊按钮同一套材质观感） */
const PICKER_RADIUS: number = 22;
/** 播放设置浮层圆角（沿用旧深色玻璃卡片的 20） */
const SETTINGS_RADIUS: number = 20;
/** 弹窗遮罩：半透明黑，点遮罩关闭 */
const PICKER_MASK: string = '#99000000';
/** 面板 0.8vp 白色描边（与播放器按钮一致；材质层之上的发丝描边，保证面板边缘清晰） */
const PICKER_BORDER: string = '#CCFFFFFF';
/** 底部条玻璃胶囊按钮高度（倍速 / 清晰度 / 全屏） */
const CONTROL_CAPSULE_HEIGHT: number = 32;
/** 玻璃胶囊按钮圆角：999 = 全圆角药丸，与底栏胶囊一致 */
const CONTROL_CAPSULE_RADIUS: number = 999;
/** 倍速胶囊宽度（'0.75x'~'2.0x' 等 4~5 字符，居中） */
const SPEED_CAPSULE_WIDTH: number = 56;
/** 清晰度胶囊宽度（'1080P' / '自动' 等徽标，居中） */
const QUALITY_CAPSULE_WIDTH: number = 68;
/** 全屏胶囊宽度（图标 + '全屏' / '退出全屏'，宽度固定避免切换时控制条抖动） */
const FULLSCREEN_CAPSULE_WIDTH: number = 88;

/** 底部控制条上方的自下而上渐变遮罩高度（vp）：竖屏时保证时间 / 进度文字压在画面上仍可读 */
const BOTTOM_SCRIM_HEIGHT: number = 96;

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
 * XComponent id 需要唯一：详情页可以叠多层（相关推荐进入另一个视频详情页），
 * 同一视频也可能在导航栈里出现多次，所以给每个内嵌播放器实例一个自增序号。
 */
let inlinePlayerSeq: number = 0;

/**
 * 自定义 XComponentController：在 onSurfaceCreated 里拿 surfaceId。
 * 官方文档说明 onLoad 的触发时机可能早于 Surface 真正可用，用 onSurfaceCreated 更稳。
 */
class InlineSurfaceController extends XComponentController {
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

/**
 * 父页面控制内嵌播放器的句柄。
 *
 * 详情页内跳转（页内全屏 / 打开其它视频 / 打开网页）时，旧页面实例不会销毁，
 * 内嵌播放器会继续在后台出声，因此父页面在跳转前必须调用 pauseAndSave()：
 * 先落盘当前进度，再暂停播放。
 */
export class InlinePlayerHandle {
  pauseAndSave: () => void = () => {
  };
  /** 父页面动作区「播放 / 暂停」按钮：复用本组件已有的 togglePlay 控制，不改播放状态机 */
  togglePlay: () => void = () => {
  };
  /**
   * 父页面进入 / 退出页内全屏前调用：打开「全屏 / 方向切换保护窗口」。
   *
   * 只负责置位 + 启动自动复位计时（本组件内 ORIENTATION_GUARD_MS 后自动结束），
   * 父页面不需要配对调用关闭；重复调用只会重新计时，不会叠加出永久抑制。
   * 保护窗口内的可见区域 0 / 窗口隐藏信号不触发暂停，窗口结束后再补判真后台。
   */
  beginOrientationChange: () => void = () => {
  };
  /**
   * 父页面折叠隐藏播放器前查询：AVPlayer 当前是否在 playing。
   *
   * 直接读播放器实时 state，而不是等 @State playing 的异步回调，
   * 避免「刚点暂停立刻折叠」这类时序下记录到过期状态。
   */
  isPlayingNow: () => boolean = () => false;
  /**
   * 父页面从折叠展开播放器后调用：折叠前在播放时从原进度继续播放。
   *
   * 只对 paused / prepared 状态调 play()：不 seek、不重新 loadSource、不重建 AVPlayer，
   * 进度沿用折叠时落盘的当前 positionMs；折叠前本来就是暂停 / 结束的由父页面判断、不会调用。
   */
  resumeAfterCollapse: () => void = () => {
  };
  /**
   * 父页面折叠隐藏播放器时调用：暂停 + 落盘进度，但**不主动唤出控制层**。
   *
   * 折叠是用户主动隐藏画面，控制层在收缩动画中淡入会闪一下；暂停 / 落盘行为与 pauseAndSave 一致。
   */
  pauseForCollapse: () => void = () => {
  };
  /**
   * 父页面折叠播放器前读取当前播放位置 / 总时长（毫秒）。
   *
   * 折叠后播放器被隐藏，常显进度条由父页面在把手区域顶部补画，需要这份进度快照；
   * 折叠必然伴随暂停（见 pauseForCollapse），所以父页面只需在折叠时取一次。
   */
  currentPositionMs: () => number = () => 0;
  currentDurationMs: () => number = () => 0;
}

@Component
export struct InlinePlayer {
  /** 父页面加载完成后传入的视频详情（本组件不再调 api.getVideo） */
  video: HanimeVideo = emptyHanimeVideo();
  /** 父页面的控制句柄（离开页面前暂停 + 落盘进度 + 动作区播放/暂停） */
  handle: InlinePlayerHandle = new InlinePlayerHandle();
  /** 是否处于页内横屏全屏（父页面负责窗口方向/系统栏，这里只切换控制层样式） */
  @Prop @Watch('onFullscreenChanged') fullscreen: boolean = false;
  /** 全屏 / 退出全屏切换：窗口方向与系统栏由父页面处理 */
  onToggleFullscreen: () => void = () => {
  };
  /** 解码画幅回调（px）：父页面据此计算播放器容器宽高比，实现比例自适应 */
  onVideoSizeChange: (width: number, height: number) => void = () => {
  };
  /** 播放状态回调：父页面动作区据「播放 / 暂停」按钮文案使用 */
  onPlaybackStateChange: (playing: boolean) => void = () => {
  };
  /**
   * 左上角「回首页」圆钮回调（返回钮右侧的独立圆钮，父页面实现「直接回首页」：
   * 暂停落盘 + 恢复竖屏/系统栏 + Router.popToRoot() + AppStorage['requestTab'] = 0）。
   *
   * 本组件只负责触发，VideoPage 传入 returnHomeFromPlayer()；
   * 返回钮本身恢复为纯单击（退出全屏 / 返回上一页），不再承担长按回首页。
   */
  onReturnHome: () => void = () => {
  };
  /**
   * 播放器被父页面折叠隐藏（容器宽高动画到 0 / Visibility.None）期间：
   * true 时 {@link handleVisibleAreaChange} 不再把「可见比例 ≈ 0」当成「被其它页面覆盖」去暂停 + 落盘。
   *
   * 为什么需要：显隐判定原本服务「详情页被登录 / 网页等二级页覆盖」的暂停策略，
   * 但视频详情页的「上滑直接折叠隐藏播放器」同样会把播放区的可见比例降到 0。
   * 折叠的暂停现在由父页面显式调用 pauseAndSave() 完成（用户主动折叠 = 暂停并落盘），
   * 这里抑制自动路径是为了避免「自动暂停」与「显式暂停」互相覆盖、重复落盘 / 改写 hiddenByCover 状态；
   * 折叠前本来就是暂停时也不会被自动路径二次处理。页面被二级页覆盖 / 真正切后台时仍传 false。
   */
  @Prop keepPlayingWhenHidden: boolean = false;
  @StorageLink('themeMode') themeMode: string = 'system';
  /** 状态栏高度（EntryAbility 写入）：全屏时顶部渐变条额外避开状态栏 / 刘海 */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航条高度（EntryAbility 写入）：全屏时底部渐变条避开手势导航区 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State useWeb: boolean = false;
  @State mediaError: string = '';
  @State qualityIndex: number = 0;
  @State speedIndex: number = DEFAULT_SPEED_INDEX;
  @State positionMs: number = 0;
  @State durationMs: number = 0;
  @State @Watch('onPlayingStateChanged') playing: boolean = false;
  @State buffering: boolean = true;
  @State playerState: string = 'idle';
  /** 「更多」播放设置浮层（只读播放信息 + 网页降级排查入口；弹窗式遮罩 + 沉浸材质面板） */
  @State showSettings: boolean = false;
  /**
   * 清晰度 / 倍速选项弹窗类型：'' = 关闭，'quality' = 清晰度，'speed' = 倍速。
   * 底部条上的两个胶囊只负责打开对应弹窗（不再循环切换），选项列表里当前项高亮 + 勾选。
   */
  @State pickerKind: string = '';
  /**
   * 清晰度 / 倍速面板的**实测高度**（vp；0 = 尚未测量）。
   *
   * 面板高度随选项数量 / 播放器尺寸变化，而 MaterialSurface 的 surfaceHeight 是普通属性
   * （ArkTS：父组件状态变化不会同步到子组件普通属性），因此材质背景层用 ForEach 以
   * 「取整后的高度」作为 key —— 高度一变，key 变，MaterialSurface 以新高度重建，材质始终贴合面板。
   */
  @State pickerPanelHeight: number = 0;
  /** 播放设置浮层的实测高度（vp；0 = 尚未测量），用途同 pickerPanelHeight */
  @State settingsPanelHeight: number = 0;
  /** 控制层是否可见：原生播放时 5 秒无操作自动隐藏，点击画面切换 */
  @State controlsVisible: boolean = true;
  /** 控制层淡出动画结束后彻底移出命中测试（Visibility.Hidden），避免透明按钮仍可点 */
  @State controlsGone: boolean = false;
  /** 手势浮动提示是否可见（进度 / 音量 / 亮度） */
  @State hintVisible: boolean = false;
  /** 手势提示主文案（进度显示「当前时间 / 总时长」，音量/亮度显示百分比） */
  @State hintTitle: string = '';
  /** 手势提示的进度值 0~1；-1 表示不显示进度条 */
  @State hintProgress: number = -1;
  /** 手势提示类型：'seek' | 'volume' | 'brightness'（决定标签文案） */
  @State hintKind: string = '';
  /** 当前音量 0~1（系统媒体音量归一化值，由右侧竖滑手势调节） */
  @State volumeLevel: number = 1;
  /**
   * 是否已锁定播放器（画面右侧的锁按钮）。
   *
   * 锁定后：控制层淡出并置为 Hidden、全部手势（单击显隐 / 双击快进 / 横滑 seek / 竖滑亮度音量 /
   * 长按倍速）直接 return，只有锁按钮本身可点 —— 手持 / 放进兜里时不会误触。
   * 退出播放器（releasePlayer）与切换视频时重置为未锁定。
   */
  @State locked: boolean = false;
  /**
   * 锁定按钮当前是否显示。
   *
   * 它有自己的 3s 计时器（LOCK_HIDE_MS），比控制层的 5s 短：
   *  - 未锁定：只在控制层可见时才有意义（lockButtonVisible 里再与 controlsShown 取与）；
   *  - 已锁定：控制层是隐藏的，这一位就是唯一开关 —— 点画面任意处重新显示 3s，方便随时解锁。
   */
  @State lockShown: boolean = true;
  /** 锁定按钮隐藏计时器 */
  private lockHideTimerId: number = -1;
  /** 锁定态轻点判定：按下坐标与时间（-1 表示没有按下的记录） */
  private lockTapX: number = -1;
  private lockTapY: number = -1;
  private lockTapAt: number = 0;
  /**
   * 当前亮度 0~1（窗口亮度，由左侧竖滑手势调节）。
   * 不再是「黑色遮罩 alpha 模拟」，而是真正下发到窗口亮度。
   */
  @State brightnessLevel: number = DEFAULT_WINDOW_BRIGHTNESS;
  /**
   * 是否在播放器最底部常显细进度条（AppSettings.playerBottomProgress，默认开启）。
   * 设置页写入 AppStorage 后这里即时刷新，不需要重进播放器。
   */
  @StorageProp('playerBottomProgress') playerBottomProgress: boolean = true;
  /** 手势层尺寸（onAreaChange 更新，用于左右半屏判定与滑动灵敏度） */
  @State gestureWidth: number = 0;
  @State gestureHeight: number = 0;
  /** 解码画幅（videoSizeChange 回调写入）：媒体层按真实比例居中 letterbox，避免全屏拉伸 */
  @State videoWidth: number = 0;
  @State videoHeight: number = 0;
  /** 播放已结束（completed）：中央按钮显示播放图标 + 下方「重播」文案，不自动跳转 */
  @State completed: boolean = false;
  /** 单视频循环播放（对齐原版底栏 Repeat 按钮，AVPlayer.loop） */
  @State looping: boolean = false;
  /** 续播恢复后浮出的「从头播放」胶囊（对齐原版 ShowResumeButton，5s 自动隐藏） */
  @State resumeVisible: boolean = false;
  /** 是否正在自动重试（重试期间显示「正在重试（n/3）」浮层） */
  @State retrying: boolean = false;
  /** 当前是第几次自动重试（1 起；0 = 未在重试） */
  @State retryAttempt: number = 0;
  /** 本实例序号（aboutToAppear 里分配），用于 XComponent 唯一 id */
  private instanceSeq: number = 0;
  /** 当前跟踪的手指 id（-1 = 无） */
  private touchId: number = -1;
  private touchStartX: number = 0;
  private touchStartY: number = 0;
  /** 本次手势的判定模式：''（未定）/ 'seek' / 'volume' / 'brightness' */
  private gestureMode: string = '';
  /** 手势开始时的播放位置 / 音量 / 亮度（相对位移的基准） */
  private gestureStartPositionMs: number = 0;
  private gestureStartVolume: number = 1;
  private gestureStartBrightness: number = DEFAULT_WINDOW_BRIGHTNESS;
  /** 系统媒体音量最大档位（0 = 尚未读到；用于把 0~1 归一化值换算成系统档位） */
  private systemVolumeMax: number = 0;
  /** 系统媒体音量 API 不可用、本次回退到 AVPlayer 自身增益 */
  private usingPlayerGainFallback: boolean = false;
  /** 本次音量竖滑是否已经改动过音量（异步读系统音量返回时不覆盖用户刚滑出的值） */
  private volumeGestureApplied: boolean = false;
  /** 进入页面时的窗口亮度原值（-1 = 跟随系统；退出全屏 / 离场恢复用） */
  private windowBrightnessOriginal: number = -1;
  /** 本次是否已改过窗口亮度（false 时无需恢复，避免无意义地写 -1） */
  private windowBrightnessApplied: boolean = false;
  /** 进度拖动起点 x（越过识别阈值后前移，避免首帧跳变） */
  private seekDragStartX: number = 0;
  /** 是否已产生拖动（抬手时不再当单击处理） */
  private gestureMoved: boolean = false;
  /** 本次按下是否已判定为双击（抬手时不再当单击处理） */
  private gestureDoubleTap: boolean = false;
  /** 本次按下是否已触发长按临时倍速（抬手时恢复原倍速且不再当单击处理） */
  private gestureLongPress: boolean = false;
  /** 长按临时 2 倍速是否生效中（松开 / 取消后恢复原倍速） */
  private boostActive: boolean = false;
  /** 长按判定定时器 id（-1 = 无） */
  private longPressTimerId: number = -1;
  /** 上一次单击抬起的时间 / 位置（双击判定用） */
  private lastTapAt: number = 0;
  private lastTapX: number = 0;
  private lastTapY: number = 0;
  /** 延迟执行的单击（显示 / 隐藏控制层）定时器 id */
  private singleTapTimer: number = -1;
  /** 手势提示自动隐藏定时器 id */
  private hintTimer: number = -1;
  /**
   * 是否正有手指按在播放器 / 进度条上（纯记录，用于触摸 Up / Cancel 时判定手势是否已结束）。
   *
   * 注意：它**不再**用来在自动隐藏计时到点时无限顺延 —— 旧实现里定时器回调发现
   * pointerDown 仍为 true 就重新排一个定时器，一旦触摸 Up / Cancel 事件丢失，
   * 标记永远复位不了，控制层就会「超过 5 秒也不隐藏」。现在到点一定隐藏，
   * 并在隐藏时对该标记做一次防御性复位。
   */
  private pointerDown: boolean = false;
  private watchUrl: string = '';
  private avPlayer: media.AVPlayer | null = null;
  private surfaceController: InlineSurfaceController = new InlineSurfaceController();
  private webController: webview.WebviewController = new webview.WebviewController();
  private surfaceId: string = '';
  /**
   * XComponent id：页面生命周期内**必须稳定**（重绘不能变）。
   * AVPlayer 的 surfaceId 绑定依赖它。
   */
  private xcomponentId: string = '';
  private pendingSeekMs: number = 0;
  private prepareRequested: boolean = false;
  /**
   * 是否正在「seek 进行中」（拖动条松手 / 双击快进 / 续播补 seek）。
   * 为 true 时 handleTimeUpdate 不把播放器报回来的旧位置写进 positionMs，
   * 否则进度条会先弹回旧位置、再跳到新位置（用户看到的「来回弹」）。
   */
  private seeking: boolean = false;
  /** 是否有一次 seek 正在等 AVPlayer 的 seekDone 回调（AVPlayer 的 seek 是异步的） */
  private seekInFlight: boolean = false;
  /**
   * seek 排队中的**最后一个**目标（trailing 语义；-1 = 无）。
   *
   * 拖动 / 连点快进时会有多次 seek 请求，不能全部下发：AVPlayer 的 seek 队列会被打满，
   * 最终落点变成某个中间值。这里只保留最新一个，等 seekDone 后补发。
   */
  private trailingSeekMs: number = -1;
  /** 本次 seek 的目标位置（seekDone 前用它压住 UI 位置） */
  private seekTargetMs: number = 0;
  /** seek 看门狗定时器 id（-1 = 无）：seekDone 丢失时不至于让进度条永久卡住 */
  private seekGuardTimer: number = -1;
  private lastSavedMs: number = 0;
  private disposed: boolean = false;
  /** 当前尝试播放的媒体地址（用于失败后的"带头重试"） */
  private sourceUrl: string = '';
  /** 是否已经尝试过带 Referer/UA/Cookie 的 MediaSource */
  private headersTried: boolean = false;
  /** 媒体加载超时定时器 id（-1 表示无） */
  private loadTimerId: number = -1;
  /** 控制层自动隐藏定时器 id（-1 表示无） */
  private hideTimerId: number = -1;
  /** 「从头播放」胶囊的自动隐藏定时器 id（-1 表示无） */
  private resumeTimerId: number = -1;
  /** 已排期的自动重试次数（0 = 未重试；成功 / 手动操作后清零） */
  private retryCount: number = 0;
  /** 下一次自动重试的定时器 id（-1 表示无） */
  private retryTimerId: number = -1;
  /** 自动重试的起播位置（毫秒）：从失败时的当前进度继续，不把用户进度重置回 0 */
  private retrySeekMs: number = 0;
  /** 下一次 loadSource 是否强制走带 Referer/UA/Cookie 的 MediaSource（自动重试方式轮换用） */
  private forceHeadersAttach: boolean = false;
  /**
   * 本次加载尝试是否已经处理过失败（防抖）：
   * AVPlayer 的 error 事件、状态机 'error'、12 秒加载超时可能对同一次失败先后回调，
   * 只允许第一个进入「换方式 / 排自动重试」，避免重试次数被重复消耗、定时器互相覆盖。
   */
  private attemptFailureHandled: boolean = false;
  /** 本次媒体是否是「从观看历史续播」：只有续播需要应用「接近结尾回退 0」的保护 */
  private resumeFromHistory: boolean = false;
  /**
   * 待落地的续播目标（毫秒；0 = 没有待应用的续播）。
   *
   * 与 `pendingSeekMs` 的区别：`pendingSeekMs` 是「下一次加载要用的 seek 参数」，
   * 每次 loadSource 都会被重写；`resumeTargetMs` 记录**历史续播这个目标本身**，
   * 直到播放器确认位置已经落在目标上（或补 seek 成功）才清零。
   * 自动重试 / 降级 / surface 重建时据此恢复，不会把续播点丢成 0。
   */
  private resumeTargetMs: number = 0;
  /** 续播 seek 是否已确认落地（false 时禁止用播放器报回的 0 / 旧位置覆盖进度与落盘） */
  private resumeSeekApplied: boolean = true;
  /**
   * 补 seek 后的旧值抑制窗口（毫秒时间戳 / 目标位置）。
   *
   * confirmResumeSeek 发现 seek 没落地时会补一次 seek；原生 seek 是异步的，
   * 完成前播放器还会继续上报旧位置（0 / 小值）。窗口内这些旧位置一律丢弃，
   * 既不改 positionMs 也不落盘，避免刚补完 seek 又被一次旧 timeUpdate 写坏历史。
   */
  private resumeHoldUntil: number = 0;
  private resumeHoldTargetMs: number = 0;
  /** 宿主窗口（屏幕常亮 / 前后台监听用；拿不到时为 null） */
  private hostWindow: window.Window | null = null;
  /** windowEvent 回调（注册与反注册必须同一引用） */
  private windowEventHandler: (data: window.WindowEventType) => void = () => {
  };
  /** 当前是否已向窗口申请屏幕常亮（避免重复调用） */
  private keepScreenOnActive: boolean = false;
  /** 是否因「页面被其他页面完全覆盖」而暂停（避免可见区变化回调重复落盘 / 暂停） */
  private hiddenByCover: boolean = false;
  /** 全屏 / 方向切换保护窗口是否进行中（期间忽略「可见比例 0 / 窗口隐藏」触发的暂停） */
  private orientationGuarding: boolean = false;
  /** 保护窗口自动复位定时器 id（-1 = 无） */
  private orientationGuardTimer: number = -1;
  /** 保护窗口结束后「被抑制的暂停」延迟确认定时器 id（-1 = 无） */
  private orientationRecheckTimer: number = -1;
  /** 保护窗口内出现过 WINDOW_HIDDEN 且之后没回到前台：延迟确认后补一次真后台暂停 */
  private pendingHiddenPause: boolean = false;
  /** 保护窗口内出现过「可见比例 0」且之后没回到完全可见：延迟确认后补暂停 */
  private pendingCoverPause: boolean = false;
  /** 折叠触发的暂停是否进行中：该暂停的 paused 回调不主动唤出控制层（避免收缩动画中控制条闪现） */
  private collapsePausePending: boolean = false;

  aboutToAppear(): void {
    this.instanceSeq = inlinePlayerSeq;
    inlinePlayerSeq = inlinePlayerSeq + 1;
    // XComponent id 一旦确定不再变化：AVPlayer 的 surfaceId 绑定依赖它
    this.xcomponentId = 'hanime_inline_player_' + this.video.videoCode + '_' + this.instanceSeq;
    this.surfaceController.onReady = (surfaceId: string) => {
      this.surfaceId = surfaceId;
      this.applySurface();
    };
    this.handle.pauseAndSave = () => {
      this.pauseAndSave();
    };
    this.handle.togglePlay = () => {
      this.togglePlay();
    };
    this.handle.beginOrientationChange = () => {
      this.beginOrientationGuard();
    };
    this.handle.isPlayingNow = () => {
      return this.isPlayerPlayingNow();
    };
    this.handle.resumeAfterCollapse = () => {
      this.resumeAfterCollapsePlayback();
    };
    this.handle.pauseForCollapse = () => {
      this.pauseForCollapsePlayback();
    };
    this.handle.currentPositionMs = () => {
      return this.positionMs;
    };
    this.handle.currentDurationMs = () => {
      return this.durationMs;
    };
    // 宿主窗口：屏幕常亮 + 前后台监听（后台暂停、回前台不自动播）
    this.bindHostWindow(true);
    // 系统媒体音量：入页先同步一次，竖滑起点的百分比才与系统音量一致（失败保留 0.5 兜底）
    this.syncSystemVolume(false);
    this.preparePlayback();
    // 控制层自动隐藏计时不在 aboutToAppear 里启动：它只由「用户操作 / 播放真正开始（playing 变化）」
    // 重新计时，避免页面初始化这种程序性时序重置 / 提前消耗掉那一次计时。
  }

  aboutToDisappear(): void {
    this.disposed = true;
    this.clearHideTimer();
    this.clearGestureTimers();
    this.clearResumeTimer();
    this.clearRetryTimer();
    // 保护窗口 / 延迟补暂停的定时器必须先清掉，避免打到已经释放的播放器上
    this.clearOrientationGuard();
    this.endSpeedBoost();
    this.saveProgressNow();
    // 先关常亮再解绑窗口监听（解绑后拿不到窗口就无法关闭常亮），最后释放播放器
    this.applyKeepScreenOn(false);
    // 离场恢复进入页面时的窗口亮度（原值 -1 → 恢复跟随系统），必须在解绑窗口前执行
    this.restoreWindowBrightness();
    this.unbindHostWindow();
    this.releasePlayer();
  }

  /**
   * 播放状态变化：通知父页面更新动作区按钮文案；暂停 / 播完时把控制层唤出（中央播放 / 重播按钮随之出现）。
   *
   * 控制层自动隐藏计时只在这里按「播放真正开始」重新开始：
   *  - playing → true：重新计时（起播 / 暂停后恢复 / 缓冲恢复都会走到，修复首播后控制层一直不隐藏）；
   *  - playing → false（暂停 / 播完）：按既有策略控制层常显，清掉计时器（不在暂停时倒计时）；
   *    这里的唤出属于播放状态驱动的程序性更新，不参与「用户操作重置 5 秒」。
   */
  onPlayingStateChanged(): void {
    this.onPlaybackStateChange(this.playing);
    if (!this.playing && !this.useWeb &&
      (this.playerState === 'paused' ||
        (this.playerState === 'completed' && !this.looping))) {
      if (this.collapsePausePending) {
        // 折叠触发的暂停：画面正在收缩 / 已隐藏，不再主动唤出控制层（用户没操作播放器）
        this.collapsePausePending = false;
      } else {
        // 暂停 / 播完：控制层常显，停止自动隐藏倒计时
        this.clearHideTimer();
        this.setControlsVisible(true);
      }
    }
    if (this.playing) {
      this.collapsePausePending = false;
      // 播放开始 / 恢复：启动（或重新开始）自动隐藏计时
      this.scheduleHideControls();
    }
    this.updateKeepScreenOn();
  }

  /** 清掉手势相关的延迟定时器（离屏 / 取消拖动时调用） */
  clearGestureTimers(): void {
    if (this.singleTapTimer !== -1) {
      clearTimeout(this.singleTapTimer);
      this.singleTapTimer = -1;
    }
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
    this.clearLongPressTimer();
  }

  // ---------------------------------------------------------------------------
  // 宿主窗口：屏幕常亮 + 前后台生命周期（对标原版 keepScreenOn / ON_STOP 暂停）
  // ---------------------------------------------------------------------------

  /** 取宿主窗口（拿不到时返回 null，不抛出） */
  private async fetchHostWindow(): Promise<window.Window | null> {
    const context: common.Context | undefined = this.getUIContext().getHostContext();
    if (context === undefined) {
      return null;
    }
    try {
      return await window.getLastWindow(context);
    } catch (e) {
      return null;
    }
  }

  /**
   * 绑定宿主窗口：注册 windowEvent 监听（后台暂停 / 失焦落盘），
   * 并按当前播放状态同步一次屏幕常亮。
   * @param retry 首次拿不到窗口时延迟重试一次（页面刚创建时 UIContext 可能尚未就绪）
   */
  private bindHostWindow(retry: boolean): void {
    this.fetchHostWindow().then((win: window.Window | null) => {
      if (this.disposed) {
        return;
      }
      if (win === null) {
        if (retry) {
          setTimeout(() => {
            if (!this.disposed && this.hostWindow === null) {
              this.bindHostWindow(false);
            }
          }, 500);
        }
        return;
      }
      this.hostWindow = win;
      // 进页面时读一次窗口亮度作为亮度手势起点（-1 跟随系统 → 0.5），离场 / 退全屏时恢复
      this.initWindowBrightness(win);
      this.windowEventHandler = (data: window.WindowEventType) => {
        this.handleWindowEvent(data);
      };
      try {
        win.on('windowEvent', this.windowEventHandler);
      } catch (e) {
        // 个别设备 / 窗口类型不支持 windowEvent：仅失去前后台暂停能力，不影响播放
      }
      this.updateKeepScreenOn();
    }).catch((err: Error) => {
      // 拿窗口失败不阻断播放
    });
  }

  /** 解绑窗口监听（aboutToDisappear 调用，幂等） */
  private unbindHostWindow(): void {
    const win: window.Window | null = this.hostWindow;
    this.hostWindow = null;
    if (win === null) {
      return;
    }
    try {
      win.off('windowEvent', this.windowEventHandler);
    } catch (e) {
      // 解绑失败不影响页面销毁
    }
  }

  /**
   * 窗口事件（对齐原版 VideoRouteHostScreen 的 Lifecycle 处理）：
   *  - WINDOW_INACTIVE（失焦，如通知栏 / 弹窗）：只落盘进度（≈ ON_PAUSE）；
   *  - WINDOW_HIDDEN（切后台 / 息屏）：落盘进度并暂停，回前台不自动播（≈ ON_STOP）。
   */
  private handleWindowEvent(data: window.WindowEventType): void {
    if (this.disposed || this.useWeb) {
      return;
    }
    // 全屏 / 方向切换保护窗口：旋转 + 系统栏切换期间的窗口事件不触发暂停（见下方保护窗口说明）
    if (this.orientationGuarding) {
      this.handleWindowEventDuringOrientation(data);
      return;
    }
    if (data === window.WindowEventType.WINDOW_INACTIVE) {
      this.saveProgressNow();
      this.updateKeepScreenOn();
      return;
    }
    if (data === window.WindowEventType.WINDOW_HIDDEN) {
      this.saveProgressNow();
      this.pauseFromBackground();
      this.updateKeepScreenOn();
      return;
    }
    if (data === window.WindowEventType.WINDOW_SHOWN ||
      data === window.WindowEventType.WINDOW_ACTIVE) {
      // 回前台不自动播（原版策略）；只把屏幕常亮恢复成当前播放状态。
      // 同时撤销保护窗口遗留的「真后台」待处理标记（窗口结束时不再补暂停）
      this.pendingHiddenPause = false;
      this.updateKeepScreenOn();
    }
  }

  /**
   * 播放区可见比例变化（≈ 原版 Lifecycle ON_STOP）：
   * 详情页被别的页面（登录 / 网页 / 其他视频等）完全覆盖时落盘进度并暂停，
   * 回到详情页不自动续播（原版策略）；被部分遮挡（转场动画中）不处理。
   */
  private handleVisibleAreaChange(isVisible: boolean, currentRatio: number): void {
    if (this.disposed || this.useWeb) {
      return;
    }
    // 全屏 / 方向切换保护窗口：旋转 / 系统栏切换瞬间可见比例会短暂回调为 0，不能当成被覆盖
    if (this.orientationGuarding) {
      this.handleVisibleAreaChangeDuringOrientation(isVisible, currentRatio);
      return;
    }
    // 父页面折叠隐藏播放器（宽高 0 / Visibility.None）不是「被二级页覆盖」：
    // 继续播放（只隐藏画面，保留声音），也不落盘进度。见 keepPlayingWhenHidden 注释。
    if (this.keepPlayingWhenHidden) {
      this.hiddenByCover = false;
      // 折叠是用户主动隐藏，撤销保护窗口遗留的「被覆盖」待处理标记，避免稍后误补暂停
      this.pendingCoverPause = false;
      return;
    }
    if (!isVisible || currentRatio <= 0.01) {
      if (!this.hiddenByCover) {
        this.hiddenByCover = true;
        this.saveProgressNow();
        this.pauseFromBackground();
      }
      this.pendingCoverPause = false;
      return;
    }
    // 可见比例 > 0.01：没有被完全覆盖，撤销保护窗口遗留的「待补暂停」
    this.pendingCoverPause = false;
    if (currentRatio >= 0.99) {
      this.hiddenByCover = false;
      this.updateKeepScreenOn();
    }
  }

  /** 切后台时静默暂停（不弹 Toast，不改变手势 / 弹窗等 UI 状态） */
  private pauseFromBackground(): void {
    this.endSpeedBoost();
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      if (player.state === 'playing') {
        player.pause().catch((err: BusinessError) => {
          // 后台暂停失败不提示
        });
      }
    } catch (e) {
      // 播放器可能已被释放
    }
  }

  /** 当前状态是否应保持屏幕常亮（对齐原版 PLAYING / BUFFERING / PREPARING） */
  private shouldKeepScreenOn(): boolean {
    if (this.useWeb || this.disposed) {
      return false;
    }
    const state: string = this.playerState;
    return state === 'playing' || state === 'prepared' ||
      state === 'initialized';
  }

  /** 按当前状态申请 / 释放屏幕常亮（setWindowKeepScreenOn 用 try/catch 包裹） */
  private updateKeepScreenOn(): void {
    this.applyKeepScreenOn(this.shouldKeepScreenOn());
  }

  private applyKeepScreenOn(on: boolean): void {
    if (on === this.keepScreenOnActive) {
      return;
    }
    const win: window.Window | null = this.hostWindow;
    if (win === null) {
      // 窗口还没拿到：状态先记下，绑定窗口成功后会补一次
      this.keepScreenOnActive = false;
      return;
    }
    this.keepScreenOnActive = on;
    try {
      win.setWindowKeepScreenOn(on).catch((err: BusinessError) => {
        // 常亮设置失败不影响播放
      });
    } catch (e) {
      // 窗口异常时忽略
    }
  }

  // ---------------------------------------------------------------------------
  // 手势的底层控制对象：系统媒体音量 + 窗口亮度（对齐 PuraPily）
  //
  // 旧实现里音量只调 AVPlayer.setVolume（播放器增益），亮度用画面黑色遮罩 alpha 模拟；
  // 现在改为真正调系统媒体音量与窗口亮度：
  //  - 系统音量 API 失败（设备 / 权限 / 未读到最大档位）时回退 AVPlayer.setVolume，保证手势仍然可用；
  //  - 窗口亮度在进页面时读取原值，退出全屏 / 离开页面时恢复（原值 -1 = 跟随系统，恢复 -1）。
  // ---------------------------------------------------------------------------

  /** 退出全屏 / 重新进入全屏：退出时恢复进入页面时的窗口亮度 */
  onFullscreenChanged(): void {
    if (!this.fullscreen) {
      this.restoreWindowBrightness();
    }
  }

  /**
   * 进页面时读窗口当前亮度作为亮度手势起点。
   * getWindowProperties().brightness 为 -1 表示跟随系统，按 0.5 作为起点（任务约定）。
   */
  private initWindowBrightness(win: window.Window): void {
    try {
      const properties: window.WindowProperties = win.getWindowProperties();
      const current: number = properties.brightness;
      this.windowBrightnessOriginal = Number.isFinite(current) ? current : -1;
      const base: number = current >= 0 ? Math.min(1, Math.max(0, current)) : DEFAULT_WINDOW_BRIGHTNESS;
      this.brightnessLevel = base;
      this.gestureStartBrightness = base;
    } catch (e) {
      // 读窗口属性失败：按跟随系统 / 0.5 兜底，不影响其它播放逻辑
      this.windowBrightnessOriginal = -1;
      this.brightnessLevel = DEFAULT_WINDOW_BRIGHTNESS;
      this.gestureStartBrightness = DEFAULT_WINDOW_BRIGHTNESS;
    }
  }

  /** 把亮度下发到窗口亮度（0~1）；失败静默忽略（不影响播放与画面） */
  private applyWindowBrightness(level: number): void {
    const win: window.Window | null = this.hostWindow;
    if (win === null) {
      return;
    }
    const target: number = Math.min(1, Math.max(0, level));
    this.windowBrightnessApplied = true;
    try {
      win.setWindowBrightness(target).catch((err: BusinessError) => {
        // 窗口亮度设置失败：保持系统亮度，不影响播放
      });
    } catch (e) {
      // 低版本 / 窗口异常时忽略
    }
  }

  /**
   * 恢复进入页面时的窗口亮度（离开页面 / 退出全屏时调用，幂等）。
   * 原值为 -1 表示跟随系统：直接恢复 -1（而不是写死某个亮度）。
   */
  private restoreWindowBrightness(): void {
    if (!this.windowBrightnessApplied) {
      return;
    }
    this.windowBrightnessApplied = false;
    const win: window.Window | null = this.hostWindow;
    const original: number = Number.isFinite(this.windowBrightnessOriginal) ? this.windowBrightnessOriginal : -1;
    // 亮度已回到原值：手势起点同步回原值（-1 跟随系统按 0.5 计）
    const base: number = original >= 0 ? Math.min(1, Math.max(0, original)) : DEFAULT_WINDOW_BRIGHTNESS;
    this.brightnessLevel = base;
    this.gestureStartBrightness = base;
    if (win === null) {
      return;
    }
    try {
      win.setWindowBrightness(original).catch((err: BusinessError) => {
        // 恢复失败不提示（窗口已销毁 / 权限异常）
      });
    } catch (e) {
      // 窗口异常时忽略
    }
  }

  /**
   * 读取系统媒体音量并归一化到 0~1。
   * 读取失败（API 不可用 / 没有权限 / 拿不到最大档位）返回 -1，调用方用本地 0.5 兜底。
   */
  private async readSystemVolume(): Promise<number> {
    try {
      const manager: audio.AudioManager = audio.getAudioManager();
      const volume: number = await manager.getVolume(audio.AudioVolumeType.MEDIA);
      if (!Number.isFinite(volume) || volume < 0) {
        return -1;
      }
      let max: number = this.systemVolumeMax;
      if (!(max > 0)) {
        max = await manager.getMaxVolume(audio.AudioVolumeType.MEDIA);
        if (!(max > 0) || !Number.isFinite(max)) {
          return -1;
        }
        this.systemVolumeMax = max;
      }
      const ratio: number = volume / max;
      if (!Number.isFinite(ratio)) {
        return -1;
      }
      return Math.min(1, Math.max(0, ratio));
    } catch (e) {
      return -1;
    }
  }

  /**
   * 入页 / 手势开始时同步系统媒体音量。
   *
   * @param gestureStart true = 手势开始（结果作为本次竖滑的起点；本次手势已改过音量则不覆盖）
   *                     false = 入页初始化（只刷新当前音量状态）
   *
   * 读不到时按任务约定用本地 0.5 作为起点（不回退到上次的 UI 值，避免与系统音量不一致）。
   */
  private syncSystemVolume(gestureStart: boolean): void {
    this.readSystemVolume().then((volume: number) => {
      if (this.disposed) {
        return;
      }
      if (gestureStart) {
        // 手指已抬起 / 已是别的（非音量）手势：不覆盖最终音量
        if (this.touchId === -1 && this.gestureMode.length === 0) {
          return;
        }
        if (this.gestureMode === 'volume' && this.volumeGestureApplied) {
          return;
        }
      }
      const next: number = volume >= 0 ? volume : DEFAULT_SYSTEM_VOLUME;
      this.volumeLevel = next;
      if (gestureStart) {
        this.gestureStartVolume = next;
      }
    }).catch((err: Error) => {
      // 读系统音量失败不影响手势：本地用 0.5 兜底
    });
  }

  /** 回退方案：系统音量不可用时改用 AVPlayer 自身增益（0~1） */
  private fallbackToPlayerVolume(level: number): void {
    this.usingPlayerGainFallback = true;
    this.applyPlayerGain(level);
  }

  /** 设置 AVPlayer 自身增益（0~1）；只在系统媒体音量不可用时作为回退使用 */
  private applyPlayerGain(level: number): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const state: string = player.state;
      if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
        player.setVolume(Math.min(1, Math.max(0, level)));
      }
    } catch (e) {
      // 音量设置失败不阻断播放
    }
  }

  // ---------------------------------------------------------------------------
  // 全屏 / 方向切换保护窗口
  //
  // 背景：页内全屏切换会调用 window.setPreferredOrientation + setWindowSystemBarEnable，
  // 窗口旋转 / 系统栏切换过程中 ArkUI 的可见区域与窗口事件都会出现瞬态：
  //  - onVisibleAreaChange 可能短暂回调 currentRatio = 0（华为官方 FAQ 在「旋转窗口切换全屏」
  //    场景同样提到「组件可见区域会短暂回调为 0」/「真正打断全屏的是 onVisibleAreaChange
  //    中的 stop()」）。旧逻辑把它当成「详情页被二级页完全覆盖」→ 落盘 + 暂停，
  //    于是退出全屏后视频停住、还要手动点播放；
  //  - windowEvent 也可能短暂派发 WINDOW_INACTIVE（失焦）甚至 WINDOW_HIDDEN。
  // 保护窗口（父页面 VideoPage 在 enterFullscreen / exitFullscreen 开始时通过
  // InlinePlayerHandle.beginOrientationChange 打开）内，这两种信号都不暂停，只落盘进度；
  // 窗口由本组件定时器在 ORIENTATION_GUARD_MS 后自动复位（不会永久抑制）。
  // 若窗口内确实出现过「窗口隐藏且未回到前台」或「持续不可见」，
  // 窗口结束时会补一次落盘 + 暂停，保证 HOME / 息屏等真后台行为不被削弱。
  // ---------------------------------------------------------------------------

  /**
   * 打开（或重新计时）全屏 / 方向切换保护窗口。
   *
   * 只由父页面在进入 / 退出全屏时调用；内部定时器负责复位，父页面不需要配对关闭。
   * 重复调用（例如退出全屏紧接着又进入全屏）会清掉上一次的待处理标记并重新计时。
   */
  private beginOrientationGuard(): void {
    if (this.disposed) {
      return;
    }
    // 进出全屏（旋转 + 系统栏切换）前先落一次盘：窗口内若被系统打断也不会丢进度
    this.saveProgressNow();
    this.orientationGuarding = true;
    this.pendingHiddenPause = false;
    this.pendingCoverPause = false;
    if (this.orientationRecheckTimer !== -1) {
      clearTimeout(this.orientationRecheckTimer);
      this.orientationRecheckTimer = -1;
    }
    if (this.orientationGuardTimer !== -1) {
      clearTimeout(this.orientationGuardTimer);
    }
    this.orientationGuardTimer = setTimeout(() => {
      this.orientationGuardTimer = -1;
      this.endOrientationGuard();
    }, ORIENTATION_GUARD_MS);
  }

  /**
   * 保护窗口结束（超时复位）：恢复常规判定，并对窗口内被抑制的信号做一次延迟确认。
   *
   * 延迟确认（ORIENTATION_GUARD_RECHECK_MS）期间：
   *  - 收到 WINDOW_SHOWN / WINDOW_ACTIVE → 撤销「真后台」标记，不暂停；
   *  - 播放区可见比例恢复到非 0（> 0.01）→ 撤销「被覆盖」标记，继续播放；
   *  - 两者都没发生（窗口一直隐藏 / 一直不可见）→ 判定为真后台 / 真被覆盖，
   *    补一次落盘 + 暂停，保证 HOME / 息屏 / 打开二级页仍会暂停。
   */
  private endOrientationGuard(): void {
    this.orientationGuarding = false;
    if (this.disposed) {
      this.pendingHiddenPause = false;
      this.pendingCoverPause = false;
      return;
    }
    if (!this.pendingHiddenPause && !this.pendingCoverPause) {
      return;
    }
    if (this.orientationRecheckTimer !== -1) {
      clearTimeout(this.orientationRecheckTimer);
    }
    this.orientationRecheckTimer = setTimeout(() => {
      this.orientationRecheckTimer = -1;
      if (this.disposed || this.orientationGuarding) {
        return;
      }
      if (!this.pendingHiddenPause && !this.pendingCoverPause) {
        return;
      }
      this.pendingHiddenPause = false;
      this.pendingCoverPause = false;
      this.hiddenByCover = true;
      this.saveProgressNow();
      this.pauseFromBackground();
      this.updateKeepScreenOn();
    }, ORIENTATION_GUARD_RECHECK_MS);
  }

  /** 清掉保护窗口相关定时器与待处理标记（页面销毁时调用，防止定时器打到已释放的播放器） */
  private clearOrientationGuard(): void {
    if (this.orientationGuardTimer !== -1) {
      clearTimeout(this.orientationGuardTimer);
      this.orientationGuardTimer = -1;
    }
    if (this.orientationRecheckTimer !== -1) {
      clearTimeout(this.orientationRecheckTimer);
      this.orientationRecheckTimer = -1;
    }
    this.orientationGuarding = false;
    this.pendingHiddenPause = false;
    this.pendingCoverPause = false;
  }

  /** 保护窗口内的窗口事件：只落盘 / 记录待处理，不暂停（真后台在窗口结束时补暂停） */
  private handleWindowEventDuringOrientation(data: window.WindowEventType): void {
    if (data === window.WindowEventType.WINDOW_HIDDEN) {
      this.pendingHiddenPause = true;
      this.saveProgressNow();
      return;
    }
    if (data === window.WindowEventType.WINDOW_INACTIVE) {
      // 失焦只落盘（与常规逻辑一致），本来就不暂停
      this.saveProgressNow();
      return;
    }
    if (data === window.WindowEventType.WINDOW_SHOWN ||
      data === window.WindowEventType.WINDOW_ACTIVE) {
      // 回到前台：撤销「真后台」待处理标记，窗口结束时不再补暂停
      this.pendingHiddenPause = false;
      this.updateKeepScreenOn();
    }
  }

  /** 保护窗口内的可见区域回调：旋转瞬态不视为「被覆盖」，只记录待处理，不暂停 */
  private handleVisibleAreaChangeDuringOrientation(isVisible: boolean, currentRatio: number): void {
    if (!isVisible || currentRatio <= 0.01) {
      this.pendingCoverPause = true;
      this.saveProgressNow();
      return;
    }
    // 只要不是接近 0 的瞬态（旋转 / 布局动画过程中），就说明没有被完全覆盖：撤销待补暂停
    this.pendingCoverPause = false;
    if (currentRatio >= 0.99) {
      // 布局已收敛、播放区完全可见：恢复常规可见状态，保持播放
      this.hiddenByCover = false;
      this.updateKeepScreenOn();
    }
  }

  // ---------------------------------------------------------------------------
  // 续播提示（「从头播放」胶囊）
  // ---------------------------------------------------------------------------

  private clearResumeTimer(): void {
    if (this.resumeTimerId !== -1) {
      clearTimeout(this.resumeTimerId);
      this.resumeTimerId = -1;
    }
  }

  /** 续播成功后浮出「从头播放」胶囊，5s 后自动隐藏（对齐原版 ShowResumeButton） */
  private showResumeChip(): void {
    this.clearResumeTimer();
    this.resumeVisible = true;
    this.resumeTimerId = setTimeout(() => {
      this.resumeTimerId = -1;
      if (!this.disposed) {
        this.resumeVisible = false;
      }
    }, RESUME_CHIP_MS);
  }

  private hideResumeChip(): void {
    this.clearResumeTimer();
    this.resumeVisible = false;
  }

  /**
   * 「从头播放」：seek 回 0，继续播放（与原版 controller.restartFromBeginning 一致：play + seek 0），
   * 并把进度显式归零落库（普通 saveProgress 的合并语义写不进 0，必须走 resetProgress）。
   */
  restartFromBeginning(): void {
    this.hideResumeChip();
    this.seeking = false;
    this.positionMs = 0;
    this.lastSavedMs = 0;
    // 用户主动从头：作废任何在途的续播 seek 目标，避免后面的补偿逻辑又跳回续播点
    this.pendingSeekMs = 0;
    this.resumeTargetMs = 0;
    this.resumeSeekApplied = true;
    this.resumeFromHistory = false;
    this.resumeHoldUntil = 0;
    this.resumeHoldTargetMs = 0;
    this.seekTo(0);
    this.resetProgressInDb();
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      if (player.state === 'paused' || player.state === 'prepared') {
        player.play().catch((err: BusinessError) => {
          Toast.show('播放失败：' + err.message);
        });
      }
    } catch (e) {
      // 播放器已释放
    }
  }

  /** 显式把进度归零落库（「从头播放」用；不受 positionMs>0 落盘规则限制） */
  private resetProgressInDb(): void {
    const video: HanimeVideo = this.video;
    if (video.videoCode.length === 0) {
      return;
    }
    LocalRepo.getInstance().resetProgress(video.videoCode).then(() => {
      notifyLibraryChanged();
    }).catch((err: Error) => {
      // 归零写库失败不影响本地播放（下次进入可能仍续播到旧位置）
    });
  }

  displayTitle(): string {
    if (this.video.title.length > 0) {
      return this.video.title;
    }
    return '播放器';
  }

  // ---------------------------------------------------------------------------
  // 原生播放失败自动重试（url / headers 轮换，递增间隔，3 次后才降级网页播放）
  // ---------------------------------------------------------------------------

  private clearRetryTimer(): void {
    if (this.retryTimerId !== -1) {
      clearTimeout(this.retryTimerId);
      this.retryTimerId = -1;
    }
  }

  /**
   * 清空自动重试状态（定时器 + 次数 + 重试浮层）：
   * 成功起播 / 用户手动切换清晰度 / 手动「重试原生」/ 降级网页播放 / 页面销毁时调用。
   */
  private clearAutoRetry(): void {
    this.clearRetryTimer();
    this.retryCount = 0;
    this.retrySeekMs = 0;
    this.forceHeadersAttach = false;
    if (this.retrying) {
      this.retrying = false;
    }
    if (this.retryAttempt !== 0) {
      this.retryAttempt = 0;
    }
  }

  /**
   * 排一次自动重试（失败入口，防抖后调用）：
   *  - 已达上限 → 结束重试，降级网页播放（错误面板显示最后一次失败原因）；
   *  - 未达上限 → 记录当前进度，按 800 / 1500 / 2500ms 递增间隔后重新 loadSource。
   * 重试期间 buffering = true（中央 Loading 可见）并显示「正在重试（n/3）」浮层；
   * 同时收掉「从头播放」胶囊，避免两个浮层叠在一起。
   */
  private scheduleAutoRetry(reason: string): void {
    if (this.disposed || this.useWeb) {
      return;
    }
    this.clearLoadTimer();
    if (this.retryCount >= AUTO_RETRY_MAX) {
      this.clearAutoRetry();
      // 原生播放重试用尽：降级网页播放
      this.fallbackToWeb(reason);
      return;
    }
    this.hideResumeChip();
    this.retryCount = this.retryCount + 1;
    this.retryAttempt = this.retryCount;
    this.retrying = true;
    this.buffering = true;
    this.mediaError = '';
    // 从失败时的当前进度继续重试；还没有任何进度时（prepared 前失败）取续播目标 / 待应用 seek，
    // 保证自动重试不会把「从历史续播」丢成从 0 开始
    this.retrySeekMs = this.positionMs > 0 ? this.positionMs : this.pendingSeekMs;
    if (this.retrySeekMs <= 0 && !this.resumeSeekApplied) {
      this.retrySeekMs = this.resumeTargetMs;
    }
    const delayIndex: number = Math.min(this.retryCount - 1, AUTO_RETRY_DELAYS_MS.length - 1);
    const delayMs: number = AUTO_RETRY_DELAYS_MS[delayIndex];
    this.clearRetryTimer();
    this.retryTimerId = setTimeout(() => {
      this.retryTimerId = -1;
      if (this.disposed || this.useWeb) {
        return;
      }
      this.performAutoRetry();
    }, delayMs);
  }

  /**
   * 执行一次自动重试：reset AVPlayer → 重新 loadSource。
   * 加载方式轮换：第 1 / 3 次用 `url` 直连、第 2 次用带头 MediaSource（url → headers → url），
   * 与原有「url 失败换带头方式」的策略互补，避免几次重试都撞在同一种注定失败的路径上。
   */
  private performAutoRetry(): void {
    if (this.disposed || this.useWeb || this.video.sources.length === 0) {
      return;
    }
    // retryCount 为奇数（第 1 / 3 次）走 url，偶数（第 2 次）走 headers
    this.forceHeadersAttach = this.retryCount % 2 === 0;
    this.loadSource(this.qualityIndex, this.retrySeekMs);
  }

  /**
   * 单次加载失败处理（AVPlayer error / error 状态 / 加载超时 / loadSource 抛错统一入口）。
   *
   * 顺序：
   *  1) 本次尝试的另一种加载方式还没试过 → 立即切换（保持原有 url → headers 兜底，不打乱播放策略）；
   *  2) 两种方式都失败 → 进入自动重试（最多 AUTO_RETRY_MAX 次，递增间隔）；
   *  3) 自动重试次数用尽 → 降级网页播放（见 scheduleAutoRetry）。
   * attemptFailureHandled 保证同一次失败只会被消费一次。
   */
  handlePlayerError(message: string): void {
    if (this.disposed || this.useWeb) {
      return;
    }
    this.clearLoadTimer();
    // 同一方式下的另一种加载路径还没试过：立即切换（不消耗自动重试次数）
    if (!this.headersTried && this.avPlayer !== null) {
      this.headersTried = true;
      // 带头方式是新的一次尝试，允许它失败后继续进入自动重试
      this.attemptFailureHandled = false;
      this.tryHeadersAttach();
      return;
    }
    if (this.attemptFailureHandled) {
      return;
    }
    this.attemptFailureHandled = true;
    this.scheduleAutoRetry(message);
  }

  // ---------------------------------------------------------------------------
  // 初始化 / 媒体源
  // ---------------------------------------------------------------------------

  /**
   * 父页面已经加载好详情，这里只做播放器侧的初始化：
   * 计算网页播放地址 → 没有可播地址直接网页降级 → 选清晰度/倍速 → 取续播位置 → 起播。
   */
  async preparePlayback(): Promise<void> {
    this.watchUrl = buildWatchUrl(AppSettings.getInstance().getBaseUrl(), this.video.videoCode);
    if (this.video.sources.length === 0) {
      this.useWeb = true;
      this.mediaError = '未解析到可播放地址，已切换为网页播放';
      Toast.show('未解析到播放地址，已切换网页播放');
      return;
    }
    this.qualityIndex = resolveInitialQuality(this.video.sources,
      AppSettings.getInstance().getPlayerQualityIndex());
    this.speedIndex = this.resolveSpeedIndex(AppSettings.getInstance().getPlayerSpeed());
    const resumeMs: number = await this.resumePosition();
    if (this.disposed) {
      return;
    }
    // 原版只在历史进度超过 5s 时才恢复续播；不足阈值按 0 起播。
    // 续播点单独存到 resumeTargetMs：播放器 prepared 阶段的 seek 可能被丢，
    // 真正「确认落地」由 confirmResumeSeek 在 playing 后的进度回调里完成。
    this.resumeFromHistory = resumeMs > RESUME_THRESHOLD_MS;
    this.resumeTargetMs = this.resumeFromHistory ? Math.round(resumeMs) : 0;
    this.resumeSeekApplied = this.resumeTargetMs <= 0;
    await this.loadSource(this.qualityIndex, this.resumeTargetMs);
  }

  async resumePosition(): Promise<number> {
    try {
      return await LocalRepo.getInstance().getResumePosition(this.video.videoCode);
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
      this.handleSeekDone(time);
    });
    // 解码画幅监听（只新增回调，不改原有播放策略）：父页面据此做容器比例自适应，
    // 本组件同时记下画幅用于媒体层居中 letterbox（全屏 / 竖屏视频不拉伸）。
    player.on('videoSizeChange', (width: number, height: number) => {
      if (this.disposed || width <= 0 || height <= 0) {
        return;
      }
      this.videoWidth = width;
      this.videoHeight = height;
      this.onVideoSizeChange(width, height);
    });
  }

  async loadSource(index: number, seekMs: number): Promise<void> {
    if (this.disposed) {
      return;
    }
    const video: HanimeVideo = this.video;
    if (index < 0 || index >= video.sources.length) {
      return;
    }
    const source: VideoSource = video.sources[index];
    if (!isPlayableUrl(source.url)) {
      this.fallbackToWeb('播放地址无效（' + source.url + '）');
      return;
    }
    // 自动重试方式轮换：本次加载是否强制使用带请求头的 MediaSource（在 await 之前取走标记）
    const useHeaders: boolean = this.forceHeadersAttach;
    this.forceHeadersAttach = false;
    this.sourceUrl = source.url;
    this.headersTried = useHeaders;
    // 新的一次加载尝试：允许失败回调被消费一次（见 handlePlayerError 防抖说明）
    this.attemptFailureHandled = false;
    // 新加载后旧的「补 seek 抑制窗口」不再适用
    this.resumeHoldUntil = 0;
    this.resumeHoldTargetMs = 0;
    // 上一次源的在途 seek / trailing 目标不能带进新源（否则 seekDone 会把旧位置 seek 回来）
    this.seekInFlight = false;
    this.trailingSeekMs = -1;
    this.clearSeekGuard();
    // 播放已结束时切换清晰度 / 重试：从头起播，避免续播到末尾立即 completed
    let effectiveSeek: number = seekMs;
    if (effectiveSeek <= 0 && !this.resumeSeekApplied && this.resumeTargetMs > 0) {
      // 自动重试 / 降级回 AV / surface 重建等路径可能传 0：续播点还没落地时以续播目标为准，
      // 不能因为一次 0 参数就把真实进度丢掉（这是「重试后从 0 开始」的直接原因）。
      effectiveSeek = this.resumeTargetMs;
    }
    if (this.completed) {
      effectiveSeek = 0;
      this.completed = false;
    }
    this.pendingSeekMs = effectiveSeek > 0 ? effectiveSeek : 0;
    if (this.pendingSeekMs > 0 && !this.resumeSeekApplied) {
      // 本次加载仍带着续播目标：加载成功后由 confirmResumeSeek 确认落地
      this.resumeTargetMs = this.pendingSeekMs;
    }
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
      // 自动重试时按 performAutoRetry 的轮换结果直接走指定方式。
      if (useHeaders) {
        await this.tryHeadersAttach();
      } else {
        this.attachByUrl();
      }
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
      // 换成带头方式属于新的一次尝试：允许它失败后继续走自动重试
      this.attemptFailureHandled = false;
      this.tryHeadersAttach();
    }
  }

  /**
   * 方式二：带 Referer / UA / Cookie 的 MediaSource（部分 CDN 防盗链时需要）。
   * 只在 url 方式失败时尝试一次；失败后进入自动重试（而不是立刻降级网页播放）。
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
      this.handlePlayerError('播放地址加载失败（' + err.message + '）');
    }
  }

  /**
   * 12 秒内没有进入 initialized/prepared/playing 就认为该方式失败：
   * 先按 handlePlayerError 切换另一种加载方式，再进入自动重试，次数用尽才降级网页播放。
   */
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
        state === 'paused' || state === 'completed') {
        return;
      }
      this.handlePlayerError('媒体加载超时：CDN 可能在当前网络不可达（已自动重试 ' +
        AUTO_RETRY_MAX + ' 次）');
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
      // 循环播放（对齐原版底栏 Repeat）
      this.applyLooping();
      // 音量：系统媒体音量由系统统一控制，播放器自身增益默认保持 1.0；
      // 只有系统音量 API 不可用、已回退到播放器增益时，才把回退值重新应用到新起播的播放器
      this.applyPlayerGain(this.usingPlayerGainFallback ? this.volumeLevel : 1);
      let target: number = this.pendingSeekMs;
      const fromHistory: boolean = this.resumeFromHistory && target > 0;
      if (fromHistory) {
        // 历史续播：接近结尾视为已看完，回退到 0（否则 seek 到结尾后 play 会立即 completed）
        const duration: number = this.durationMs > 0 ? this.durationMs : player.duration;
        if (duration > 0 && target >= duration - RESUME_END_GUARD_MS) {
          target = 0;
        }
        this.resumeFromHistory = false;
      }
      if (target > 0) {
        // 起播续播同样走精确 seek：SEEK_PREV_SYNC 会退到关键帧，续播点会明显偏前；
        // 这里统一用 SEEK_CLOSEST，并复用 issueSeek 的「在途 seek 排队」逻辑
        this.positionMs = target;
        this.seekTargetMs = target;
        this.seeking = true;
        this.issueSeek(target);
        if (fromHistory) {
          // 仅「从观看历史续播」时浮出「从头播放」胶囊 5s（切清晰度保位置不提示）。
          // 这里只记录目标、不清 pendingSeekMs：prepared 内的 seek 不保证落地，
          // playing 后的首个进度回调里由 confirmResumeSeek 确认 / 补偿。
          this.resumeTargetMs = target;
          this.resumeSeekApplied = false;
          this.pendingSeekMs = target;
          this.showResumeChip();
        } else {
          this.pendingSeekMs = 0;
        }
      } else {
        this.pendingSeekMs = 0;
        if (fromHistory) {
          // 续播点接近结尾被回退到 0：本场从头播，作废续播待办，
          // 否则 isResumeSeekPending() 会一直为 true、导致后续进度永远不落盘
          this.resumeTargetMs = 0;
          this.resumeSeekApplied = true;
        }
      }
      player.play().catch((err: BusinessError) => {
        this.handlePlayerError('播放失败：' + err.message);
      });
      this.updateKeepScreenOn();
    } else if (state === 'playing') {
      this.playing = true;
      this.buffering = false;
      this.completed = false;
      // 重新开始播放：清掉「页面被覆盖」标记，下一次被覆盖仍能触发暂停
      this.hiddenByCover = false;
      // 真正进入播放 = 本次加载（含自动重试）成功：清空自动重试计数与「正在重试」浮层
      this.clearAutoRetry();
      // 续播落地判定同样交给首个真实进度回调（prepared 里的 positionMs 只是预设目标值）
      this.updateKeepScreenOn();
    } else if (state === 'paused') {
      this.playing = false;
      // 暂停即落盘（不依赖 5s 节流）：避免「暂停后直接退出 / 杀进程」丢最后一段进度
      this.saveProgressNow();
      this.updateKeepScreenOn();
    } else if (state === 'completed') {
      this.playing = false;
      // 循环播放：AVPlayer 会自动回到开头继续播放，不展示「播完 / 重播」UI
      if (this.looping) {
        this.saveProgressNow();
        return;
      }
      this.completed = true;
      this.hideResumeChip();
      // 播放结束位置按末尾记（与 Android onCompleted 后 ON_PAUSE 落盘一致）；
      // 不自动跳转下一个视频，由中央「重播」按钮决定
      this.positionMs = this.durationMs > 0 ? this.durationMs : this.positionMs;
      this.saveProgressNow();
      this.updateKeepScreenOn();
    } else if (state === 'error') {
      this.handlePlayerError('播放器进入错误状态');
    }
  }

  handleTimeUpdate(time: number): void {
    // 刚补过 resume seek：settle 窗口内播放器可能还在报 seek 前的旧位置，丢弃它们。
    // 用户在窗口内主动拖动 / seek 时立即结束抑制，不能和用户操作抢位置。
    if (this.resumeHoldUntil > 0) {
      if (this.seeking) {
        this.resumeHoldUntil = 0;
        this.resumeHoldTargetMs = 0;
      } else if (Date.now() < this.resumeHoldUntil &&
        time < this.resumeHoldTargetMs - RESUME_SEEK_TOLERANCE_MS) {
        this.positionMs = this.resumeHoldTargetMs;
        return;
      } else {
        this.resumeHoldUntil = 0;
        this.resumeHoldTargetMs = 0;
      }
    }
    // 续播 seek 尚未确认落地时：播放器报回来的旧位置（常见为 0）不能写进 positionMs，
    // 更不能落盘 —— 否则历史里的真实续播点会被 0 / 小位置覆盖，下次进入就彻底从 0 开始。
    if (this.resumeTargetMs > 0 && !this.resumeSeekApplied) {
      if (this.confirmResumeSeek(time)) {
        // 刚刚补了一次 seek：本次回调里的旧位置不可信，直接丢弃
        return;
      }
      if (time < this.resumeTargetMs - RESUME_SEEK_TOLERANCE_MS) {
        this.positionMs = this.resumeTargetMs;
        return;
      }
    }
    if (!this.seeking) {
      this.positionMs = time;
    }
    if (time - this.lastSavedMs >= SAVE_INTERVAL_MS || time < this.lastSavedMs) {
      this.lastSavedMs = time;
      this.saveProgress(time);
    }
  }

  /**
   * 确认历史续播 seek 是否真正落地，必要时补一次。
   *
   * 背景：AVPlayer 在 prepared 里「先 seek 再立刻 play」不保证 seek 生效，页面必须独立校验一次
   * （落盘只认页面里的 positionMs）。若播放器实际从 0 起播，而这里不校验，
   * 5s 节流 / 暂停 / 退出落盘就会把 0 写进历史（续播从此永久失效）。
   *
   * @param currentMs 播放器当前上报的位置（毫秒）
   * @returns true = 本次做了一次补偿 seek（调用方应丢弃这次旧位置）；false = 已落地或无需处理
   */
  private confirmResumeSeek(currentMs: number): boolean {
    if (this.resumeTargetMs <= 0 || this.resumeSeekApplied) {
      return false;
    }
    const target: number = this.resumeTargetMs;
    if (currentMs >= target - RESUME_SEEK_TOLERANCE_MS) {
      // seek 已落地：清掉待办，positionMs / lastSavedMs 对齐目标，
      // 避免紧接着的一次 timeUpdate 用旧值触发一次错误落盘
      this.resumeSeekApplied = true;
      this.resumeTargetMs = 0;
      this.pendingSeekMs = 0;
      this.positionMs = currentMs > 0 ? currentMs : target;
      this.lastSavedMs = this.positionMs;
      return false;
    }
    // 播放器还停在旧位置（0 / seek 被重置丢弃）：补一次精确定位
    this.seekTo(target);
    this.positionMs = target;
    this.lastSavedMs = target;
    this.resumeSeekApplied = true;
    this.resumeTargetMs = 0;
    this.pendingSeekMs = 0;
    // 原生 seek 是异步的：完成前继续丢弃旧位置，防止旧 timeUpdate 把刚补的进度写坏
    this.resumeHoldTargetMs = target;
    this.resumeHoldUntil = Date.now() + RESUME_SEEK_TOLERANCE_MS;
    return true;
  }

  /**
   * AVPlayer seek 落地回调。
   *
   *  - 有 trailing 目标（seek 期间又拖 / 又点快进）：只补发最后一个，中间值全部丢弃；
   *  - 否则解锁 seeking，并用 seekDone 给的**真实落点**回写 positionMs —— 不能等下一次
   *    timeUpdate：那之间播放器还会报一次旧位置，进度条就会「弹回原处」。
   */
  private handleSeekDone(time: number): void {
    this.seekInFlight = false;
    this.clearSeekGuard();
    if (this.disposed) {
      return;
    }
    if (this.pointerDown) {
      // 手指还按在进度条上：这次 seekDone 属于上一次 seek，落点已经过时，
      // 不能拿它回写（否则滑块会被拽回旧位置）；松手后的正式 seek 会重新下发。
      this.trailingSeekMs = -1;
      return;
    }
    if (this.trailingSeekMs >= 0) {
      const next: number = this.trailingSeekMs;
      this.trailingSeekMs = -1;
      this.seekTargetMs = next;
      this.positionMs = next;
      this.issueSeek(next);
      return;
    }
    this.seeking = false;
    if (Number.isFinite(time) && time >= 0) {
      this.positionMs = time;
      this.seekTargetMs = time;
      if (time - this.lastSavedMs >= SAVE_INTERVAL_MS || time < this.lastSavedMs) {
        this.lastSavedMs = time;
        this.saveProgress(time);
      }
    }
  }

  handleDurationUpdate(duration: number): void {
    if (duration > 0) {
      this.durationMs = duration;
    }
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
        this.endSpeedBoost();
        player.pause().catch((err: BusinessError) => {
          Toast.show('暂停失败：' + err.message);
        });
      } else if (state === 'paused' || state === 'prepared') {
        player.play().catch((err: BusinessError) => {
          Toast.show('播放失败：' + err.message);
        });
      } else if (state === 'completed') {
        // 播放结束后点中央按钮 = 重播：进度归零后从头播（不自动跳转下一个视频）
        this.completed = false;
        this.hideResumeChip();
        this.positionMs = 0;
        this.lastSavedMs = 0;
        this.pendingSeekMs = 0;
        this.resumeTargetMs = 0;
        this.resumeSeekApplied = true;
        this.resetProgressInDb();
        // 重播回 0 也用 SEEK_CLOSEST：SEEK_PREV_SYNC 在部分流上会停在第一个同步帧之后
        player.seek(0, media.SeekMode.SEEK_CLOSEST);
        player.play().catch((err: BusinessError) => {
          Toast.show('播放失败：' + err.message);
        });
      }
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  /**
   * 精确 seek 到指定毫秒（进度条松手 / 双击快进 / 手势拖拽松手 / 续播补偿都走这里）。
   *
   * 三个关键点，缺一就不准：
   *  1. **只在松手时调用**（调用方保证）：拖动过程中的中间值只更新 UI 与 pendingSeekMs；
   *  2. **SEEK_CLOSEST**：SEEK_PREV_SYNC 会跳到前一个关键帧，看起来就是「快进跳过头」；
   *  3. **乐观落点 + seeking 锁**：立刻把 positionMs 置为目标并锁住 timeUpdate，
   *     等 seekDone 拿到真实落点再回写，不会被旧位置覆盖（「弹回原处」）。
   */
  seekTo(positionMs: number): void {
    const target: number = this.clampSeekMs(positionMs);
    this.positionMs = target;
    this.seekTargetMs = target;
    this.seeking = true;
    this.issueSeek(target);
  }

  /** seek 目标归一：毫秒整数 + 夹到 [0, durationMs]（durationMs 未知时只做下界保护） */
  private clampSeekMs(positionMs: number): number {
    let target: number = Math.round(positionMs);
    if (!Number.isFinite(target) || target < 0) {
      target = 0;
    }
    if (this.durationMs > 0 && target > this.durationMs) {
      target = this.durationMs;
    }
    return target;
  }

  /**
   * 真正下发一次 AVPlayer seek。
   *
   * @param target 目标毫秒（已 clamp）
   *
   * 上一次 seek 还没回调 seekDone 时只记 trailing 目标、不重复下发：
   * 连点快进 / 快速拖动会把 AVPlayer 的 seek 队列打满，落点会变成更早的中间值。
   */
  private issueSeek(target: number): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      this.seeking = false;
      return;
    }
    let state: string = '';
    try {
      state = player.state;
    } catch (e) {
      state = 'idle';
    }
    if (state !== 'prepared' && state !== 'playing' && state !== 'paused' && state !== 'completed') {
      // 还没到可 seek 的状态（idle / initialized / error）：留给 prepared 阶段的续播 seek
      this.pendingSeekMs = target;
      this.seeking = false;
      return;
    }
    if (this.seekInFlight) {
      this.trailingSeekMs = target;
      return;
    }
    try {
      this.seekInFlight = true;
      this.startSeekGuard();
      // 毫秒整数 + SEEK_CLOSEST：SEEK_PREV_SYNC/SEEK_NEXT_SYNC 都只能落在同步帧上
      player.seek(target, media.SeekMode.SEEK_CLOSEST);
    } catch (e) {
      this.seekInFlight = false;
      this.seeking = false;
      this.clearSeekGuard();
      Toast.show(describeError(e as Error));
    }
  }

  /** seek 看门狗：seekDone 迟迟不来时解锁，避免进度条永久停住 */
  private startSeekGuard(): void {
    this.clearSeekGuard();
    this.seekGuardTimer = setTimeout(() => {
      this.seekGuardTimer = -1;
      if (this.disposed) {
        return;
      }
      this.seekInFlight = false;
      this.trailingSeekMs = -1;
      this.seeking = false;
    }, SEEK_DONE_TIMEOUT_MS);
  }

  private clearSeekGuard(): void {
    if (this.seekGuardTimer !== -1) {
      clearTimeout(this.seekGuardTimer);
      this.seekGuardTimer = -1;
    }
  }

  /**
   * 相对 seek（双击左 / 右半屏的 ±10s）。
   * 只改播放位置与提示，不改变播放 / 暂停状态；时长未知（加载中 / 直播流）时不响应。
   */
  seekBy(deltaMs: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    // 基准用 positionMs：seek 期间它就是「上一次 seek 的目标」，连点 / 连拖不会因为
    // 播放器还没真正跳过去而少算距离（旧实现的误差累积就是这么来的）
    const target: number = Math.round(Math.min(this.durationMs, Math.max(0, this.positionMs + deltaMs)));
    this.positionMs = target;
    this.seekTo(target);
    const label: string = deltaMs < 0 ? '快退 10 秒' : '快进 10 秒';
    const progress: number = this.durationMs > 0 ? target / this.durationMs : 0;
    this.showGestureHint('seek', label + ' · ' + formatMs(target) + ' / ' + formatMs(this.durationMs), progress);
    this.scheduleHideGestureHint();
    if (this.controlsVisible) {
      this.scheduleHideControls();
    }
  }

  /**
   * 把 UI 音量（0~1）下发到**系统媒体音量**（对齐 PuraPily）：
   * 0~1 归一化值按系统最大档位换算成系统音量档位后调用 setVolume。
   *
   * 系统音量 API 不可用（设备限制 / 没读到最大档位 / promise 失败）时回退 AVPlayer.setVolume，
   * 保证右半屏竖滑在任何设备上都至少能改变播放器自身音量。
   */
  applyVolume(): void {
    const target: number = Math.min(1, Math.max(0, this.volumeLevel));
    const max: number = this.systemVolumeMax;
    if (max > 0) {
      try {
        const index: number = Math.round(target * max);
        audio.getAudioManager().setVolume(audio.AudioVolumeType.MEDIA, index).then(() => {
          // 系统音量已生效：之前回退过的播放器增益归位到 1.0（避免双重衰减）
          if (this.usingPlayerGainFallback) {
            this.usingPlayerGainFallback = false;
            this.applyPlayerGain(1);
          }
        }).catch((err: BusinessError) => {
          this.fallbackToPlayerVolume(target);
        });
        return;
      } catch (e) {
        // 同步抛错（API 不可用 / 无权限）→ 走播放器增益兜底
      }
    }
    this.fallbackToPlayerVolume(target);
  }

  /** 应用当前倍速：长按临时加速生效时用 2.0x，否则用用户选择的档位 */
  applySpeed(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const state: string = player.state;
      if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
        const speed: media.PlaybackSpeed = this.boostActive ?
          SPEED_OPTIONS[SPEED_OPTIONS.length - 1].speed : SPEED_OPTIONS[this.speedIndex].speed;
        player.setSpeed(speed);
      }
    } catch (e) {
      // setSpeed 失败不阻断播放
    }
  }

  /** 把单视频循环开关同步给 AVPlayer（只能在 prepared/playing/paused/completed 设置） */
  applyLooping(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const state: string = player.state;
      if (state === 'prepared' || state === 'playing' || state === 'paused' || state === 'completed') {
        player.loop = this.looping;
      }
    } catch (e) {
      // 循环设置失败不阻断播放
    }
  }

  /** 切换单视频循环（对齐原版底栏 Repeat 按钮 + Toast 反馈） */
  toggleLooping(): void {
    this.looping = !this.looping;
    this.applyLooping();
    Toast.show(this.looping ? '已开启循环播放' : '已关闭循环播放');
    if (this.controlsVisible) {
      this.scheduleHideControls();
    }
  }

  /** 长按开始：临时 2.0x（原版长按倍速，AVPlayer 最高档为 2.0x），并显示「2x 倍速中」提示 */
  beginSpeedBoost(): void {
    if (this.boostActive) {
      return;
    }
    if (this.avPlayer === null) {
      return;
    }
    const player: media.AVPlayer | null = this.avPlayer;
    try {
      if (player.state !== 'playing') {
        return;
      }
      this.boostActive = true;
      player.setSpeed(SPEED_OPTIONS[SPEED_OPTIONS.length - 1].speed);
      this.showSpeedBoostHint();
    } catch (e) {
      this.boostActive = false;
    }
  }

  /** 长按临时倍速的提示层（「2x 倍速中」）；不在自动隐藏计时内，松开时由 endSpeedBoost 收起 */
  private showSpeedBoostHint(): void {
    this.hintKind = 'boost';
    this.hintTitle = '2x 倍速中';
    this.hintProgress = -1;
    this.hintVisible = true;
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
  }

  /** 长按结束 / 取消：恢复用户选择的倍速并收起「2x 倍速中」提示 */
  endSpeedBoost(): void {
    if (!this.boostActive) {
      return;
    }
    this.boostActive = false;
    this.applySpeed();
    if (this.hintKind === 'boost') {
      this.hintVisible = false;
      this.hintKind = '';
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

  changeQuality(index: number): void {
    if (index === this.qualityIndex || index < 0 || index >= this.video.sources.length) {
      return;
    }
    this.endSpeedBoost();
    // 用户主动换清晰度 = 新的一次加载：清空自动重试计数（不把旧失败次数带进新清晰度）
    this.clearAutoRetry();
    const position: number = this.completed ? 0 : this.positionMs;
    this.qualityIndex = index;
    Toast.show('切换到 ' + sourceLabel(this.video.sources[index], index));
    // 换 source 需要 reset → 重新 prepare，并把进度 seek 回原位置
    this.loadSource(index, position);
  }

  // ---------------------------------------------------------------------------
  // 选项弹窗（清晰度 / 倍速）与「更多」播放设置浮层的开合
  // ---------------------------------------------------------------------------

  /** 打开播放选项弹窗；与「更多」设置浮层互斥，弹窗打开期间**暂停**控制层自动隐藏计时 */
  openPicker(kind: string): void {
    if (kind !== 'quality' && kind !== 'speed') {
      return;
    }
    this.showSettings = false;
    this.setControlsVisible(true);
    this.pickerKind = kind;
    // 弹窗打开期间暂停计时（关闭时由 closePicker 重新计时），避免弹窗被连带收起
    this.clearHideTimer();
  }

  /** 关闭选项弹窗（点遮罩 / 点选项 / 再点胶囊）：关闭后重新开始自动隐藏计时 */
  closePicker(): void {
    if (this.pickerKind.length === 0) {
      return;
    }
    this.pickerKind = '';
    if (this.controlsVisible) {
      this.scheduleHideControls();
    }
  }

  openQualityPicker(): void {
    this.openPicker('quality');
  }

  openSpeedPicker(): void {
    this.openPicker('speed');
  }

  /** 「更多」播放设置浮层开 / 关（与选项弹窗互斥；打开期间暂停自动隐藏计时） */
  toggleSettings(): void {
    if (this.showSettings) {
      this.closeSettings();
      return;
    }
    this.pickerKind = '';
    this.setControlsVisible(true);
    this.showSettings = true;
    this.clearHideTimer();
  }

  closeSettings(): void {
    if (!this.showSettings) {
      return;
    }
    this.showSettings = false;
    if (this.controlsVisible) {
      this.scheduleHideControls();
    }
  }

  /** 播放状态中文文案（设置浮层「播放信息」只读展示，不提供切换功能） */
  playerStateLabel(): string {
    if (this.useWeb) {
      return '网页播放';
    }
    if (this.retrying) {
      return '正在重试（' + this.retryAttempt + '/' + AUTO_RETRY_MAX + '）';
    }
    const state: string = this.playerState;
    if (state === 'playing') {
      return '正在播放';
    }
    if (state === 'paused') {
      return '已暂停';
    }
    if (state === 'completed') {
      return '播放结束';
    }
    if (state === 'prepared') {
      return '已就绪';
    }
    if (state === 'initialized') {
      return '缓冲中';
    }
    if (state === 'idle') {
      return '未开始';
    }
    if (state === 'error') {
      return '播放出错';
    }
    return state.length > 0 ? state : '未知';
  }

  qualityLabel(): string {
    if (this.video.sources.length === 0) {
      return '自动';
    }
    return sourceBadge(this.video.sources[this.qualityIndex]);
  }

  /** 原生播放彻底失败（自动重试全部用尽 / 播放地址无效）后降级网页播放 */
  fallbackToWeb(reason: string): void {
    if (this.disposed) {
      return;
    }
    // 重试已结束：清空自动重试计数与「正在重试」浮层，避免降级后还在后台排重试
    this.clearAutoRetry();
    this.mediaError = reason;
    this.useWeb = true;
    this.buffering = false;
    this.playing = false;
    this.endSpeedBoost();
    this.hideResumeChip();
    this.updateKeepScreenOn();
    // 网页播放时控制层常显：把可能处于「已淡出」的显隐状态复位（纯 UI，不改播放策略）
    this.controlsVisible = true;
    this.controlsGone = false;
    this.releasePlayer();
    Toast.show('原生播放失败，已切换网页播放');
  }

  /** 用户手动「重试原生」：不占用自动重试次数，先清空计数再重新加载（可无限手动重试） */
  retryNative(): void {
    if (this.video.sources.length === 0) {
      Toast.show('没有可用的播放地址，只能网页播放');
      return;
    }
    this.clearAutoRetry();
    this.useWeb = false;
    this.mediaError = '';
    this.resumeFromHistory = false;
    this.loadSource(this.qualityIndex, this.positionMs);
    // 回到原生播放后恢复控制层与自动隐藏计时（纯 UI 状态）
    this.showControls();
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

  /**
   * 用应用内网页直接打开媒体地址（能加载 m3u8/mp4 说明地址与网络可用，问题在 AVPlayer）。
   * 全屏态下先退出全屏：否则网页页仍横屏、且 AppStorage['videoFullscreen'] 仍为 true，
   * 会导致在网页页按返回被 Index 当成「退出播放器全屏」消费，而不是 pop 网页页。
   */
  openSourceUrl(): void {
    if (this.sourceUrl.length === 0) {
      Toast.show('暂无播放地址');
      return;
    }
    if (this.fullscreen) {
      this.onToggleFullscreen();
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
    // 释放即视为离开播放：解除锁定，避免下次进入沿用上次的锁定态导致「点哪都没反应」
    this.locked = false;
    this.clearLockHideTimer();
    this.lockShown = true;
    this.clearLoadTimer();
    this.clearRetryTimer();
    // 在途 seek 的看门狗 / trailing 目标一并清掉，避免页面销毁后定时器还打到已释放的播放器
    this.clearSeekGuard();
    this.seekInFlight = false;
    this.trailingSeekMs = -1;
    this.seeking = false;
    const player: media.AVPlayer | null = this.avPlayer;
    this.avPlayer = null;
    this.prepareRequested = false;
    if (player !== null) {
      this.releaseExternally(player);
    }
  }

  /**
   * 父页面跳转前调用：先落盘进度再暂停。
   * 详情页被新页面盖住时不会销毁，不暂停会导致两个页面同时出声。
   */
  pauseAndSave(): void {
    this.saveProgressNow();
    this.endSpeedBoost();
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      if (player.state === 'playing') {
        player.pause().catch((err: BusinessError) => {
          // 页面可能正在销毁，暂停失败不提示
        });
      }
    } catch (e) {
      // 播放器已释放
    }
  }

  /** 全屏 / 退出全屏：交给父页面（父页面负责窗口方向与系统栏） */
  requestFullscreen(): void {
    this.showSettings = false;
    this.pickerKind = '';
    this.showControls();
    this.onToggleFullscreen();
  }

  // ---------------------------------------------------------------------------
  // 左上角返回圆钮：单击 = 全屏退出 / 返回上一页（「回首页」是右侧独立圆钮，见 topBar）
  // ---------------------------------------------------------------------------

  /**
   * 返回钮单击：全屏态退出全屏，非全屏态 Router.pop() 返回上一页（与改造前完全一致）。
   */
  handleBackTap(): void {
    this.showControls();
    if (this.fullscreen) {
      this.onToggleFullscreen();
    } else {
      Router.pop();
    }
  }

  // ---------------------------------------------------------------------------
  // 折叠 / 展开的播放联动（父页面小白条折叠隐藏 / 展开播放器时经句柄调用）
  // ---------------------------------------------------------------------------

  /** 父页面折叠播放器前查询：AVPlayer 是否正在 playing（播放器未创建 / 已释放时 false） */
  private isPlayerPlayingNow(): boolean {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return false;
    }
    try {
      return player.state === 'playing';
    } catch (e) {
      // 播放器已释放 / 状态不可读时按「未在播放」处理
      return false;
    }
  }

  /**
   * 折叠隐藏播放器时的暂停：与 pauseAndSave 一样落盘 + 暂停，
   * 但标记「本次暂停来自折叠」，paused 回调不再主动唤出控制层（画面正在收缩 / 已隐藏，避免 UI 闪一下）。
   * 只有正在 playing 时才置标记，暂停失败 / 本来就没播时不影响后续正常唤出控制层。
   */
  private pauseForCollapsePlayback(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    if (player !== null) {
      try {
        if (player.state === 'playing') {
          this.collapsePausePending = true;
        }
      } catch (e) {
        // 播放器已释放：pauseAndSave 会做兜底
      }
    }
    this.pauseAndSave();
  }

  /**
   * 折叠后展开恢复播放：父页面只在「折叠前正在播放」时调用。
   *
   * 只对 paused / prepared 调 play()（与 togglePlay 的续播路径同一 API）：
   *  - 不 seek，进度就是折叠暂停时保留的 positionMs；
   *  - 不重新 loadSource / 不重建 AVPlayer / 不申请新 surface，surfaceId 仍是同一个；
   *  - 玩家在折叠期间已被其它逻辑（真正切后台 / 被二级页覆盖）暂停时，
   *    这里只做 play()，不改变其它状态；结束后重新计时控制层自动隐藏。
   */
  private resumeAfterCollapsePlayback(): void {
    // 用户主动展开并恢复播放 = 明确的「要看 / 要听」意图：
    // 撤销方向保护窗口可能遗留的待补暂停，避免 1.4s 后又被延迟确认误暂停。
    this.pendingHiddenPause = false;
    this.pendingCoverPause = false;
    this.hiddenByCover = false;
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    try {
      const state: string = player.state;
      if (state !== 'paused' && state !== 'prepared') {
        return;
      }
      player.play().catch((err: BusinessError) => {
        Toast.show('播放失败：' + err.message);
      });
      // 暂停时控制层被唤出且自动隐藏计时已结束，恢复播放后重新开始 5 秒计时
      this.scheduleHideControls();
    } catch (e) {
      // 播放器已释放
    }
  }

  // ---------------------------------------------------------------------------
  // 控制层显隐（仅 UI 状态，不涉及播放逻辑）
  // ---------------------------------------------------------------------------

  clearHideTimer(): void {
    if (this.hideTimerId !== -1) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
  }

  /** 清掉锁定按钮的隐藏计时器（重复调用安全） */
  clearLockHideTimer(): void {
    if (this.lockHideTimerId !== -1) {
      clearTimeout(this.lockHideTimerId);
      this.lockHideTimerId = -1;
    }
  }

  /**
   * 显示锁定按钮并重新开始 3s 计时。
   * 任何一次主动操作（点画面显隐控制层、锁定 / 解锁、按下播放器）都会调用它，
   * 保证「刚操作过就看得见，停手 3s 就收起」。
   */
  showLockTemporarily(): void {
    this.lockShown = true;
    this.clearLockHideTimer();
    this.lockHideTimerId = setTimeout(() => {
      this.lockHideTimerId = -1;
      if (this.disposed) {
        return;
      }
      this.lockShown = false;
    }, LOCK_HIDE_MS);
  }

  /** 锁定按钮是否应渲染：已锁定只看自己的开关；未锁定还要控制层可见 */
  lockButtonVisible(): boolean {
    if (!this.lockShown) {
      return false;
    }
    return this.locked || this.controlsShown();
  }

  /**
   * 自动隐藏控制层的计时（唯一入口：先 clear 再 set，保证同一时刻只有一个定时器）。
   *
   * 只在「用户主动操作 / 主动显示控制层 / 播放真正开始（playing 变化）」时调用；
   * 时间更新、状态回调等程序性更新不会调用它，所以不会出现计时被悄悄重置、永远数不到点的现象。
   * 到点后的判定是**一次性的**，不满足条件就结束本次计时（等对应事件再重新计时），
   * 绝不在回调里无条件重新排定时器：
   *  - 网页播放：不自动隐藏（保持网页控件可交互、退出全屏入口常驻）；
   *  - 设置浮层 / 清晰度、倍速弹窗打开：暂停计时（关闭弹窗时由 closeSettings / closePicker 重新计时）；
   *  - 暂停 / 播完 / 缓冲：控制层常显（既有策略，播放恢复时由 playing 变化重新计时）；
   *  - 其余情况：到点一定隐藏。即使 pointerDown 因触摸 Up / Cancel 丢失而残留，
   *    也在这里防御性复位后隐藏，不会再被它无限顺延。
   */
  scheduleHideControls(): void {
    this.clearHideTimer();
    if (this.disposed || this.useWeb) {
      return;
    }
    this.hideTimerId = setTimeout(() => {
      this.hideTimerId = -1;
      if (this.disposed || this.useWeb) {
        return;
      }
      // 弹窗打开：本次计时结束（不重排），关闭弹窗后重新计时
      if (this.showSettings || this.pickerKind.length > 0) {
        return;
      }
      // 对齐原版：只有播放中才自动隐藏控件；暂停 / 播完 / 缓冲时控制层常显，
      // 保证中央播放键、重播提示与进度条一直可见
      if (!this.playing) {
        return;
      }
      // 到点一定隐藏：按住标记若是残留（触摸 Up / Cancel 丢失）会在隐藏时被复位
      this.pointerDown = false;
      this.setControlsVisible(false);
    }, CONTROLS_HIDE_MS);
  }

  /** 控制层当前是否应该显示（网页播放时永远显示） */
  controlsShown(): boolean {
    // 锁定期间控制层整体不显示（锁按钮自己不受这个开关约束，见 lockButtonLayer）
    return !this.locked && (this.useWeb || this.controlsVisible);
  }

  /**
   * 中央播放 / 暂停按钮是否渲染：原生播放、已拿到媒体、且不处于缓冲中。
   * 图标随播放状态切换（播放中 = 暂停图标，暂停 / 播完 = 播放图标）；
   * 控制层隐藏时随整层一起淡出，不需要单独隐藏。
   */
  centerVisible(): boolean {
    if (this.useWeb) {
      return false;
    }
    return !this.buffering && this.playerState !== 'idle';
  }

  // ---------------------------------------------------------------------------
  // 控制层尺寸（三段式铺满布局：顶部条 / 中部居中按钮 / 底部条）
  // ---------------------------------------------------------------------------

  /**
   * 顶部渐变条高度：56 内容高。
   * 非全屏时播放器容器本身已位于状态栏下方（VideoPage 用 position.y 下移），不需要再加安全区；
   * 全屏时容器铺满窗口，若系统栏隐藏失败 / 有刘海，需要额外让出 statusBarHeight。
   */
  topBarHeight(): number {
    if (this.fullscreen) {
      return 56 + this.statusBarHeight;
    }
    return 56;
  }

  /**
   * 底部渐变条高度：Slider 行 40 + 倍速/清晰度/全屏胶囊行 44 = 84，再加 4 底部呼吸 = 88。
   * （内嵌播放器高度只有屏宽 / 画幅，底条不宜过高；顶部 56 + 底部 88 后中部仍有空间放 56 圆按钮）
   * 网页播放时只有一行 44 的胶囊 + 12 底部呼吸（共 56）。全屏时再补导航条高度作为安全区。
   */
  bottomBarHeight(): number {
    const safe: number = this.fullscreen ? this.navBarHeight : 0;
    if (this.useWeb) {
      return 56 + safe;
    }
    return 88 + safe;
  }

  /**
   * 控制层显隐：180ms 透明度 + 位移动画（由 .opacity/.translate 绑定 controlsVisible 实现）。
   * 淡出结束后把控制层设为 Visibility.Hidden，保证透明状态下的按钮不会再被点到
   * （HitTestMode.None 只让容器自身不命中，子按钮仍可能响应，所以必须整体隐藏）。
   */
  setControlsVisible(visible: boolean): void {
    if (visible) {
      this.controlsGone = false;
      animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
        this.controlsVisible = true;
      });
      return;
    }
    if (!this.controlsVisible) {
      return;
    }
    animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
      this.controlsVisible = false;
    });
    setTimeout(() => {
      if (!this.disposed && !this.controlsVisible) {
        this.controlsGone = true;
      }
    }, 190);
  }

  /** 用户操作后：显示控制层并重新计时 */
  showControls(): void {
    this.setControlsVisible(true);
    this.scheduleHideControls();
    // 控制层出现的同时把锁定按钮一起叫出来，并重开 3s 计时
    this.showLockTemporarily();
  }

  /**
   * 锁定 / 解锁：锁定 = 收控制层 + 关掉全部手势入口；解锁 = 恢复控制层并重新计时。
   * 锁定时顺手把浮层（设置面板 / 倍速清晰度选择器）收掉，否则它们会留在画面上。
   */
  toggleLock(): void {
    this.locked = !this.locked;
    if (this.locked) {
      this.clearHideTimer();
      this.clearLongPressTimer();
      this.showSettings = false;
      this.pickerKind = '';
      this.setControlsVisible(false);
      Toast.show('已锁定，点右侧锁图标解锁');
    } else {
      this.showControls();
    }
  }

  /** 点击画面：显示 / 隐藏控制层（隐藏时一并收起浮层，避免浮层残留但控制层消失） */
  toggleControls(): void {
    if (this.controlsVisible) {
      this.clearHideTimer();
      if (this.showSettings) {
        this.showSettings = false;
      }
      if (this.pickerKind.length > 0) {
        this.pickerKind = '';
      }
      this.setControlsVisible(false);
      // 点画面收起控制层时，锁定按钮同步收起（不必等它的 3s）
      this.clearLockHideTimer();
      this.lockShown = false;
    } else {
      this.showControls();
    }
  }

  // ---------------------------------------------------------------------------
  // 手势层（纯 UI 状态 + 系统媒体音量 / 窗口亮度，不改播放状态机）
  // ---------------------------------------------------------------------------

  /** 手势浮动提示：seek 显示「当前时间 / 总时长」，音量/亮度显示百分比 */
  showGestureHint(kind: string, title: string, progress: number): void {
    if (this.disposed) {
      return;
    }
    this.hintKind = kind;
    this.hintTitle = title;
    this.hintProgress = progress;
    this.hintVisible = true;
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
      this.hintTimer = -1;
    }
  }

  /** 松手后延迟收起手势提示（拖动中不收起） */
  scheduleHideGestureHint(): void {
    if (this.hintTimer !== -1) {
      clearTimeout(this.hintTimer);
    }
    this.hintTimer = setTimeout(() => {
      this.hintTimer = -1;
      if (!this.disposed) {
        this.hintVisible = false;
      }
    }, GESTURE_HINT_MS);
  }

  /** 复位一次手势的临时状态（不改变播放） */
  resetGestureState(): void {
    this.touchId = -1;
    this.gestureMode = '';
    this.gestureMoved = false;
    this.gestureLongPress = false;
    this.pointerDown = false;
  }

  /** 清掉长按判定定时器 */
  clearLongPressTimer(): void {
    if (this.longPressTimerId !== -1) {
      clearTimeout(this.longPressTimerId);
      this.longPressTimerId = -1;
    }
  }

  /** 手势层触摸入口：单击 / 双击 / 长按倍速 / 横滑 seek / 竖滑音量（右）/ 亮度（左） */
  onPlayerTouch(event: TouchEvent): void {
    if (this.disposed || this.useWeb) {
      return;
    }
    // 已锁定：所有手势（单击显隐 / 双击 / 横滑 seek / 竖滑亮度音量 / 长按倍速）全部失效，
    // 只有右侧锁按钮能点。锁按钮渲染在手势层之上，它的 onClick 在手势层之前被消费。
    // 但「点画面」仍要能叫出锁按钮：否则锁上之后按钮 3s 一收，就再也没法解锁了。
    if (this.locked) {
      this.handleLockedTouch(event);
      return;
    }
    if (event.type === TouchType.Down) {
      this.handleGestureDown(event);
    } else if (event.type === TouchType.Move) {
      this.handleGestureMove(event);
    } else if (event.type === TouchType.Up) {
      this.handleGestureUp(event);
    } else if (event.type === TouchType.Cancel) {
      this.handleGestureCancel();
    }
  }

  /**
   * 锁定态下的触摸处理：只认「轻点」，用来显隐锁定按钮，其余一概忽略。
   *
   * 为什么要位移判定：锁定时横滑 / 竖滑都被禁掉了，如果直接看 Up 事件，
   * 任何一次滑动抬手都会被当成轻点，锁按钮就会莫名其妙地闪现 —— 用 12vp 位移 + 400ms 时窗卡住。
   */
  private handleLockedTouch(event: TouchEvent): void {
    if (event.type === TouchType.Down) {
      if (event.touches.length === 1) {
        this.lockTapX = event.touches[0].x;
        this.lockTapY = event.touches[0].y;
        this.lockTapAt = Date.now();
      }
      return;
    }
    if (event.type !== TouchType.Up) {
      return;
    }
    if (this.lockTapX < 0 || Date.now() - this.lockTapAt > 400) {
      return;
    }
    const touch: TouchObject = event.changedTouches[0];
    const moved: number = Math.abs(touch.x - this.lockTapX) + Math.abs(touch.y - this.lockTapY);
    this.lockTapX = -1;
    if (moved > 12) {
      return;
    }
    // 轻点：按钮已在 → 立即收起；已收起 → 重新显示并开始 3s 计时
    if (this.lockShown) {
      this.clearLockHideTimer();
      this.lockShown = false;
    } else {
      this.showLockTemporarily();
    }
  }

  private handleGestureDown(event: TouchEvent): void {
    if (event.touches.length !== 1) {
      this.handleGestureCancel();
      return;
    }
    const touch: TouchObject = event.touches[0];
    const now: number = Date.now();
    // 双击判定：与上一次单击抬起的时间 / 位置都很近 → 按区域执行（左 1/3 快退、右 1/3 快进、中间播放暂停）
    const nearInTime: boolean = now - this.lastTapAt <= DOUBLE_TAP_MS;
    const nearInPlace: boolean = Math.abs(touch.x - this.lastTapX) <= DOUBLE_TAP_SLOP &&
      Math.abs(touch.y - this.lastTapY) <= DOUBLE_TAP_SLOP;
    if (nearInTime && nearInPlace) {
      this.lastTapAt = 0;
      this.gestureDoubleTap = true;
      if (this.singleTapTimer !== -1) {
        clearTimeout(this.singleTapTimer);
        this.singleTapTimer = -1;
      }
      this.handleDoubleTap(touch.x);
      return;
    }
    this.touchId = touch.id;
    this.touchStartX = touch.x;
    this.touchStartY = touch.y;
    // 上一次单击的延迟显隐还没执行就开始了新手势：取消它，避免拖动中途控制层闪一下
    if (this.singleTapTimer !== -1) {
      clearTimeout(this.singleTapTimer);
      this.singleTapTimer = -1;
    }
    this.gestureStartPositionMs = this.positionMs;
    this.gestureStartVolume = this.volumeLevel;
    this.gestureStartBrightness = this.brightnessLevel;
    this.volumeGestureApplied = false;
    // 竖滑音量以**系统媒体音量**为起点：每次按下都异步读一次（读不到用本地 0.5 兜底）
    this.syncSystemVolume(true);
    this.gestureMode = '';
    this.gestureMoved = false;
    this.gestureDoubleTap = false;
    this.gestureLongPress = false;
    this.pointerDown = true;
    // 用户按下 = 一次主动操作：从此刻重新开始自动隐藏计时。
    // 即使后续触摸 Up / Cancel 事件丢失，到点也会隐藏（定时器回调不再被 pointerDown 无限顺延）。
    this.scheduleHideControls();
    // 长按 500ms：播放中临时 2 倍速（原版长按倍速），左 / 右滑或抬手会取消 / 结束
    this.clearLongPressTimer();
    this.longPressTimerId = setTimeout(() => {
      this.longPressTimerId = -1;
      if (this.disposed || this.useWeb || this.touchId === -1) {
        return;
      }
      if (this.gestureMoved || this.gestureDoubleTap) {
        return;
      }
      // 长按临时倍速：按播放器当前是否在播放判断
      if (!this.isPlayerPlayingNow()) {
        return;
      }
      this.gestureLongPress = true;
      this.beginSpeedBoost();
    }, LONG_PRESS_MS);
  }

  /**
   * 双击分流：中间 1/3 播放 / 暂停；左 1/3 快退 10s；右 1/3 快进 10s（浮动提示目标时间）。
   *
   * 备注：Android 最新 Compose 版（HanimeVideoPlayer.kt 的 onDoubleTap）只做「双击任意位置播放/暂停」，
   * 没有 ±10s；这里按本轮任务明确要求的三分区手势实现（旧版 JZVD 式），
   * 中间播放/暂停与最新原版一致，左右分区是额外增强。
   */
  private handleDoubleTap(x: number): void {
    const width: number = this.gestureWidth > 0 ? this.gestureWidth : 1;
    const leftEdge: number = width / 3;
    const rightEdge: number = width * 2 / 3;
    if (x < leftEdge) {
      this.seekBy(-DOUBLE_TAP_SEEK_MS);
      return;
    }
    if (x > rightEdge) {
      this.seekBy(DOUBLE_TAP_SEEK_MS);
      return;
    }
    this.togglePlay();
    if (this.controlsVisible) {
      this.scheduleHideControls();
    }
  }

  private handleGestureMove(event: TouchEvent): void {
    if (this.touchId === -1 || this.gestureDoubleTap) {
      return;
    }
    // 长按倍速期间禁用拖动（对齐原版 dragEnabled = false）
    if (this.gestureLongPress || this.boostActive) {
      return;
    }
    if (event.touches.length !== 1 || event.touches[0].id !== this.touchId) {
      this.handleGestureCancel();
      return;
    }
    const touch: TouchObject = event.touches[0];
    const dx: number = touch.x - this.touchStartX;
    const dyUp: number = this.touchStartY - touch.y;
    const adx: number = Math.abs(dx);
    const ady: number = Math.abs(dyUp);
    if (!this.gestureMoved && (adx > GESTURE_SLOP || ady > GESTURE_SLOP)) {
      this.gestureMoved = true;
      // 一旦开始拖动就不再判定长按
      this.clearLongPressTimer();
    }
    if (!this.gestureMoved) {
      return;
    }
    if (this.gestureMode.length === 0) {
      if (adx >= SEEK_SLOP && adx >= ady * 1.5) {
        this.gestureMode = 'seek';
        // 识别阈值不计入进度位移：从越过阈值的位置开始换算，避免起步跳一段
        this.seekDragStartX = this.touchStartX + (dx > 0 ? SEEK_SLOP : -SEEK_SLOP);
        this.gestureStartPositionMs = this.positionMs;
      } else if (ady >= LEVEL_SLOP && ady >= adx * 1.2) {
        // 右半屏 = 音量，左半屏 = 亮度（以手势层宽度中线划分）
        const centerX: number = this.gestureWidth / 2;
        this.gestureMode = this.touchStartX < centerX ? 'brightness' : 'volume';
      } else {
        return;
      }
    }
    if (this.gestureMode === 'seek') {
      this.applySeekPreview(touch.x);
    } else if (this.gestureMode === 'volume') {
      this.applyVolumeGesture(dyUp);
    } else if (this.gestureMode === 'brightness') {
      this.applyBrightnessGesture(dyUp);
    }
  }

  /** 水平拖动：只更新预览位置与浮动提示，松手才真正 seek（避免拖动中频繁 seek 卡顿） */
  private applySeekPreview(currentX: number): void {
    if (this.durationMs <= 0) {
      return;
    }
    const width: number = this.gestureWidth > 0 ? this.gestureWidth : 1;
    // 灵敏度按时长自适应：短片整屏 ≈ 50% 时长，长片按比例放大但不至于一滑几十分钟
    const durationSec: number = this.durationMs / 1000;
    const secPerScreen: number = durationSec <= 600 ? durationSec * 0.5 :
      (durationSec <= 3600 ? durationSec * 0.3 : Math.max(durationSec * 0.12, 600));
    const deltaMs: number = ((currentX - this.seekDragStartX) / width) * secPerScreen * 1000;
    let target: number = this.gestureStartPositionMs + deltaMs;
    target = Math.min(this.durationMs, Math.max(0, target));
    this.seeking = true;
    this.positionMs = target;
    const progress: number = this.durationMs > 0 ? target / this.durationMs : 0;
    this.showGestureHint('seek',
      formatMs(Math.round(target)) + ' / ' + formatMs(Math.round(this.durationMs)), progress);
  }

  /** 右侧竖滑：系统媒体音量（0~1），向上为增大；系统 API 失败时回退播放器增益 */
  private applyVolumeGesture(dyUp: number): void {
    const height: number = this.gestureHeight > 0 ? this.gestureHeight : 1;
    const delta: number = (dyUp / (height * LEVEL_SENSITIVITY));
    let next: number = this.gestureStartVolume + delta;
    next = Math.min(1, Math.max(0, next));
    if (Math.abs(next - this.volumeLevel) < 0.005) {
      return;
    }
    this.volumeLevel = next;
    this.volumeGestureApplied = true;
    this.applyVolume();
    this.showGestureHint('volume', '音量 ' + Math.round(next * 100) + '%', next);
  }

  /** 左侧竖滑：窗口亮度（0~1），向上为增大；不再用黑色遮罩模拟 */
  private applyBrightnessGesture(dyUp: number): void {
    const height: number = this.gestureHeight > 0 ? this.gestureHeight : 1;
    const delta: number = (dyUp / (height * LEVEL_SENSITIVITY));
    let next: number = this.gestureStartBrightness + delta;
    next = Math.min(1, Math.max(0, next));
    if (Math.abs(next - this.brightnessLevel) < 0.005) {
      return;
    }
    this.brightnessLevel = next;
    this.applyWindowBrightness(next);
    this.showGestureHint('brightness', '亮度 ' + Math.round(next * 100) + '%', next);
  }

  private handleGestureUp(event: TouchEvent): void {
    // 抬手即视为本次触摸结束：先把按住标记复位（不依赖下面各分支），
    // 避免双击等提前 return 的分支把 pointerDown 残留成 true。
    this.pointerDown = false;
    this.clearLongPressTimer();
    if (this.touchId === -1) {
      // 双击 / 长按松开后不会再走到这里（touchId 已复位），只做倍速兜底恢复
      this.endSpeedBoost();
      return;
    }
    const touch: TouchObject | undefined = event.changedTouches.length > 0 ? event.changedTouches[0] : undefined;
    const mode: string = this.gestureMode;
    const moved: boolean = this.gestureMoved;
    const longPressed: boolean = this.gestureLongPress;
    this.resetGestureState();
    // 长按倍速结束：恢复原倍速并收起「2x 倍速中」提示，本次不再触发单击显隐
    if (longPressed || this.boostActive) {
      this.endSpeedBoost();
      if (this.controlsVisible) {
        this.scheduleHideControls();
      }
      return;
    }
    if (mode === 'seek') {
      this.seeking = false;
      if (this.durationMs > 0) {
        this.seekTo(Math.round(this.positionMs));
      }
      this.scheduleHideGestureHint();
    } else if (mode === 'volume') {
      this.applyVolume();
      this.scheduleHideGestureHint();
    } else if (mode === 'brightness') {
      this.scheduleHideGestureHint();
    }
    if (!moved && !this.gestureDoubleTap) {
      // 单击：300ms 内没有第二次按下（双击）才执行显示 / 隐藏控制层
      if (touch !== undefined) {
        this.lastTapAt = Date.now();
        this.lastTapX = touch.x;
        this.lastTapY = touch.y;
      }
      if (this.singleTapTimer !== -1) {
        clearTimeout(this.singleTapTimer);
      }
      this.singleTapTimer = setTimeout(() => {
        this.singleTapTimer = -1;
        if (!this.disposed) {
          this.toggleControls();
        }
      }, SINGLE_TAP_DELAY_MS);
    } else if (this.controlsVisible) {
      // 拖动 / 双击后：控制层仍可见时重新开始 5 秒计时
      this.scheduleHideControls();
    }
  }

  private handleGestureCancel(): void {
    this.clearLongPressTimer();
    const startMs: number = this.gestureStartPositionMs;
    const wasSeek: boolean = this.gestureMode === 'seek';
    this.resetGestureState();
    this.seeking = false;
    this.endSpeedBoost();
    if (wasSeek) {
      // 取消拖动：位置回到手势开始前，不做 seek
      this.positionMs = startMs;
      this.hintVisible = false;
    }
    if (this.controlsVisible) {
      this.scheduleHideControls();
    }
  }

  // ---------------------------------------------------------------------------
  // 观看进度
  //
  // 落盘规则（修复续播被 0 覆盖的关键）：
  //  1. 进度只由播放器写（LocalRepo.saveProgress → AppDb.updateProgress 原子 UPDATE），
  //     详情页入口只刷新历史元信息，不再用 positionMs=0 去“整行覆盖”；
  //  2. 续播 seek 还没确认落地时（resumeTargetMs>0 && !resumeSeekApplied）一律不写：
  //     此时播放器报的位置是旧值（常见为 0），写进去会把历史里的真实续播点清掉；
  //  3. positionMs<=0 不写（播放器初始 0 不能进历史）；「从头播放」的显式归零走 resetProgress；
  //  4. 真到退出 / 暂停时如果 positionMs 因回调滞后还是 0，用播放器实时位置兜底。
  // ---------------------------------------------------------------------------

  /** 续播 seek 是否仍在等待确认落地（此时禁止落盘） */
  private isResumeSeekPending(): boolean {
    return this.resumeTargetMs > 0 && !this.resumeSeekApplied;
  }

  /** 读播放器实时位置（毫秒）：positionMs 可信时直接用，否则回退 AVPlayer / 待应用 seek */
  private currentPlaybackPositionMs(): number {
    if (this.positionMs > 0) {
      return this.positionMs;
    }
    const player: media.AVPlayer | null = this.avPlayer;
    if (player !== null) {
      try {
        const current: number = player.currentTime;
        if (Number.isFinite(current) && current > 0) {
          return Math.round(current);
        }
      } catch (e) {
        // 播放器已释放 / 状态不可读：继续用下面的兜底
      }
    }
    if (this.pendingSeekMs > 0) {
      return this.pendingSeekMs;
    }
    return this.resumeSeekApplied ? 0 : this.resumeTargetMs;
  }

  saveProgress(positionMs: number): void {
    const video: HanimeVideo = this.video;
    if (video.videoCode.length === 0) {
      return;
    }
    if (this.isResumeSeekPending()) {
      // 续播还没落地：不落盘，避免旧位置 / 0 覆盖历史里的续播点
      return;
    }
    if (!(positionMs > 0)) {
      return;
    }
    LocalRepo.getInstance().saveProgress(video.videoCode, positionMs, this.durationMs)
      .catch((err: Error) => {
        // 进度写失败不影响播放
      });
  }

  saveProgressNow(): void {
    const video: HanimeVideo = this.video;
    if (video.videoCode.length === 0) {
      return;
    }
    if (this.isResumeSeekPending()) {
      // 续播点还没确认落地：库里本来就是续播点，任何写入都只会把它改坏
      return;
    }
    const positionMs: number = this.currentPlaybackPositionMs();
    if (!(positionMs > 0)) {
      return;
    }
    LocalRepo.getInstance().saveProgress(video.videoCode, positionMs, this.durationMs).then(() => {
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
    // 全屏态下打开网页前先退出全屏（窗口方向/系统栏由父页面恢复），避免网页页仍横屏
    if (this.fullscreen) {
      this.onToggleFullscreen();
    }
    // 与详情页其它跳转一致：先落盘进度并暂停，避免网页页盖住后底层继续出声
    this.pauseAndSave();
    Router.openWeb(this.watchUrl, this.displayTitle());
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /** 视频真实画幅（宽 / 高）；未拿到 videoSizeChange 前为 0 */
  videoRatio(): number {
    if (this.videoWidth > 0 && this.videoHeight > 0) {
      return this.videoWidth / this.videoHeight;
    }
    return 0;
  }

  /**
   * 媒体层宽度：原生播放时按视频画幅在播放器区域内居中 letterbox（多余区域由黑底承担），
   * 这样全屏 / 竖屏视频 / 窄窗口下都不会被 AVPlayer 拉伸变形（对齐原版 aspectRatio 居中）。
   * 画幅未知或网页播放时铺满。
   */
  mediaWidth(): Length {
    const ratio: number = this.videoRatio();
    if (this.useWeb || ratio <= 0 || this.gestureWidth <= 0 || this.gestureHeight <= 0) {
      return '100%';
    }
    const containerRatio: number = this.gestureWidth / this.gestureHeight;
    if (containerRatio > ratio) {
      return this.gestureHeight * ratio;
    }
    return this.gestureWidth;
  }

  /** 媒体层高度：与 mediaWidth 配套，保证画面比例与视频一致 */
  mediaHeight(): Length {
    const ratio: number = this.videoRatio();
    if (this.useWeb || ratio <= 0 || this.gestureWidth <= 0 || this.gestureHeight <= 0) {
      return '100%';
    }
    const containerRatio: number = this.gestureWidth / this.gestureHeight;
    if (containerRatio > ratio) {
      return this.gestureHeight;
    }
    return this.gestureWidth / ratio;
  }


  /**
   * 原生播放专用纯黑铺底（网页降级分支不渲染这一层，网页自己铺满自己的背景）。
   *
   * 为什么单独铺一层而不是只靠父容器：竖屏视频 contain 之后左右是 letterbox，
   * 这片区域暴露出来的是「播放器外面」的底色。父页面 / 主题色一旦带透明度或不是纯黑，
   * 黑边就会发灰、和画面里 AVPlayer 自己的黑对不上。这里用不透明 #000000 兜住整块区域，
   * 左右黑边只可能是纯黑。
   */
  @Builder
  blackBackdrop() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#000000')
      .hitTestBehavior(HitTestMode.None);
  }

  /** 画面层：原生播放用 XComponent（按画幅居中），网页降级用 Web 铺满（无圆角，纯黑底） */
  @Builder
  mediaLayer() {
    Stack({ alignContent: Alignment.Center }) {
      Column() {
        if (this.useWeb) {
          Web({ src: this.watchUrl, controller: this.webController })
            .domStorageAccess(true)
            .javaScriptAccess(true)
            .mixedMode(MixedMode.All)
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Black);
        } else {
          // 原生播放：系统 AVPlayer。controller 的 onSurfaceCreated 拿 surfaceId 交给 AVPlayer
          XComponent({
            // 每个内嵌播放器实例唯一：详情页可叠多层，XComponent id 不能重复
            id: this.xcomponentId,
            type: XComponentType.SURFACE,
            controller: this.surfaceController
          })
            .width('100%')
            .height('100%')
            .backgroundColor(Color.Black)
            // 触摸全部交给上方的透明手势层，XComponent 自身不参与命中
            .hitTestBehavior(HitTestMode.None)
            .onLoad(() => {
              this.onXComponentLoad();
            });
        }
      }
      .width(this.mediaWidth())
      .height(this.mediaHeight());
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black);
  }

  /**
   * 透明手势层：XComponent 之上、控制层之下。
   * 只挂 onTouch，不拦截控制层（控制层在其上层渲染，按钮优先命中）。
   */
  @Builder
  gestureLayer() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(Color.Transparent)
      .onTouch((event: TouchEvent) => {
        this.onPlayerTouch(event);
      })
      .onAreaChange((_old: Area, area: Area) => {
        // Area 的 width/height 类型标注是 Length，运行时通常是 vp 数值；兼容字符串形态做一次兜底
        let width: number = Number(area.width);
        let height: number = Number(area.height);
        if (isNaN(width)) {
          width = parseFloat(area.width.toString());
        }
        if (isNaN(height)) {
          height = parseFloat(area.height.toString());
        }
        if (width > 0 && Math.abs(width - this.gestureWidth) > 0.5) {
          this.gestureWidth = width;
        }
        if (height > 0 && Math.abs(height - this.gestureHeight) > 0.5) {
          this.gestureHeight = height;
        }
      });
  }

  /** 常显底部进度条的已播放比例（0~1；时长未知时为 0，只显示空轨道） */
  bottomProgressRatio(): number {
    if (!(this.durationMs > 0) || !(this.positionMs > 0)) {
      return 0;
    }
    const ratio: number = this.positionMs / this.durationMs;
    if (!Number.isFinite(ratio)) {
      return 0;
    }
    return Math.min(1, Math.max(0, ratio));
  }

  /**
   * 播放器最底部的常显细进度条（3vp，不随控制层显隐，全屏 / 竖屏 / 折叠控制层时都显示）：
   * 轨道半透明白 + 已播放部分主题色、圆角 2；自身 hitTestBehavior(None)，
   * 不拦截点击 / 滑动，播放器手势与控制层按钮行为不变。
   */
  @Builder
  bottomProgressBar() {
    Column() {
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(BOTTOM_PROGRESS_HEIGHT)
          .borderRadius(2)
          .backgroundColor(BOTTOM_PROGRESS_TRACK);
        Row()
          .width((this.bottomProgressRatio() * 100) + '%')
          .height(BOTTOM_PROGRESS_HEIGHT)
          .borderRadius(2)
          .backgroundColor(Theme.colors().primary);
      }
      .width('100%')
      .height(BOTTOM_PROGRESS_HEIGHT);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None);
  }

  /** 手势提示标题（seek / volume / brightness / boost） */
  hintLabel(): string {
    if (this.hintKind === 'boost') {
      return '倍速';
    }
    if (this.hintKind === 'seek') {
      return '进度';
    }
    if (this.hintKind === 'volume') {
      return '音量';
    }
    return '亮度';
  }

  /** 手势浮动提示：进度显示「当前时间 / 总时长」，音量/亮度显示百分比，长按显示「2x 倍速中」 */
  @Builder
  gestureHint() {
    Column() {
      Column() {
        Row() {
          Text(this.hintLabel())
            .fontSize(11)
            .fontColor('#CCFFFFFF');
        }
        .width('100%');

        Text(this.hintTitle)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: 4 });

        if (this.hintProgress >= 0) {
          Stack({ alignContent: Alignment.Start }) {
            Row()
              .width('100%')
              .height(3)
              .borderRadius(2)
              .backgroundColor('#4DFFFFFF');
            Row()
              .width(Math.round(this.hintProgress * 100) + '%')
              .height(3)
              .borderRadius(2)
              .backgroundColor('#FFFFFF');
          }
          .width('100%')
          .height(3)
          .margin({ top: 8 });
        }
      }
      .width(170)
      .padding({ left: 14, right: 14, top: 10, bottom: 10 })
      .borderRadius(14)
      .backgroundColor('#B3000000')
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: 0.8, color: '#4DFFFFFF' })
      .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .opacity(this.hintVisible ? 1 : 0)
    .animation({ duration: 150, curve: Curve.EaseOut })
    .hitTestBehavior(HitTestMode.None);
  }

  /**
   * 顶部渐变条（控制层第一段，固定高度、水平铺满、贴播放器顶边）：
   * 返回（全屏时退出全屏）+ 回首页（返回钮右侧独立圆钮）+ 单行标题 + 更多（播放设置）。
   * 左上角返回圆钮：单击 = 退出全屏 / Router.pop() 返回上一页；
   * 右侧「回首页」圆钮与返回钮同款式、同尺寸，点击回调父页面 onReturnHome（清栈 + 切首页 Tab）。
   * 右上角只保留「更多」圆钮：分享入口在简介 tab 动作区、全屏入口在底部控制条，不重复渲染。
   */
  @Builder
  topBar() {
    Row() {
      Row() {
        Image(this.fullscreen ? $r('app.media.ic_close') : $r('app.media.ic_back'))
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
      .border({ width: 0.8, color: '#CCFFFFFF' })
      // 返回钮恢复为纯单击：全屏 = 退出全屏，非全屏 = 返回上一页
      .onClick(() => {
        this.handleBackTap();
      });

      // 「回首页」独立圆钮：紧跟返回钮右侧（间距 8），全屏 / 竖屏 / 横屏都显示
      Row() {
        Image($r('app.media.ic_home'))
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
      .border({ width: 0.8, color: '#CCFFFFFF' })
      .margin({ left: 8 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        this.showControls();
        this.onReturnHome();
      });

      Text(this.displayTitle())
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .textAlign(TextAlign.Center)
        .layoutWeight(1)
        .margin({ left: 10, right: 10 });

      Row() {
        Image($r('app.media.ic_more'))
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
      .border({ width: 0.8, color: '#CCFFFFFF' })
      .onClick(() => {
        this.showControls();
        this.toggleSettings();
      });
    }
    .width('100%')
    .height(this.topBarHeight())
    .padding({
      left: 12,
      right: 12,
      top: this.fullscreen ? this.statusBarHeight : 0
    })
    .alignItems(VerticalAlign.Center)
    .linearGradient({
      direction: GradientDirection.Bottom,
      colors: [['#99000000', 0.0], ['#00000000', 1.0]]
    })
    .translate({ y: this.controlsShown() ? 0 : -6 });
  }

  /**
   * 中央播放 / 暂停大按钮（56 圆形半透明玻璃，挂在控制层中部 layoutWeight(1) 的居中容器里）。
   * 播放中显示暂停图标、暂停显示播放图标；播放结束后图标下方额外显示「重播」文案
   * （对齐原版 COMPLETED 态的 replay 提示），显隐随整个控制层 180ms 淡入淡出。
   */
  @Builder
  centerPlayButton() {
    Column() {
      Row() {
        Image(this.playing ? $r('app.media.ic_pause') : $r('app.media.ic_play'))
          .width(24)
          .height(24)
          .fillColor('#FFFFFF');
      }
      .width(56)
      .height(56)
      .borderRadius(28)
      .justifyContent(FlexAlign.Center)
      .backgroundColor('#66000000')
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: 0.8, color: '#CCFFFFFF' })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        this.togglePlay();
        this.showControls();
      });

      if (this.completed) {
        Text('重播')
          .fontSize(12)
          .fontColor('#E6FFFFFF')
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(999)
          .backgroundColor('#66000000')
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .margin({ top: 8 })
          .onClick(() => {
            this.togglePlay();
            this.showControls();
          });
      }
    }
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  /** 缓冲中：中央 LoadingProgress（不拦截触摸，点击仍可切换控制层 / 使用手势） */
  @Builder
  bufferingOverlay() {
    Column() {
      LoadingProgress()
        .width(44)
        .height(44)
        .color('#FFFFFF')
        .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None);
  }

  /** 网页降级浮动面板：重试原生 / 复制播放地址 / 浏览器打开（深色玻璃胶囊） */
  @Builder
  webFallbackPanel() {
    Column() {
      Column() {
        Text('网页播放' + (this.mediaError.length > 0 ? '：' + this.mediaError : ''))
          .fontSize(11)
          .fontColor('#E6FFFFFF')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');

        Row() {
          Text('重试原生')
            .fontSize(12)
            .fontColor('#FFFFFF')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(999)
            .backgroundColor('#66000000')
            .backgroundBlurStyle(Glass.CHIP_BLUR)
            .border({ width: 0.8, color: '#CCFFFFFF' })
            .onClick(() => {
              this.retryNative();
              this.showControls();
            });
          if (this.sourceUrl.length > 0) {
            Text('复制播放地址')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor('#66000000')
              .backgroundBlurStyle(Glass.CHIP_BLUR)
              .border({ width: 0.8, color: '#CCFFFFFF' })
              .margin({ left: 8 })
              .onClick(() => {
                this.copySourceUrl();
                this.showControls();
              });
            Text('浏览器打开')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(999)
              .backgroundColor('#66000000')
              .backgroundBlurStyle(Glass.CHIP_BLUR)
              .border({ width: 0.8, color: '#CCFFFFFF' })
              .margin({ left: 8 })
              .onClick(() => {
                this.openSourceUrl();
                this.showControls();
              });
          }
        }
        .width('100%')
        .margin({ top: 8 });
      }
      .width('100%')
      .padding(10)
      .borderRadius(16)
      .backgroundColor('#99000000')
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: 0.8, color: '#4DFFFFFF' });
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, top: this.topBarHeight() + 8 })
    .justifyContent(FlexAlign.Start)
    .alignItems(HorizontalAlign.Start)
    .hitTestBehavior(HitTestMode.None);
  }

  /**
   * 底部渐变条（控制层第三段，固定高度、水平铺满、贴播放器底边）：
   * 时间 / Slider（primary）/ 总时长 + 倍速 / 清晰度 / 全屏胶囊（深色玻璃）。
   * 上边是 Slider 行，下边是功能胶囊行，整条渐变从底边向上淡出，不会漂浮到画面中间。
   */
  @Builder
  bottomBar() {
    Column() {
      if (!this.useWeb) {
        Row() {
          Text(formatMs(this.positionMs))
            .fontSize(12)
            .fontColor('#FFFFFF');
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
              // 拖动中只更新 UI 与 pendingSeekMs，**绝不下发 seek**：AVPlayer 的 seek 是异步队列，
              // 每次 Moving 都提交会把队列打满，最终落点变成某个中间值而不是松手位置。
              if (mode === SliderChangeMode.Begin) {
                this.seeking = true;
                this.pointerDown = true;
                this.positionMs = value;
                this.pendingSeekMs = value;
                this.showControls();
              } else if (mode === SliderChangeMode.Moving) {
                this.positionMs = value;
                this.pendingSeekMs = value;
              } else {
                // End / Click（点轨道直接定位）才是真正的提交点：用最后一个 value 精确 seek
                this.positionMs = Math.round(value);
                this.pointerDown = false;
                this.seekTo(Math.round(value));
                this.showControls();
              }
            });
          Text(formatMs(this.durationMs))
            .fontSize(12)
            .fontColor('#FFFFFF');
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center);

        Row() {
          // 倍速 / 清晰度 / 全屏：回到上一版的深色玻璃胶囊（#66000000 + CHIP_BLUR + 0.8 白描边）
          Row() {
            Text(SPEED_OPTIONS[this.speedIndex].label)
              .fontSize(12)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .width(SPEED_CAPSULE_WIDTH)
          .height(CONTROL_CAPSULE_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .borderRadius(CONTROL_CAPSULE_RADIUS)
          .backgroundColor('#66000000')
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: 0.8, color: '#CCFFFFFF' })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.openSpeedPicker();
          });

          Row() {
            Text(this.qualityLabel())
              .fontSize(12)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .width(QUALITY_CAPSULE_WIDTH)
          .height(CONTROL_CAPSULE_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .borderRadius(CONTROL_CAPSULE_RADIUS)
          .backgroundColor('#66000000')
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: 0.8, color: '#CCFFFFFF' })
          .margin({ left: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.openQualityPicker();
          });

          // 单视频循环（对齐原版底栏 Repeat 按钮）：与倍速 / 清晰度胶囊同尺寸、同圆角、同玻璃底，
          // 开启时用 primary 填充 + onPrimary 文字保持状态醒目（不再用 padding 撑出来的小胶囊）
          Row() {
            Text('循环')
              .fontSize(12)
              .fontColor(this.looping ? Theme.colors().onPrimary : '#FFFFFF')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis });
          }
          .width(SPEED_CAPSULE_WIDTH)
          .height(CONTROL_CAPSULE_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .borderRadius(CONTROL_CAPSULE_RADIUS)
          .backgroundColor(this.looping ? Theme.colors().primary : '#66000000')
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: 0.8, color: '#CCFFFFFF' })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .margin({ left: 8 })
          .onClick(() => {
            this.toggleLooping();
          });

          Blank();

          Row() {
            Image($r('app.media.ic_fullscreen'))
              .width(14)
              .height(14)
              .fillColor('#FFFFFF');
            Text(this.fullscreen ? '退出全屏' : '全屏')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .margin({ left: 4 })
              .maxLines(1);
          }
          .width(FULLSCREEN_CAPSULE_WIDTH)
          .height(CONTROL_CAPSULE_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .borderRadius(CONTROL_CAPSULE_RADIUS)
          .backgroundColor('#66000000')
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: 0.8, color: '#CCFFFFFF' })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.requestFullscreen();
          });
        }
        .width('100%')
        .height(44)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center);
      } else {
        Row() {
          Text('网页播放中')
            .fontSize(12)
            .fontColor('#E6FFFFFF');
          Blank();
          Row() {
            Image($r('app.media.ic_fullscreen'))
              .width(14)
              .height(14)
              .fillColor('#FFFFFF');
            Text(this.fullscreen ? '退出全屏' : '全屏')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .margin({ left: 4 })
              .maxLines(1);
          }
          .width(FULLSCREEN_CAPSULE_WIDTH)
          .height(CONTROL_CAPSULE_HEIGHT)
          .justifyContent(FlexAlign.Center)
          .borderRadius(CONTROL_CAPSULE_RADIUS)
          .backgroundColor('#66000000')
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: 0.8, color: '#CCFFFFFF' })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            this.requestFullscreen();
          });
        }
        .width('100%')
        .height(44)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center);
      }
    }
    .width('100%')
    .height(this.bottomBarHeight())
    .padding({
      bottom: (this.useWeb ? 12 : 4) + (this.fullscreen ? this.navBarHeight : 0)
    })
    .justifyContent(FlexAlign.End)
    .linearGradient({
      direction: GradientDirection.Top,
      colors: [['#E6000000', 0.0], ['#00000000', 1.0]]
    })
    .translate({ y: this.controlsShown() ? 0 : 6 });
  }

  /**
   * 「更多」播放设置浮层（系统沉浸材质面板）：
   *  - 材质背景：`MaterialSurface(kind 'panel' + 渐变模糊)`，与顶栏 / 悬浮底栏同一条材质路径，
   *    高度 = 内容实测高度（面板高度随播放器尺寸 / 内容变化，所以不能在代码里写死）；
   *  - 内容层（标题 + 只读播放信息 + 网页降级排查入口）叠在材质层之上，原有显隐 / 开合动画不变；
   *  - 只保留非重复项：清晰度 / 倍速的切换入口只在底部条胶囊打开的选项弹窗里，这里不再放重复选项。
   *
   * ⚠️ 材质层为什么用 ForEach 按「取整后的高度」做 key：
   * `MaterialSurface.surfaceHeight` 是普通属性，ArkTS 里父组件状态变化不会同步到子组件的普通属性，
   * 直接传 `this.settingsPanelHeight` 会让材质层永远停在首帧高度。用高度作 key 后，内容实测高度一变，
   * ForEach 就重建 MaterialSurface，材质背景始终与内容同高（测量只发生在开合 / 内容行增减时）。
   */
  @Builder
  settingsCard() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          Text('播放设置')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .layoutWeight(1);
          Image($r('app.media.ic_close'))
            .width(16)
            .height(16)
            .fillColor('#FFFFFF')
            .onClick(() => {
              this.closeSettings();
            });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 6 });

        Scroll() {
          Column() {
            if (this.useWeb) {
              Text('网页播放中：' + (this.mediaError.length > 0 ? this.mediaError : '原生播放器不可用'))
                .fontSize(11)
                .fontColor('#E6FFFFFF')
                .width('100%');
              Flex({ wrap: FlexWrap.Wrap }) {
                Button('重试原生')
                  .fontSize(11)
                  .height(28)
                  .borderRadius(14)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor('#66000000')
                  .backgroundBlurStyle(Glass.CHIP_BLUR)
                  .border({ width: 0.8, color: '#CCFFFFFF' })
                  .fontColor('#FFFFFF')
                  .margin({ right: 8, bottom: 6 })
                  .onClick(() => {
                    this.retryNative();
                    this.showControls();
                  });
                if (this.sourceUrl.length > 0) {
                  Button('复制播放地址')
                    .fontSize(11)
                    .height(28)
                    .borderRadius(14)
                    .padding({ left: 10, right: 10 })
                    .margin({ right: 8, bottom: 6 })
                    .backgroundColor('#66000000')
                    .backgroundBlurStyle(Glass.CHIP_BLUR)
                    .border({ width: 0.8, color: '#CCFFFFFF' })
                    .fontColor('#FFFFFF')
                    .onClick(() => {
                      this.copySourceUrl();
                      this.showControls();
                    });
                  Button('浏览器打开')
                    .fontSize(11)
                    .height(28)
                    .borderRadius(14)
                    .padding({ left: 10, right: 10 })
                    .margin({ right: 8, bottom: 6 })
                    .backgroundColor('#66000000')
                    .backgroundBlurStyle(Glass.CHIP_BLUR)
                    .border({ width: 0.8, color: '#CCFFFFFF' })
                    .fontColor('#FFFFFF')
                    .onClick(() => {
                      this.openSourceUrl();
                      this.showControls();
                    });
                }
              }
              .width('100%')
              .margin({ top: 6 });
            } else if (this.mediaError.length > 0) {
              Text(this.mediaError)
                .fontSize(12)
                .fontColor(Theme.colors().error)
                .width('100%');
            }

            // 播放信息（只读）：不提供清晰度 / 倍速切换，避免与底部胶囊打开的选项弹窗重复
            Text('播放信息')
              .fontSize(11)
              .fontColor('#B3FFFFFF')
              .width('100%')
              .margin({ top: 10 });
            Column() {
              Text('状态：' + this.playerStateLabel())
                .fontSize(11)
                .fontColor('#E6FFFFFF')
                .width('100%');
              Text('清晰度：' + this.qualityLabel() + ' · 倍速：' + SPEED_OPTIONS[this.speedIndex].label)
                .fontSize(11)
                .fontColor('#E6FFFFFF')
                .width('100%')
                .margin({ top: 4 });
              if (this.durationMs > 0) {
                Text('进度：' + formatMs(this.positionMs) + ' / ' + formatMs(this.durationMs))
                  .fontSize(11)
                  .fontColor('#E6FFFFFF')
                  .width('100%')
                  .margin({ top: 4 });
              }
            }
            .width('100%');

            if (!this.useWeb && this.sourceUrl.length > 0) {
              Text('当前播放地址：' + this.sourceUrl)
                .fontSize(10)
                .fontColor('#8CFFFFFF')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
                .margin({ top: 4 });
              Row() {
                Button('复制播放地址')
                  .fontSize(11)
                  .height(28)
                  .borderRadius(14)
                  .padding({ left: 10, right: 10 })
                  .backgroundColor('#66000000')
                  .backgroundBlurStyle(Glass.CHIP_BLUR)
                  .border({ width: 0.8, color: '#CCFFFFFF' })
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.copySourceUrl();
                    this.showControls();
                  });
                Button('浏览器打开')
                  .fontSize(11)
                  .height(28)
                  .borderRadius(14)
                  .padding({ left: 10, right: 10 })
                  .margin({ left: 8 })
                  .backgroundColor('#66000000')
                  .backgroundBlurStyle(Glass.CHIP_BLUR)
                  .border({ width: 0.8, color: '#CCFFFFFF' })
                  .fontColor('#FFFFFF')
                  .onClick(() => {
                    this.openSourceUrl();
                    this.showControls();
                  });
              }
              .width('100%')
              .margin({ top: 4 });
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start);
        }
        .width('100%')
        .constraintSize({ maxHeight: this.settingsScrollMaxHeight() })
        .scrollBar(BarState.Off);
      }
      .width('100%')
      .padding(14)
      .borderRadius(SETTINGS_RADIUS)
      .backgroundColor('#66000000')
      .backgroundBlurStyle(Glass.BAR_BLUR)
      .border({ width: 0.8, color: PICKER_BORDER });
    }
    .width('100%');
  }

  /** 设置浮层滚动区最大高度：随播放器尺寸收敛，避免面板溢出播放器 */
  settingsScrollMaxHeight(): number {
    const height: number = this.gestureHeight > 0 ? this.gestureHeight : 360;
    let max: number = height - this.topBarHeight() - 84;
    if (max < 64) {
      max = 64;
    }
    if (max > 280) {
      max = 280;
    }
    return max;
  }

  /** 选项弹窗列表最大高度：内嵌播放器高度有限，超出部分在面板内滚动 */
  pickerListMaxHeight(): number {
    const height: number = this.gestureHeight > 0 ? this.gestureHeight : 360;
    let max: number = height - 116;
    if (max < 96) {
      max = 96;
    }
    if (max > 300) {
      max = 300;
    }
    return max;
  }

  /**
   * onAreaChange 的 Length 高度读数转 vp 数值（与手势层同款兜底：运行时通常是 vp 数值，
   * 兼容字符串形态；解析不出时返回 0，调用方据此跳过更新）。
   */
  private areaHeightVp(area: Area): number {
    let height: number = Number(area.height);
    if (isNaN(height)) {
      height = parseFloat(area.height.toString());
    }
    return isNaN(height) ? 0 : height;
  }

  /** 选中某一项后关闭弹窗（清晰度换源 / 倍速下发都由原有 change* 方法处理） */
  selectPickerOption(index: number): void {
    if (this.pickerKind === 'quality') {
      this.changeQuality(index);
    } else if (this.pickerKind === 'speed') {
      this.changeSpeed(index);
    }
    this.closePicker();
  }

  /** 选项弹窗里的一行：选中项主色填充 + 勾选，未选中白字透明底 */
  @Builder
  pickerOptionRow(label: string, index: number, selected: boolean) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(selected ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(selected ? Theme.colors().onPrimary : '#E6FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1);
      if (selected) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().onPrimary);
      }
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .borderRadius(12)
    .backgroundColor(selected ? Theme.colors().primary : Color.Transparent)
    .margin({ bottom: 4 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      this.selectPickerOption(index);
    });
  }

  /**
   * 清晰度 / 倍速选项面板（系统沉浸材质面板 + 0.8 白描边 + 圆角 22）：
   *  - 材质背景：`MaterialSurface(kind 'panel' + 渐变模糊)`，与顶栏 / 悬浮底栏同一条材质路径；
   *    面板高度随选项数量与播放器尺寸变化（列表内部滚动），所以背景高度取内容实测值；
   *  - 内容层（标题 + 关闭圆钮 + 选项列表）叠在材质之上，选项高亮 / 开合动画保持原样；
   *  - 材质层用 ForEach 以「取整后的高度」作 key：高度一变就重建 MaterialSurface，
   *    规避「父状态不会同步子组件普通属性」的限制（原因同 settingsCard）。
   */
  @Builder
  pickerPanel() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        Row() {
          Text(this.pickerKind === 'quality' ? '清晰度' : '倍速')
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .layoutWeight(1);
          Row() {
            Image($r('app.media.ic_close'))
              .width(14)
              .height(14)
              .fillColor('#E6FFFFFF');
          }
          .width(28)
          .height(28)
          .borderRadius(14)
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#33FFFFFF')
          .onClick(() => {
            this.closePicker();
          });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 });

        if (this.pickerKind === 'quality' && this.video.sources.length === 0) {
          Text('暂无可用清晰度')
            .fontSize(12)
            .fontColor('#B3FFFFFF')
            .width('100%')
            .padding({ top: 10, bottom: 10 });
        } else {
          Scroll() {
            Column() {
              if (this.pickerKind === 'speed') {
                ForEach(SPEED_OPTIONS, (option: SpeedOption, index: number) => {
                  this.pickerOptionRow(option.label, index, index === this.speedIndex);
                }, (option: SpeedOption) => option.label);
              } else {
                ForEach(this.video.sources, (source: VideoSource, index: number) => {
                  this.pickerOptionRow(sourceLabel(source, index), index, index === this.qualityIndex);
                }, (source: VideoSource, index: number) => source.url + index);
              }
            }
            .width('100%');
          }
          .width('100%')
          .constraintSize({ maxHeight: this.pickerListMaxHeight() })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring);
        }
      }
      .width('100%')
      .padding({ left: 14, right: 14, top: 12, bottom: 10 })
      .borderRadius(PICKER_RADIUS)
      .backgroundColor('#66000000')
      .backgroundBlurStyle(Glass.BAR_BLUR)
      .border({ width: 0.8, color: PICKER_BORDER });
    }
    .width('88%')
    .constraintSize({ maxWidth: 300 });
  }

  /** 弹窗式浮层：半透明遮罩 + 居中面板，点遮罩 / 点选项关闭；开合 200ms 淡入 + 缩放 + 上移 */
  @Builder
  pickerOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(PICKER_MASK)
        .onClick(() => {
          this.closePicker();
        });
      this.pickerPanel();
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY
      .animation({ duration: PICKER_ANIM_MS, curve: Curve.Friction })
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })
        .animation({ duration: PICKER_ANIM_MS, curve: Curve.Friction }))
      .combine(TransitionEffect.translate({ y: 14 })
        .animation({ duration: PICKER_ANIM_MS, curve: Curve.Friction })));
  }

  /** 「更多」播放设置浮层：半透明遮罩 + 右上角沉浸材质卡片（点遮罩关闭） */
  @Builder
  settingsOverlay() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#66000000')
        .onClick(() => {
          this.closeSettings();
        });
      Column() {
        this.settingsCard();
      }
      .width('76%')
      .constraintSize({ maxWidth: 340 })
      .margin({ top: this.topBarHeight() + 8, right: 12 });
    }
    .width('100%')
    .height('100%')
    .transition(TransitionEffect.OPACITY
      .animation({ duration: 180, curve: Curve.EaseOut })
      .combine(TransitionEffect.scale({ x: 0.96, y: 0.96 })
        .animation({ duration: 180, curve: Curve.EaseOut })));
  }

  /**
   * 续播提示：「从头播放」玻璃胶囊（对齐原版 ShowResumeButton）。
   *
   * 位置（本轮修复）：内嵌播放器高度只有「屏宽 / 画幅」（16:9 时约 200vp），
   * 中央播放/暂停大按钮占画面正中，底栏又是 88vp —— 原先居中 + `padding.bottom = 底栏 + 8`
   * 的胶囊正好压在中键上（两层浮层必然重合，用户点不到播放键）。
   * 现在改为：**贴着底部控制条上方、水平右对齐**（距底栏 6vp、距右缘 12vp），
   * 与居中的播放键横向错开、与底部进度条纵向错开，任何画幅下都不重叠；
   * 仍保留 5s 自动消失，自身不拦截画面手势（只有胶囊本体可点）。
   */
  @Builder
  resumeChip() {
    Column() {
      Row() {
        Image($r('app.media.ic_play'))
          .width(12)
          .height(12)
          .fillColor('#FFFFFF');
        Text('从头播放')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .margin({ left: 5 });
      }
      .padding({ left: 12, right: 14, top: 7, bottom: 7 })
      .borderRadius(999)
      .backgroundColor('#99000000')
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: 0.8, color: '#CCFFFFFF' })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
      .onClick(() => {
        this.restartFromBeginning();
        this.showControls();
      });
    }
    .width('100%')
    .height('100%')
    .padding({
      left: 12,
      right: 12,
      bottom: this.bottomBarHeight() + 6
    })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.End)
    .hitTestBehavior(HitTestMode.None);
  }

  /**
   * 自动重试状态浮层：「正在重试（n/3）」玻璃胶囊。
   *
   * 只在原生播放失败后自动重试期间显示（useWeb 为 false），浮在底部控制条上方居中；
   * 与「从头播放」胶囊互斥（进入重试时会先收掉续播胶囊），不参与控制层 5 秒自动隐藏，
   * 让用户明确知道当前不是卡死而是在自动重试。
   */
  @Builder
  retryIndicator() {
    Column() {
      Row() {
        LoadingProgress()
          .width(14)
          .height(14)
          .color('#FFFFFF');
        Text('正在重试（' + this.retryAttempt + '/' + AUTO_RETRY_MAX + '）')
          .fontSize(12)
          .fontColor('#FFFFFF')
          .margin({ left: 6 });
      }
      .padding({ left: 12, right: 14, top: 7, bottom: 7 })
      .borderRadius(999)
      .backgroundColor('#99000000')
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: 0.8, color: '#CCFFFFFF' });
    }
    .width('100%')
    .height('100%')
    .padding({ left: 12, right: 12, bottom: this.bottomBarHeight() + 6 })
    .justifyContent(FlexAlign.End)
    .alignItems(HorizontalAlign.Center)
    .hitTestBehavior(HitTestMode.None);
  }

  // ---------------------------------------------------------------------------
  // 竖屏（窄画面）黑边布局：圆形浮动按钮移进左右 letterbox
  //
  // 为什么单独做一套按钮而不是复用浮层里的：黑边是纯黑，浮层按钮的「半透明黑 + 0.8 白描边」
  // 在黑边上会有一种「飘在画面里」的观感；这里改成更实的 rgba(0,0,0,0.55) + 1vp #33FFFFFF，
  // 尺寸也统一成 44 起，保证按钮**完全落在黑边内**、不压视频画面。
  // 所有按钮的点击行为都复用原有方法（togglePlay / requestFullscreen / handleBackTap …），
  // 不复制任何播放逻辑，也不碰手势层。
  // ---------------------------------------------------------------------------

  /** 黑边·播放 / 暂停（44/48 圆形，图标随播放状态切换；点击行为与中央大按钮一致） */

  /**
   * 底部控制条渐变遮罩（仅竖屏黑边布局下补一层，横屏保持原样）：
   * 自下而上 rgba(0,0,0,0) → rgba(0,0,0,0.6)，高 96，盖住画面的最下沿，
   * 保证时间 / 进度 / 胶囊文字压在视频画面上仍然清晰。自身不参与命中，显隐随控制层。
   */
  @Builder
  bottomBarScrim() {
    Column() {
      Column()
        .width('100%')
        .height(BOTTOM_SCRIM_HEIGHT)
        .linearGradient({
          direction: GradientDirection.Bottom,
          colors: [['#00000000', 0.0], ['#99000000', 1.0]]
        });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .visibility(this.controlsGone ? Visibility.Hidden : Visibility.Visible)
    .opacity(this.controlsShown() ? 1 : 0)
    .hitTestBehavior(HitTestMode.None);
  }

  /**
   * 画面右侧的锁定按钮（竖屏 / 横屏都固定贴在容器右侧垂直居中）。
   *
   * 交互：点一下锁定 → 控制层淡出隐藏、所有手势失效，只留这颗按钮；再点一下解锁并恢复控制层。
   * 布局：外层 Row 铺满且 HitTestMode.None，只有 36 的圆钮本身参与命中，
   * 因此未锁定时它不会挡住横滑 seek / 单击显隐等手势。
   * 显隐：未锁定跟随控制层显隐（淡出时一起消失）；锁定后常显，且底色更实一点提示当前状态。
   */
  @Builder
  lockButtonLayer() {
    Row() {
      Row() {
        Text(this.locked ? '🔒' : '🔓')
          .fontSize(15)
          .fontColor('#FFFFFF');
      }
      .width(36)
      .height(36)
      .borderRadius(18)
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.locked ? '#B3000000' : '#66000000')
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: 0.8, color: '#CCFFFFFF' })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        this.toggleLock();
      });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    .alignItems(VerticalAlign.Center)
    // 右边距与顶栏圆钮一致（topBar 的 Row padding 是 14），视觉上贴同一条竖线
    .padding({ right: 14 })
    .hitTestBehavior(HitTestMode.None)
    .opacity(this.lockButtonVisible() ? 1 : 0)
    .animation({ duration: 180, curve: Curve.EaseOut })
    .visibility(this.lockButtonVisible() ? Visibility.Visible : Visibility.Hidden);
  }

  /**
   * 控制层：铺满播放器的全尺寸层（纯 UI，不含任何播放逻辑）。
   *
   * 布局为「三段式 Column」：
   *  1. 顶部渐变条 topBar()：固定高 56（全屏 +statusBarHeight），贴播放器顶边；
   *  2. 中部 layoutWeight(1)：占满剩余高度，justifyContent(Center) 把 56 圆形播放/暂停按钮放在画面正中；
   *  3. 底部渐变条 bottomBar()：固定高 88（全屏 +navBarHeight），贴播放器底边。
   *
   * 命中策略：根节点与中部容器都是 HitTestMode.None（自身不响应、不阻塞子节点与下层手势层），
   * 只有顶部/底部条与中央按钮真正拦截触摸，因此控制层铺满也不会挡住单击/双击/滑动 seek。
   * 显隐：整层 180ms 淡出（opacity → 0），淡出结束后 Visibility.Hidden 彻底移出命中测试，
   * 不参与布局（Stack 覆盖层），不会挤压视频画面。
   */
  @Builder
  controlLayer() {
    Column() {
      this.topBar();

      Column() {
        // 中央播放/暂停键：点画面切换播放/暂停的手势也在（走 gestureLayer），按钮只是显式入口
        if (!this.useWeb && this.centerVisible()) {
          this.centerPlayButton();
        }
      }
      .width('100%')
      .layoutWeight(1)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .hitTestBehavior(HitTestMode.None);

      this.bottomBar();
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.SpaceBetween)
    .visibility(this.controlsGone ? Visibility.Hidden : Visibility.Visible)
    .opacity(this.controlsShown() ? 1 : 0)
    .hitTestBehavior(HitTestMode.None);
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 原生播放先铺一层不透明纯黑底：竖屏视频 contain 后左右 letterbox 露出来的就是这层，
      // 不再受父页面 / 主题底色影响（网页降级分支不铺，网页自己铺满自己的背景）
      if (!this.useWeb) {
        this.blackBackdrop();
      }

      this.mediaLayer();

      // 亮度手势直接调窗口亮度（不再用黑色遮罩模拟画面变暗），这里不再有遮罩层
      if (!this.useWeb) {
        // 透明手势层：位于 XComponent 之上、控制层之下（单击/双击/横滑/竖滑）
        this.gestureLayer();
      }

      if (!this.useWeb && this.buffering && this.playerState !== 'playing') {
        this.bufferingOverlay();
      }

      // 网页播放时的降级提示面板：顶部贴合（在顶部条下方），自身不拦截网页触摸
      if (this.useWeb) {
        this.webFallbackPanel();
      }

      // 底部控制条渐变遮罩：自下而上的黑色渐变，保证时间 / 进度 / 胶囊文字压在画面上仍可读
      if (!this.useWeb) {
        this.bottomBarScrim();
      }

      // 控制层（铺满播放器，含顶部条 / 居中播放键 / 底部条）：由 controlsVisible 驱动 180ms 显隐
      this.controlLayer();

      // 画面右侧的锁定按钮：锁上后控制层隐藏、手势全部失效，只有它能点（避免误触）
      if (!this.useWeb) {
        this.lockButtonLayer();
      }

      // 底部常显细进度条：贴着播放器下边缘，不随控制层显隐（设置页开关即时生效）；
      // 渲染在控制层之上才能盖住底部渐变条，但仍位于各类弹窗浮层之下
      if (this.playerBottomProgress && !this.useWeb) {
        this.bottomProgressBar();
      }

      // 自动重试状态：原生播放失败后的 n/3 次自动重试期间显示（与续播胶囊互斥）
      if (this.retrying && !this.useWeb) {
        this.retryIndicator();
      }

      // 续播「从头播放」胶囊：底部控制条上方右侧（避开中央播放键与进度条），弹窗打开时让位
      if (this.resumeVisible && !this.useWeb && this.pickerKind.length === 0 && !this.showSettings) {
        this.resumeChip();
      }

      // 「更多」播放设置浮层：半透明遮罩 + 右上角深色玻璃卡片（遮罩 / 卡片按钮正常命中）
      if (this.showSettings) {
        this.settingsOverlay();
      }

      // 清晰度 / 倍速选项弹窗：盖在控制层与手势层之上，遮罩拦截手势，关闭后完全移除
      if (this.pickerKind.length > 0) {
        this.pickerOverlay();
      }

      // 手势浮动提示（进度 / 音量 / 亮度）：盖在控制层之上，不拦截触摸
      if (!this.useWeb) {
        this.gestureHint();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    // 页面被其他页面完全覆盖（≈ 原版 ON_STOP）：落盘进度并暂停，返回后不自动播
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      this.handleVisibleAreaChange(isVisible, currentRatio);
    });
  }
}
