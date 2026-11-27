/**
 * Han1meViewer HarmonyOS —— 领域模型。
 *
 * 本文件是纯 TypeScript（可被 Node 直接执行，用于解析层单元测试），
 * 同时会被 ArkTS 编译。因此遵守 ArkTS 限制：
 *  - 不使用 `any`、`enum`、动态属性访问、对象展开；
 *  - 只使用 interface / 普通字段 / 显式构造；
 *  - 时间统一用毫秒时间戳 number 或 ISO 字符串 string。
 */

/** 视频条目（列表卡片）类型：0 = 普通（v2 版式），1 = 简化版式 */
export const ITEM_TYPE_NORMAL = 0;
export const ITEM_TYPE_SIMPLIFIED = 1;

/** 首页 banner */
export interface Banner {
  title: string;
  description: string;
  picUrl: string;
  videoCode: string;
}

/**
 * 视频条目（卡片）。对应 Android 的 HanimeInfo。
 * coverUrl 为绝对地址；views / duration / reviews 是站点上的展示文本，保持原样。
 */
export interface HanimeInfo {
  title: string;
  coverUrl: string;
  videoCode: string;
  duration: string;
  views: string;
  uploadTime: string;
  genre: string;
  reviews: string;
  currentArtist: string;
  /** 0 = 普通，1 = 简化 */
  itemType: number;
  /** 播放列表内条目 id（站点 DOM id），无则为空串 */
  playlistItemId: string;
  /** 是否为当前正在播放的条目（仅系列播放列表使用） */
  isPlaying: boolean;
}

/** 首页各分区 */
export interface HomePage {
  csrfToken: string;
  avatarUrl: string;
  username: string;
  userId: string;
  banner: Banner | null;
  latestRelease: HanimeInfo[];
  latestHanime: HanimeInfo[];
  ecchiAnime: HanimeInfo[];
  shortEpisodeAnime: HanimeInfo[];
  motionAnime: HanimeInfo[];
  threeDCG: HanimeInfo[];
  twoPointFiveDAnime: HanimeInfo[];
  twoDAnime: HanimeInfo[];
  aiGenerated: HanimeInfo[];
  mmd: HanimeInfo[];
  cosplay: HanimeInfo[];
  watchingNow: HanimeInfo[];
  newAnimeTrailer: HanimeInfo[];
  /** 抓取时间戳（毫秒） */
  timestamp: number;
}

/** 搜索结果（一页） */
export interface SearchPage {
  list: HanimeInfo[];
  /** 站点允许的最后页码，用于"是否还有下一页" */
  maxPage: number;
}

/** 搜索请求参数（对应站点 /search 的 query 参数） */
export interface SearchRequest {
  page: number;
  query: string;
  genre: string;
  sort: string;
  /** broad=on 时是"广泛搜索" */
  broad: boolean;
  date: string;
  duration: string;
  tags: string[];
  brands: string[];
}

/** 视频清晰度/线路 → 播放地址 */
export interface VideoSource {
  /** 例如 "1080P" / "720P" / "auto" */
  resolution: string;
  /** 绝对播放地址（m3u8 或 mp4） */
  url: string;
  /** MIME 类型，可能为空串 */
  type: string;
}

/** 作者 */
export interface Artist {
  name: string;
  avatarUrl: string;
  genre: string;
  userId: string;
  artistId: string;
  isSubscribed: boolean;
}

/** 用户播放清单（站点"我的清单"）里的一个条目 */
export interface MyListInfo {
  code: string;
  title: string;
  isSelected: boolean;
}

/** 视频页的"我的清单"状态 */
export interface MyList {
  isWatchLater: boolean;
  myListInfo: MyListInfo[];
}

/** 系列播放列表 */
export interface Playlist {
  playlistName: string;
  video: HanimeInfo[];
}

/** 视频详情 */
export interface HanimeVideo {
  videoCode: string;
  title: string;
  chineseTitle: string;
  introduction: string;
  coverUrl: string;
  uploadTime: string;
  views: string;
  /** 视频页上的点赞/点踩数，-1 表示未解析到 */
  favTimes: number;
  unlikesCount: number;
  isFav: boolean;
  isUnlike: boolean;
  csrfToken: string;
  currentUserId: string;
  tags: string[];
  sources: VideoSource[];
  myList: MyList | null;
  playlist: Playlist | null;
  relatedHanimes: HanimeInfo[];
  artist: Artist | null;
  originalComic: string;
  /** 视频页评论总数（#tab-comments-count） */
  commentCount: number;
}

/** 评论点赞/点踩/举报相关的表单数据 */
export interface VideoCommentPost {
  foreignId: string;
  isPositive: boolean;
  commentLikesCount: number;
  commentLikesSum: number;
  likeCommentStatus: boolean;
  unlikeCommentStatus: boolean;
}

/** 一条评论（含子评论） */
export interface VideoComment {
  avatar: string;
  username: string;
  date: string;
  content: string;
  /** 点赞数，-1 表示未登录/未解析 */
  thumbUp: number;
  isChildComment: boolean;
  hasMoreReplies: boolean;
  replyCount: number;
  id: string;
  post: VideoCommentPost;
  redirectUrl: string;
  reportableId: string;
  reportableType: string;
}

/** 评论列表 / 一页评论 */
export interface VideoComments {
  comments: VideoComment[];
  currentUserId: string;
  csrfToken: string;
  hasMoreComments: boolean;
  /** 下一页 offset，-1 表示没有 */
  nextCommentOffset: number;
}

/** 发表评论 / 回复的响应 */
export interface PostCommentResult {
  /** 新评论；解析失败为 null */
  comment: VideoComment | null;
  /** 新评论总数（仅创建主评论返回），-1 表示无 */
  commentCount: number;
  /** 父评论 id（仅回复返回），空串表示无 */
  parentCommentId: string;
}

/** 账号资料 */
export interface UserAccount {
  csrfToken: string;
  avatarUrl: string;
  username: string;
  email: string;
  emailEditable: boolean;
  userId: string;
  joinedLabel: string;
  subscriberCount: number;
  videoCount: number;
}

/** 收藏/稍后观看/历史 等用户清单的一页 */
export interface MyListPage {
  items: HanimeInfo[];
  desc: string;
  csrfToken: string;
  maxPage: number;
}

/** "我的播放清单"列表项 */
export interface PlaylistSummary {
  listCode: string;
  title: string;
  total: number;
  coverUrl: string;
}

/** 播放清单列表页 */
export interface PlaylistsPage {
  playlists: PlaylistSummary[];
  csrfToken: string;
  maxPage: number;
}

/** 本地收藏（HarmonyOS 端本地库） */
export interface LocalVideoRecord {
  videoCode: string;
  title: string;
  coverUrl: string;
  uploadTime: string;
  genre: string;
  /** 添加时间戳（毫秒） */
  addedAt: number;
}

/** 本地观看历史 */
export interface HistoryRecord {
  videoCode: string;
  title: string;
  coverUrl: string;
  /** 上次播放位置（毫秒） */
  positionMs: number;
  /** 视频总时长（毫秒），未知为 0 */
  durationMs: number;
  /** 最后观看时间戳（毫秒） */
  updatedAt: number;
}

/** 本站抓取到的搜索筛选项（来自 rawfile/search_options） */
export interface SearchOptionItem {
  /** 展示用（当前语言） */
  label: string;
  /** 提交给站点的值；空串表示"全部" */
  key: string;
}

/** 视频清晰度列表里的一项（播放器使用） */
export interface QualityOption {
  label: string;
  url: string;
}

// ---------------------------------------------------------------------------
// 空对象工厂：ArkUI 的 struct 成员需要默认值，这里提供统一的空实例，
// 避免每个页面重复写字面量。
// ---------------------------------------------------------------------------

export function emptyHanimeInfo(): HanimeInfo {
  const info: HanimeInfo = {
    title: '',
    coverUrl: '',
    videoCode: '',
    duration: '',
    views: '',
    uploadTime: '',
    genre: '',
    reviews: '',
    currentArtist: '',
    itemType: ITEM_TYPE_NORMAL,
    playlistItemId: '',
    isPlaying: false
  };
  return info;
}

export function emptyHomePage(): HomePage {
  const page: HomePage = {
    csrfToken: '',
    avatarUrl: '',
    username: '',
    userId: '',
    banner: null,
    latestRelease: [],
    latestHanime: [],
    ecchiAnime: [],
    shortEpisodeAnime: [],
    motionAnime: [],
    threeDCG: [],
    twoPointFiveDAnime: [],
    twoDAnime: [],
    aiGenerated: [],
    mmd: [],
    cosplay: [],
    watchingNow: [],
    newAnimeTrailer: [],
    timestamp: 0
  };
  return page;
}

export function emptyVideoComment(): VideoComment {
  const post: VideoCommentPost = {
    foreignId: '',
    isPositive: false,
    commentLikesCount: 0,
    commentLikesSum: 0,
    likeCommentStatus: false,
    unlikeCommentStatus: false
  };
  const comment: VideoComment = {
    avatar: '',
    username: '',
    date: '',
    content: '',
    thumbUp: -1,
    isChildComment: false,
    hasMoreReplies: false,
    replyCount: 0,
    id: '',
    post: post,
    redirectUrl: '',
    reportableId: '',
    reportableType: ''
  };
  return comment;
}

export function emptyUserAccount(): UserAccount {
  const account: UserAccount = {
    csrfToken: '',
    avatarUrl: '',
    username: '',
    email: '',
    emailEditable: false,
    userId: '',
    joinedLabel: '',
    subscriberCount: 0,
    videoCount: 0
  };
  return account;
}

export function emptyHanimeVideo(): HanimeVideo {
  const video: HanimeVideo = {
    videoCode: '',
    title: '',
    chineseTitle: '',
    introduction: '',
    coverUrl: '',
    uploadTime: '',
    views: '',
    favTimes: -1,
    unlikesCount: -1,
    isFav: false,
    isUnlike: false,
    csrfToken: '',
    currentUserId: '',
    tags: [],
    sources: [],
    myList: null,
    playlist: null,
    relatedHanimes: [],
    artist: null,
    originalComic: '',
    commentCount: 0
  };
  return video;
}
