/**
 * 「我的订阅」领域模型（纯 TypeScript，ArkTS 可编译）。
 *
 * 对应 Android 上游 `logic/model/MySubscriptions.kt`：
 *  - `MySubscriptions`       ← 页面数据（作者列表 + 视频更新 + 总页数）
 *  - `SubscriptionArtist`    ← `MySubscriptions.kt` 的 `SubscriptionItem`
 *  - `SubscriptionVideo`     ← `MySubscriptions.kt` 的 `SubscriptionVideosItem`
 *
 * 与上游的差异：上游字段全部可空（`String?`）；这里统一用空串表示「未解析到」，
 * 避免 ArkUI 模板里到处判 null。`length > 0` 即等价于上游的非空判断。
 */

/** 已订阅作者（作者卡片） */
export interface SubscriptionArtist {
  /** 作者名（`div.card-mobile-title` 文本） */
  artistName: string;
  /** 头像绝对地址（卡片内第 2 个 img 的 src，第 1 个通常是封面/背景） */
  avatar: string;
}

/** 订阅作者的最新投稿（视频卡片） */
export interface SubscriptionVideo {
  /** 标题（视频卡片 `title` 属性） */
  title: string;
  /** 封面绝对地址（`img[class^=main-thumb]` 的 src） */
  coverUrl: string;
  /** 站点视频编号（`watch?v=(\d+)`） */
  videoCode: string;
  /** 时长展示文本，如 `02:29:45` */
  duration: string;
  /** 播放量展示文本，如 `32.4萬次` */
  views: string;
  /** 好评率展示文本（`.stats-container .stat-item` 的 ownText），如 `100%` */
  reviews: string;
  /** 作者名（`div.subtitle` 里 `•` 前半段） */
  currentArtist: string;
  /** 上传时间展示文本（`div.subtitle` 里 `•` 后半段），如 `10個月前` */
  uploadTime: string;
}

/** 「我的订阅」一页数据 */
export interface MySubscriptions {
  /** 当前页里的已订阅作者（第 1 页才是完整作者列表，翻页时站点可能重复返回） */
  artists: SubscriptionArtist[];
  /** 当前页里的订阅视频更新 */
  videos: SubscriptionVideo[];
  /** 站点允许的最大页码（`ul.pagination`），无分页时 1 */
  maxPage: number;
}

/** 空作者对象（ArkUI @State 默认值用） */
export function emptySubscriptionArtist(): SubscriptionArtist {
  const artist: SubscriptionArtist = {
    artistName: '',
    avatar: ''
  };
  return artist;
}

/** 空视频对象（ArkUI @State 默认值用） */
export function emptySubscriptionVideo(): SubscriptionVideo {
  const video: SubscriptionVideo = {
    title: '',
    coverUrl: '',
    videoCode: '',
    duration: '',
    views: '',
    reviews: '',
    currentArtist: '',
    uploadTime: ''
  };
  return video;
}

/** 空订阅页对象（页面初始状态用） */
export function emptyMySubscriptions(): MySubscriptions {
  const page: MySubscriptions = {
    artists: [],
    videos: [],
    maxPage: 1
  };
  return page;
}
