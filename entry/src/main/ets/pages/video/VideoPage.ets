/**
 * 视频详情页（播放器置顶 + 「简介 / 评论 / 相关推荐」三标签 + 页内横屏全屏）。
 *
 * 布局（单列，宽屏 / 窄屏一致；不再有右侧评论栏）：
 *  1. 播放器：置顶、通栏（横屏画幅铺满宽度；竖屏视频按实际比例收窄居中），纯黑底、无圆角；
 *     顶部位于状态栏下方（窗口是全屏布局，用 AppStorage['statusBarHeight'] 下移），
 *     状态栏高度区域由页面最底层一层通栏纯黑覆盖（图标固定白色，离开本页恢复主题默认色）。
 *     全屏时页面只渲染播放器并铺满窗口；
 *  1.1 「简介 / 评论 / 相关推荐」Tabs 上方有白色小圆角拖拽把手（36×4，16vp 通栏热区）：
 *     上滑折叠**直接隐藏播放器**（playerLayer 宽高动画到 0、动画结束后 Visibility.None，播放器实例不重建）、
 *     折叠态下滑展开、展开态下滑进入全屏、轻点切换展开/折叠；折叠 / 展开 240ms Curve.Friction 吸附；
 *     折叠态把手（黑底 + 白色小条）保留在 Tabs 上方，与状态栏黑底连成一条，
 *     内容区顶到状态栏下方（contentLayer.padding-top = statusBarHeight，Tabs 从把手下方开始）；
 *     折叠只隐藏画面（播放器组件 / AVPlayer 不重建）；播放联动：
 *     上滑折叠时若正在播放 → 静默暂停 + 落盘进度（本来就是暂停 / 结束的保持暂停），
 *     下滑展开时若折叠前在播放 → 从原进度继续播放（折叠前已暂停的保持暂停，不强行播）；
 *     折叠 / 展开的播放状态由 wasPlayingBeforeCollapse 记录，统一在 snapPlayerCollapsed 状态机里处理，
 *     并与全屏 / 方向保护窗口互不干扰。拖动过程实时改播放器几何与内容 padding。
 *  2. 「简介 / 评论 / 相关推荐」Tabs 紧跟播放器（自定义 tabBar：选中 primary 粗体、底部 3vp primary 指示条）：
 *     - 简介 tab（独立 Scroll）：标题 / 动作区（收藏、赞、踩、稍后再看、分享 5 个 44 圆按钮，
 *       播放/暂停交给播放器手势与中央按钮；分享点击弹 ActionSheet：复制分享文本（对齐上游
 *       getHanimeShareText：标题 + 链接 + 来源署名）/ 复制视频链接）/ 元信息 → 可展开简介卡（panelRadius 30；
 *       作者行右侧「作品 ▼」小胶囊 → **作者作品二级面板**：全屏遮罩 + 居中沉浸材质网格，
 *       竖屏 2 列 / 横屏 4 列，网格在面板内独立滚动，不与简介页 Scroll 抢手势）→ 标签 chips
 *       → 系列播放列表（行高 167 = VideoCard 160 宽卡实际高度 165 + 2 余量，与底部网页入口间距 ≈16，
 *       不再留 50+ 空白）；
 *     - 评论 tab：独立滚动的 CommentSection（embedded）+ 悬浮评论输入框
 *       （高 48 / 圆角 24，浮在列表上方；三层 Stack：最底「保险实底」/ 沉浸材质层 / 输入条内容，
 *        材质层键盘收起与弹起都常驻，内容层 zIndex 最高、永远可见可点；
 *        评论数「评论 N」以 12 号次级色小标签渲染在输入胶囊内部左侧，不再占用列表顶部；
 *        键盘态为**手动避让**：输入框聚焦时窗口避让模式切 NONE，输入条按 keyboardHeight + 12 上抬，
 *        列表底部预留同步加键盘高度；失焦后恢复系统 OFFSET 避让。未登录时为「登录后参与评论」胶囊，
 *        同样显示评论数）+ 输入框正上方一行：左侧**评论排序胶囊**（36 高 / 圆角 18 / GlassCapsule
 *        kind 'composer' 系统沉浸材质，⇅ + 当前排序名；点击弹**自定义沉浸材质排序弹窗**：
 *        站点顺序 / 最新 / 最早 / 回复最多 / 最多点赞 / 最多点踩，对齐上游 CommentSortType，
 *        切换只客户端重排已加载评论）、
 *        右侧**独立圆形刷新钮**（40 圆 / GlassCapsule kind 'composer'，点击自增 commentReloadToken
 *        重新拉列表，未登录也显示）；评论条目的举报 / 子回复点赞由 CommentSection / CommentItemView 处理；
 *       列表顶部只留 4 的呼吸间距，底部为输入框 + 键盘避让留白。
 *     - 相关推荐 tab（第 3 个）：2 列 Grid（columnsTemplate '1fr 1fr'、行列间距 12、左右 12 页面边距）
 *       渲染**本页自绘的竖版卡片**（RelatedVideoCard，名称区紧凑、封面**固定 3:4**），点击仍走
 *       openOtherVideo（先暂停落盘再跳转）；列表来自详情接口的 `video.relatedHanimes`，详情返回即落地
 *       （relatedList 首帧可用，不依赖 tab 可见 / 滚动到底部），只有详情返回空列表时才后台静默补拉一次，
 *       失败保留旧数据 + 错误行重试（不清空）；底部留白 = 24 + navBarHeight（详情页是二级页，
 *       不叠 Index 悬浮底栏，不需要 bottomInset），空态用公共 InlineEmptyRow。
 *       卡片宽度按**内容区实际可用宽度**计算（relatedPanelWidth / relatedCardWidth）：
 *       竖屏 = 窗口宽，横屏 = 右侧面板宽（窗口宽 - 左播放器分栏 - 分隔条），仍保持 2 列；
 *       封面高度严格 = 卡宽 × 4/3（见 RelatedVideoCard），拖分隔条 / 旋转屏幕时卡片宽高跟随更新。
 *       本轮修复「上下滑动经过底部区域时卡片闪现 / 到底部才冒出」：**一次性渲染全部相关推荐**
 *       （数据来自详情、条目有限），删除 onReachEnd 增量放出与 relatedShownCount，
 *       Grid.cachedCount 取列表长度（全部预构建），ForEach 用去重后的 videoCode 作稳定唯一 key；
 *       封面高度也不再把播放器 / 可用高度算进来（固定 3:4），滚动时卡片几何不再变化。
 *     三个 Tab 切换（本轮修复「点击仍闪一下」）：**彻底移除内容层的 opacity / translateY 过渡**，
 *     点击与左右滑动都只使用 Tabs 自带页面动画 + tabBar 文字颜色 / 指示条宽度动画；
 *     任何 tab 内容的 opacity 都恒为 1、translate 恒为 0，旧 / 新 tab 都不会被打空。
 *  3. 动画：控制层显隐 180ms、动作按钮 clickEffect + 选中弹簧 1→1.18→1、
 *     全屏切换 animateTo 240ms 宽高过渡、收藏/点赞选中弹簧；
 *     评论悬浮输入框 / 刷新钮页面出现即最终态，**不参与 Tab 切换动画**（避免闪一下）。
 *  4. 播放器左上角：返回圆钮单击 = 全屏退出 / 返回上一页；其右侧独立「回首页」圆钮
 *     （InlinePlayer 的 onReturnHome → returnHomeFromPlayer：暂停落盘 + 恢复方向锁/系统栏
 *      + Router.popToRoot() 清栈 + AppStorage['requestTab'] = 0 切首页 Tab + Toast 反馈）。
 *
 * 播放器：`InlinePlayer`（AVPlayer 逻辑与 PlayerPage 同源）。本页只做：
 *  - 接收 InlinePlayer 的 videoSizeChange 回调，用 @State videoRatio 计算容器宽高（16:9 默认，
 *    竖屏按实际比例，高度 clamp 到屏高 56%）；
 *  - 页内横屏全屏：进入时 setPreferredOrientation(LANDSCAPE) + setWindowSystemBarEnable([])，
 *    退出时按用户「屏幕方向锁」恢复方向（跟随系统 / 竖屏 / 横屏）+ status/navigation；
 *    aboutToDisappear 里一定恢复，防止退出页面后仍停留在全屏方向 / 系统栏被隐藏。
 *    与 Index 约定：全屏期间 AppStorage['videoFullscreen']=true；系统返回被 Index 的
 *    NavDestination.onBackPressed 消费并自增 AppStorage['exitVideoFullscreen']，本页 Watch 收到后
 *    执行退出全屏（恢复方向锁 + 系统栏），因此返回不会直接 pop 回首页。
 *  - 全屏 / 方向切换保护窗口：enterFullscreen / exitFullscreen 一开始就通过
 *    InlinePlayerHandle.beginOrientationChange() 让播放器打开约 1s 的保护窗口（播放器内部定时复位）。
 *    旋转 + 系统栏切换期间播放区可见比例会短暂回调为 0、窗口事件也可能短暂失焦 / 隐藏，
 *    这些信号不再被当成「切后台」去暂停；退出全屏后保持原来的播放状态（不 pauseAndSave、
 *    不重启播放器、不重新 loadSource、不 seek 回 0），真正 HOME / 息屏仍会暂停。
 *
 * 横屏模式（参考 PuraPily，本轮新增）：
 *  - 「是否分栏」只看窗口宽高：viewportWidth > viewportHeight 且非全屏时进入横屏分栏布局；
 *    窗口方向本身由设置项 AppSettings.screenOrientationLock（EntryAbility 启动时 / 设置页切换时
 *    调用 window.setPreferredOrientation）驱动，本页不强制方向（进入 / 退出全屏除外）。
 *  - 横屏 = 左右分栏：左侧播放器区域（宽 = 窗口宽 × splitRatio，默认 62%，可用分隔条在 45%~80%
 *    之间拖拽调整），右侧「简介 / 评论 / 相关推荐」Tabs 独立滚动、宽度自适应剩余空间。
 *  - 左侧是纯黑容器，铺平分栏高度（状态栏下方 → 底部导航条上方）；播放器实例沿用同一个
 *    InlinePlayer（不重建），其 mediaLayer 继续按视频真实画幅在容器内居中 letterbox ——
 *    竖屏视频在横屏下自动左右留黑边，横屏视频铺满，不做任何拉伸。
 *  - 分栏分隔条：10vp 宽热区 + 中间 4×40 圆角把手，PanGesture 横向拖拽改 splitRatio，夹取 45%~80%，
 *    比例只保存在页面状态（不落盘）；全屏时不分栏、播放器铺满窗口。
 *  - 进入页面首帧就按横屏布局（横屏转场优化）：aboutToAppear 里先用 Index 维护的窗口尺寸
 *    （AppStorage['windowWidth'/'windowHeight']）同步初始化 viewportWidth/Height，取不到时再异步
 *    用 window.getLastWindow().getWindowProperties().windowRect 兜底；之后 onAreaChange 继续更新。
 *    这样从横屏列表 push 进本页时不会先渲染一帧竖屏布局、再在转场中重排成横屏分栏。
 *  - 相关推荐卡片宽度按右侧面板实际可用宽度计算（relatedPanelWidth / relatedCardWidth），
 *    拖分隔条 / 旋转后卡片宽与 3:4 封面高度跟随更新（详情见 relatedTab 与 RelatedVideoCard）。
 *  - 横屏下不显示 Tabs 顶部的白色拖拽把手（折叠 / 全屏入口改由播放器控制层的返回 / 更多 / 全屏按钮承担）；
 *    窗口宽 <= 高时完全回到原竖屏布局（播放器顶部 + Tabs 下方），折叠 / 全屏 / 把手逻辑不变。
 *
 * 数据与交互逻辑：api.getVideo / 登录态刷新 / Cloudflare 验证自动重试 / notifyLibraryChanged /
 * 评论回调（分页、点赞、回复、发评论全部沿用 CommentSection 原实现）保持原样；
 * 动作区「收藏 / 赞 / 踩 / 稍后再看」在登录态下**同步站点账号**（HanimeApi.favVideo / rateVideo /
 * addToMyList），乐观更新 + 失败回滚，本地收藏 / 稍后再看仅作镜像；未登录时维持原本地 / 引导登录行为。
 */

import { common } from '@kit.AbilityKit';
import { window, KeyboardAvoidMode, display } from '@kit.ArkUI';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, RouteParam, CF_VERIFY_TICK_KEY } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { BusinessError, pasteboard } from '@kit.BasicServicesKit';
import {
  LoadingView,
  RatingBar,
  SectionHeader,
  TagChip,
  VideoCard,
  VIDEO_CARD_INFO_HEIGHT
} from '../../components/common/Widgets';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { CloudflareChallengeError, LoginExpiredError, describeError } from '../../logic/net/Errors';
import { LocalRepo } from '../../logic/db/LocalRepo';
import { AppSettings, applyScreenOrientationLock } from '../../logic/settings/AppSettings';
import {
  Artist,
  HanimeInfo,
  HanimeVideo,
  MyListPage,
  Playlist,
  SearchPage,
  SearchRequest,
  emptyHanimeVideo
} from '../../core/model/Models';
import { buildWatchUrl } from '../../core/util/Urls';
import { buildVideoShareText } from '../../core/util/ShareText';
import {
  COMMENT_SORT_EARLIEST,
  COMMENT_SORT_LATEST,
  COMMENT_SORT_MOST_DISLIKES,
  COMMENT_SORT_MOST_LIKES,
  COMMENT_SORT_MOST_REPLY,
  COMMENT_SORT_SITE,
  commentSortLabel
} from '../../core/parser/CommentParser';
import {
  applyArtistSubscribed,
  applyVideoFavorite,
  applyVideoRating,
  buildLocalRecord,
  likeRatio,
  normalizeIntroduction
} from '../../viewmodel/video/VideoUiUtils';
import { CommentInputBar } from './CommentInputBar';
import { CommentPanelHandle, CommentSection } from './CommentSection';
import { InlinePlayer, InlinePlayerHandle } from './InlinePlayer';
import { ErrorStateView, InlineEmptyRow, InlineErrorRow, InlineLoadingRow } from './StateViews';
import { RelatedVideoCard } from './RelatedVideoCard';
import { GlassCapsule } from '../../components/common/GlassCapsule';
import { EmptyRefreshHeader, PullRefreshHeader } from '../../components/common/PullRefreshHeader';
import { Material } from '../../common/Material';
import { notifyLibraryChanged, MY_LIST_TYPE_SAVES } from '../../viewmodel/library/LibraryViewModel';
import { SessionActions } from '../../viewmodel/library/SessionActions';

const api: HanimeApi = HanimeApi.getInstance();

/** 简介超过该长度才显示「展开/收起」 */
const INTRO_COLLAPSE_LENGTH: number = 120;
/** 默认画幅（16:9），拿到 videoSizeChange 之前先用它占位 */
const DEFAULT_VIDEO_RATIO: number = 16 / 9;
/** 播放区域高度上限：不超过屏高 56%（竖屏视频 / 矮窗口下不占满整屏） */
const MAX_PLAYER_HEIGHT_RATIO: number = 0.56;
/** 播放区域最小高度（保证控制条可用） */
const MIN_PLAYER_HEIGHT: number = 150;
/**
 * 横屏左右分栏比例（左侧播放器宽度 / 窗口宽度）：
 *  - 默认 62%（PuraPily 的 SPLIT_DEFAULT_RATIO 观感：播放器为主、右侧信息面板可读）；
 *  - 分隔条拖拽时夹取到 45%~80%，避免播放器过窄或右侧面板不可用。
 */
const SPLIT_DEFAULT_RATIO: number = 0.62;
const SPLIT_MIN_RATIO: number = 0.45;
const SPLIT_MAX_RATIO: number = 0.8;
/** 分栏分隔条：10vp 宽热区（可拖拽）+ 中间 4×40 圆角可视把手 */
const SPLIT_DIVIDER_WIDTH: number = 10;
const SPLIT_HANDLE_WIDTH: number = 4;
const SPLIT_HANDLE_HEIGHT: number = 40;
/** 系列播放列表横向卡片宽度（简介 tab 的系列区块） */
const PLAYLIST_CARD_WIDTH: number = 160;
/**
 * 系列播放列表行的固定高度 = VideoCard 的实际卡片高度：
 * 卡片宽 160 → 内容宽 144，封面 16:9 高 81；标题固定 36（+上 6）、元信息固定 24（+上 2）、
 * 卡片内边距 8×2 = 16，合计 = 16 + 81 + 42 + 26 = 165；这里取 167（≈2 余量），避免横滑卡被裁掉。
 * 原值 220 会在卡片下方留出 50+ 空白，把简介 tab 底部内容推得离系列区块过远；
 * 收紧后系列区块 → 简介 tab 底部网页入口间距 ≈ 16，与页面其它区块间距一致。
 */
const PLAYLIST_RAIL_HEIGHT: number = 167;
/**
 * 折叠态播放器高度（vp）。
 *
 * 需求变更：上滑折叠不再收成 148 高的迷你播放器，而是**直接隐藏视频**。
 * 因此折叠态高度固定为 0：playerLayer 的 height / width 同步动画到 0（并裁剪），
 * 折叠吸附动画结束后再 Visibility.None（组件留在树上，AVPlayer 不重建、声音继续）。
 * contentLayer 的 padding-top 只读 playerAreaHeight()，折叠时自然变成 statusBarHeight，
 * Tabs 与把手整体上移到状态栏下方。
 */
const COLLAPSED_PLAYER_HEIGHT: number = 0;
/** 折叠 / 展开吸附动画时长（与全屏切换同一节奏） */
const PLAYER_SNAP_ANIM_MS: number = 240;
/**
 * 折叠动画结束后再等一帧多点（240ms 动画 + 40ms 余量，低帧率 / 定时器抖动也不截断动画尾巴）
 * 才把 playerLayer 设为 Visibility.None：动画期间必须保持可见才能看到「收缩到 0」的过程，
 * 动画结束后组件不参与布局 / 命中，避免 0 尺寸的 XComponent 表面与透明热区残留在把手 / Tabs 上。
 */
const PLAYER_HIDE_SETTLE_MS: number = 280;
/** 拖拽把手：白色小圆角条宽 36 / 厚 4，整条热区高 16（含上下的点击 / 拖拽余量） */
const PLAYER_HANDLE_WIDTH: number = 36;
const PLAYER_HANDLE_THICKNESS: number = 4;
const PLAYER_HANDLE_AREA_HEIGHT: number = 16;
/**
 * 折叠态常显进度条高度（vp，与 InlinePlayer 内部的常显进度条一致）：折叠后播放器高度为 0，
 * 进度条由本页画在把手热区最顶部 —— 也就是折叠后播放器的下边缘。
 */
const COLLAPSED_PROGRESS_HEIGHT: number = 3;
/** 折叠态常显进度条轨道颜色（半透明白；把手热区是播放器黑底） */
const COLLAPSED_PROGRESS_TRACK: string = '#4DFFFFFF';
/** 把手拖拽触发阈值（vp）：上滑折叠，折叠态下滑展开，展开态下滑进入全屏 */
const HANDLE_DRAG_THRESHOLD: number = 48;
/** 展开态往下拖时的阻尼反馈上限（vp）：只给一点「拉得动」的手感，松手过阈值进全屏 */
const PLAYER_PULL_FEEDBACK: number = 96;
/** 还没拿到窗口尺寸时的兜底宽度 */
const FALLBACK_VIEWPORT_WIDTH: number = 360;
/** 悬浮评论输入框高度（PuraPily 风格收紧：56 → 48，圆角 = 高度一半 = 24） */
const COMPOSER_HEIGHT: number = 48;
/**
 * 评论列表悬浮刷新圆钮（原顶部「评论数 + 刷新」胶囊的刷新入口，已单独悬浮到底部输入框上方右侧）：
 *  - 直径 40 / 圆角 20，与悬浮输入框 / 底栏同一套 GlassCapsule 沉浸材质（kind 'composer'）；
 *  - 位置：悬浮评论输入框正上方、右侧对齐（右侧 12 = 输入框左右页边距），
 *    与输入框放在同一列，键盘态随 composerBottomMargin 一起上抬；
 *  - 点击沿用 commentReloadToken 自增触发 CommentSection 重新拉首屏；未登录也显示（用于重新拉列表）。
 */
const COMMENT_REFRESH_SIZE: number = 40;
/** 刷新圆钮底边与输入框顶边之间的间距（vp） */
const COMMENT_REFRESH_GAP: number = 8;
/**
 * 评论排序胶囊（输入框正上方左侧，与右侧刷新圆钮同一行）：
 *  - 高 36 / 圆角 18（= 高度一半，胶囊形）：改用 GlassCapsule kind 'composer'，与搜索胶囊 /
 *    刷新圆钮 / 悬浮底栏同一档系统沉浸材质，不再用普通 chipTint 实底 + 描边；
 *  - 固定宽度：按最长排序名（4 字）+ ⇅ 图标 + 左右 12 内边距预留，切换排序时胶囊宽度不跳变；
 *  - 内容层（文字 / 图标）在材质层之上，并带 1vp glassBorder 描边（与搜索胶囊做法一致），
 *    材质不可用时由 GlassCapsule 内部回退 chipTint + 薄模糊 + 描边，深浅色都可读。
 */
const COMMENT_SORT_PILL_HEIGHT: number = 36;
const COMMENT_SORT_PILL_WIDTH: number = 96;
/**
 * 评论排序弹窗（自定义，替代系统 ActionSheet：样式完全受控且带同源沉浸材质）：
 *  - 面板宽 88%（max 340）/ 圆角 26 / 固定高 352；
 *  - 352 = 上下内边距 12×2 + 标题行 36 + 标题下间距 4 + 6 个选项行 × 48，六项不滚动即可完整放下；
 *  - 面板背景 GlassCapsule kind 'panel'：与顶栏 / 底栏 / 评论输入框同一条系统沉浸材质路径；
 *    材质不可用时 GlassCapsule 内部回退「chipTint + CHIP_BLUR + 1vp 描边」深/浅色玻璃。
 *  - 开合动画 200ms Curve.Friction：遮罩淡入淡出 + 面板 scale 0.94→1 / 上移 12→0
 *    （过渡挂在弹窗根节点上，见 commentSortOverlay）。
 */
const COMMENT_SORT_PANEL_HEIGHT: number = 352;
const COMMENT_SORT_PANEL_RADIUS: number = 26;
const COMMENT_SORT_PANEL_MAX_WIDTH: number = 340;
/** 弹窗标题行高度（标题 + 关闭圆钮垂直居中） */
const COMMENT_SORT_TITLE_HEIGHT: number = 36;
/** 选项行高度（文字 14 号，整行可点 + 按压缩放） */
const COMMENT_SORT_OPTION_HEIGHT: number = 48;
/** 排序弹窗开合动画时长（与面板 scale / translate 一致） */
const COMMENT_SORT_MENU_ANIM_MS: number = 200;
/**
 * 评论列表内容顶部预留（vp）：顶部原有「评论数 + 刷新」悬浮胶囊已移除，
 * 不再需要 60 的胶囊避让，只留 4 的呼吸间距，首条评论贴着列表顶部开始滚动。
 */
const COMMENT_LIST_TOP_INSET: number = 4;
/**
 * 键盘避让由谁负责（悬浮评论输入框的位置计算依据）。
 *
 * 真机反馈：系统默认避让（OFFSET / RESIZE）在部分设备上只把页面挪到「光标可见」的位置，
 * 底部悬浮输入框仍会被输入法压住一点。因此这里改为**手动避让**：
 *  - 评论输入框获得焦点时，把当前 UIContext 的键盘避让模式设为 `KeyboardAvoidMode.NONE`
 *    （系统完全不挪页面，避免「系统上抬 + 手工上抬」双份偏移把输入条顶出可视区）；
 *  - `composerBottomMargin()` 在 `keyboardHeight > 0` 时返回 `keyboardHeight + 12`，
 *    把输入条精确抬到输入法上沿再留 12vp 呼吸；键盘收起时恢复 `navBarHeight + 4`；
 *  - 评论列表底部预留高度（commentComposerReservedHeight）同步加上键盘高度，最后一条评论可滚到键盘上方；
 *  - 输入框失焦 / 页面销毁时把避让模式恢复为 `KeyboardAvoidMode.OFFSET`，
 *    避免其他页面（登录页等）的输入框因为本页遗留的 NONE 而不避让。
 *
 * 该模式设置在 UIContext（窗口级），因此只在「评论输入框聚焦」期间切换，绝不整页常驻。
 */
const KEYBOARD_MANUAL_AVOID: boolean = true;
/**
 * Tab 选中态文字颜色 / 指示条宽度过渡时长。
 * 本轮去掉了点击切换时对 TabContent 内容做 opacity / translateY 的「入场过渡」，
 * tab 切换只保留 Tabs 自带的页面动画 + 这里 tabBar 文字颜色 / 指示条宽度的显式动画。
 */
const TAB_COLOR_ANIM_MS: number = 220;
/** 相关推荐 Grid 顶部内边距（vp） */
const RELATED_GRID_TOP: number = 12;
/** 相关推荐 Grid 底部呼吸（vp；详情页是二级页，不叠 Index 悬浮底栏，只让出系统导航条） */
const RELATED_GRID_BOTTOM: number = 24;
/**
 * 横屏相关推荐 Grid 底部呼吸（vp）：右侧面板本身较矮（窗口高 - 状态栏），
 * 底部再留 24 会把最后一行卡片推得离导航条过远，收紧到 16；导航条高度仍照常叠加。
 */
const RELATED_GRID_BOTTOM_LANDSCAPE: number = 16;
/**
 * 「作者作品」二级面板（简介卡作者行右侧「作品 ▼」小胶囊打开，不再内联在简介 tab 里）：
 *  - 入口：作者行右侧 26 高 / 圆角 999 的小胶囊（chipTint 底 + glassBorder 细描边），
 *    与作者名同一行垂直居中；作者行本体点击同样打开面板（同一个幂等方法，不会重复触发）；
 *  - 数据：站点没有独立作者作品接口，首次打开面板时复用 `HanimeApi.search`（query = 当前作者名、
 *    其余筛选留空、page = 1），排除当前视频并按 videoCode 去重后最多保留前 20 条；
 *  - 面板：宽 = 窗口宽 92%（上限 560）、高按网格内容估算并夹到窗口高 78%、圆角 26，
 *    背景沿用评论排序弹窗的 GlassCapsule kind 'panel' 沉浸材质；
 *  - 网格：竖屏 2 列 / 横屏 4 列（viewportWidth > viewportHeight），行列间距 Dimens.gap，
 *    内容超过面板高度上限后由网格自身竖向滚动（scrollBar Auto），不与简介页 Scroll 抢手势。
 */
const AUTHOR_WORKS_BUTTON_HEIGHT: number = 26;
/**
 * 作者作品最多翻多少页 / 最多保留多少条。
 *
 * 站点搜索每页约 20 条，旧实现只取第 1 页并截断 20 条 —— 作者的其它作品（尤其是
 * 排在第 1 页之后的）根本不会出现，用户看到的就是「列表到某一条就断了」。
 * 现在按 SearchPage.maxPage 一直翻到底，只用一个防跑飞的上限兜住异常站点。
 */
const AUTHOR_WORKS_MAX_PAGES: number = 12;
const AUTHOR_WORKS_MAX_ITEMS: number = 240;
const AUTHOR_WORKS_PANEL_WIDTH_RATIO: number = 0.92;
const AUTHOR_WORKS_PANEL_MAX_WIDTH: number = 560;
const AUTHOR_WORKS_PANEL_MAX_HEIGHT_RATIO: number = 0.78;
/** 还没拿到窗口高度时的面板高度兜底（与 FALLBACK_VIEWPORT_WIDTH 同一用途） */
const AUTHOR_WORKS_PANEL_FALLBACK_HEIGHT: number = 720;
const AUTHOR_WORKS_PANEL_RADIUS: number = 26;
/** 面板内容左右内边距（网格宽度 / 卡片宽度按它扣减） */
const AUTHOR_WORKS_PANEL_PADDING: number = 16;
/** 面板标题行高度（标题 + 30 关闭圆钮垂直居中） */
const AUTHOR_WORKS_PANEL_TITLE_HEIGHT: number = 48;
/** 面板内容区底部呼吸 */
const AUTHOR_WORKS_PANEL_BOTTOM: number = 16;
/** 加载中 / 失败 / 空态的内容区高度：这几种状态不需要按网格行数撑高，面板保持紧凑 */
const AUTHOR_WORKS_STATE_HEIGHT: number = 104;
/** 作者作品面板开合动画时长（与评论排序弹窗一致） */
const AUTHOR_WORKS_PANEL_ANIM_MS: number = 200;

/**
 * 站点「稍后再看」默认清单的 code（POST /save 的 input_id）。
 * 对齐 Android 上游 WatchLaterSubViewModel.deleteMyWatchLater：listCode = "save"；
 * 站点在线列表则用 `user/{id}/saves`（MyListType.WATCH_LATER("saves")）读取。
 */
const WATCH_LATER_LIST_CODE: string = 'save';

/**
 * 相关推荐展示列表规范化（一次性渲染全部 + 稳定唯一 key 的配套）：
 *  - 丢掉 videoCode 为空的条目（无法点击，也无法作为稳定 key）；
 *  - 按 videoCode 去重并保留首次出现顺序：站点返回的 relatedHanimes 偶尔会重复，
 *    重复 key 会让 Grid 的节点复用错乱，滚动时出现卡片闪现 / 显示隐藏。
 * ArkTS 状态数组整体重赋值，这里统一生成新数组。
 */
function dedupeRelatedItems(items: HanimeInfo[]): HanimeInfo[] {
  const result: HanimeInfo[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i: number = 0; i < items.length; i++) {
    const item: HanimeInfo = items[i];
    const code: string = item.videoCode;
    if (code.length === 0 || seen.has(code)) {
      continue;
    }
    seen.add(code);
    result.push(item);
  }
  return result;
}

/**
 * 作者作品列表规范化：**保留当前正在播放的这一条**，只按 videoCode 去重并跳过空 code。
 *
 * 旧实现会排除当前 videoCode 并截断前 20 条 —— 结果是「当前作品」以及它之后的作品一起消失，
 * 面板看起来像只显示了一半。现在当前作品照常展示，由 UI 在卡片上标「正在播放」并加播放动画。
 */
function normalizeAuthorWorks(items: HanimeInfo[]): HanimeInfo[] {
  const result: HanimeInfo[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i: number = 0; i < items.length; i++) {
    const item: HanimeInfo = items[i];
    const code: string = item.videoCode;
    if (code.length === 0 || seen.has(code)) {
      continue;
    }
    seen.add(code);
    result.push(item);
  }
  return result;
}

/** 追加一页结果：按 videoCode 去重（保留已有顺序），返回新数组供 @State 整体重赋值 */
function appendAuthorWorks(current: HanimeInfo[], more: HanimeInfo[]): HanimeInfo[] {
  const merged: HanimeInfo[] = current.slice(0);
  const seen: Set<string> = new Set<string>();
  for (let i: number = 0; i < merged.length; i++) {
    seen.add(merged[i].videoCode);
  }
  for (let i: number = 0; i < more.length; i++) {
    const item: HanimeInfo = more[i];
    const code: string = item.videoCode;
    if (code.length === 0 || seen.has(code)) {
      continue;
    }
    seen.add(code);
    merged.push(item);
    if (merged.length >= AUTHOR_WORKS_MAX_ITEMS) {
      break;
    }
  }
  return merged;
}

@Component
export struct VideoPage {
  p: RouteParam = new RouteParam();
  @StorageLink('themeMode') themeMode: string = 'system';
  /** Cloudflare 网页验证完成信号（WebPage 写入），收到后自动重试当前页 */
  @StorageLink(CF_VERIFY_TICK_KEY) @Watch('onCfVerified') cfVerifyTick: number = 0;
  /** 登录态变化（登录页返回）时静默重新拉取一次，拿到新的 csrf / userId */
  @StorageProp('loggedIn') @Watch('onLoginChanged') loggedIn: boolean = false;
  /** 状态栏高度（EntryAbility 写入；窗口全屏布局，播放器从状态栏下方开始） */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部导航条高度（评论输入条贴底时避让） */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  /**
   * 软键盘高度（EntryAbility 的 keyboardHeightChange 监听写入 AppStorage，单位 vp）。
   * 用途只决定悬浮输入条是否贴键盘上沿：键盘上方只留 8 的呼吸间距（见 composerBottomMargin）。
   * 注意两层：
   *  ① 系统默认 OFFSET/RESIZE 避让已经把页面挪到键盘上方，这里**不能**再把键盘高度
   *     叠加到 margin，否则双份偏移会把输入条顶出可视区；
   *  ② 键盘态**不改变**输入框的背景层级：沉浸材质层始终挂载（见 floatingComposer），
   *     不再像上一版那样「键盘弹起就换实底 / 不挂材质」。
   */
  @StorageProp('keyboardHeight') @Watch('onKeyboardHeightChanged') keyboardHeight: number = 0;
  /**
   * 跨页面「退出播放器全屏」信号（与 Index 约定）。
   * Index 的 NavDestination.onBackPressed 检测到 AppStorage['videoFullscreen'] 为 true 时，
   * 不 pop 页面，而是把本 tick 自增；本页 Watch 收到后执行与「退出全屏」按钮相同的逻辑：
   * 恢复方向锁 + 系统栏 + fs=false，从而回到非全屏播放页，而不是直接退回首页。
   */
  @StorageLink('exitVideoFullscreen') @Watch('onExitFullscreenTick') exitVideoFullscreen: number = 0;
  /**
   * 跨页面「关闭作者作品二级面板」信号（与 Index 约定，机制同全屏 tick）：
   * Index 的 NavDestination.onBackPressed 检测到 AppStorage['videoPanelOpen'] 为 true 时，
   * 不 pop 页面，而是把本 tick 自增；本页 Watch 收到后关掉面板 —— 系统返回手势/返回键
   * 只退出二级面板，不会一下退到首页。
   */
  @StorageLink('exitVideoPanel') @Watch('onExitVideoPanelTick') exitVideoPanel: number = 0;
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State cloudflare: boolean = false;
  @State refreshing: boolean = false;
  /** 下拉手势阶段（简介 tab 的下拉刷新）：只给 PullRefreshHeader 换文案用，不参与数据逻辑 */
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State video: HanimeVideo = emptyHanimeVideo();
  @State fav: boolean = false;
  @State watchLater: boolean = false;
  @State favBusy: boolean = false;
  @State rateBusy: boolean = false;
  /** 关注作者请求在途（防连点；乐观更新，失败回滚） */
  @State subBusy: boolean = false;
  @State introExpanded: boolean = false;
  @State commentCount: number = 0;
  @State commentReloadToken: number = 0;
  /**
   * 评论排序（对齐上游 ui/screen/video/CommentSortType.kt）：
   * 默认 COMMENT_SORT_SITE = 站点原始顺序；切换后由 CommentSection 对已加载评论
   * 客户端重排（不重新请求），子回复同样按此排序。
   *
   * 用 AppStorage 而不是 @State/@Prop 传递：评论列表项是 ForEach 的子组件，
   * 排序值再用 @StorageProp 直接绑定同一 key，切换排序时主评论与子回复都能拿到新值
   * （ForEach 复用已有 item，不会重新执行 itemGenerator，普通 @Prop 无法保证更新）。
   */
  @StorageLink('commentSortType') commentSort: string = COMMENT_SORT_SITE;
  /**
   * 评论排序弹窗是否打开：true 时 build() 末尾条件渲染 commentSortOverlay()
   * （全屏遮罩 + 居中沉浸材质面板）。开合动画由该节点的 transition 承担，这里只做挂载 / 卸载。
   */
  @State commentSortMenuOpen: boolean = false;
  /** 当前 Tab：0 = 简介，1 = 评论，2 = 相关推荐 */
  @State contentTab: number = 0;
  /** 视频画幅（宽 / 高），由 InlinePlayer 的 videoSizeChange 回调更新 */
  @State videoRatio: number = DEFAULT_VIDEO_RATIO;
  /** 页内横屏全屏 */
  @State fs: boolean = false;
  /** 播放器是否折叠隐藏（展开 / 折叠两态，全屏由 fs 单独表示） */
  @State playerCollapsed: boolean = false;
  /** 拖拽把手手势进行中（true 时 playerAreaHeight 使用 dragDy 实时插值） */
  @State handleDragging: boolean = false;
  /** 把手的实时竖直位移（vp，向上为负）：驱动播放器高度 / 内容上边距同步变化 */
  @State handleDragDy: number = 0;
  /**
   * 折叠 / 展开吸附动画进行中：true 时 playerLayer 必须保持 Visibility.Visible，
   * 否则「收缩到 0 / 从 0 长出」的 240ms 动画会因为立刻切 None 而看不到过程。
   * 动画结束（PLAYER_HIDE_SETTLE_MS）后复位，此时折叠态才真正 Visibility.None。
   */
  @State playerSettling: boolean = false;
  /** 内嵌播放器当前是否在播放（动作区按钮文案用） */
  @State videoPlaying: boolean = false;
  /**
   * 折叠隐藏播放器前是否在播放：展开时据此自动恢复播放。
   * 折叠时若在播放 → 静默暂停 + 落盘（见 pauseForPlayerCollapse）；
   * 展开时若折叠前在播放 → 从原进度继续（见 resumeAfterPlayerExpand）；
   * 折叠前本来就是暂停 / 结束的保持暂停，不强行播。
   */
  private wasPlayingBeforeCollapse: boolean = false;
  /** 窗口尺寸（onAreaChange 更新，用于计算播放器比例/位置） */
  @State viewportWidth: number = 0;
  @State viewportHeight: number = 0;
  /**
   * 横屏分栏比例（左侧播放器宽度 / 窗口宽度，45%~80%，默认 62%）。
   * 只在页面状态里保存（旋转回竖屏再转回来仍保持上次拖拽的比例），不落盘。
   */
  @State splitRatio: number = SPLIT_DEFAULT_RATIO;
  /** 分隔条拖拽中（高亮把手 + 只在该状态响应纵向/横向位移） */
  @State dividerDragging: boolean = false;
  /** 分隔条拖拽起始比例（用相对位移累加，避免累计误差 / 跳变） */
  private dividerDragStartRatio: number = SPLIT_DEFAULT_RATIO;
  /** 评论 tab：当前回复目标名（CommentSection 回传，悬浮输入框显示「回复 @xxx」） */
  @State panelReplyName: string = '';
  /** 评论 tab：评论发送中（禁用悬浮输入框的发送按钮） */
  @State panelSending: boolean = false;
  /**
   * 相关推荐列表（本页快照，已按 videoCode 去重）：详情接口返回时由 applyRelatedFromVideo 直接落地，
   * 不依赖相关 tab 是否可见 / 是否滚动到底部；**一次性渲染全部条目**，
   * 后续静默补拉 / 重试失败都不清空。
   */
  @State relatedList: HanimeInfo[] = [];
  /** 相关推荐是否正在加载（仅在列表为空、还没有可展示数据时显示加载行） */
  @State relatedLoading: boolean = false;
  /** 相关推荐加载失败文案（有旧数据时仍展示重试行，列表不清空） */
  @State relatedError: string = '';
  /**
   * 「作者作品」二级面板（简介卡作者行右侧「作品 ▼」小胶囊打开，不再内联在简介 tab 里）：
   *  - panelOpen：面板是否打开；默认关闭，首次打开才发起搜索（懒加载）；
   *  - loading / failed：加载中与失败态（失败显示「加载失败，点击重试」文字按钮）；
   *  - list：搜索结果里排除当前视频、去重后的前 20 条（@State 整体重赋值）。
   */
  @State authorWorksPanelOpen: boolean = false;
  @State authorWorksLoading: boolean = false;
  @State authorWorksFailed: boolean = false;
  @State authorWorks: HanimeInfo[] = [];
  /** 动作区按钮弹簧缩放（选中时 1 → 1.18 → 1） */
  @State favScale: number = 1;
  @State likeScale: number = 1;
  @State dislikeScale: number = 1;
  @State laterScale: number = 1;
  /** 稍后再看是否正在写站点 / 本地（防连点） */
  @State laterBusy: boolean = false;
  private disposed: boolean = false;
  /**
   * 主窗口缓存：aboutToAppear 预取，退出全屏 / 页面销毁时直接复用。
   * aboutToDisappear 阶段 this.getUIContext() 可能已经不可用，现场再取窗口会失败导致
   * setWindowSystemBarEnable 永远不执行 —— 这正是「横屏下系统状态栏消失」的直接原因之一。
   */
  private cachedHostWindow: window.Window | null = null;
  private loadedCode: string = '';
  /** 折叠吸附动画结束后切 Visibility.None 的定时器 id */
  private playerHideTimer: number = -1;
  /** 相关推荐静默补拉 / 重试请求是否在途（避免重复请求） */
  private relatedFetching: boolean = false;
  /**
   * 作者作品是否已成功加载：区分「还没加载过」（首次打开面板要请求）与
   * 「加载成功但确实没有其它作品」（面板显示空态、不再重复请求）。
   */
  private authorWorksLoaded: boolean = false;
  /** 作者作品请求是否在途（打开面板 / 失败重试连点时不重复发请求） */
  private authorWorksFetching: boolean = false;
  /**
   * 站点「稍后再看」校正请求序号：进入页面时异步拉 user/{id}/saves 校正初始态，
   * 若期间用户已经手动点过稍后再看（序号变化），回调不再覆盖用户操作结果。
   */
  private watchLaterSyncSeq: number = 0;
  /**
   * 动作操作序号：loadLocalState 异步读本地库 / 站点状态期间，若用户已经点过收藏 / 赞踩 /
   * 稍后再看（序号变化），初始态不再覆盖用户刚点出来的结果。
   */
  private actionSeq: number = 0;
  /** 内嵌播放器句柄：离开页面前暂停 + 落盘进度、动作区播放/暂停 */
  private playerHandle: InlinePlayerHandle = new InlinePlayerHandle();
  /** 评论列表句柄：发评论 / 取消回复（复用 CommentSection 内部逻辑） */
  private commentHandle: CommentPanelHandle = new CommentPanelHandle();
  /**
   * 悬浮评论输入框的系统沉浸材质当前是否可渲染（与 GlassCapsule 内部的 materialReady
   * 守卫同一条件：Material.usable()）。
   * 只在 aboutToAppear 算一次 —— 可用性由系统能力 / 应用级材质状态决定，页面生命周期内不变。
   * 用途：输入框最底层的「保险实底」仅在材质不可用时可见；材质能渲染时它保持全透明，
   * 避免近不透明的实底把材质透出的背景盖住（那正是「沉浸材质不见了」的观感来源）。
   */
  private composerMaterialReady: boolean = false;
  /**
   * 当前是否已把窗口键盘避让模式切到 NONE（手动避让）。
   * 只在评论输入框聚焦期间为 true；失焦 / 页面销毁时恢复 OFFSET，避免影响其他页面输入框。
   */
  private keyboardManualMode: boolean = false;
  /** 评论输入框当前是否持有焦点（键盘高度变化时用于补切手动避让） */
  private composerFocused: boolean = false;
  /**
   * 键盘高度数据是否可用（EntryAbility 的 keyboardHeightChange 监听是否注册成功）。
   * 不可用时没有可依赖的 keyboardHeight，不能切 NONE（否则输入条无法上抬），保持系统避让。
   */
  private keyboardHeightAvailable: boolean = false;
  /**
   * 视频页当前是否可见：进入本页时把状态栏图标固定白色（播放器上方是黑底），
   * 被网页等二级页完全覆盖时恢复主题默认色，回到本页再切回白色。
   * aboutToAppear/aboutToDisappear 在「覆盖 / 返回」时不会重新触发，因此可见性变化单独兜一层。
   */
  private pageVisible: boolean = false;
  /**
   * 是否在播放器底部常显细进度条（AppSettings.playerBottomProgress，默认开启）。
   * 与 InlinePlayer 读同一个 AppStorage 键：设置页切换后两处即时生效。
   */
  @StorageProp('playerBottomProgress') playerBottomProgress: boolean = true;
  /**
   * 折叠隐藏播放器时的进度快照（0~1；-1 = 还没折叠过 / 时长未知，不画折叠态进度条）。
   * 折叠必然伴随暂停（见 pauseForPlayerCollapse），所以只在折叠时取一次即可。
   */
  @State collapsedProgressRatio: number = -1;

  aboutToAppear(): void {
    // 首帧横屏布局：build 之前先把 viewportWidth/Height 填好（见 initViewport）。
    // onAreaChange 要等首帧布局完成后才回调，如果只依赖它，横屏 push 进入本页时首帧会先按
    // viewportWidth = 0 的竖屏布局渲染、转场中再重排成横屏分栏（明显跳动）。
    this.initViewport();
    // 预取并缓存主窗口：进入全屏 / 退出全屏 / 页面销毁恢复系统栏时不再依赖可能已失效的 UIContext
    this.prefetchHostWindow();
    // 评论排序每次进入视频页回到「站点顺序」（排序选择不跨视频页保留；
    // 与上游 CommentViewModel 每个视频页各自持有一个 CommentSortType 的语义一致）
    this.commentSort = COMMENT_SORT_SITE;
    // 进入详情页默认不是全屏：清掉可能残留的跨页全屏标记（Index 的返回拦截依赖它）
    AppStorage.setOrCreate<boolean>('videoFullscreen', false);
    // 视频页可能多层叠加（相关推荐进入另一个详情页），计数用于决定「最后一个视频页离开」时才恢复状态栏色
    const pageCount: number = AppStorage.get<number>('videoPageCount') ?? 0;
    AppStorage.setOrCreate<number>('videoPageCount', pageCount + 1);
    // 材质可用性只取决于设备/应用配置：提前算好，build 里据此决定保险实底是否可见
    this.composerMaterialReady = Material.usable();
    // 键盘高度键由 EntryAbility 注册监听后写入；不存在说明监听注册失败，退回系统避让
    this.keyboardHeightAvailable = AppStorage.has('keyboardHeight');
    // 播放器上方（y = statusBarHeight）的状态栏区域是纯黑底：图标固定白色
    this.applyStatusBarContentColor('#FFFFFF');
    // 评论悬浮输入框 / 悬浮刷新钮常驻最终态（无 opacity / translate 入场，也不在任何内容过渡层里），
    // 因此点击 / 滑动切到评论 tab 时它们不会闪一下。
    this.reload(true);
  }

  aboutToDisappear(): void {
    this.disposed = true;
    // 页面销毁时清掉「面板开着」的跨页标记：否则返回手势会被一个已经不存在的面板一直吃掉
    AppStorage.setOrCreate<boolean>('videoPanelOpen', false);
    const pageCount: number = AppStorage.get<number>('videoPageCount') ?? 0;
    const remainingVideoPages: number = pageCount > 1 ? pageCount - 1 : 0;
    AppStorage.setOrCreate<number>('videoPageCount', remainingVideoPages);
    if (this.playerHideTimer !== -1) {
      clearTimeout(this.playerHideTimer);
      this.playerHideTimer = -1;
    }
    // 站点稍后再看校正可能还在途：页面销毁后回调不再改 UI
    this.watchLaterSyncSeq = this.watchLaterSyncSeq + 1;
    // 防止退出页面后仍停留在横屏 / 系统栏被隐藏：除了页内 fs 标记，也看跨页 videoFullscreen
    // （onBackPressed 退出全屏与直接 pop 可能交错），只要任一为 true 就必须恢复方向与系统栏。
    const wasFullscreen: boolean = this.fs ||
      AppStorage.get<boolean>('videoFullscreen') === true;
    this.fs = false;
    if (wasFullscreen) {
      // restoreWindowBars 走缓存窗口：aboutToDisappear 里 getUIContext() 可能已不可用，
      // 不能现场再取窗口（旧实现取不到窗口会直接 return，系统栏就永远不回来）
      this.restoreWindowBars();
    }
    // 评论输入框聚焦期间切过的键盘避让模式必须恢复，否则会影响后续页面的输入框避让
    this.setKeyboardAvoidManual(false);
    AppStorage.setOrCreate<boolean>('videoFullscreen', false);
    // 最后一个视频页离开（返回首页 / 内容库等）后状态栏图标恢复主题默认色（浅色底黑字 / 深色底白字）；
    // 若下面还压着另一个视频页则不恢复，避免把那个视频页的白色图标改回默认色。
    if (remainingVideoPages === 0) {
      this.applyStatusBarContentColor(Theme.isDark() ? '#FFFFFF' : '#000000');
    }
  }

  // ---------------------------------------------------------------------------
  // 键盘避让：评论输入框聚焦期间手动避让（NONE + keyboardHeight），失焦恢复系统 OFFSET
  // ---------------------------------------------------------------------------

  /**
   * 切换窗口键盘避让模式。
   *  - true：`KeyboardAvoidMode.NONE`（系统不挪页面，由 composerBottomMargin 手动上抬输入条）；
   *  - false：`KeyboardAvoidMode.OFFSET`（HarmonyOS 主窗口默认避让方式，其他页面输入框照常避让）。
   * 该设置是窗口级 / UIContext 级，用 try/catch 包裹，接口不可用时退回系统默认避让。
   */
  setKeyboardAvoidManual(manual: boolean): void {
    if (manual === this.keyboardManualMode) {
      return;
    }
    // 没有可用的键盘高度数据时不能切 NONE：否则输入条无法按键盘高度上抬，反而会被键盘完全盖住
    if (manual && !this.keyboardHeightAvailable) {
      return;
    }
    try {
      this.getUIContext().setKeyboardAvoidMode(
        manual ? KeyboardAvoidMode.NONE : KeyboardAvoidMode.OFFSET);
      this.keyboardManualMode = manual;
    } catch (e) {
      // 低版本 / 能力不支持时保持系统默认避让
    }
  }

  /** 评论输入框焦点变化：聚焦时切手动避让，失焦恢复系统避让 */
  onComposerFocusChange(focused: boolean): void {
    if (this.disposed) {
      return;
    }
    this.composerFocused = focused;
    this.setKeyboardAvoidManual(focused);
  }

  /**
   * 键盘高度变化：
   *  - 键盘弹起时若评论输入框仍持有焦点（失焦回调未触发 / 焦点一直在输入框上），补切手动避让；
   *  - 键盘完全收起时兜底恢复系统避让模式。
   * 输入框失焦回调在个别场景（切换 Tab / 页面被覆盖）可能不触发，
   * 这里用键盘高度再兜一层，避免 NONE 模式遗留给后续页面。
   */
  onKeyboardHeightChanged(): void {
    if (this.keyboardHeight <= 0) {
      if (this.keyboardManualMode) {
        this.setKeyboardAvoidManual(false);
      }
      return;
    }
    if (this.composerFocused && !this.keyboardManualMode) {
      this.setKeyboardAvoidManual(true);
    }
  }

  /**
   * Index 的 NavDestination.onBackPressed 在播放器全屏时消费了系统返回并自增 tick；
   * 这里执行与「退出全屏」按钮完全相同的逻辑：恢复方向锁 + 系统栏 + fs=false，不 pop 页面。
   */
  onExitFullscreenTick(): void {
    if (this.disposed || !this.fs) {
      return;
    }
    this.exitFullscreen();
  }

  /**
   * Tabs.onChange：只同步当前 Tab 下标 + 键盘避让，**不再对内容做任何 opacity / translate 过渡**。
   *
   * 修复「点击 tab 切换仍会闪一下」：点击切换 / 左右滑动切换都直接使用 Tabs 自带页面动画，
   * tabBar 的选中文字颜色与底部指示条宽度仍由 tabBarItem 的 .animation 平滑过渡；
   * 三个 TabContent 的内容 opacity 恒为 1、translate 恒为 0，旧 / 新 tab 都不会出现打空帧。
   */
  handleTabChanged(index: number): void {
    if (this.contentTab === index) {
      return;
    }
    this.contentTab = index;
    // 离开评论 Tab 时恢复系统键盘避让，避免 NONE 模式在非评论页残留
    if (index !== 1) {
      this.setKeyboardAvoidManual(false);
    }
  }

  // ---------------------------------------------------------------------------
  // 相关推荐：详情接口返回即落地（首帧可用），不依赖 tab 可见 / 滚动到底；
  // 只有详情返回空列表或用户点重试时才后台静默补拉，失败保留旧数据。
  // ---------------------------------------------------------------------------

  /**
   * 详情接口返回相关推荐后立即落地到本页快照（relatedList）：
   *  - 列表直接来自 `video.relatedHanimes`，详情返回时就有数据，相关 tab 首帧可用；
   *  - 落地前按 videoCode 去重（见 dedupeRelatedItems），保证 ForEach key 稳定唯一，
   *    **全部条目一次性落地**，不再分批放出（滚动到底不会再改变列表长度 / 触发节点重建）；
   *  - 空列表视为「本次没拿到」：**保留旧数据不清空**；若当前也没有任何可展示数据，
   *    在后台静默补拉一次详情（站点没有独立的相关推荐接口，relatedHanimes 只来自 /watch 页面解析）。
   */
  private applyRelatedFromVideo(list: HanimeInfo[]): void {
    if (list.length > 0) {
      const normalized: HanimeInfo[] = dedupeRelatedItems(list);
      // 内容（去重后的 videoCode 顺序）完全一致时整体不重赋值，避免无意义的 Grid 重建 / 闪动
      if (!this.sameRelatedList(normalized)) {
        this.relatedList = normalized;
      }
      this.relatedError = '';
      this.relatedLoading = false;
      return;
    }
    if (this.relatedList.length === 0) {
      this.loadRelatedRecommendations(true);
    }
  }

  /** 相关推荐列表是否与当前快照完全一致（按 videoCode 顺序比较），用于避免无意义的重建 */
  private sameRelatedList(list: HanimeInfo[]): boolean {
    if (list.length !== this.relatedList.length) {
      return false;
    }
    for (let i: number = 0; i < list.length; i++) {
      if (list[i].videoCode !== this.relatedList[i].videoCode) {
        return false;
      }
    }
    return true;
  }

  /**
   * 拉取相关推荐（后台静默 / 手动重试共用）：
   *  - 数据源只有详情接口：站点没有单独的相关推荐 API，`relatedHanimes` 来自 /watch 页面解析，
   *    因此这里重新请求一次详情、只取相关推荐列表；
   *  - 正常路径下详情返回时已通过 applyRelatedFromVideo 落地，这里只作为空数据兜底；
   *  - 失败时保留 relatedList（不清空），记录错误文案供错误行「点击重试」；
   *  - silent = true（后台静默兜底）时不主动清空已有错误、也不弹 Toast；
   *    列表为空时仍显示轻量加载行，避免先闪一下「暂无相关推荐」再出现数据。
   */
  async loadRelatedRecommendations(silent: boolean): Promise<void> {
    if (this.relatedFetching) {
      return;
    }
    const code: string = this.videoCode();
    if (code.length === 0) {
      return;
    }
    this.relatedFetching = true;
    if (!silent) {
      this.relatedError = '';
    }
    // 还没有任何可展示数据时（首次空列表兜底 / 重试）显示加载行；
    // 已有旧数据时静默刷新不改变列表呈现，避免闪烁
    if (this.relatedList.length === 0) {
      this.relatedLoading = true;
    }
    try {
      const detail: HanimeVideo = await api.getVideo(code);
      if (this.disposed) {
        this.relatedFetching = false;
        return;
      }
      this.relatedLoading = false;
      const list: HanimeInfo[] = detail.relatedHanimes;
      if (list.length > 0) {
        const normalized: HanimeInfo[] = dedupeRelatedItems(list);
        if (!this.sameRelatedList(normalized)) {
          this.relatedList = normalized;
        }
        this.relatedError = '';
      }
      // 请求成功但站点确实没有相关推荐：保持空态，不当作失败（不显示错误行）
    } catch (e) {
      if (this.disposed) {
        this.relatedFetching = false;
        return;
      }
      this.relatedLoading = false;
      this.relatedError = describeError(e as Error);
    }
    this.relatedFetching = false;
  }

  /** 相关推荐错误行「点击重试」：保留旧数据，只重新拉一次 */
  retryRelated(): void {
    if (this.disposed || this.relatedFetching) {
      return;
    }
    this.loadRelatedRecommendations(false);
  }

  // ---------------------------------------------------------------------------
  // 相关推荐：一次性渲染全部（稳定 key / 不做增量放出），卡片宽度按内容区实际可用宽度算
  // ---------------------------------------------------------------------------

  /**
   * 相关推荐 tab 内容区实际可用宽度（vp）：
   *  - 竖屏：窗口宽（内容层铺满整页，只有左右页边距）；
   *  - 横屏分栏：右侧面板宽 = 窗口宽 - 左侧播放器分栏宽 - 分隔条热区宽
   *    （contentLayer 用左 padding 让出「播放器 + 分隔条」，见 contentLayer）。
   * 拖拽分隔条（splitRatio 是 @State）/ 旋转屏幕（viewport 是 @State）都会触发 build 重算，
   * 卡片宽度与 3:4 封面高度随之更新，不会沿用竖屏全宽算出来的过大卡片。
   */
  relatedPanelWidth(): number {
    const total: number = this.contentWidth();
    if (!this.landscapeLayout()) {
      return total;
    }
    const panel: number = total - this.splitLeftWidth() - SPLIT_DIVIDER_WIDTH;
    return panel > 0 ? panel : total;
  }

  /**
   * 相关推荐卡片宽度：面板可用宽 - 左右页边距 - 列间距，再按 2 列均分。
   * 横屏右侧面板再窄也保持 2 列（不硬塞 3 列把卡压得过小）；返回 0 时卡片按 100% 宽兜底。
   */
  relatedCardWidth(): number {
    const available: number = this.relatedPanelWidth() - Dimens.pagePadding * 2 - Dimens.gap;
    if (!(available > 0)) {
      return 0;
    }
    return available / 2;
  }

  /**
   * 相关推荐 Grid 底部留白（vp）：让最后一行卡片能滚到系统导航条上方。
   * 横屏右侧面板较矮（面板高 = 窗口高 - 状态栏），呼吸收紧到 16；
   * navBarHeight 由 EntryAbility 随系统栏监听写入，横竖屏切换后是最新值。
   */
  relatedGridBottomInset(): number {
    if (this.landscapeLayout()) {
      return RELATED_GRID_BOTTOM_LANDSCAPE + this.navBarHeight;
    }
    return RELATED_GRID_BOTTOM + this.navBarHeight;
  }

  // ---------------------------------------------------------------------------
  // 作者作品：简介卡作者行右侧「作品 ▼」按钮 → 二级面板（懒加载网格）
  // ---------------------------------------------------------------------------

  /**
   * 打开作者作品二级面板（作者行本体 / 右侧「作品 ▼」胶囊都调用这里）：
   *  - 先收起输入焦点（评论输入框若在输入，键盘随之落下，面板不会被输入法压住）；
   *  - 首次打开才懒加载；已成功加载过（含空列表）或请求在途时直接复用现有数据；
   *  - 打开用幂等判断：行本体与胶囊可能先后各触发一次，第二次直接返回，不会重复请求。
   */
  openAuthorWorksPanel(): void {
    if (this.authorWorksPanelOpen) {
      return;
    }
    this.dismissComposerFocus();
    this.authorWorksPanelOpen = true;
    // 告诉 Index：详情页上有浮层打开了，系统返回先交给本页处理（见 Index.consumeBackWhenVideoPanel）
    AppStorage.setOrCreate<boolean>('videoPanelOpen', true);
    // 懒加载：只有第一次打开（还没成功加载过、也没有在途请求）才请求，关闭再打开不重复请求
    if (this.authorWorksLoaded || this.authorWorksFetching) {
      return;
    }
    this.loadAuthorWorks();
  }

  /** 关闭作者作品二级面板（点遮罩 / 关闭圆钮 / 选中卡片都会走这里；淡出动画由 transition 负责） */
  closeAuthorWorksPanel(): void {
    if (!this.authorWorksPanelOpen) {
      return;
    }
    this.authorWorksPanelOpen = false;
    AppStorage.setOrCreate<boolean>('videoPanelOpen', false);
  }

  /** Index 收到系统返回、判定「面板开着」时自增 tick，这里关掉面板（与全屏 tick 同一套写法） */
  onExitVideoPanelTick(): void {
    if (this.authorWorksPanelOpen) {
      this.closeAuthorWorksPanel();
    }
  }

  /**
   * 懒加载作者作品（首次打开面板 / 失败重试）：
   *  - 站点没有独立「作者作品」接口，复用搜索接口：page=1、query=当前作者名，其余筛选条件全部留空；
   *  - 返回结果排除当前正在播放的视频、按 videoCode 去重，最多保留前 AUTHOR_WORKS_LIMIT（20）条；
   *  - 成功才置 authorWorksLoaded（空列表视为「确实没有其它作品」，重开面板不再请求）；
   *  - 失败只置 failed（面板显示「加载失败，点击重试」），已加载的旧数据不清空；
   *  - 页面已销毁时直接返回，不再改状态。
   */
  async loadAuthorWorks(): Promise<void> {
    if (this.disposed || this.authorWorksFetching) {
      return;
    }
    const name: string = this.authorName();
    if (name.length === 0) {
      this.authorWorksFailed = true;
      return;
    }
    this.authorWorksFetching = true;
    this.authorWorksLoading = true;
    this.authorWorksFailed = false;
    // ArkTS 里空数组字面量放进对象字面量容易产生类型推断争议，这里显式声明空筛选数组
    const noTags: string[] = [];
    const noBrands: string[] = [];
    try {
      const first: SearchRequest = {
        page: 1,
        query: name,
        genre: '',
        sort: '',
        broad: false,
        date: '',
        duration: '',
        tags: noTags,
        brands: noBrands
      };
      const firstPage: SearchPage = await api.search(first);
      if (this.disposed) {
        return;
      }
      // 第一页先落地：面板立刻有内容，后续页在后台继续追加
      let all: HanimeInfo[] = normalizeAuthorWorks(firstPage.list);
      this.authorWorks = all;
      this.authorWorksLoaded = true;
      if (!this.disposed) {
        this.authorWorksLoading = false;
      }
      // 继续翻页：站点搜索每页约 20 条，作者作品常常跨多页。
      // 旧实现只取第 1 页并截断 20 条，于是「当前作品及其之后的」全都看不到。
      let page: number = 2;
      while (page <= firstPage.maxPage && page <= AUTHOR_WORKS_MAX_PAGES &&
        all.length < AUTHOR_WORKS_MAX_ITEMS && !this.disposed) {
        const next: SearchRequest = {
          page: page,
          query: name,
          genre: '',
          sort: '',
          broad: false,
          date: '',
          duration: '',
          tags: noTags,
          brands: noBrands
        };
        const nextPage: SearchPage = await api.search(next);
        if (this.disposed) {
          return;
        }
        const before: number = all.length;
        all = appendAuthorWorks(all, nextPage.list);
        this.authorWorks = all;
        // 某页没带来新条目（重复 / 空页）→ 提前结束，避免对着空结果一直翻
        if (all.length === before) {
          break;
        }
        page = page + 1;
      }
    } catch (e) {
      if (!this.disposed) {
        // 已有部分数据就保留（至少第一页是完整的），只在一条都没有时显示失败态
        this.authorWorksFailed = this.authorWorks.length === 0;
      }
    } finally {
      this.authorWorksFetching = false;
      if (!this.disposed) {
        this.authorWorksLoading = false;
      }
    }
  }

  /** 作者作品网格列数：竖屏固定 2 列、横屏固定 4 列（与页面横竖屏判断同源，旋转后即时重排） */
  authorWorksColumns(): number {
    return this.viewportWidth > this.viewportHeight ? 4 : 2;
  }

  /** Grid 的 columnsTemplate 字符串（显式拼串，ArkTS 里不用动态属性访问） */
  authorWorksGridTemplate(): string {
    const columns: number = this.authorWorksColumns();
    let template: string = '1fr';
    for (let i: number = 1; i < columns; i++) {
      template = template + ' 1fr';
    }
    return template;
  }

  /** 面板宽度：窗口宽 92%、上限 560（横屏分栏时遮罩仍覆盖整窗，面板居中，不跟随右侧简介栏宽度） */
  authorWorksPanelWidth(): number {
    const viewport: number = this.viewportWidth > 0 ? this.viewportWidth : FALLBACK_VIEWPORT_WIDTH;
    const width: number = viewport * AUTHOR_WORKS_PANEL_WIDTH_RATIO;
    return width < AUTHOR_WORKS_PANEL_MAX_WIDTH ? width : AUTHOR_WORKS_PANEL_MAX_WIDTH;
  }

  /** 面板高度上限：窗口高 78%（拿不到窗口高度时用 720 兜底，避免 0 高面板） */
  authorWorksPanelMaxHeight(): number {
    const viewport: number = this.viewportHeight > 0
      ? this.viewportHeight
      : AUTHOR_WORKS_PANEL_FALLBACK_HEIGHT;
    return viewport * AUTHOR_WORKS_PANEL_MAX_HEIGHT_RATIO;
  }

  /** 面板内网格可用宽度：面板宽 - 左右内容内边距 */
  authorWorksGridWidth(): number {
    const available: number = this.authorWorksPanelWidth() - AUTHOR_WORKS_PANEL_PADDING * 2;
    return available > 0 ? available : 0;
  }

  /** 网格单卡宽度（VideoCard 在 Grid 里是 100% 列宽，这里只用于估算面板高度） */
  authorWorksCardWidth(): number {
    const columns: number = this.authorWorksColumns();
    const available: number = this.authorWorksGridWidth() - Dimens.gap * (columns - 1);
    if (!(available > 0)) {
      return 0;
    }
    return available / columns;
  }

  /**
   * 网格内容高度：按条目行数算内容高度（卡片高 = 列宽 × 9/16 + VIDEO_CARD_INFO_HEIGHT，与 VideoCard 口径一致）。
   * 只算内容本身，不再夹到固定上限 —— 面板高度由 authorWorksPanelHeight 统一夹到窗口高 78%。
   */
  authorWorksGridHeight(): number {
    const count: number = this.authorWorks.length;
    if (count === 0) {
      return 0;
    }
    const columns: number = this.authorWorksColumns();
    const rows: number = Math.ceil(count / columns);
    const cardHeight: number = this.authorWorksCardWidth() * 9 / 16 + VIDEO_CARD_INFO_HEIGHT;
    return rows * cardHeight + (rows - 1) * Dimens.gap;
  }

  /**
   * 面板实际高度 = 标题行 + 内容区 + 底部呼吸；网格内容多时夹到窗口高 78%，
   * 超出部分由面板内的 Grid 自己竖向滚动（不与简介页 Scroll 冲突）。
   * 加载中 / 失败 / 空态用固定内容区高度（AUTHOR_WORKS_STATE_HEIGHT），面板保持紧凑。
   */
  authorWorksPanelHeight(): number {
    const gridHeight: number = this.authorWorksGridHeight();
    const contentHeight: number = gridHeight > 0 ? gridHeight : AUTHOR_WORKS_STATE_HEIGHT;
    const desired: number = AUTHOR_WORKS_PANEL_TITLE_HEIGHT + AUTHOR_WORKS_PANEL_BOTTOM + contentHeight;
    const maxHeight: number = this.authorWorksPanelMaxHeight();
    return desired < maxHeight ? desired : maxHeight;
  }

  /**
   * 面板材质宿主的重建 key：GlassCapsule 的 `capsuleHeight` 是普通成员变量（父组件重绘不会热更新），
   * 而面板高度会随「加载中 → 网格」、旋转屏幕变化，直接复用旧实例会被初始高度裁切。
   * 这里把高度 + 内容态拼成 key 交给 ForEach：任一变化都以新参数重建材质宿主，
   * 保证沉浸材质面板与内容层严格同高、内容不会留在旧实例里（重建成本与开合动画同一量级）。
   */
  authorWorksPanelKey(): string {
    const height: number = Math.round(this.authorWorksPanelHeight());
    const loading: string = this.authorWorksLoading ? 'L' : '-';
    const failed: string = this.authorWorksFailed ? 'F' : '-';
    return height.toString() + loading + failed + this.authorWorks.length.toString();
  }

  /** 动作按钮弹簧：1 → 1.18 → 1（收藏 / 点赞 / 踩 / 稍后再看选中时） */
  playScaleBounce(target: string): void {
    animateTo({ duration: 120, curve: Curve.EaseOut }, () => {
      if (target === 'fav') {
        this.favScale = 1.18;
      } else if (target === 'like') {
        this.likeScale = 1.18;
      } else if (target === 'dislike') {
        this.dislikeScale = 1.18;
      } else {
        this.laterScale = 1.18;
      }
    });
    setTimeout(() => {
      if (this.disposed) {
        return;
      }
      animateTo({ duration: 220, curve: Curve.Friction }, () => {
        if (target === 'fav') {
          this.favScale = 1;
        } else if (target === 'like') {
          this.likeScale = 1;
        } else if (target === 'dislike') {
          this.dislikeScale = 1;
        } else {
          this.laterScale = 1;
        }
      });
    }, 130);
  }

  onLoginChanged(): void {
    if (this.loadedCode.length === 0 || this.disposed) {
      return;
    }
    this.reload(false);
    this.commentReloadToken = this.commentReloadToken + 1;
  }

  /** Cloudflare 网页验证完成后自动重试详情页（WebPage 写入 cfVerifyTick） */
  onCfVerified(): void {
    if (this.cfVerifyTick > 0 && this.errorMsg.length > 0 && !this.disposed) {
      this.reload(true);
    }
  }

  videoCode(): string {
    if (this.p.videoCode.length > 0) {
      return this.p.videoCode;
    }
    return this.video.videoCode;
  }

  async reload(showLoading: boolean): Promise<void> {
    const code: string = this.videoCode();
    if (code.length === 0) {
      this.loading = false;
      this.errorMsg = '缺少视频编号';
      return;
    }
    if (showLoading) {
      this.loading = true;
    }
    this.errorMsg = '';
    this.cloudflare = false;
    try {
      const video: HanimeVideo = await api.getVideo(code);
      if (this.disposed) {
        return;
      }
      this.video = video;
      this.loadedCode = video.videoCode;
      this.commentCount = video.commentCount;
      this.loading = false;
      // 相关推荐在详情返回时就落地（relatedList 首帧可用），不依赖相关 tab 是否可见 / 是否滚到底部；
      // 详情没有相关推荐数据时在后台静默补拉一次，失败保留旧数据。
      this.applyRelatedFromVideo(video.relatedHanimes);
      this.loadLocalState();
    } catch (e) {
      if (this.disposed) {
        return;
      }
      const err: Error = e as Error;
      if (err instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      if (showLoading) {
        this.errorMsg = describeError(err);
        this.cloudflare = err instanceof CloudflareChallengeError;
        this.loading = false;
      } else {
        Toast.show(describeError(err));
      }
    }
  }

  /**
   * 初始化动作区状态 + 观看记录（进入页面即记录历史，但**不写播放进度**）。
   *
   * 收藏 / 赞 / 踩 / 稍后再看按钮初始态以**站点账号数据为准**（登录态）：
   *  - 收藏 / 赞 / 踩：详情页 HTML 已经带出 `isFav` / `isUnlike`（`input[name=like-status]` 等），
   *    登录后 `reload()` 会重新拉取，因此 onLoginChanged 后这里会再次校正；
   *  - 稍后再看：详情页 `#playlist-save-checkbox` 解析到 `video.myList.isWatchLater`；
   *    若详情没给到（站点改版 / 未解析），再异步拉一次 `user/{id}/saves` 第 1 页做兜底校正，
   *    只做「站点已保存 → 按钮点亮」的升级，避免误清用户刚点出来的状态。
   * 未登录时维持原有本地行为（本地收藏 / 本地稍后再看仍可用）。
   */
  async loadLocalState(): Promise<void> {
    const code: string = this.video.videoCode;
    const repo: LocalRepo = LocalRepo.getInstance();
    const seq: number = this.actionSeq;
    let favLocal: boolean = false;
    let laterLocal: boolean = false;
    try {
      favLocal = await repo.isFavorited(code);
      laterLocal = await repo.isWatchLater(code);
    } catch (e) {
      // 本地库尚未初始化时不影响页面展示
    }
    // 期间用户已手动操作过动作区时（序号变化）不再用旧初始态覆盖；历史记录仍照常写（见下）
    if (!this.disposed && seq === this.actionSeq) {
      const siteWatchLater: boolean = this.video.myList !== null ? this.video.myList.isWatchLater : false;
      if (this.loggedIn) {
        // 登录态：按钮初始态跟随账号侧（站点详情页解析结果）
        this.fav = this.video.isFav;
        this.watchLater = siteWatchLater;
        // 站点详情没带出稍后再看状态时，用在线「稍后再看」列表兜底校正一次
        if (!this.watchLater) {
          this.correctWatchLaterFromSite();
        }
      } else {
        // 未登录：保持原本地行为（本地收藏 / 本地稍后再看）
        this.fav = favLocal;
        this.watchLater = laterLocal;
      }
    }
    try {
      // 只刷新历史元信息 / 时间戳，不传 positionMs=0：进度由播放器独占写入。
      // 旧写法 `recordWatch(..., 0, 0)` 是「读旧行再整行写回」，与播放器 5s 节流落盘并发时
      // 可能把旧进度写回；且 upsertHistory 的 ≥95% 规则可能把刚保存的进度归零 → 续播失效。
      await repo.touchHistory(code, this.video.title, this.video.coverUrl);
      // 通知「我的」Tab 刷新本地计数（详情页进入即产生一条历史）
      notifyLibraryChanged();
    } catch (e) {
      // 观看历史写失败不影响页面
    }
  }

  /**
   * 登录态下用站点「稍后再看」列表（`GET user/{id}/saves?page=1`）校正按钮初始态。
   *
   * 为什么需要：详情页的 `#playlist-save-checkbox` 是站点 DOM 约定，改版 / 登录态解析失败时
   * isWatchLater 会误判为 false，导致账号里明明收藏了但按钮不亮。这里只在「按钮当前是灭的」
   * 时请求一次第 1 页（最近保存的在前），命中才点亮；请求失败 / 没命中都保持原状态（不清状态）。
   * 期间用户手动点过稍后再看（watchLaterSyncSeq 变化）则不覆盖用户操作。
   */
  private async correctWatchLaterFromSite(): Promise<void> {
    if (this.disposed || !this.loggedIn) {
      return;
    }
    const code: string = this.video.videoCode;
    if (code.length === 0) {
      return;
    }
    const userId: string = this.video.currentUserId.length > 0
      ? this.video.currentUserId
      : (AppStorage.get<string>('userId') ?? '');
    if (userId.length === 0) {
      return;
    }
    this.watchLaterSyncSeq = this.watchLaterSyncSeq + 1;
    const seq: number = this.watchLaterSyncSeq;
    try {
      const page: MyListPage = await api.getMyList(userId, MY_LIST_TYPE_SAVES, 1);
      if (this.disposed || seq !== this.watchLaterSyncSeq) {
        return;
      }
      if (this.video.videoCode !== code) {
        return;
      }
      for (let i: number = 0; i < page.items.length; i++) {
        if (page.items[i].videoCode === code) {
          this.watchLater = true;
          return;
        }
      }
    } catch (e) {
      // 校正失败保持本地 / 详情页解析出来的状态，不打断页面
    }
  }

  /** 简介 tab 下拉刷新：重新拉详情（静默，不显示整页 loading）并让评论一起刷新 */
  async refresh(): Promise<void> {
    this.refreshing = true;
    await this.reload(false);
    if (!this.disposed) {
      this.commentReloadToken = this.commentReloadToken + 1;
    }
    this.refreshing = false;
  }

  authorName(): string {
    const artist: Artist | null = this.video.artist;
    if (artist !== null) {
      return artist.name;
    }
    return '';
  }

  artistAvatar(): string {
    const artist: Artist | null = this.video.artist;
    if (artist !== null) {
      return artist.avatarUrl;
    }
    return '';
  }

  playlistVideos(): HanimeInfo[] {
    const playlist: Playlist | null = this.video.playlist;
    if (playlist !== null) {
      return playlist.video;
    }
    return [];
  }

  playlistTitle(): string {
    const playlist: Playlist | null = this.video.playlist;
    if (playlist !== null && playlist.playlistName.length > 0) {
      return playlist.playlistName;
    }
    return '系列播放列表';
  }

  introText(): string {
    return normalizeIntroduction(this.video.introduction);
  }

  // ---------------------------------------------------------------------------
  // 布局尺寸：播放器比例自适应（videoSizeChange → videoRatio → 容器宽高）
  // ---------------------------------------------------------------------------

  /**
   * 首帧横屏布局初始化（build 之前调用，只做一次）：
   *  1. 同步取 Index 根容器 onAreaChange 维护的 AppStorage['windowWidth'/'windowHeight']
   *     —— 从列表页 push 进来时 Index 早已测量过窗口，能保证**首帧**就是正确的横屏分栏几何；
   *  2. 取不到时（例如冷启动直接打开视频页）再异步向系统窗口要一次尺寸兜底：
   *     window.getLastWindow(...).getWindowProperties().windowRect（px → vp）。
   * 之后 onAreaChange 继续按实际布局区域增量更新（旋转 / 折叠 / 分屏都走它）。
   * 全程只改 viewportWidth / viewportHeight 两个布局状态，不触碰播放器实例与播放状态。
   */
  private initViewport(): void {
    const storedWidth: number | undefined = AppStorage.get<number>('windowWidth');
    const storedHeight: number | undefined = AppStorage.get<number>('windowHeight');
    if (storedWidth !== undefined && storedHeight !== undefined &&
      storedWidth > 0 && storedHeight > 0) {
      this.viewportWidth = storedWidth;
      this.viewportHeight = storedHeight;
      return;
    }
    // 兜底 1（同步）：直接问系统当前显示方向/尺寸。Index 的 onAreaChange 尚未写过 AppStorage
    // （例如冷启动直接打开视频页）时，也能在 build 之前拿到正确横竖屏，避免首帧竖屏布局。
    if (this.syncViewportFromDisplay()) {
      return;
    }
    // 兜底 2（异步）：不阻塞首帧（await 结果回来前仍可用 onAreaChange / 窗口比例兜底判断方向）
    this.initViewportFromHostWindow();
  }

  /** 同步用系统显示信息初始化 viewport（不依赖 AppStorage / 窗口异步查询）：成功返回 true */
  private syncViewportFromDisplay(): boolean {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const width: number = px2vp(info.width);
      const height: number = px2vp(info.height);
      if (!(width > 0) || !(height > 0)) {
        return false;
      }
      this.viewportWidth = width;
      this.viewportHeight = height;
      return true;
    } catch (e) {
      return false;
    }
  }

  /** 系统当前是否为横屏（与 viewport 无关，仅在 viewport 未就绪时作为方向兜底） */
  private displayIsLandscape(): boolean {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      return info.width > info.height;
    } catch (e) {
      return false;
    }
  }

  /** 从系统窗口读取一次窗口尺寸（px → vp）：Index 还没写过 AppStorage 时的兜底 */
  private async initViewportFromHostWindow(): Promise<void> {
    const hostWindow: window.Window | null = await this.fetchHostWindow();
    if (this.disposed || hostWindow === null) {
      return;
    }
    // 期间 onAreaChange 可能已经给出更精确的布局尺寸：不要用窗口尺寸覆盖它
    if (this.viewportWidth > 0 && this.viewportHeight > 0) {
      return;
    }
    try {
      const properties: window.WindowProperties = hostWindow.getWindowProperties();
      const width: number = px2vp(properties.windowRect.width);
      const height: number = px2vp(properties.windowRect.height);
      if (!(width > 0) || !(height > 0)) {
        return;
      }
      this.viewportWidth = width;
      this.viewportHeight = height;
    } catch (e) {
      // 窗口属性暂不可用：保持 onAreaChange 作为唯一来源，不影响页面其它逻辑
    }
  }

  /** 根容器尺寸变化：更新窗口宽高（用于播放器比例/居中和 Tab 内容布局） */
  updateLayout(area: Area): void {
    // Area 的 width/height 类型标注是 Length，运行时通常是 vp 数值；兼容字符串形态做一次兜底
    let width: number = Number(area.width);
    let height: number = Number(area.height);
    if (isNaN(width)) {
      width = parseFloat(area.width.toString());
    }
    if (isNaN(height)) {
      height = parseFloat(area.height.toString());
    }
    if (!(width > 0) || !(height > 0)) {
      return;
    }
    if (Math.abs(width - this.viewportWidth) < 0.5 && Math.abs(height - this.viewportHeight) < 0.5) {
      return;
    }
    this.viewportWidth = width;
    this.viewportHeight = height;
    // 把本页实测到的窗口尺寸回写给 AppStorage：保证 Index / 转场 / 其它页面读到的是最新方向
    // （旋转瞬间 AppStorage 可能还是旧值，用本页真实布局尺寸校正，避免 landscapeLayout 误判）。
    AppStorage.setOrCreate<number>('windowWidth', width);
    AppStorage.setOrCreate<number>('windowHeight', height);
    AppStorage.setOrCreate<boolean>('windowIsLandscape', width > height);
  }

  /** 播放器回调：解码画幅变化时更新容器比例（竖屏视频按实际比例展示） */
  updateVideoRatio(width: number, height: number): void {
    if (width <= 0 || height <= 0) {
      return;
    }
    const ratio: number = width / height;
    if (this.videoRatio > 0 && Math.abs(ratio - this.videoRatio) < 0.001) {
      return;
    }
    this.videoRatio = ratio;
  }

  contentWidth(): number {
    return this.viewportWidth > 0 ? this.viewportWidth : FALLBACK_VIEWPORT_WIDTH;
  }

  // ---------------------------------------------------------------------------
  // 横屏分栏布局：窗口宽 > 高且非全屏时，左侧播放器 + 右侧「简介/评论/相关推荐」
  // ---------------------------------------------------------------------------

  /**
   * 是否使用横屏左右分栏布局（只看窗口宽高；全屏始终铺满窗口、不分栏）。
   * 页面自身 viewport 还没测量出来时（转场首帧 / 极端时序），用 Index 维护的窗口比例兜底判断：
   * 这样横屏 push 进入本页时首帧就按横屏布局渲染，不会先竖屏再切横屏。
   */
  landscapeLayout(): boolean {
    if (this.fs) {
      return false;
    }
    if (this.viewportWidth > 0 && this.viewportHeight > 0) {
      // viewport 可能来自转场首帧的旧方向（如旋转后 Index 还没来得及回写）：以窗口比例为准，
      // 若两者不一致（典型：viewport 仍是竖屏尺寸、而 Index 已标记横屏），以 Index 的为准，
      // 保证「横屏点卡片进入」首帧就是横屏分栏。
      const viewportLandscape: boolean = this.viewportWidth > this.viewportHeight;
      const stored: boolean | undefined = AppStorage.get<boolean>('windowIsLandscape');
      if (stored !== undefined && stored !== viewportLandscape) {
        return stored;
      }
      return viewportLandscape;
    }
    const stored: boolean | undefined = AppStorage.get<boolean>('windowIsLandscape');
    if (stored !== undefined) {
      return stored;
    }
    return this.displayIsLandscape();
  }

  /** 当前分栏比例（夹取到 45%~80%；异常值回退默认 62%） */
  clampedSplitRatio(): number {
    const ratio: number = this.splitRatio;
    if (!Number.isFinite(ratio)) {
      return SPLIT_DEFAULT_RATIO;
    }
    if (ratio < SPLIT_MIN_RATIO) {
      return SPLIT_MIN_RATIO;
    }
    if (ratio > SPLIT_MAX_RATIO) {
      return SPLIT_MAX_RATIO;
    }
    return ratio;
  }

  /** 左侧播放器分栏宽度（vp）：窗口宽 × 分栏比例 */
  splitLeftWidth(): number {
    if (!(this.viewportWidth > 0)) {
      return 0;
    }
    return this.viewportWidth * this.clampedSplitRatio();
  }

  /**
   * 横屏左侧播放器区域高度（vp）：状态栏下方 → 底部导航条上方（安全边距）。
   * 播放器容器纯黑铺满这块区域，InlinePlayer 内部再按视频真实画幅居中 letterbox，
   * 因此竖屏视频在横屏下自动左右留黑边，横屏视频铺满，画面不会被拉伸。
   */
  landscapePlayerHeight(): number {
    const height: number = this.viewportHeight - this.statusBarHeight - this.navBarHeight;
    if (height > MIN_PLAYER_HEIGHT) {
      return height;
    }
    const fallback: number = this.viewportHeight - this.statusBarHeight;
    return fallback > 0 ? fallback : this.viewportHeight;
  }

  /** 分栏分隔条按住：记录起始比例并高亮（不改播放器 / 内容状态） */
  startDividerDrag(): void {
    if (this.disposed || !this.landscapeLayout()) {
      return;
    }
    this.dividerDragStartRatio = this.clampedSplitRatio();
    this.dividerDragging = true;
  }

  /** 分隔条横向拖拽：比例 = 起始比例 + 位移 / 窗口宽度，夹取 45%~80% */
  updateDividerDrag(offsetX: number): void {
    if (this.disposed || !this.dividerDragging || !(this.viewportWidth > 0)) {
      return;
    }
    const next: number = this.dividerDragStartRatio + offsetX / this.viewportWidth;
    if (next < SPLIT_MIN_RATIO) {
      this.splitRatio = SPLIT_MIN_RATIO;
    } else if (next > SPLIT_MAX_RATIO) {
      this.splitRatio = SPLIT_MAX_RATIO;
    } else {
      this.splitRatio = next;
    }
  }

  /** 分隔条松手 / 手势取消：结束高亮，比例归一到合法区间（拖拽过程中已实时写入 splitRatio） */
  finishDividerDrag(): void {
    this.dividerDragging = false;
    this.splitRatio = this.clampedSplitRatio();
  }

  effectiveRatio(): number {
    return this.videoRatio > 0 ? this.videoRatio : DEFAULT_VIDEO_RATIO;
  }

  /**
   * 播放器容器高度：宽度 / 画幅；窗口偏矮或竖屏视频时 clamp 到屏高 56%。
   * 父容器决定高度（InlinePlayer 铺满），因此用显式 height 而不是 aspectRatio。
   */
  playerHeight(): number {
    const ratio: number = this.effectiveRatio();
    const width: number = this.contentWidth();
    const viewportHeight: number = this.viewportHeight > 0 ? this.viewportHeight : 640;
    const maxHeight: number = viewportHeight * MAX_PLAYER_HEIGHT_RATIO;
    let height: number = width / ratio;
    if (height > maxHeight) {
      height = maxHeight;
    }
    const minHeight: number = Math.min(MIN_PLAYER_HEIGHT, maxHeight);
    if (height < minHeight) {
      height = minHeight;
    }
    return height;
  }

  /**
   * 播放器容器宽度：**竖屏 / 窄画面也铺满内容宽度**。
   *
   * 旧行为是按画幅把容器收窄并居中（width = height × ratio），结果播放器左右两侧露出的是
   * 页面底色（浅色主题下就是一块白），也就是用户反馈的「视频外面左右两侧的白色区域」。
   * 现在容器始终通栏、由 InlinePlayer 内部 contain 出左右黑边（黑色底层由 InlinePlayer 自绘），
   * 视觉上「视频 + 两侧黑边」是一整块黑色播放器区域。
   * 超宽画面（比屏更宽）仍然 clamp 到内容宽度。
   */
  playerWidth(): number {
    return this.contentWidth();
  }

  /**
   * 播放器当前布局高度（vp）：全屏铺满窗口；横屏分栏铺满分栏高度（状态栏下 → 导航条上）；
   * 竖屏展开态按视频画幅；折叠态为 0（**直接隐藏**）；把手拖动过程中按 handleDragDy 实时插值。
   * playerLayer 的 height/width 与 contentLayer 的 padding 都只读这一套函数，保证两者同步。
   */
  playerAreaHeight(): number {
    if (this.fs) {
      return this.viewportHeight > 0 ? this.viewportHeight : this.playerHeight();
    }
    if (this.landscapeLayout()) {
      // 横屏分栏：左侧播放器占满分栏高度，折叠 / 拖拽几何不参与（横屏下不显示折叠把手）
      return this.landscapePlayerHeight();
    }
    const expanded: number = this.playerHeight();
    const collapsed: number = Math.min(COLLAPSED_PLAYER_HEIGHT, expanded);
    const base: number = this.playerCollapsed ? collapsed : expanded;
    if (!this.handleDragging) {
      return base;
    }
    const raw: number = base + this.handleDragDy;
    if (this.playerCollapsed) {
      // 折叠态：往下拖展开（上限 = 展开高度），往上拖不再变化
      return Math.min(expanded, Math.max(collapsed, raw));
    }
    if (raw <= base) {
      // 展开态：往上拖折叠（下限 = 0，即完全隐藏播放器）
      return Math.max(collapsed, raw);
    }
    // 展开态：往下拖只给一点阻尼反馈（松手过阈值才进全屏）
    return base + Math.min(PLAYER_PULL_FEEDBACK, (raw - base) * 0.4);
  }

  /**
   * 播放器是否可见：全屏 / 横屏分栏恒可见（横屏不提供折叠入口，折叠态只是竖屏的临时状态）；
   * 竖屏折叠态仅在拖动 / 吸附动画期间保持可见（动画结束后 Visibility.None）。
   */
  playerLayerVisible(): boolean {
    return this.fs || this.landscapeLayout() || !this.playerCollapsed ||
      this.handleDragging || this.playerSettling;
  }

  /**
   * 播放器当前布局宽度：全屏 = 窗口宽；横屏分栏 = 左侧分栏宽度；竖屏展开态按视频比例
   * （竖屏视频收窄居中），折叠 / 拖动过程按「当前高度 / 展开高度」等比收缩。
   */
  playerAreaWidth(): number {
    const fullWidth: number = this.contentWidth();
    if (this.fs) {
      return fullWidth;
    }
    if (this.landscapeLayout()) {
      return this.splitLeftWidth();
    }
    const expandedHeight: number = this.playerHeight();
    if (!(expandedHeight > 0)) {
      return fullWidth;
    }
    // 往下拖的阻尼反馈会让高度略超展开高度：宽度按展开态封顶，不做「越拉越宽」
    const currentHeight: number = Math.min(expandedHeight, Math.max(0, this.playerAreaHeight()));
    const width: number = this.playerWidth() * (currentHeight / expandedHeight);
    return Math.min(fullWidth, Math.max(0, width));
  }

  /**
   * 播放器水平偏移：竖屏非全屏时按当前布局宽度居中（窗口尺寸未就绪前先靠左，避免首帧负偏移）；
   * 横屏分栏时贴左（x = 0）。
   */
  playerAreaOffsetX(): number {
    if (this.fs || !(this.viewportWidth > 0)) {
      return 0;
    }
    if (this.landscapeLayout()) {
      return 0;
    }
    return (this.viewportWidth - this.playerAreaWidth()) / 2;
  }

  /**
   * 评论数文案：显示在底部悬浮评论输入框内部左侧的小标签（「评论 N」；无数据时只显示「评论」）。
   * 登录态输入条与未登录「登录后参与评论」胶囊共用。
   */
  commentTitle(): string {
    if (this.commentCount > 0) {
      return '评论 ' + this.commentCount;
    }
    return '评论';
  }

  // ---------------------------------------------------------------------------
  // 页内横屏全屏：窗口方向 + 系统栏（播放器 UI 由 InlinePlayer 控制层负责）
  // ---------------------------------------------------------------------------

  /**
   * 取主窗口：优先用 aboutToAppear 时缓存好的实例（aboutToDisappear / 退出全屏阶段
   * this.getUIContext() 可能已经不可用，现场取窗口会失败 → 系统栏恢复被跳过）。
   * 首次调用（页面还在前台）走 getUIContext().getHostContext() 取一次并缓存。
   */
  async fetchHostWindow(): Promise<window.Window | null> {
    const cached: window.Window | null = this.cachedHostWindow;
    if (cached !== null) {
      return cached;
    }
    try {
      const context: common.Context | undefined = this.getUIContext().getHostContext();
      if (context === undefined) {
        return null;
      }
      const hostWindow: window.Window = await window.getLastWindow(context);
      this.cachedHostWindow = hostWindow;
      return hostWindow;
    } catch (e) {
      // 页面销毁 / 预览器等场景取不到 context：返回 null，由调用方按「无窗口」兜底
      return null;
    }
  }

  /** 预取主窗口并缓存（失败静默）：只为了让退出全屏 / 页面销毁时一定能恢复系统栏 */
  private prefetchHostWindow(): void {
    this.fetchHostWindow().then(() => {
      // 成功时 fetchHostWindow 内部已缓存；失败不影响页面（后续全屏 / 恢复时会再尝试一次）
    }).catch(() => {
      // 忽略
    });
  }

  /**
   * 非页内全屏时确保系统状态栏 / 导航条可见：
   * 只改系统栏可见性与图标颜色，不动播放器 / 方向 / 页面布局。
   * 页面重新可见（onVisibleAreaChange）时兜底调用，避免全屏链路异常后状态栏永久消失。
   */
  private ensureSystemBarsVisible(): void {
    if (this.fs || AppStorage.get<boolean>('videoFullscreen') === true) {
      return;
    }
    this.setSystemBarsVisible(true);
  }

  /**
   * 只切换系统栏可见性（不动方向 / 播放 / 页面布局）：
   *  - true：恢复状态栏 / 导航条（退出全屏、全屏页被二级页覆盖、页面重新可见时）；
   *  - false：隐藏系统栏（回到仍处于页内全屏的本页，恢复沉浸）。
   * 用缓存的窗口执行，页面销毁 / 转场期间也不会因为拿不到 UIContext 而跳过。
   */
  private setSystemBarsVisible(show: boolean): void {
    this.fetchHostWindow().then((hostWindow: window.Window | null) => {
      if (hostWindow === null) {
        return;
      }
      try {
        if (show) {
          hostWindow.setWindowSystemBarEnable(['status', 'navigation']).catch((err: BusinessError) => {
            // 系统栏恢复失败不影响页面（Index / EntryAbility 在方向变化时还会兜底）
          });
        } else {
          hostWindow.setWindowSystemBarEnable([]).catch((err: BusinessError) => {
            // 隐藏系统栏失败不影响全屏播放
          });
        }
      } catch (e) {
        // 低版本 / 预览器不支持时忽略
      }
    }).catch(() => {
      // 忽略
    });
  }

  /**
   * 设置状态栏图标颜色（只改 content 颜色，系统栏背景仍透出页面顶部的纯黑底）。
   * 视频页：进入时白色（播放器上方是黑底）；离开 / 被二级页覆盖时恢复主题默认色。
   * window 接口在部分设备 / 预览器不可用：fetchHostWindow 内部已 catch，
   * 这里再包 try/catch + Promise.catch，保证不影响页面其它逻辑。
   */
  applyStatusBarContentColor(color: string): void {
    this.fetchHostWindow().then((hostWindow: window.Window | null) => {
      if (hostWindow === null) {
        return;
      }
      try {
        hostWindow.setWindowSystemBarProperties({ statusBarContentColor: color })
          .catch((err: BusinessError) => {
            // 系统栏属性设置失败不影响页面（状态栏保持原色）
          });
      } catch (e) {
        // 低版本 / 预览器不支持时忽略
      }
    }).catch((err: Error) => {
      // 拿窗口失败时忽略
    });
  }

  /**
   * 页面可见性变化：被网页等二级页完全覆盖时把状态栏图标恢复成主题默认色，
   * 回到本页再切回白色（aboutToAppear 只在本页首次挂载时调用，覆盖 / 返回不会重新触发）。
   * 同一栈里还压着别的视频页（videoPageCount > 1）时不恢复，避免把上层视频页的白色改回默认。
   */
  onPageVisibilityChanged(isVisible: boolean, currentRatio: number): void {
    if (this.disposed) {
      return;
    }
    const visible: boolean = isVisible && currentRatio > 0.01;
    if (visible === this.pageVisible) {
      return;
    }
    this.pageVisible = visible;
    if (visible) {
      this.applyStatusBarContentColor('#FFFFFF');
      if (this.fs) {
        // 回到仍处于页内全屏的本页：重新隐藏系统栏，恢复全屏沉浸（覆盖期间曾为二级页放开系统栏）
        this.setSystemBarsVisible(false);
      } else {
        // 回到本页且不是页内全屏时兜底恢复系统栏：防止上一次全屏 / 二级页覆盖期间系统栏被隐藏后
        // 再也没有恢复（横屏下「状态栏消失」的兜底）。
        this.ensureSystemBarsVisible();
      }
      return;
    }
    if (this.fs) {
      // 全屏播放页被其它页面（网页等）覆盖：二级页需要正常的状态栏 / 导航条，先还回来；
      // 返回本页时上面的 visible 分支会重新隐藏，全屏状态不丢。
      this.setSystemBarsVisible(true);
    }
    const pageCount: number = AppStorage.get<number>('videoPageCount') ?? 0;
    if (pageCount <= 1) {
      this.applyStatusBarContentColor(Theme.isDark() ? '#FFFFFF' : '#000000');
    }
    // 折叠隐藏播放器期间，InlinePlayer 的「可见比例 0 → 自动暂停」被 keepPlayingWhenHidden 抑制
    // （折叠的暂停由 pauseForPlayerCollapse 显式完成）；此时若页面被登录 / 网页等二级页完全覆盖
    // 或退到后台，由页面自己兜底暂停 + 落盘进度，保持「离开本页不停在后台出声」的原有行为。
    // 同时撤销「展开自动恢复播放」的意图：从二级页 / 后台返回后展开不应突然出声。
    if (this.playerCollapsed) {
      this.wasPlayingBeforeCollapse = false;
      this.playerHandle.pauseAndSave();
    }
  }

  /**
   * 退出全屏时恢复「用户设置的方向锁」+ 系统栏（系统栏恢复优先，方向恢复单独兜底）。
   *
   * 顺序很关键：先 setWindowSystemBarEnable(['status','navigation']) 让状态栏 / 导航条回来，
   * 再做方向恢复。旧实现先恢复方向再恢复系统栏，且任一 await 失败（或拿不到窗口）就直接跳过，
   * 于是横屏下会出现「状态栏一直不显示」。
   *
   * 注意：不再无条件恢复 PORTRAIT —— 用户可能把设置锁成横屏（screenOrientationLock='landscape'），
   * 退出全屏后应回到横屏分栏布局；跟随系统则回到 AUTO_ROTATION。
   */
  async restoreWindowBars(): Promise<void> {
    const hostWindow: window.Window | null = await this.fetchHostWindow();
    if (hostWindow === null) {
      return;
    }
    // 1) 系统栏必须先恢复：即使下面方向恢复失败，状态栏 / 导航条也不能丢
    try {
      await hostWindow.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (e) {
      // 系统栏恢复失败不影响页面（Index / EntryAbility 在方向变化时还会再兜底一次）
    }
    // 2) 再恢复用户设置的方向锁（跟随系统 = AUTO_ROTATION；锁定竖屏 / 横屏 = 硬锁）
    await applyScreenOrientationLock(hostWindow, AppSettings.getInstance().getScreenOrientationLock());
  }

  async enterFullscreen(): Promise<void> {
    if (this.fs) {
      return;
    }
    // 先打开播放器的「方向切换保护窗口」：随后 setPreferredOrientation + setWindowSystemBarEnable
    // 触发的窗口旋转 / 系统栏切换期间，播放区可见比例会短暂回调为 0、窗口事件也可能短暂失焦，
    // 这些瞬态不能再被当成「切后台」去暂停（保护窗口约 1s，由 InlinePlayer 内部定时复位）。
    this.playerHandle.beginOrientationChange();
    // 与 Index 约定：全屏期间置位 videoFullscreen，Index 的 NavDestination.onBackPressed
    // 会据此消费系统返回、改为自增 exitVideoFullscreen tick（而不是直接 pop 详情页）
    AppStorage.setOrCreate<boolean>('videoFullscreen', true);
    // 播放器容器宽高 / 位置用 animateTo 做 240ms 过渡（方向切换由窗口异步完成）
    animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.fs = true;
    });
    const hostWindow: window.Window | null = await this.fetchHostWindow();
    if (hostWindow === null) {
      // 拿不到窗口时保持页内全屏布局（播放器铺满窗口）
      return;
    }
    try {
      // 对齐原版：竖屏 / 方形视频全屏时保持竖屏（空间利用率更高），横屏视频才切横屏
      const portraitVideo: boolean = this.effectiveRatio() <= 1;
      await hostWindow.setPreferredOrientation(
        portraitVideo ? window.Orientation.PORTRAIT : window.Orientation.LANDSCAPE);
    } catch (e) {
      // 部分设备/窗口模式不支持强制方向时保持页内全屏
    }
    try {
      await hostWindow.setWindowSystemBarEnable([]);
    } catch (e) {
      // 隐藏系统栏失败不影响全屏播放
    }
  }

  async exitFullscreen(): Promise<void> {
    // 先打开播放器的「方向切换保护窗口」，再改 fs / 恢复方向：整个旋转 + 系统栏恢复期间
    // 不允许播放区可见比例瞬态 0 / 短暂失焦把视频暂停。这里**只改窗口与布局状态**，
    // 不调用 pauseAndSave、不重启播放器、不重新 loadSource、不 seek，原 playing 状态继续播放。
    this.playerHandle.beginOrientationChange();
    // 先清跨页全屏标记：此后按返回键应正常 pop 详情页
    AppStorage.setOrCreate<boolean>('videoFullscreen', false);
    if (this.fs) {
      animateTo({ duration: 240, curve: Curve.Friction }, () => {
        this.fs = false;
      });
    }
    await this.restoreWindowBars();
  }

  toggleFullscreen(): void {
    if (this.fs) {
      this.exitFullscreen();
    } else {
      this.enterFullscreen();
    }
  }

  // ---------------------------------------------------------------------------
  // 拖拽把手：展开（默认）/ 折叠隐藏 / 全屏 三态
  // 播放器实例不重建：折叠只改 playerLayer 的宽高 + contentLayer 的 padding-top，
  // 松手后用 animateTo(240ms, Curve.Friction) 吸附到目标态（与全屏切换同一节奏）。
  // 播放联动：折叠 = 播放中则暂停 + 落盘；展开 = 折叠前在播放则从原进度继续。
  // ---------------------------------------------------------------------------

  /**
   * 把手吸附到展开 / 折叠态（240ms Curve.Friction，与全屏过渡一致）。
   *
   * 折叠 = 播放器高度 / 宽度动画到 0（contentLayer padding-top 同步回到 statusBarHeight）；
   * 动画期间 playerSettling 保持 playerLayer 可见，动画结束后才 Visibility.None，
   * 所以过程中能看到「视频收缩到 0」而不是瞬间消失。播放器组件始终在树里，AVPlayer 不重建。
   * 状态真正切换时顺带处理播放联动（折叠暂停 / 展开恢复），回弹不触发。
   */
  snapPlayerCollapsed(collapsed: boolean): void {
    if (this.playerHideTimer !== -1) {
      clearTimeout(this.playerHideTimer);
      this.playerHideTimer = -1;
    }
    // 折叠 / 展开的播放联动（先于动画执行，读的是切换前的实时状态）：
    //  - 折叠：正在播放则静默暂停 + 落盘，并记录「折叠前在播放」；
    //  - 展开：折叠前在播放则从原进度继续，折叠前已暂停 / 结束的保持暂停。
    // 只在状态真正切换时处理，未过阈值的回弹（snap 到当前状态）不会误触发。
    if (collapsed !== this.playerCollapsed) {
      if (collapsed) {
        // 折叠后播放器画面隐藏，底部的常显进度条改由本页在把手区域补画：先取进度快照
        this.captureCollapsedProgress();
        this.pauseForPlayerCollapse();
      } else {
        this.resumeAfterPlayerExpand();
      }
    }
    animateTo({ duration: PLAYER_SNAP_ANIM_MS, curve: Curve.Friction }, () => {
      this.handleDragging = false;
      this.handleDragDy = 0;
      this.playerCollapsed = collapsed;
      this.playerSettling = true;
    });
    // 展开时同样安排一次复位（对可见性无影响），保证 playerSettling 不会一直停在 true
    this.playerHideTimer = setTimeout(() => {
      this.playerHideTimer = -1;
      if (this.disposed) {
        return;
      }
      this.playerSettling = false;
    }, PLAYER_HIDE_SETTLE_MS);
  }

  /**
   * 折叠播放器时记录一次进度快照（0~1）。
   *
   * 折叠后 playerLayer 高度为 0 并最终 Visibility.None，InlinePlayer 内部的常显进度条随画面一起隐藏；
   * 为了「折叠也始终显示进度」，本页在把手热区顶部补画一条，需要播放器内部的 position / duration。
   */
  private captureCollapsedProgress(): void {
    const duration: number = this.playerHandle.currentDurationMs();
    const position: number = this.playerHandle.currentPositionMs();
    if (!(duration > 0)) {
      // 时长未知（网页播放 / 还没加载出媒体）：没有可画的进度，保持 -1 不画（而不是画一条空轨道）
      this.collapsedProgressRatio = -1;
      return;
    }
    const ratio: number = position / duration;
    this.collapsedProgressRatio = Number.isFinite(ratio) ? Math.min(1, Math.max(0, ratio)) : 0;
  }

  /** 折叠态常显进度条的宽度百分比（0~1 → '0%'~'100%'） */
  collapsedProgressWidth(): string {
    const ratio: number = this.collapsedProgressRatio;
    if (!(ratio > 0)) {
      return '0%';
    }
    return (Math.min(1, ratio) * 100) + '%';
  }

  /**
   * 折叠态播放器底部的常显细进度条（播放器高度为 0 后由本页补画）：
   * 画在把手热区最顶部 = 折叠后播放器的下边缘；不拦截触摸（把手手势 / 点击照常）。
   */
  @Builder
  collapsedProgressBar() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(COLLAPSED_PROGRESS_HEIGHT)
        .borderRadius(2)
        .backgroundColor(COLLAPSED_PROGRESS_TRACK);
      Row()
        .width(this.collapsedProgressWidth())
        .height(COLLAPSED_PROGRESS_HEIGHT)
        .borderRadius(2)
        .backgroundColor(Theme.colors().primary);
    }
    .width('100%')
    .height(COLLAPSED_PROGRESS_HEIGHT)
    .hitTestBehavior(HitTestMode.None);
  }

  /**
   * 折叠隐藏播放器：如果正在播放 → 静默暂停并落盘进度（不弹 Toast、不主动改变控制层等 UI 状态），
   * 并记下「折叠前在播放」，供展开时自动恢复。本来就是暂停 / 结束的保持原状态。
   *
   * 走播放器的折叠专用暂停（内部即 pauseAndSave 落盘 + 暂停）显式路径：与全屏 / 方向的保护窗口
   * 互不干扰（保护窗口只抑制 windowEvent 与可见区域的自动暂停，不会拦截用户主动折叠触发的暂停）。
   */
  pauseForPlayerCollapse(): void {
    const playing: boolean = this.playerHandle.isPlayingNow();
    this.wasPlayingBeforeCollapse = playing;
    if (!playing) {
      return;
    }
    // 走播放器的「折叠专用暂停」：同样落盘 + 暂停，但不主动唤出控制层，
    // 避免控制条在播放器收缩动画里闪一下（用户此刻并没有操作播放器）
    this.playerHandle.pauseForCollapse();
    // 乐观同步动作区状态；AVPlayer 的 paused 回调还会再同步一次（幂等）
    this.videoPlaying = false;
  }

  /**
   * 展开播放器：折叠前在播放则从原进度继续播放（复用播放器现有 play() 路径，
   * AVPlayer / surface 不重建、进度不丢）；折叠前已暂停 / 结束则保持暂停。
   * 展开是用户主动操作，不受全屏 / 方向保护窗口抑制。
   */
  resumeAfterPlayerExpand(): void {
    const shouldResume: boolean = this.wasPlayingBeforeCollapse;
    this.wasPlayingBeforeCollapse = false;
    if (shouldResume) {
      this.playerHandle.resumeAfterCollapse();
      this.videoPlaying = true;
    }
  }

  /** 轻点把手：展开 / 折叠隐藏切换（全屏时把手隐藏，不会走到这里） */
  togglePlayerCollapsed(): void {
    if (this.disposed || this.fs) {
      return;
    }
    this.snapPlayerCollapsed(!this.playerCollapsed);
  }

  /** 按住把手开始拖拽：记录起点，后续按竖直位移实时改播放器几何 */
  startHandleDrag(): void {
    if (this.disposed || this.fs) {
      return;
    }
    // 从折叠态（playerLayer 已 Visibility.None）开始下滑时，本次拖拽要让播放器重新可见：
    // handleDragging 本身就是 playerLayerVisible 的可见条件，这里同时清掉待执行的隐藏定时器。
    if (this.playerHideTimer !== -1) {
      clearTimeout(this.playerHideTimer);
      this.playerHideTimer = -1;
    }
    this.playerSettling = false;
    this.handleDragging = true;
    this.handleDragDy = 0;
  }

  /** 拖拽中：竖直位移（vp，向上为负）驱动 playerAreaHeight / contentLayer padding 实时变化 */
  updateHandleDrag(offsetY: number): void {
    if (this.disposed || !this.handleDragging || this.fs) {
      return;
    }
    this.handleDragDy = offsetY;
  }

  /**
   * 松手吸附：上滑 → 折叠隐藏播放器；折叠态下滑 → 展开；展开态下滑 → 全屏；未过阈值回弹。
   * 三态切换规则（折叠隐藏 / 展开 / 全屏）沿用原逻辑，只把「折叠」的目标高度从 148 改成 0。
   */
  finishHandleDrag(): void {
    if (this.disposed || !this.handleDragging) {
      return;
    }
    const dy: number = this.handleDragDy;
    if (dy <= -HANDLE_DRAG_THRESHOLD) {
      this.snapPlayerCollapsed(true);
      return;
    }
    if (dy >= HANDLE_DRAG_THRESHOLD) {
      if (this.playerCollapsed) {
        this.snapPlayerCollapsed(false);
        return;
      }
      // 展开态下滑 → 页内全屏（复用现有 enterFullscreen：横屏 / 系统栏隐藏逻辑不变）；
      // 先把拖动几何归位，再走全屏自身的 240ms 过渡。
      this.handleDragging = false;
      this.handleDragDy = 0;
      this.enterFullscreen();
      return;
    }
    // 未过阈值：回弹到当前状态
    this.snapPlayerCollapsed(this.playerCollapsed);
  }

  /** 手势取消（来电 / 多指等）：回弹到当前状态 */
  cancelHandleDrag(): void {
    if (this.disposed || !this.handleDragging) {
      return;
    }
    this.snapPlayerCollapsed(this.playerCollapsed);
  }

  // ---------------------------------------------------------------------------
  // 跳转（离开当前页面前先暂停内嵌播放器并落盘进度，避免两层页面同时出声）
  // ---------------------------------------------------------------------------

  openOtherVideo(code: string): void {
    if (code.length === 0 || code === this.video.videoCode) {
      return;
    }
    this.playerHandle.pauseAndSave();
    Router.openVideo(code);
  }

  /**
   * 播放器左上角「回首页」圆钮（返回钮右侧独立圆钮）：直接回首页
   * （接入 InlinePlayer 的 onReturnHome 回调）。
   *
   * 流程：
   *  1. 先暂停内嵌播放器并落盘进度，避免清栈后旧的 AVPlayer 实例还在后台出声；
   *  2. 全屏态下恢复方向锁 + 系统栏（与退出全屏同一条恢复路径），并清掉跨页全屏标记，
   *     否则 Index 的返回拦截会误以为仍在全屏；
   *  3. Router.popToRoot() 清空导航栈回到根页（首页），再写 AppStorage['requestTab'] = 0
   *     让 Index 把底部 Tab 切到首页；
   *  4. Toast 轻量反馈。
   *
   * 与返回钮单击（全屏退出 / Router.pop）、系统左滑返回互不影响：回首页是返回钮右侧的独立圆钮。
   */
  returnHomeFromPlayer(): void {
    if (this.disposed) {
      return;
    }
    this.playerHandle.pauseAndSave();
    const wasFullscreen: boolean = this.fs;
    if (wasFullscreen) {
      this.fs = false;
      this.restoreWindowBars();
    }
    // 先清跨页全屏标记：此后系统返回 / 页面销毁都按非全屏处理
    AppStorage.setOrCreate<boolean>('videoFullscreen', false);
    Router.popToRoot();
    // 与 Index 约定：0 = 首页 Tab（Index.onRequestTab 切 Tab 后复位为 -1）
    AppStorage.setOrCreate<number>('requestTab', 0);
    Toast.show('已返回首页');
  }

  openSitePage(): void {
    const code: string = this.videoCode();
    if (code.length === 0) {
      return;
    }
    this.playerHandle.pauseAndSave();
    const baseUrl: string = AppSettings.getInstance().getBaseUrl();
    Router.openWeb(buildWatchUrl(baseUrl, code), '视频页面');
  }

  openTag(tag: string): void {
    if (tag.length === 0) {
      return;
    }
    this.playerHandle.pauseAndSave();
    Router.openSearchResult(tag);
  }

  /**
   * 分享入口：弹原生 ActionSheet 选择「复制分享文本 / 复制视频链接」。
   *  - 复制分享文本：对齐上游 `getHanimeShareText`（标题 + 链接 + 来源署名，见 core/util/ShareText.ts）；
   *  - 复制视频链接：保留旧的纯链接复制行为。
   * 本移植版没有接入系统分享面板，因此两项都是复制到剪贴板（@kit.BasicServicesKit pasteboard）。
   */
  openShareMenu(): void {
    ActionSheet.show({
      title: '分享',
      message: '复制后粘贴到你想分享的地方',
      autoCancel: true,
      cancel: () => {
      },
      sheets: [
        {
          title: '复制分享文本',
          action: () => {
            this.copyShareText();
          }
        },
        {
          title: '复制视频链接',
          action: () => {
            this.copyWatchLink();
          }
        }
      ]
    });
  }

  /** 写系统剪贴板（pasteboard）并 Toast 结果 */
  copyToClipboard(text: string, successMessage: string): void {
    try {
      const data: pasteboard.PasteData =
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      pasteboard.getSystemPasteboard().setData(data).then(() => {
        Toast.show(successMessage);
      }).catch((err: BusinessError) => {
        Toast.show('复制失败：' + err.message);
      });
    } catch (e) {
      Toast.show('复制失败');
    }
  }

  /** 复制视频链接（原分享按钮行为） */
  copyWatchLink(): void {
    const code: string = this.videoCode();
    if (code.length === 0) {
      Toast.show('暂无视频链接');
      return;
    }
    const url: string = buildWatchUrl(AppSettings.getInstance().getBaseUrl(), code);
    this.copyToClipboard(url, '视频链接已复制');
  }

  /**
   * 复制分享文本（对齐上游 `getHanimeShareText`）：
   *   标题
   *   https://<当前域名>/watch?v=<code>
   *   - From Han1meViewer -
   * 标题缺失时退回中文标题，仍为空则提示不可分享。
   */
  copyShareText(): void {
    const code: string = this.videoCode();
    const title: string = this.video.title.length > 0 ? this.video.title : this.video.chineseTitle;
    if (code.length === 0 || title.length === 0) {
      Toast.show('暂无分享内容');
      return;
    }
    const text: string = buildVideoShareText(title, code, AppSettings.getInstance().getBaseUrl());
    this.copyToClipboard(text, '分享文本已复制');
  }

  /**
   * 打开评论排序弹窗（对齐上游 CommentSortType）：默认站点顺序，其余 5 项为上游客户端排序类型。
   *
   * 呈现改为**自定义沉浸材质弹窗**（不再用样式不受控的系统 ActionSheet）：
   *  - 打开前先收起评论输入框焦点（键盘随之落下），弹窗居中显示时不会被输入法压住；
   *  - 弹窗节点由 `commentSortMenuOpen` 条件渲染，开合动画由 `commentSortOverlay()` 的 transition 承担；
   *  - 选择后只更新 commentSort，由 CommentSection 客户端重排已加载评论（不重新请求）；
   *  - 排序是纯客户端行为，未登录也可用。
   */
  openCommentSortMenu(): void {
    if (this.commentSortMenuOpen) {
      return;
    }
    this.dismissComposerFocus();
    this.commentSortMenuOpen = true;
  }

  /** 关闭排序弹窗（点遮罩 / 点关闭圆钮 / 选中选项都会走这里；淡出动画由 transition 负责） */
  closeCommentSortMenu(): void {
    if (!this.commentSortMenuOpen) {
      return;
    }
    this.commentSortMenuOpen = false;
  }

  /** 弹窗里选中一项：应用排序（本地重排 + 写 commentSortType）并关闭弹窗 */
  chooseCommentSort(type: string): void {
    this.applyCommentSort(type);
    this.closeCommentSortMenu();
  }

  /**
   * 收起当前焦点（评论输入框若在输入，直接失焦 → 键盘落下）。
   * 只影响「弹窗打开前」的输入态：失焦回调会把键盘避让模式恢复成系统 OFFSET（见 onComposerFocusChange），
   * 输入框里的文字、回复目标等状态都不受影响。
   * 焦点控制器不可用（预览器 / 低版本）时保持原状，遮罩仍会拦截点击。
   */
  private dismissComposerFocus(): void {
    try {
      this.getUIContext().getFocusController().clearFocus();
    } catch (e) {
      // 预览器等环境没有焦点控制器：忽略，弹窗照常打开
    }
  }

  applyCommentSort(type: string): void {
    if (this.commentSort === type) {
      return;
    }
    this.commentSort = type;
  }

  // ---------------------------------------------------------------------------
  // 收藏 / 评分 / 稍后再看（站点账号同步 + 乐观更新 + 失败回滚）
  //
  // 与上一版的区别：登录态下四个动作**全部写站点**（而不是只写本地）：
  //  - 收藏 / 赞 / 踩：复用 HanimeApi.favVideo / rateVideo（POST /like），与上游
  //    NetworkRepo.addToMyFavVideo / rateVideo 的字段一致；
  //  - 稍后再看：复用 HanimeApi.addToMyList（POST /save，input_id = 'save'，
  //    对齐上游 WatchLaterSubViewModel.deleteMyWatchLater 使用的清单 code），
  //    成功后与站点 `user/{id}/saves` 列表同步，本地列表仅作为镜像保留。
  //
  // UI 采用「先乐观更新、失败回滚」：点击立即点亮按钮并播弹簧，接口失败时把
  // video / fav / watchLater 恢复到操作前快照并弹错误提示，避免按钮卡在错误状态。
  // 本地库写入放在站点成功之后单独 try/catch：本地写失败不影响已经成功的账号状态。
  // 未登录：收藏 / 赞 / 踩保持原「引导登录」行为；稍后再看维持原本地行为（离线可用）。
  // ---------------------------------------------------------------------------

  /** 写操作失败：登录过期时统一清理登录态，再按错误类型提示 */
  private showActionError(rawError: Error): void {
    if (rawError instanceof LoginExpiredError) {
      SessionActions.onSessionExpired();
    }
    Toast.show(describeError(rawError));
  }

  /** 站点写操作前置校验：已登录但页面还没拿到 csrf（例如刚登录 / 详情未刷新）时提示刷新 */
  private ensureCsrfReady(): boolean {
    if (this.video.csrfToken.length > 0) {
      return true;
    }
    Toast.show('登录状态未就绪，请下拉刷新后重试');
    return false;
  }

  /** 收藏：登录态写站点 POST /like，乐观更新 + 失败回滚，成功后再镜像本地收藏 */
  async toggleFavorite(): Promise<void> {
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    if (this.favBusy) {
      return;
    }
    if (!this.ensureCsrfReady()) {
      return;
    }
    const target: boolean = !this.fav;
    const prevVideo: HanimeVideo = this.video;
    const prevFav: boolean = this.fav;
    // 用户已手动操作：作废仍在途的初始态校正
    this.actionSeq = this.actionSeq + 1;
    this.favBusy = true;
    // 乐观更新：先点亮 / 熄灭按钮（失败在 catch 里回滚）
    this.fav = target;
    this.video = applyVideoFavorite(prevVideo, target);
    // 收藏按钮弹簧：选中时 1 → 1.18 → 1
    this.playScaleBounce('fav');
    let siteOk: boolean = false;
    try {
      // favVideo(cancel: !target)：target=true 表示收藏（cancel=false）
      await api.favVideo(prevVideo.videoCode, !target, prevVideo.currentUserId, prevVideo.csrfToken);
      siteOk = true;
    } catch (e) {
      if (!this.disposed) {
        this.video = prevVideo;
        this.fav = prevFav;
        this.showActionError(e as Error);
      }
    } finally {
      this.favBusy = false;
    }
    if (!siteOk || this.disposed) {
      return;
    }
    // 站点成功：本地收藏仅作镜像（本地写失败不回滚账号状态）
    try {
      await LocalRepo.getInstance().setFavorite(buildLocalRecord(this.video), target);
      notifyLibraryChanged();
    } catch (e) {
      // 本地库异常不阻断
    }
    if (!this.disposed) {
      Toast.show(target ? '已收藏' : '已取消收藏');
    }
  }

  /**
   * 关注 / 取消关注作者，对齐安卓 ArtistSection 的订阅按钮（VideoIntroductionScreen.kt:1247-1272）。
   *
   * 站点接口：POST `/subscribe`，表单 `subscribe-user-id` / `subscribe-artist-id` / `subscribe-status`
   * （未订阅发空串、已订阅发 '1'），与上游 HanimeSubscriptionService 逐字段一致。
   *
   * 数据来源：Artist.userId / Artist.artistId 由视频页 `#video-subscribe-form` 的两个 hidden input 解析而来
   * （HanimeParser.parseArtist）。安卓只有在拿到这个表单时才画订阅按钮 —— 这里同样：
   * userId 或 artistId 为空（未登录 / 站点改版）就直接隐藏按钮，而不是画一个点了没反应的。
   */
  async toggleArtistSubscribe(): Promise<void> {
    const artist: Artist | null = this.video.artist;
    if (artist === null) {
      return;
    }
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    if (this.subBusy) {
      return;
    }
    if (!this.ensureCsrfReady()) {
      return;
    }
    const target: boolean = !artist.isSubscribed;
    const prevVideo: HanimeVideo = this.video;
    this.subBusy = true;
    // 乐观更新：先切按钮文案，失败在 catch 里回滚
    this.video = applyArtistSubscribed(prevVideo, target);
    try {
      await api.subscribeArtist(artist.userId, artist.artistId, target, prevVideo.csrfToken);
      if (!this.disposed) {
        Toast.show(target ? '已关注作者' : '已取消关注');
      }
    } catch (e) {
      if (!this.disposed) {
        this.video = prevVideo;
        this.showActionError(e as Error);
      }
    } finally {
      this.subBusy = false;
    }
  }

  /** 赞 / 踩：登录态写站点 POST /like（rateVideo），乐观更新 + 失败回滚 */
  async rateVideo(positive: boolean): Promise<void> {
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    if (this.rateBusy) {
      return;
    }
    if (!this.ensureCsrfReady()) {
      return;
    }
    // 操作前快照：接口入参必须是「点击前」的 isFav / isUnlike / 计数（服务端据此切换）
    const prevVideo: HanimeVideo = this.video;
    const prevFav: boolean = this.fav;
    const wasLiked: boolean = positive ? prevVideo.isFav : prevVideo.isUnlike;
    // 用户已手动操作：作废仍在途的初始态校正
    this.actionSeq = this.actionSeq + 1;
    this.rateBusy = true;
    this.video = applyVideoRating(prevVideo, positive);
    this.fav = this.video.isFav;
    this.playScaleBounce(positive ? 'like' : 'dislike');
    let siteOk: boolean = false;
    try {
      await api.rateVideo(prevVideo.videoCode, positive, prevVideo.isFav, prevVideo.isUnlike,
        prevVideo.favTimes, prevVideo.unlikesCount, prevVideo.currentUserId, prevVideo.csrfToken);
      siteOk = true;
    } catch (e) {
      if (!this.disposed) {
        this.video = prevVideo;
        this.fav = prevFav;
        this.showActionError(e as Error);
      }
    } finally {
      this.rateBusy = false;
    }
    if (!siteOk || this.disposed) {
      return;
    }
    // 站点 like 与收藏是同一份状态（isFav），本地镜像跟着同步；本地失败不回滚
    try {
      await LocalRepo.getInstance().setFavorite(buildLocalRecord(this.video), this.video.isFav);
      notifyLibraryChanged();
    } catch (e) {
      // 本地库异常不阻断
    }
    if (!this.disposed) {
      Toast.show(wasLiked ? (positive ? '已取消点赞' : '已取消踩') : (positive ? '已点赞' : '已踩'));
    }
  }

  /**
   * 稍后再看：
   *  - 登录态 → 站点 POST /save（addToMyList，listCode='save'），成功后再写本地镜像；
   *    失败回滚按钮状态并提示；
   *  - 未登录 → 维持原本地行为（LocalRepo 稍后再看列表离线可用，不做登录引导）。
   */
  async toggleWatchLater(): Promise<void> {
    if (this.laterBusy) {
      return;
    }
    const target: boolean = !this.watchLater;
    // 用户手动操作：作废可能还在途的站点初始态校正，避免它把结果改回去
    this.watchLaterSyncSeq = this.watchLaterSyncSeq + 1;
    this.actionSeq = this.actionSeq + 1;
    const prevLater: boolean = this.watchLater;
    if (!this.loggedIn) {
      this.laterBusy = true;
      this.watchLater = target;
      this.playScaleBounce('later');
      let localOk: boolean = false;
      try {
        await LocalRepo.getInstance().setWatchLater(buildLocalRecord(this.video), target);
        notifyLibraryChanged();
        localOk = true;
      } catch (e) {
        if (!this.disposed) {
          this.watchLater = prevLater;
          this.showActionError(e as Error);
        }
      } finally {
        this.laterBusy = false;
      }
      if (localOk && !this.disposed) {
        Toast.show(target ? '已加入稍后再看' : '已移出稍后再看');
      }
      return;
    }
    if (!this.ensureCsrfReady()) {
      return;
    }
    const prevVideo: HanimeVideo = this.video;
    this.laterBusy = true;
    this.watchLater = target;
    this.playScaleBounce('later');
    let siteOk: boolean = false;
    try {
      await api.addToMyList(WATCH_LATER_LIST_CODE, prevVideo.videoCode, target, prevVideo.csrfToken);
      siteOk = true;
    } catch (e) {
      if (!this.disposed) {
        this.watchLater = prevLater;
        this.showActionError(e as Error);
      }
    } finally {
      this.laterBusy = false;
    }
    if (!siteOk || this.disposed) {
      return;
    }
    // 站点成功：本地稍后再看镜像同步（本地失败不回滚账号状态）
    try {
      await LocalRepo.getInstance().setWatchLater(buildLocalRecord(prevVideo), target);
      notifyLibraryChanged();
    } catch (e) {
      // 本地库异常不阻断
    }
    if (!this.disposed) {
      Toast.show(target ? '已加入稍后再看' : '已移出稍后再看');
    }
  }

  // ---------------------------------------------------------------------------
  // UI：播放器（置顶单实例，全屏 / 折叠隐藏只改变容器几何，不重建播放器）
  // ---------------------------------------------------------------------------

  @Builder
  playerLayer() {
    Column() {
      if (this.video.videoCode.length > 0) {
        InlinePlayer({
          video: this.video,
          handle: this.playerHandle,
          fullscreen: this.fs,
          // 折叠 / 拖拽 / 吸附期间抑制 InlinePlayer 的「可见比例 0 → 自动暂停」：
          // 折叠的暂停由页面在状态机里显式 pauseAndSave 完成（避免自动 / 显式两条路径互相覆盖），
          // 展开动画期间的可见比例增长也不会被当成被覆盖；页面真被二级页覆盖时仍按正常逻辑暂停。
          keepPlayingWhenHidden: this.playerCollapsed || this.handleDragging || this.playerSettling,
          onToggleFullscreen: () => {
            this.toggleFullscreen();
          },
          onVideoSizeChange: (width: number, height: number) => {
            this.updateVideoRatio(width, height);
          },
          onPlaybackStateChange: (playing: boolean) => {
            if (!this.disposed) {
              this.videoPlaying = playing;
            }
          },
          // 左上角「回首页」圆钮（返回钮右侧）：直接回首页（暂停落盘 + 恢复方向锁/系统栏 + 清栈 + 切首页 Tab）
          onReturnHome: () => {
            this.returnHomeFromPlayer();
          }
        });
      } else {
        // 兜底：详情没有解析出视频编号（异常数据）时只留黑底占位
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor(Theme.colors().playerBg);
      }
    }
    .width(this.fs ? '100%' : this.playerAreaWidth())
    .height(this.fs ? '100%' : this.playerAreaHeight())
    .backgroundColor(Theme.colors().playerBg)
    // 折叠收缩过程中裁剪到容器内：高度趋近 0 时视频 / 控制层不会溢出到把手和 Tabs 上
    .clip(true)
    // 折叠吸附动画结束后彻底移出布局：0 尺寸的 XComponent 表面 / 透明热区不再残留，
    // 但组件留在树上（AVPlayer 不重建），展开时同一个实例重新参与布局继续播放
    .visibility(this.playerLayerVisible() ? Visibility.Visible : Visibility.None)
    .position({
      x: this.fs ? 0 : this.playerAreaOffsetX(),
      y: this.fs ? 0 : this.statusBarHeight
    });
  }

  @Builder
  loadingPlaceholder() {
    // 横屏分栏：加载占位也用分栏骨架（左侧黑色播放器区域 + 右侧内容区），
    // 这样点卡片进入本页的首帧就是横屏播放器布局，视频加载完不会从「中间一小块」
    // 跳变成横屏分栏（用户看到的左右大片空白即竖屏占位在横屏窗口里居中导致的）。
    if (this.landscapeLayout()) {
      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color('#FFFFFF');
        }
        .width(this.splitLeftWidth())
        .height(this.landscapePlayerHeight())
        .position({ x: 0, y: this.statusBarHeight })
        .backgroundColor(Theme.colors().playerBg)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);

        Column() {
          LoadingView({ text: '加载视频信息…' });
        }
        .width(this.viewportWidth - this.splitLeftWidth() - SPLIT_DIVIDER_WIDTH)
        .height(this.landscapePlayerHeight())
        .position({
          x: this.splitLeftWidth() + SPLIT_DIVIDER_WIDTH,
          y: this.statusBarHeight
        })
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center);
      }
      .width('100%')
      .height('100%');
    } else {
      Column() {
        Column() {
          LoadingProgress()
            .width(28)
            .height(28)
            .color('#FFFFFF');
        }
        .width(this.playerWidth())
        .height(this.playerHeight())
        .backgroundColor(Theme.colors().playerBg)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .margin({ top: this.statusBarHeight });

        Column() {
          LoadingView({ text: '加载视频信息…' });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%')
      .alignItems(HorizontalAlign.Center);
    }
  }

  // ---------------------------------------------------------------------------
  // UI：标题 / 动作区 / 元信息
  // ---------------------------------------------------------------------------

  /** 玻璃卡片内的小节标题（不追加页面左右留白，避免与卡片 padding 叠加） */
  @Builder
  cardSectionLabel(title: string) {
    Row() {
      Row()
        .width(3)
        .height(13)
        .borderRadius(2)
        .linearGradient({
          angle: 180,
          colors: [[Theme.colors().primary, 0.0], [Theme.colors().secondary, 1.0]]
        })
        .margin({ right: 6 });
      Text(title)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().textPrimary);
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
    .margin({ bottom: 8 });
  }

  /** 卡片内分隔发丝线 */
  @Builder
  cardDivider() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(Theme.colors().divider)
      .margin({ top: 12, bottom: 10 });
  }

  @Builder
  headerBlock() {
    Column() {
      // 标题主次对齐安卓原版 TitleSection（VideoIntroductionScreen.kt:1276）：
      // 中文名（chineseTitle）存在时作为主标题，原日文/英文名降为副标题；
      // 只在两者不同时才画副标题，避免同一串文字重复两行。
      Text(this.primaryTitle())
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().textPrimary)
        .maxLines(3)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');

      if (this.secondaryTitle().length > 0) {
        Text(this.secondaryTitle())
          .fontSize(Dimens.bodySize)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.colors().textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 6 })
          .width('100%');
      }

      this.metaRow();
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 10 });
  }

  /** 主标题：中文名优先（安卓 TitleSection 的 primaryTitle 规则） */
  primaryTitle(): string {
    const chinese: string = this.video.chineseTitle;
    if (chinese.length > 0) {
      return chinese;
    }
    return this.video.title;
  }

  /** 副标题：与主标题不同才有值（安卓 secondaryTitle = title.takeIf { it != primaryTitle }） */
  secondaryTitle(): string {
    const primary: string = this.primaryTitle();
    if (this.video.title !== primary) {
      return this.video.title;
    }
    return '';
  }

  /**
   * 动作区，对齐安卓 ActionSection（VideoIntroductionScreen.kt:1485）：
   * 横向可滚动的「图标在上 + 文字在下」按钮（min 76 宽、圆角 14、图标 primary 色）。
   *
   * 与安卓的差异（本移植版没有的能力，不伪造入口）：
   *  - 安卓有「签到」「加入我的清单」「下载」；本工程没有签到与 App 内下载，
   *    「我的清单」入口在资料库页，因此这三项不出现在这里；
   *  - 安卓分享「长按 = 复制分享文本」，这里同样支持。
   */
  @Builder
  actionRow() {
    Scroll() {
      Row({ space: 8 }) {
        VideoActionButton({
          icon: '☆',
          label: this.fav ? '已收藏' : '收藏',
          active: this.fav,
          onTap: () => {
            this.toggleFavorite();
          }
        });
        VideoActionButton({
          icon: '👍',
          label: '点赞',
          active: this.video.isFav,
          onTap: () => {
            this.rateVideo(true);
          }
        });
        VideoActionButton({
          icon: '👎',
          label: '点踩',
          active: this.video.isUnlike,
          onTap: () => {
            this.rateVideo(false);
          }
        });
        VideoActionButton({
          icon: '🕘',
          label: this.watchLater ? '已稍后' : '稍后再看',
          active: this.watchLater,
          onTap: () => {
            this.toggleWatchLater();
          }
        });
        VideoActionButton({
          icon: '📤',
          label: '分享',
          active: false,
          onTap: () => {
            this.openShareMenu();
          },
          onLongTap: () => {
            // 安卓 VideoActionButton 的 onLongClick 就是「复制分享文本」
            this.copyShareText();
          }
        });
        VideoActionButton({
          icon: '🌐',
          label: '原站打开',
          active: false,
          onTap: () => {
            this.openSitePage();
          }
        });
        if (this.video.originalComic.length > 0) {
          VideoActionButton({
            icon: '📖',
            label: '原作漫画',
            active: false,
            onTap: () => {
              Router.openWeb(this.video.originalComic, '原作漫画');
            }
          });
        }
      }
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding })
      .margin({ top: 12 })
      .alignItems(VerticalAlign.Top);
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
    .align(Alignment.Start);
  }

  /**
   * 元信息区，对齐安卓 MetaSection（VideoIntroductionScreen.kt:1311）：
   * 第一段是评分（赞/踩比例条，对应 VideoRatingButtons），第二段是「观看数 · 上传时间」。
   * 作者不再挤在这里 —— 安卓有独立 ArtistSection，本页也改成独立作者卡（见 artistCard）。
   */
  @Builder
  metaRow() {
    Column() {
      if (this.video.favTimes >= 0 || this.video.unlikesCount >= 0) {
        RatingBar({
          ratio: likeRatio(this.video),
          likes: this.video.favTimes,
          unlikes: this.video.unlikesCount
        });
      }
      Row() {
        if (this.video.views.length > 0) {
          Text('▶ ' + this.video.views)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textSecondary);
        }
        if (this.video.uploadTime.length > 0) {
          Text((this.video.views.length > 0 ? '   ' : '') + '🕘 ' + this.video.uploadTime)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textSecondary)
            .margin({ left: this.video.views.length > 0 ? 12 : 0 });
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .margin({ top: this.hasRating() ? 10 : 0 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 10 });
  }

  /** 是否有评分数据（赞/踩都取不到时安卓也不画 VideoRatingButtons） */
  hasRating(): boolean {
    return this.video.favTimes >= 0 || this.video.unlikesCount >= 0;
  }

  // ---------------------------------------------------------------------------
  // UI：Tabs（简介 / 评论 / 相关推荐）
  // ---------------------------------------------------------------------------

  /**
   * 自定义 tabBar 单项：文字 + 底部指示条。
   * 选中态文字颜色 / 指示条宽度由 `.animation` 平滑过渡（220ms Curve.Friction）；
   * 点击与左右滑动切换都会改变 contentTab，两种来源都有指示条动画。
   * 本轮不再对 TabContent 内容做任何 opacity / translate 过渡（修复点击 tab 闪一下）。
   */
  @Builder
  tabBarItem(index: number, label: string) {
    Column() {
      Text(label)
        .fontSize(15)
        .fontWeight(this.contentTab === index ? FontWeight.Bold : FontWeight.Normal)
        .fontColor(this.contentTab === index ? Theme.colors().primary : Theme.colors().textSecondary)
        .animation({ duration: TAB_COLOR_ANIM_MS, curve: Curve.Friction });
      Row()
        .width(this.contentTab === index ? 18 : 8)
        .height(3)
        .borderRadius(2)
        .backgroundColor(Theme.colors().primary)
        .opacity(this.contentTab === index ? 1 : 0)
        .margin({ top: 5 })
        .animation({ duration: TAB_COLOR_ANIM_MS, curve: Curve.Friction });
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center);
  }

  @Builder
  tabsBlock() {
    Tabs({ barPosition: BarPosition.Start, index: this.contentTab }) {
      // 三个 TabContent 都显式撑满 Tabs 内容区：避免个别版本把 TabContent 高度按内容自适应，
      // 导致相关推荐 Grid 只拿到「一行卡片」的高度、必须立刻滚动（本轮相关推荐首屏修复的配套）。
      TabContent() {
        this.introTab();
      }
      .tabBar(this.tabBarItem(0, '简介'))
      .width('100%')
      .height('100%');

      TabContent() {
        this.commentTab();
      }
      .tabBar(this.tabBarItem(1, '评论'))
      .width('100%')
      .height('100%');

      TabContent() {
        this.relatedTab();
      }
      .tabBar(this.tabBarItem(2, '相关推荐'))
      .width('100%')
      .height('100%');
    }
    .barHeight(44)
    .barMode(BarMode.Fixed)
    .barBackgroundColor(Color.Transparent)
    .animationDuration(180)
    // 点击 / 滑动切换都只用 Tabs 自带动画；不再有 onTabBarClick 内容过渡，
    // 三个 TabContent 的内容 opacity 恒为 1、translate 恒为 0。
    .onChange((index: number) => {
      this.handleTabChanged(index);
    })
    .layoutWeight(1)
    .width('100%');
  }

  // ---------------------------------------------------------------------------
  // UI：简介 tab（标题 / 动作区 / 元信息已从页面固定区搬到这里）
  // ---------------------------------------------------------------------------

  @Builder
  introTab() {
    // 包一层 Stack 只为承载下拉刷新浮层：浮层用 position 绝对定位，不参与布局，
    // 所以 Scroll 的高度/起点与改动前完全一致（详情页内容区顶部没有悬浮顶栏，topInset = 0）。
    Stack({ alignContent: Alignment.TopStart }) {
      Refresh({ refreshing: $$this.refreshing, builder: EmptyRefreshHeader }) {
        Scroll() {
          Column() {
            // 段落顺序对齐安卓 VideoIntroductionScreen 的 LazyColumn（:393-471）：
            // 作者卡 → 标题 → 元信息 → 简介 → 动作区 → 标签 → 系列播放列表。
            // 相关推荐在本工程是独立 Tab（安卓是简介内的一段），这里不重复渲染。
            this.artistCard();
            this.headerBlock();
            this.introCard();
            this.actionRow();
            // 「作者作品」不再内联在这里：入口是作者卡右侧的「作品 ▼」胶囊（打开二级面板）。
            this.tagsBlock();
            this.playlistBlock();
            this.introFooter();
          }
          .width('100%')
          // 详情页是 NavDestination 二级页，Index 的悬浮底栏会被覆盖，不需要再预留 bottomInset(96)，
          // 只留 24 的内容呼吸 + 系统导航条高度，消除页面底部多余空白。
          .padding({ bottom: 24 + this.navBarHeight });
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
      .onRefreshing(() => {
        this.refresh();
      })
      // 跟手 1:1 + 触发距离 110，与首页/列表页同一套手感（KHenTai GalleryListView.ets:886-889）
      .pullDownRatio(1)
      .refreshOffset(110)
      .onStateChange((state: RefreshStatus) => {
        this.refreshStatus = state;
      })
      .width('100%')
      .height('100%');

      PullRefreshHeader({
        status: this.refreshStatus,
        refreshing: this.refreshing,
        topInset: 0
      });
    }
    .width('100%')
    .height('100%');
  }

  /**
   * 独立作者卡，对齐安卓 ArtistSection（VideoIntroductionScreen.kt:1208）：
   * 52 圆头像 + 名字（粗体）+ 分类（次要色）+ 右侧按钮，整卡可点（进入作者作品）。
   *
   * 与安卓的两处已知差异（没有对应能力，不伪造）：
   *  - 安卓右侧是「订阅 / 已订阅」按钮，走站点 POST 订阅；本移植版 HanimeApi 没有订阅接口，
   *    因此改为「作品」入口（复用既有的作者作品面板）；
   *  - 安卓有 artist.genre 之外的字段（帖子数等）不展示，这里只显示 genre。
   */
  @Builder
  artistCard() {
    if (this.authorName().length > 0) {
      // 外层只负责左右留白：卡片本体 width 100% 同时带水平 margin 时，margin 不会被从 100% 里扣掉，
      // 实际会溢出到贴边（这就是作者卡看起来没有左右边距的原因）；改用外层 padding 造内缩。
      Column() {
        Column() {
        // 上半行：头像 + 名字/分类 + 关注按钮。
        // 关注按钮是这一行**唯一**的可点目标（32 高、最小宽 76），不与别的入口挤在一起。
        Row() {
          if (this.artistAvatar().length > 0) {
            Image(this.artistAvatar())
              .width(52)
              .height(52)
              .borderRadius(26)
              .objectFit(ImageFit.Cover)
              .backgroundColor(Theme.colors().surfaceVariant)
              .border({ width: 1, color: Theme.colors().glassBorder });
          } else {
            Row() {
              Text(this.authorName().substring(0, 1))
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.colors().primary);
            }
            .width(52)
            .height(52)
            .borderRadius(26)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.colors().primaryContainer)
            .border({ width: 1, color: Theme.colors().glassBorder });
          }

          Column() {
            Text(this.authorName())
              .fontSize(Dimens.subtitleSize)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.colors().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%');
            Text(this.artistGenre().length > 0 ? this.artistGenre() : '作者')
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().textSecondary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .margin({ top: 2 })
              .width('100%');
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 12 });

          // 关注 / 已关注：对齐安卓 ArtistSection 的订阅按钮。
          // 尺寸从 26 高的小胶囊改成 32 高、最小宽 76 —— 原来两个 26 高的小按钮上下相隔 6vp，
          // 手指很容易点错，这是本次「容易误触」的直接原因。
          if (this.canSubscribeArtist()) {
            Text(this.video.artist !== null && this.video.artist.isSubscribed ? '已关注' : '+ 关注')
              .fontSize(Dimens.bodySize)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.video.artist !== null && this.video.artist.isSubscribed
                ? Theme.colors().textSecondary : Theme.colors().onPrimary)
              .maxLines(1)
              .constraintSize({ minWidth: 76 })
              .height(32)
              .padding({ left: 14, right: 14 })
              .borderRadius(999)
              .backgroundColor(this.video.artist !== null && this.video.artist.isSubscribed
                ? Theme.colors().chipTint : Theme.colors().primary)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .textAlign(TextAlign.Center)
              .margin({ left: 12 })
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.toggleArtistSubscribe();
              });
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ left: 12, right: 12, top: 12, bottom: 12 });

        // 下半行：「全部作品」独占通栏一行（40 高），与关注按钮之间隔着一条分隔线，
        // 点击热区完全分开，不会再互相误触。整卡不再有点击 → 点头像/名字什么都不会发生。
        Row() {
          Text('全部作品')
            .fontSize(Dimens.captionSize)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.colors().textSecondary);
          Blank();
          Text('查看')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().primary);
          Text('›')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().primary)
            .margin({ left: 2 });
        }
        .width('100%')
        .height(40)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
        .border({ width: { top: Glass.borderWidth() }, color: Theme.colors().glassBorder })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.98 })
        .onClick(() => {
          this.openAuthorWorksPanel();
        });
      }
      .width('100%')
      .borderRadius(Dimens.listRadius)
      .backgroundColor(Theme.colors().cardBg)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .clip(true)
      }
      .width('100%')
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 12 });
    }
  }

  /** 作者分类（安卓 ArtistSection 的第二行 genre） */
  artistGenre(): string {
    const artist: Artist | null = this.video.artist;
    if (artist !== null) {
      return artist.genre;
    }
    return '';
  }

  /**
   * 是否显示「关注」按钮：必须有作者，且 `#video-subscribe-form` 的 userId / artistId 都解析到了。
   * 与安卓一致（Parser.kt:600-612 只有拿到这两个 hidden input 才构造 Artist.post）。
   * 未登录时站点不下发这个表单，因此未登录看不到按钮 —— 这也避免了一个必然 401 的按钮。
   */
  canSubscribeArtist(): boolean {
    const artist: Artist | null = this.video.artist;
    if (artist === null) {
      return false;
    }
    return artist.userId.length > 0 && artist.artistId.length > 0;
  }

  /** 可展开简介卡：panelRadius 30 + cardBg 纯色 + 1vp glassBorder */
  @Builder
  introCard() {
    Column() {
      Column() {
        this.cardSectionLabel('简介');
        if (this.introText().length > 0) {
          Text(this.introText())
            .fontSize(Dimens.bodySize)
            .lineHeight(21)
            .fontColor(Theme.colors().textSecondary)
            .maxLines(this.introExpanded ? 200 : 4)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          if (this.introText().length > INTRO_COLLAPSE_LENGTH) {
            Text(this.introExpanded ? '收起' : '展开')
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().primary)
              .padding({ top: 6 })
              .onClick(() => {
                this.introExpanded = !this.introExpanded;
              });
          }
        } else {
          Text('暂无简介')
            .fontSize(Dimens.bodySize)
            .fontColor(Theme.colors().textHint)
            .width('100%');
        }

      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(16)
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().cardBg)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 12 });
  }

  /**
   * 作者作品二级面板（简介卡作者行右侧「作品 ▼」胶囊 / 作者行本体打开）：
   *  - 全屏半透明遮罩（Theme.colors().overlay）：拦截所有点击、点击关闭；zIndex 30 盖在简介页内容之上，
   *    节点挂在页面根 Stack 最后一项（见 build()）；
   *  - 开合动画 200ms Curve.Friction：遮罩淡入淡出 + 面板 scale 0.94→1 / 上移 12→0（挂在整层上，
   *    与评论排序弹窗 commentSortOverlay 完全同一套写法）；
   *  - 面板本身是 GlassCapsule kind 'panel' 沉浸材质，与评论排序弹窗 / 顶栏 / 底栏同源；
   *    网格在面板内独立竖向滚动，不与简介页 Scroll 抢手势。
   */
  @Builder
  authorWorksPanelOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：整屏半透明，拦截所有点击（点击关闭）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.colors().overlay)
        .onClick(() => {
          this.closeAuthorWorksPanel();
        });
      // 居中圆角面板（沉浸材质）
      this.authorWorksPanel();
    }
    .width('100%')
    .height('100%')
    .zIndex(30)
    .transition(TransitionEffect.OPACITY
      .animation({ duration: AUTHOR_WORKS_PANEL_ANIM_MS, curve: Curve.Friction })
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })
        .animation({ duration: AUTHOR_WORKS_PANEL_ANIM_MS, curve: Curve.Friction }))
      .combine(TransitionEffect.translate({ y: 12 })
        .animation({ duration: AUTHOR_WORKS_PANEL_ANIM_MS, curve: Curve.Friction })));
  }

  /**
   * 面板容器：宽 = 窗口宽 92%（上限 560）、高按网格内容估算并夹到窗口高 78%、圆角 26。
   * GlassCapsule 需要精确的 capsuleHeight（且它是普通成员变量，父组件重绘不会热更新），
   * 这里用 authorWorksPanelKey 作 ForEach key：高度 / 内容态一变就重建材质宿主，
   * 新实例拿到新的 capsuleHeight，材质面板与内容层始终同高、不会被旧高度裁切。
   */
  @Builder
  authorWorksPanel() {
    Column() {
      ForEach([this.authorWorksPanelKey()], (panelKey: string) => {
        GlassCapsule({
          capsuleHeight: this.authorWorksPanelHeight(),
          capsuleRadius: AUTHOR_WORKS_PANEL_RADIUS,
          kind: 'panel'
        }) {
          this.authorWorksPanelContent();
        }
      }, (panelKey: string) => panelKey);
    }
    .width(this.authorWorksPanelWidth())
    .height(this.authorWorksPanelHeight());
  }

  /**
   * 面板内容层（叠在沉浸材质之上）：标题行「<作者名> 的作品」+ 30 关闭圆钮，
   * 下方按四态渲染：加载中转圈 / 加载失败点击重试 / 暂无其它作品 / 竖向滚动网格。
   */
  @Builder
  authorWorksPanelContent() {
    Column() {
      Row() {
        Text(this.authorName() + ' 的作品')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Row() {
          Image($r('app.media.ic_close'))
            .width(14)
            .height(14)
            .fillColor(Theme.colors().textSecondary);
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.colors().chipTint)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.closeAuthorWorksPanel();
        });
      }
      .width('100%')
      .height(AUTHOR_WORKS_PANEL_TITLE_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .padding({ left: AUTHOR_WORKS_PANEL_PADDING, right: 12 });

      if (this.authorWorksLoading) {
        Row() {
          LoadingProgress()
            .width(18)
            .height(18)
            .color(Theme.colors().primary);
          Text('加载中…')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textSecondary)
            .margin({ left: 8 });
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center);
      } else if (this.authorWorksFailed) {
        Row() {
          Text('加载失败，点击重试')
            .fontSize(Dimens.bodySize)
            .fontColor(Theme.colors().primary)
            .padding({ left: 12, right: 12, top: 8, bottom: 8 });
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .onClick(() => {
          this.loadAuthorWorks();
        });
      } else if (this.authorWorks.length === 0) {
        Row() {
          Text('暂无其它作品')
            .fontSize(Dimens.bodySize)
            .fontColor(Theme.colors().textHint);
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center);
      } else {
        Grid() {
          // normalizeAuthorWorks 按 videoCode 去重（保留当前作品），key 唯一且稳定
          ForEach(this.authorWorks, (item: HanimeInfo) => {
            GridItem() {
              // 徽标放封面左上角：卡片底部左侧是播放量、右下是时长，左上角是空位
              Stack({ alignContent: Alignment.TopStart }) {
                VideoCard({
                  item: item,
                  cardWidth: 0,
                  onTap: () => {
                    // 点自己：只关面板（不重新加载同一个视频，避免播放器被打断）
                    if (item.videoCode === this.videoCode()) {
                      this.closeAuthorWorksPanel();
                      return;
                    }
                    // 与相关推荐 / 系列一致：先关面板，再暂停落盘并跳到另一个详情页
                    this.closeAuthorWorksPanel();
                    this.openOtherVideo(item.videoCode);
                  }
                });
                // 正在播放的那一条：左下角「正在播放」徽标 + 三根跳动的音量条
                if (item.videoCode === this.videoCode()) {
                  NowPlayingBadge();
                }
              }
              .width('100%');
            }
          }, (item: HanimeInfo) => item.videoCode);
        }
        .columnsTemplate(this.authorWorksGridTemplate())
        .columnsGap(Dimens.gap)
        .rowsGap(Dimens.gap)
        .width('100%')
        .layoutWeight(1)
        // 底部留出面板呼吸；网格高度由面板剩余空间决定，内容多时自身竖向滚动
        .padding({
          left: AUTHOR_WORKS_PANEL_PADDING,
          right: AUTHOR_WORKS_PANEL_PADDING,
          bottom: AUTHOR_WORKS_PANEL_BOTTOM
        })
        // 一次性预构建全部 20 张卡：网格内滚动经过任意位置都不会出现卡片闪现 / 空白
        .cachedCount(this.authorWorks.length)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%')
    .height(this.authorWorksPanelHeight());
  }

  /** 标签 chips */
  @Builder
  tagsBlock() {
    Column() {
      if (this.video.tags.length > 0) {
        SectionHeader({ title: '标签' });
        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.video.tags, (tag: string) => {
            TagChip({
              text: tag,
              selected: false,
              onTap: () => {
                this.openTag(tag);
              }
            });
          }, (tag: string) => tag);
        }
        .width('100%')
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });
      }
    }
    .width('100%');
  }

  /** 系列播放列表：SectionHeader + 横向 VideoCard（cardWidth 160） */
  @Builder
  playlistBlock() {
    Column() {
      if (this.playlistVideos().length > 0) {
        // 对齐安卓 PlaylistSection 的 SectionHeader（VideoIntroductionScreen.kt:1640）：
        // 主标题固定「系列视频」，清单名作为副标题（原来把清单名当标题，长短不一、层级也不对）。
        Column() {
          Text('系列视频')
            .fontSize(Dimens.subtitleSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary)
            .width('100%');
          Text(this.playlistTitle())
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%');
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, bottom: 8 });
        List({ space: Dimens.gap }) {
          ForEach(this.playlistVideos(), (item: HanimeInfo) => {
            ListItem() {
              VideoCard({
                item: item,
                cardWidth: PLAYLIST_CARD_WIDTH,
                onTap: () => {
                  this.openOtherVideo(item.videoCode);
                }
              });
            }
          }, (item: HanimeInfo) => item.videoCode + item.title);
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(PLAYLIST_RAIL_HEIGHT)
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });
      }
    }
    .width('100%');
  }

  /**
   * 相关推荐 tab（第 3 个，内容Tab）：2 列 Grid 渲染**本页自绘的竖版卡片**。
   *
   * 本轮修复「上下滑动经过底部区域时卡片闪现 / 显示隐藏、到底部才冒出」：
   *  - 列表来自 `relatedList` 快照：详情接口返回时由 applyRelatedFromVideo **一次性落地全部条目**
   *    （落地时按 videoCode 去重），进入页面 / 切到该 tab 时首帧就可用，不依赖 tab 可见；
   *  - 删除 onReachEnd 增量放出与相关条数状态：滚动到底不会再改变列表长度，
   *    不会触发 Grid 重新计算 / 节点重建，也不再有「滚到底部才冒出更多卡片」的观感；
   *  - Grid.cachedCount 取列表长度：所有卡片一次预构建，滚动回收不会反复创建 / 销毁 item；
   *    横屏右侧面板更矮、可视行数更少，全量预构建天然覆盖面板高度内的所有卡片，
   *    因此横屏不按面板高度缩小缓存（缩小会让卡片进入可视区才创建，重新引入闪现）；
   *  - ForEach key 用去重后的 videoCode（唯一且稳定），避免重复 key 造成节点错乱 / 闪动；
   *  - 卡片封面固定 3:4（见 RelatedVideoCard），高度只随卡片宽度变化，
   *    滚动 / 播放器状态变化都不会再重排卡片；
   *  - 只有详情返回空列表时才后台静默补拉一次；失败保留旧数据，展示错误行 + 点击重试（不清空）。
   * 呈现：
   *  - columnsTemplate '1fr 1fr'，行列间距 Dimens.gap（12），左右各 12 页面边距；
   *    卡片宽度按内容区实际可用宽度算（竖屏窗口宽 / 横屏右侧面板宽，见 relatedCardWidth），
   *    横屏面板再窄也保持 2 列，不硬塞 3 列；
   *  - 点击仍走 openOtherVideo（先暂停落盘再跳转）；
   *  - 底部留白见 relatedGridBottomInset（竖屏 24、横屏 16，均叠加 navBarHeight）；
   *    空态沿用公共 InlineEmptyRow；
   *  - 不做任何 opacity / translate 入场（切 tab 不闪）。
   */
  @Builder
  relatedTab() {
    Column() {
      // 有旧数据但本次加载失败：顶部展示错误行 + 重试，列表保持可见不清空
      if (this.relatedError.length > 0) {
        InlineErrorRow({
          message: this.relatedError,
          onRetry: () => {
            this.retryRelated();
          }
        });
      }
      if (this.relatedList.length > 0) {
        Grid() {
          // 一次性渲染全部（relatedList 已按 videoCode 去重），key 唯一且稳定
          ForEach(this.relatedList, (item: HanimeInfo) => {
            GridItem() {
              RelatedVideoCard({
                item: item,
                cardWidth: this.relatedCardWidth(),
                onTap: () => {
                  this.openOtherVideo(item.videoCode);
                }
              });
            }
          }, (item: HanimeInfo) => item.videoCode);
        }
        .columnsTemplate('1fr 1fr')
        .columnsGap(Dimens.gap)
        .rowsGap(Dimens.gap)
        // 卡片高度不再统一（里番 3:4 / 三次元 16:9）：DEFAULT 时同一行按最高卡片统一行高，
        // 短卡的背景不会跟着拉满，视觉上保持顶部对齐
        .alignItems(GridItemAlignment.DEFAULT)
        .width('100%')
        .layoutWeight(1)
        // 覆盖全部条目（横屏面板再矮也覆盖可见行）：滚动经过任意位置都不需要「滚到附近才创建」
        .cachedCount(this.relatedList.length)
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          top: RELATED_GRID_TOP,
          bottom: this.relatedGridBottomInset()
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      } else if (this.relatedLoading) {
        InlineLoadingRow({ text: '正在加载相关推荐…' });
      } else if (this.relatedError.length === 0) {
        Column() {
          InlineEmptyRow({ text: '暂无相关推荐', hint: '换个视频看看相似内容吧' });
        }
        .width('100%')
        .padding({ top: 24 })
        .alignItems(HorizontalAlign.Center);
      }
    }
    .width('100%')
    .height('100%');
  }

  /** 简介 tab 底部：站点网页入口（登录 / 评论等站点操作） */
  @Builder
  introFooter() {
    Row() {
      Text('在网页中打开（登录 / 评论等站点操作）')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .padding({ top: 8, bottom: 8 })
        .onClick(() => {
          this.openSitePage();
        });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 6 });
  }

  // ---------------------------------------------------------------------------
  // UI：评论 tab（复用 CommentSection 的 embedded 模式；列表铺满，
  // 「评论数」移入底部悬浮输入框内部，输入框上方一行左侧为排序胶囊、右侧为圆形刷新钮）
  // ---------------------------------------------------------------------------

  @Builder
  commentTab() {
    Stack({ alignContent: Alignment.Bottom }) {
      // 第 1 层：独立滚动的评论列表铺满整个 tab（顶部已无固定表头 / 悬浮胶囊），
      // 顶部只留少量呼吸，底部预留悬浮输入框（含键盘态）高度
      Column() {
        CommentSection({
          videoCode: this.video.videoCode,
          currentUserId: this.video.currentUserId,
          csrfToken: this.video.csrfToken,
          commentCount: this.commentCount,
          reloadToken: this.commentReloadToken,
          embedded: true,
          topInset: COMMENT_LIST_TOP_INSET,
          bottomInset: this.commentComposerReservedHeight(),
          panelHandle: this.commentHandle,
          onCommentCountChange: (count: number) => {
            this.commentCount = count;
          },
          onReplyNameChange: (name: string) => {
            this.panelReplyName = name;
          },
          onSendingChange: (sending: boolean) => {
            this.panelSending = sending;
          }
        });
      }
      .width('100%')
      .height('100%');
      // 评论列表内容不参与任何 tab 内容透明度 / 位移动画（opacity 恒 1、translate 恒 0）

      // 第 2 层：悬浮评论输入框（三层 Stack：最底保险实底 / 沉浸材质背景 / 输入条内容），
      // 输入框正上方一行：左侧评论排序胶囊 + 右侧独立圆形刷新钮（见 floatingComposer）
      this.floatingComposer();
    }
    .width('100%')
    .height('100%');
  }

  /**
   * 评论排序胶囊：悬浮在底部评论输入框正上方、左侧对齐（与右侧刷新圆钮同一行）。
   *
   * - 材质：GlassCapsule(capsuleHeight 36 / capsuleRadius 18 / kind 'composer') —— 与搜索胶囊、
   *   旁边刷新圆钮、悬浮底栏同一档系统沉浸材质，不再用普通 chipTint 实底；
   * - 内容层（材质之上）：⇅ 图标（次级色）+ 当前排序名（主色、Medium，4 字内不换行），
   *   内容层带 1vp glassBorder 描边；材质不可用时 GlassCapsule 内部回退 chipTint + 薄模糊 + 描边，
   *   深浅色主题下文字都可读；
   * - 点击弹自定义排序弹窗（openCommentSortMenu），排序只客户端重排已加载评论、不重新请求；
   * - 宽度固定（96），切换排序时与右侧刷新圆钮都不会跳动；外层 40 高行内垂直居中。
   */
  @Builder
  commentSortPill() {
    Column() {
      GlassCapsule({
        capsuleHeight: COMMENT_SORT_PILL_HEIGHT,
        capsuleRadius: COMMENT_SORT_PILL_HEIGHT / 2,
        kind: 'composer'
      }) {
        Row() {
          Text('⇅')
            .fontSize(13)
            .fontColor(Theme.colors().textSecondary);
          Text(commentSortLabel(this.commentSort))
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.colors().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ left: 5 });
        }
        .width('100%')
        .height(COMMENT_SORT_PILL_HEIGHT)
        .padding({ left: 12, right: 12 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
        .borderRadius(COMMENT_SORT_PILL_HEIGHT / 2)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
      }
    }
    .width(COMMENT_SORT_PILL_WIDTH)
    .height(COMMENT_SORT_PILL_HEIGHT)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      this.openCommentSortMenu();
    })
    .accessibilityText('评论排序：' + commentSortLabel(this.commentSort));
  }

  /**
   * 单个排序选项行（弹窗内）：
   *  - 高 48 / 文字 14 / 左右 12 内边距，整行可点；
   *  - 当前项：主色文字 + Medium + 浅主色底 + 右侧 ✓；非当前项：主文字色、透明底；
   *  - 按压缩放反馈：clickEffect LIGHT 0.97（与播放器选项弹窗同一套手感）。
   */
  @Builder
  commentSortOptionRow(label: string, type: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(this.commentSort === type ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.commentSort === type ? Theme.colors().primary : Theme.colors().textPrimary)
        .maxLines(1)
        .layoutWeight(1);
      if (this.commentSort === type) {
        Text('✓')
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().primary);
      }
    }
    .width('100%')
    .height(COMMENT_SORT_OPTION_HEIGHT)
    .padding({ left: 12, right: 12 })
    .borderRadius(14)
    .backgroundColor(this.commentSort === type ? Theme.accentContainer() : Color.Transparent)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      this.chooseCommentSort(type);
    });
  }

  /**
   * 排序弹窗内容层：标题「评论排序」+ 关闭圆钮 + 6 个选项行。
   * 总高 = 标题行 36 + 间距 4 + 6×48 = 328，加上下内边距 12×2 正好等于面板固定高 352，
   * 六项一次完整呈现、不需要滚动。内容层内的圆角描边与材质面板同半径，形成 1vp 玻璃边。
   */
  @Builder
  commentSortPanelContent() {
    Column() {
      Row() {
        Text('评论排序')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .layoutWeight(1);
        Row() {
          Image($r('app.media.ic_close'))
            .width(14)
            .height(14)
            .fillColor(Theme.colors().textSecondary);
        }
        .width(30)
        .height(30)
        .borderRadius(15)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.colors().chipTint)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.9 })
        .onClick(() => {
          this.closeCommentSortMenu();
        });
      }
      .width('100%')
      .height(COMMENT_SORT_TITLE_HEIGHT)
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 4 })
      .margin({ bottom: 4 });

      this.commentSortOptionRow('站点顺序', COMMENT_SORT_SITE);
      this.commentSortOptionRow('最新', COMMENT_SORT_LATEST);
      this.commentSortOptionRow('最早', COMMENT_SORT_EARLIEST);
      this.commentSortOptionRow('回复最多', COMMENT_SORT_MOST_REPLY);
      this.commentSortOptionRow('最多点赞', COMMENT_SORT_MOST_LIKES);
      this.commentSortOptionRow('最多点踩', COMMENT_SORT_MOST_DISLIKES);
    }
    .width('100%')
    .height(COMMENT_SORT_PANEL_HEIGHT)
    .padding({
      left: 8,
      right: 8,
      top: 12,
      bottom: 12
    })
    .borderRadius(COMMENT_SORT_PANEL_RADIUS)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
  }

  /**
   * 排序弹窗面板：GlassCapsule(kind 'panel') 承载系统沉浸材质（与顶栏 / 底栏 / 评论输入框同源），
   * 内容层（标题 / 关闭钮 / 选项行）叠在材质之上；88% 宽（max 340）/ 圆角 26 / 固定高 352。
   *
   * 开合过渡挂在弹窗根节点（commentSortOverlay）上：整层 200ms 淡入 + scale 0.94→1 + 上移 12→0，
   * 面板位于整层正中，视觉上就是「面板本身」在缩放上移（与播放器清晰度/倍速弹窗同一套写法）。
   */
  @Builder
  commentSortPanel() {
    Column() {
      GlassCapsule({
        capsuleHeight: COMMENT_SORT_PANEL_HEIGHT,
        capsuleRadius: COMMENT_SORT_PANEL_RADIUS,
        kind: 'panel'
      }) {
        this.commentSortPanelContent();
      }
    }
    .width('88%')
    .constraintSize({ maxWidth: COMMENT_SORT_PANEL_MAX_WIDTH })
    .height(COMMENT_SORT_PANEL_HEIGHT);
  }

  /**
   * 评论排序弹窗（自定义，替代系统 ActionSheet）：
   *  - 全屏半透明遮罩（Theme.colors().overlay）：拦截所有点击，点击关闭；zIndex 30 盖在评论输入框 /
   *    控制层之上（根 Stack 最后一项本来也在最上层，这里显式声明层级意图）；
   *  - 开合动画 200ms Curve.Friction：遮罩淡入淡出 + 面板 scale 0.94→1 / 上移 12→0。
   *    过渡挂在这一层（整层缩放 / 上移，面板居中所以观感就是面板在缩放上移；遮罩是纯色，
   *    缩放过程与同时进行的透明度淡入叠加后不可见，且与播放器选项弹窗的实现完全一致）。
   *  - 排序只作用于已加载评论（applyCommentSort → commentSortType），不重新请求，未登录也可用。
   */
  @Builder
  commentSortOverlay() {
    Stack({ alignContent: Alignment.Center }) {
      // 遮罩：整屏半透明，拦截所有点击（点击关闭）
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Theme.colors().overlay)
        .onClick(() => {
          this.closeCommentSortMenu();
        });
      // 居中圆角面板（沉浸材质）
      this.commentSortPanel();
    }
    .width('100%')
    .height('100%')
    .zIndex(30)
    .transition(TransitionEffect.OPACITY
      .animation({ duration: COMMENT_SORT_MENU_ANIM_MS, curve: Curve.Friction })
      .combine(TransitionEffect.scale({ x: 0.94, y: 0.94 })
        .animation({ duration: COMMENT_SORT_MENU_ANIM_MS, curve: Curve.Friction }))
      .combine(TransitionEffect.translate({ y: 12 })
        .animation({ duration: COMMENT_SORT_MENU_ANIM_MS, curve: Curve.Friction })));
  }

  /**
   * 评论工具行（输入框正上方，高 40）：左侧排序胶囊 + 右侧独立圆形刷新钮。
   *
   * - 刷新钮直径 40 / 圆角 20，材质 / 描边与悬浮输入框同源：GlassCapsule(capsuleHeight 40 /
   *   capsuleRadius 20 / kind 'composer')，内置系统沉浸材质与「chipTint + 薄模糊 + 描边」降级；
   * - 刷新点击沿用 commentReloadToken 自增触发 CommentSection 重新拉首屏（与旧表头「刷新」一致）；
   * - 排序胶囊点击弹 `openCommentSortMenu()`，只重排当前列表、不重新请求；
   * - 外层通栏 Row 用 HitTestMode.Transparent：Row 自身与子节点（胶囊 / 圆钮）都参与命中测试，
   *   两个按钮因此有确定的命中链；同时 Transparent 不阻塞兄弟节点，胶囊与圆钮之间由 Blank 占的
   *   空白区域仍可拖拽滚动下方评论列表。
   *   这里不再用 None —— None 会把 Row 自身从命中链里摘掉（只剩子节点参与），按钮的可点性完全
   *   取决于子节点与宿主链，语义不明确；Transparent 同时满足「按钮可点」与「不挡下层手势」。
   */
  @Builder
  commentRefreshButton() {
    Row() {
      this.commentSortPill();
      Blank();
      Stack({ alignContent: Alignment.Center }) {
        GlassCapsule({
          capsuleHeight: COMMENT_REFRESH_SIZE,
          capsuleRadius: COMMENT_REFRESH_SIZE / 2,
          kind: 'composer'
        }) {
          Column()
            .width('100%')
            .height(COMMENT_REFRESH_SIZE)
            .backgroundColor(Color.Transparent)
            .hitTestBehavior(HitTestMode.None);
        }
        // 描边层（材质之上、↻ 文字之下）：与 commentSortPill 内容层同一套 glassBorder 细描边，
        // 浅色主题下即站点排序按钮那种灰色细边；透明底 + 命中穿透，不改圆钮尺寸 / 位置 / 点击逻辑。
        Row()
          .width(COMMENT_REFRESH_SIZE)
          .height(COMMENT_REFRESH_SIZE)
          .borderRadius(COMMENT_REFRESH_SIZE / 2)
          .backgroundColor(Color.Transparent)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .hitTestBehavior(HitTestMode.None);
        Text('↻')
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.colors().textSecondary);
      }
      .width(COMMENT_REFRESH_SIZE)
      .height(COMMENT_REFRESH_SIZE)
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
      .onClick(() => {
        // 增量 token 触发 CommentSection 的 @Watch 重新拉首屏
        this.commentReloadToken = this.commentReloadToken + 1;
      });
    }
    .width('100%')
    .height(COMMENT_REFRESH_SIZE)
    .margin({ bottom: COMMENT_REFRESH_GAP })
    .alignItems(VerticalAlign.Center)
    // Transparent：胶囊 / 圆钮正常响应点击，透明通栏 Row 自身不阻塞下方评论列表的点击 / 滚动
    .hitTestBehavior(HitTestMode.Transparent);
  }

  /**
   * 悬浮评论输入框距 Tab 内容区底部的间距（vp）。
   *
   * 键盘态为**手动避让**（见 `KEYBOARD_MANUAL_AVOID` 与 `setKeyboardAvoidManual`）：
   *  - 键盘收起：navBarHeight + 4（避让系统导航条，与列表底部留白同一档）；
   *  - 键盘弹起（keyboardHeight > 0）：keyboardHeight + 12 —— 输入条精确抬到输入法上沿，
   *    再留 12vp 呼吸，保证输入框本体 / 发送按钮完整可见可点；
   *  - 若设备上手动避让不可用（setKeyboardAvoidMode 失败），仍保留 navBarHeight + 4 的兜底，
   *    此时由系统默认 OFFSET 避让负责上抬。
   */
  composerBottomMargin(): number {
    // 只有「手动避让确实生效（NONE 已设置成功）+ 键盘高度已知」时才按键盘高度精确上抬；
    // 若系统避让模式切换失败，保持较小的底部间距，交给系统 OFFSET 避让，避免双份偏移。
    if (KEYBOARD_MANUAL_AVOID && this.keyboardManualMode && this.keyboardHeight > 0) {
      return this.keyboardHeight + 12;
    }
    return this.navBarHeight + 4;
  }

  /**
   * 评论列表底部需要为悬浮输入框留出的高度（vp）：
   * 输入框高 48 + 8 与最后一条评论的呼吸间距 + 输入框距页面底部的间距（composerBottomMargin）。
   * 键盘态下间距已包含 keyboardHeight + 12，因此列表底部预留会同步增长，
   * 最后一条评论能滚到键盘上方而不是被输入框 / 输入法挡住。
   * CommentSection 自身还会再加 12 底部 padding。
   */
  commentComposerReservedHeight(): number {
    return COMPOSER_HEIGHT + 8 + this.composerBottomMargin();
  }

  /**
   * 悬浮评论输入框：左右 12 + 高 48 + 圆角 24（PuraPily 风格，原 56 / 28 收紧）。
   * 输入框正上方右侧另有独立圆形刷新钮（`commentRefreshButton()`，间距 8、右对齐），
   * 两者在同一 Column 内一起做键盘避让。
   *
   * 层级（Stack，自下而上；尺寸恒为 48 / 圆角 24，不随键盘改变）：
   *  1. `composerSolidBackdrop()` 保险实底：常驻最底层，但**只在系统沉浸材质不可用时可见**
   *     （barTint 近不透明 + BAR_BLUR）；材质可渲染时是全透明占位，既不会盖住材质，
   *     也让「材质没渲染出来的设备/场景」下输入框仍有可读底板。
   *  2. `composerMaterialBackdrop()` 沉浸材质层：GlassCapsule(capsuleHeight 48 / capsuleRadius 24 /
   *     kind 'composer')，内部只有空的材质画布、不承载控件；与 Index 悬浮底栏同一条渲染路径
   *     （Tabs barModifier + CommonModifier.systemMaterial），**键盘收起和弹起都常驻**
   *     （不再按 keyboardHeight 增删），整层 hitTestBehavior(None)，任何情况下都不挡内容点击。
   *  3. `composerContent()` 内容层：CommentInputBar（或未登录登录胶囊），zIndex 最高，
   *     始终可见、可点。
   *
   * 键盘弹起为什么不再去掉材质：上一版为了排除「只剩沉浸材质」把键盘态换成实底，
   * 用户反馈材质消失。真正的根因是控件曾放在材质宿主子树里、被窗口避让后的重新合成盖住；
   * 现在控件是材质层的**兄弟层**（zIndex 3），结构上排除「背景盖住内容」，
   * 材质层只剩背景，键盘态保留它不会影响输入框 / 按钮的可见与点击。
   *
   * 键盘态变化：输入框聚焦时窗口避让模式切 `KeyboardAvoidMode.NONE`（手动避让），
   * composerBottomMargin 从 navBarHeight + 4 变成 keyboardHeight + 12，输入条随键盘精确上抬；
   * 失焦后恢复系统 OFFSET 避让。背景层与内容层都不重建（TextArea / Button 实例稳定，输入中的文字不丢）。
   * 不参与 Tab 切换动画：输入条常驻最终态（无 opacity/translate 入场），切换 tab 时不会闪一下。
   *
   * 命中测试：本 Column 是 commentTab 的 Stack 里最上层节点，整层设为 HitTestMode.Transparent ——
   * 子节点（输入框 / 排序胶囊 / 刷新钮）照常响应点击，但本层不阻塞兄弟节点，
   * 「工具行（排序胶囊 + 刷新钮）及其之间的空白」不再挡住下方评论列表的点击 / 滚动。
   */
  @Builder
  floatingComposer() {
    Column() {
      // 输入框正上方、右侧对齐的独立圆形刷新钮（未登录也显示，点击重新拉列表）
      this.commentRefreshButton();
      Stack({ alignContent: Alignment.Center }) {
        // 第 1 层（最底）：保险实底，材质可渲染时全透明（见 composerMaterialReady）
        this.composerSolidBackdrop();
        // 第 2 层：沉浸材质层，键盘收起 / 弹起都常驻
        this.composerMaterialBackdrop();
        // 第 3 层（最顶）：输入条内容，永远在背景之上
        this.composerContent();
      }
      .width('100%')
      .height(COMPOSER_HEIGHT);
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding })
    .margin({ bottom: this.composerBottomMargin() })
    // Transparent：输入条 / 排序胶囊 / 刷新钮（子节点）照常响应点击，但本 Column 不阻塞兄弟节点，
    // 因此「排序胶囊 + 刷新钮 + 两者中间的空白」这一条区域不再挡住下方评论列表的点击 / 滚动
    // （Stack 里本层是最上层节点；保持默认 Default 时会把整条区域的下层手势全部拦截）。
    .hitTestBehavior(HitTestMode.Transparent);
  }

  /**
   * 第 1 层（最底）：保险实底，与输入框同尺寸同圆角、命中穿透。
   *  - 材质可渲染：全透明 + 不做模糊（纯占位，绝不盖住上方的沉浸材质）；
   *  - 材质不可用：barTint 近不透明 + BAR_BLUR，低版本 / 未开启沉浸光效时也能保证底板可读。
   */
  @Builder
  composerSolidBackdrop() {
    Row()
      .width('100%')
      .height(COMPOSER_HEIGHT)
      .borderRadius(COMPOSER_HEIGHT / 2)
      .backgroundColor(this.composerMaterialReady ? '#00000000' : Theme.colors().barTint)
      .backgroundBlurStyle(this.composerMaterialReady ? BlurStyle.NONE : Glass.BAR_BLUR)
      .hitTestBehavior(HitTestMode.None)
      .zIndex(0);
  }

  /**
   * 第 2 层：沉浸材质（GlassCapsule / kind 'composer'），键盘收起 / 弹起都常驻。
   * 尺寸与输入框完全一致（宽 100% / 高 48 / 圆角 24）：外层 Column 显式同尺寸，
   * 避免材质层比内容层高 / 宽导致错位。
   * 背景层内部不承载控件（传一个空的 48 高占位作为 content）—— 材质只画背景，
   * 控件全部在 `composerContent()` 这个兄弟层里；整层自身命中穿透（子级为空、无可点区域），
   * 不会挡住上方输入条的点击 / 输入。材质不可用时 GlassCapsule 内部自动回退到
   * chipTint + CHIP_BLUR + 描边，最底层还有 `composerSolidBackdrop()` 兜底，保证底板可读。
   */
  @Builder
  composerMaterialBackdrop() {
    Column() {
      GlassCapsule({ capsuleHeight: COMPOSER_HEIGHT, capsuleRadius: COMPOSER_HEIGHT / 2, kind: 'composer' }) {
        Column()
          .width('100%')
          .height(COMPOSER_HEIGHT)
          // 描边：与 commentSortPill 同口径的 1vp glassBorder（浅色 = 灰色细边，深色 = 半透明白边），
          // 画在沉浸材质之上、输入内容之下；圆角与胶囊一致（COMPOSER_HEIGHT / 2），避免描边在圆角处被裁切。
          .borderRadius(COMPOSER_HEIGHT / 2)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .backgroundColor(Color.Transparent)
          .hitTestBehavior(HitTestMode.None);
      }
    }
    .width('100%')
    .height(COMPOSER_HEIGHT)
    .hitTestBehavior(HitTestMode.None)
    .zIndex(1);
  }

  /** 第 3 层：输入条真正的内容（登录态：输入框 + 发送 + 取消回复；未登录：登录引导胶囊） */
  @Builder
  composerContent() {
    Column() {
      if (this.loggedIn) {
        CommentInputBar({
          placeholder: this.panelReplyName.length > 0 ? ('回复 @' + this.panelReplyName + '…') : '说点什么…',
          replyToName: this.panelReplyName,
          sending: this.panelSending,
          material: true,
          // 评论数移入输入胶囊内部左侧（12 号次级色小标签，不占列表顶部空间）
          commentCount: this.commentCount,
          countLabel: this.commentTitle(),
          onFocusChange: (focused: boolean) => {
            this.onComposerFocusChange(focused);
          },
          onSend: (text: string) => {
            this.commentHandle.submit(text);
          },
          onCancelReply: () => {
            this.commentHandle.cancelReply();
          }
        });
      } else {
        Row() {
          // 未登录胶囊同样在左侧显示评论数（样式与登录态输入条内标签一致）
          Text(this.commentTitle())
            .fontSize(12)
            .fontColor(Theme.colors().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 80 })
            .margin({ right: 8 });
          Text('登录后参与评论')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textSecondary)
            .layoutWeight(1);
          Button('去登录')
            .fontSize(12)
            .height(32)
            .borderRadius(16)
            .backgroundColor(Theme.colors().primary)
            .fontColor(Theme.colors().onPrimary)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Router.openLogin();
            });
        }
        .width('100%')
        .height('100%')
        .padding({ left: 16, right: 8 })
        .alignItems(VerticalAlign.Center);
      }
    }
    .width('100%')
    .height(COMPOSER_HEIGHT)
    // 内容层永远盖在背景层之上：即使材质宿主重新合成，也不会遮住输入框 / 按钮
    .zIndex(3);
  }

  // ---------------------------------------------------------------------------
  // UI：单列页面骨架
  // ---------------------------------------------------------------------------

  /**
   * 「简介 / 评论 / 相关推荐」Tabs 上方的拖拽把手：播放器黑底上的白色小圆角条（36×4，圆角 2，白色 65%），
   * 外层 16vp 通栏热区承载手势（不侵占播放器与下方列表的滚动 / 点击）：
   *  - 按住上滑超过 48 → **直接折叠隐藏播放器**（拖动过程中播放器高度实时收缩到 0）；
   *  - 折叠态下滑超过 48 → 恢复播放器展开；展开态下滑超过 48 → 进入页内全屏；
   *  - 轻点把手 → 展开 / 折叠隐藏切换。
   * 热区恒为通栏、底色为播放器黑（playerBg）：
   *  - 展开态：这条黑底位于播放器正下方，白色把手落在黑底上（浅色 / 深色主题都清晰）；
   *  - 折叠态：播放器高度为 0，这条 16vp 黑底直接接在状态栏黑底下方，与状态栏连成一条，
   *    把手仍然可见（用户可下滑恢复播放器 / 轻点展开），Tabs 紧跟在把手下方；
   *    若开启「常显播放进度条」，折叠态由本页在热区最顶部补画一条 3vp 细进度条
   *    （InlinePlayer 的常显进度条随折叠画面一起隐藏，见 collapsedProgressBar）。
   */
  @Builder
  playerDragHandle() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 折叠态：播放器画面已隐藏，常显进度条在这里补画（贴着折叠后播放器的下边缘）。
      // 折叠吸附动画期间播放器自身仍在收缩（其内部进度条可见），这里等动画结束再画，避免两条线同时出现
      if (this.playerBottomProgress && this.playerCollapsed && !this.playerSettling &&
        !this.handleDragging && !this.fs && this.collapsedProgressRatio >= 0) {
        this.collapsedProgressBar();
      }
      // 白色小圆角把手条：在 16vp 热区内垂直居中，自身不参与命中，手势由外层 Stack 处理
      Row() {
        Row()
          .width(PLAYER_HANDLE_WIDTH)
          .height(PLAYER_HANDLE_THICKNESS)
          .borderRadius(PLAYER_HANDLE_THICKNESS / 2)
          .backgroundColor('#A6FFFFFF');
      }
      .width('100%')
      .height(PLAYER_HANDLE_AREA_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .hitTestBehavior(HitTestMode.None);
    }
    .width(this.contentWidth())
    .height(PLAYER_HANDLE_AREA_HEIGHT)
    .backgroundColor(Theme.colors().playerBg)
    // 竖直拖拽 + 轻点：Exclusive 组合保证拖拽成立时不会同时触发点击切换
    .gesture(
      GestureGroup(GestureMode.Exclusive,
        TapGesture({ count: 1 })
          .onAction(() => {
            this.togglePlayerCollapsed();
          }),
        PanGesture({ direction: PanDirection.Vertical })
          .onActionStart(() => {
            this.startHandleDrag();
          })
          .onActionUpdate((event: GestureEvent) => {
            this.updateHandleDrag(event.offsetY);
          })
          .onActionEnd(() => {
            this.finishHandleDrag();
          })
          .onActionCancel(() => {
            this.cancelHandleDrag();
          })
      )
    );
  }

  /**
   * 横屏分栏分隔条（左侧播放器 / 右侧 Tabs 之间）：
   *  - 10vp 宽热区，竖向铺满分栏高度（状态栏下方 → 窗口底部），叠在播放器与内容层之上；
   *  - 中间 4×40 圆角抓手 + 一条竖向发丝线帮助视觉分界，拖拽中抓手 / 分界线高亮为主色；
   *  - PanGesture 横向拖拽：实时改 splitRatio（夹取 45%~80%），只改页面布局状态，
   *    不触碰播放器实例 / 播放状态（播放器几何由 playerAreaWidth 单实例驱动，不重建）。
   */
  @Builder
  landscapeDivider() {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width(0.5)
        .height('100%')
        .backgroundColor(this.dividerDragging ? Theme.colors().primary : Theme.colors().divider);
      // 圆角抓手：外层 10vp 宽、40 高，自身不参与命中（手势由外层 Stack 统一处理）
      Column() {
        Row()
          .width(SPLIT_HANDLE_WIDTH)
          .height(SPLIT_HANDLE_HEIGHT)
          .borderRadius(SPLIT_HANDLE_WIDTH / 2)
          .backgroundColor(this.dividerDragging ? Theme.colors().primary : Theme.colors().glassBorder);
      }
      .width(SPLIT_DIVIDER_WIDTH)
      .height(SPLIT_HANDLE_HEIGHT)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .hitTestBehavior(HitTestMode.None);
    }
    .width(SPLIT_DIVIDER_WIDTH)
    .height(this.viewportHeight - this.statusBarHeight)
    .position({ x: this.splitLeftWidth(), y: this.statusBarHeight })
    .backgroundColor(this.dividerDragging ? Theme.colors().chipTint : Color.Transparent)
    .gesture(
      PanGesture({ direction: PanDirection.Horizontal })
        .onActionStart(() => {
          this.startDividerDrag();
        })
        .onActionUpdate((event: GestureEvent) => {
          this.updateDividerDrag(event.offsetX);
        })
        .onActionEnd(() => {
          this.finishDividerDrag();
        })
        .onActionCancel(() => {
          this.finishDividerDrag();
        })
    );
  }

  /** 页面内容层（播放器下方 / 横屏右侧）：竖屏时把手 + Tabs 紧跟播放器，横屏时为右侧 Tabs 面板；全屏时整体隐藏 */
  @Builder
  contentLayer() {
    Column() {
      // 竖屏：Tabs 顶部的白色折叠 / 全屏拖拽把手；横屏分栏不显示（分隔条承担分栏手势，折叠入口隐藏）
      if (!this.landscapeLayout()) {
        this.playerDragHandle();
      }
      this.tabsBlock();
    }
    .width('100%')
    .height('100%')
    // 竖屏：播放器高度 / 折叠态 / 拖动位移都从这里取，与 playerLayer 的几何严格同步
    // （展开态 padding-top = statusBarHeight + 播放器高度；折叠态 = statusBarHeight，把手接在状态栏黑底下方）。
    // 横屏分栏：内容层铺满窗口，用左 padding 让出「左侧播放器 + 分隔条」的宽度，Tabs 从状态栏下方开始。
    .padding({
      left: this.landscapeLayout() ? this.splitLeftWidth() + SPLIT_DIVIDER_WIDTH : 0,
      top: this.landscapeLayout() ? this.statusBarHeight : this.statusBarHeight + this.playerAreaHeight()
    })
    // 关键：内容层是一个全屏容器，padding 区域正好压在播放器上。
    // 容器自身不参与命中（子节点 Tabs / 列表照常响应），否则会挡住播放器手势层 —— 这正是
    // 上一轮「播放器无法点击」的根因（透明/空容器也会参与命中测试，阻塞下层兄弟节点）。
    .hitTestBehavior(HitTestMode.None)
    .visibility(this.fs ? Visibility.None : Visibility.Visible);
  }

  @Builder
  errorLayer() {
    Column() {
      ErrorStateView({
        message: this.errorMsg,
        cloudflare: this.cloudflare,
        baseUrl: AppSettings.getInstance().getBaseUrl(),
        onRetry: () => {
          this.reload(true);
        }
      });
    }
    .width('100%')
    .height('100%');
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 状态栏黑底：播放器从 y = statusBarHeight 开始，状态栏高度区域原本会露出页面灰底；
      // 这里铺一层通栏纯黑（最底层、命中穿透），非全屏 / 全屏（被播放器完全覆盖）都成立。
      Row()
        .width('100%')
        .height(this.statusBarHeight)
        .backgroundColor('#000000')
        .hitTestBehavior(HitTestMode.None);

      if (this.loading) {
        this.loadingPlaceholder();
      } else if (this.errorMsg.length > 0) {
        this.errorLayer();
      } else {
        // 横屏分栏左侧黑底：播放器高度让出底部导航条后，剩余区域也保持纯黑，
        // 视觉上「状态栏下方 → 导航条上方」是一整块播放器区域（放在播放器层下方，不参与命中）。
        if (this.landscapeLayout()) {
          Row()
            .width(this.splitLeftWidth())
            .height(this.viewportHeight - this.statusBarHeight)
            .position({ x: 0, y: this.statusBarHeight })
            .backgroundColor(Theme.colors().playerBg)
            .hitTestBehavior(HitTestMode.None);
        }
        // 播放器永远只创建一个实例：全屏 / 折叠 / 横屏分栏只改变它的容器几何，避免重建 AVPlayer / XComponent
        this.playerLayer();
        this.contentLayer();
        // 横屏分栏分隔条：叠在播放器与右侧内容层之上，PanGesture 横向拖拽调整比例
        if (this.landscapeLayout()) {
          this.landscapeDivider();
        }
      }

      // 评论排序弹窗（自定义沉浸材质面板）：根 Stack 最后一项 + zIndex 30，
      // 盖在评论悬浮输入框 / 控制层之上；全屏遮罩拦截点击，点遮罩 / 关闭钮 / 选中项都会关闭。
      if (this.commentSortMenuOpen) {
        this.commentSortOverlay();
      }

      // 作者作品二级面板：同样是全屏遮罩 + 居中沉浸材质面板，根 Stack 最后一项 + zIndex 30。
      // 打开入口是简介卡作者行右侧「作品 ▼」胶囊；网格在面板内独立滚动，不与简介页 Scroll 冲突。
      if (this.authorWorksPanelOpen) {
        this.authorWorksPanelOverlay();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.fs ? Theme.colors().playerBg : Color.Transparent)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.updateLayout(newValue);
    })
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      this.onPageVisibilityChanged(isVisible, currentRatio);
    });
  }
}

/**
 * 简介页动作按钮，对齐安卓 `VideoActionButton`（VideoIntroductionScreen.kt:1546）：
 * 图标在上、文字在下、最小宽 76、圆角 14、选中态整块用 primary 底色。
 *
 * 为什么单独抽成 @Component 而不是 @Builder：需要「点击 + 长按」两种手势共用同一节点，
 * 抽成组件后 onTap/onLongTap 作为普通成员传入，比把闭包塞进 @Builder 参数更稳（ArkTS 1.0 限制少）。
 */
@Component
struct VideoActionButton {
  @Prop label: string = '';
  @Prop icon: string = '';
  @Prop active: boolean = false;
  onTap: () => void = () => {
  };
  onLongTap: () => void = () => {
  };

  build() {
    Column() {
      Text(this.icon)
        .fontSize(20)
        .fontColor(this.active ? Theme.colors().onPrimary : Theme.colors().primary);
      Text(this.label)
        .fontSize(11)
        .maxLines(1)
        .fontColor(this.active ? Theme.colors().onPrimary : Theme.colors().textPrimary)
        .margin({ top: 6 });
    }
    .constraintSize({ minWidth: 76 })
    .padding({ left: 10, right: 10, top: 8, bottom: 8 })
    .borderRadius(14)
    .backgroundColor(this.active ? Theme.colors().primary : Theme.colors().chipTint)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      this.onTap();
    })
    .gesture(LongPressGesture({ repeat: false, duration: 500 })
      .onAction(() => {
        this.onLongTap();
      }));
  }
}

/**
 * 「正在播放」徽标：作者作品面板里标出当前这条视频，并给三根跳动的音量条做播放动画。
 *
 * 为什么要自绘动画而不直接用 LoadingProgress：原版的「正在播放」是一个小音量条动效，
 * 转圈会和「加载中」混淆。三根条用 260ms 定时器改高度 + 200ms 补间，
 * 关掉面板（组件销毁）时清掉定时器，不会在后台空转。
 */
@Component
struct NowPlayingBadge {
  @State bar1: number = 8;
  @State bar2: number = 14;
  @State bar3: number = 10;
  private timerId: number = -1;
  /** 三根条的候选高度（vp）：交替取值形成跳动感，不做随机，保证可复现、不会剧烈闪烁 */
  private static readonly LEVELS: number[] = [6, 10, 14, 16, 12, 8];

  aboutToAppear(): void {
    let tick: number = 0;
    this.timerId = setInterval(() => {
      tick = tick + 1;
      const levels: number[] = NowPlayingBadge.LEVELS;
      const n: number = levels.length;
      animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
        this.bar1 = levels[(tick) % n];
        this.bar2 = levels[(tick * 2 + 1) % n];
        this.bar3 = levels[(tick * 3 + 2) % n];
      });
    }, 260);
  }

  aboutToDisappear(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  build() {
    Row({ space: 3 }) {
      Row()
        .width(2.5)
        .height(this.bar1)
        .borderRadius(2)
        .backgroundColor('#FFFFFF');
      Row()
        .width(2.5)
        .height(this.bar2)
        .borderRadius(2)
        .backgroundColor('#FFFFFF');
      Row()
        .width(2.5)
        .height(this.bar3)
        .borderRadius(2)
        .backgroundColor('#FFFFFF');
      Text('正在播放')
        .fontSize(10)
        .fontColor('#FFFFFF')
        .margin({ left: 3 });
    }
    .padding({ left: 6, right: 6, top: 3, bottom: 3 })
    .margin({ left: 6, top: 6 })
    .borderRadius(6)
    .backgroundColor('rgba(0,0,0,0.62)')
    .alignItems(VerticalAlign.Center);
  }
}
