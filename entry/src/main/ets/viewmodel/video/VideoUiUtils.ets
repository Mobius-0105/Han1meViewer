/**
 * 视频详情 / 播放器 / 评论区共用的纯逻辑工具。
 *
 * 这里只放「没有 UI 状态」的函数与对象拷贝辅助：
 *  - ArkUI 的 @State 对象必须整体重新赋值才会刷新，而 HanimeVideo / VideoComment
 *    字段多且嵌套（post），所以统一在这里做显式逐字段拷贝（ArkTS 禁止对象展开）；
 *  - 比例 / 文案 / 本地记录组装之类的换算也放这里，页面保持薄。
 */

import {
  HanimeVideo,
  LocalVideoRecord,
  VideoComment,
  VideoCommentPost,
  VideoSource
} from '../../core/model/Models';

/** 数值夹取 */
export function clampNumber(value: number, min: number, max: number): number {
  if (value < min) {
    return min;
  }
  if (value > max) {
    return max;
  }
  return value;
}

/**
 * 点赞比例（百分数，0..100）。
 * favTimes / unlikesCount 为 -1 表示站点未解析到该数字，按 0 处理。
 */
export function likeRatio(video: HanimeVideo): number {
  const likes: number = video.favTimes > 0 ? video.favTimes : 0;
  const unlikes: number = video.unlikesCount > 0 ? video.unlikesCount : 0;
  const total: number = likes + unlikes;
  if (total <= 0) {
    return 0;
  }
  return clampNumber(Math.round(likes * 100 / total), 0, 100);
}

/** 拷贝评论点赞表单（字段多，避免共享引用） */
function copyCommentPost(post: VideoCommentPost): VideoCommentPost {
  const next: VideoCommentPost = {
    foreignId: post.foreignId,
    isPositive: post.isPositive,
    commentLikesCount: post.commentLikesCount,
    commentLikesSum: post.commentLikesSum,
    likeCommentStatus: post.likeCommentStatus,
    unlikeCommentStatus: post.unlikeCommentStatus
  };
  return next;
}

/** 拷贝一条评论 */
export function copyVideoComment(comment: VideoComment): VideoComment {
  const next: VideoComment = {
    avatar: comment.avatar,
    username: comment.username,
    date: comment.date,
    content: comment.content,
    thumbUp: comment.thumbUp,
    isChildComment: comment.isChildComment,
    hasMoreReplies: comment.hasMoreReplies,
    replyCount: comment.replyCount,
    id: comment.id,
    post: copyCommentPost(comment.post),
    redirectUrl: comment.redirectUrl,
    reportableId: comment.reportableId,
    reportableType: comment.reportableType
  };
  return next;
}

/**
 * 评论点赞成功后的本地状态更新（与站点前端 handleCommentLike 一致）：
 * liked 为 true 表示这次操作后处于「已赞」，false 表示取消了赞。
 * thumbUp 为 -1 表示未登录/未解析，此时不动计数。
 */
export function applyCommentLike(comment: VideoComment, liked: boolean): VideoComment {
  const next: VideoComment = copyVideoComment(comment);
  const post: VideoCommentPost = next.post;
  if (liked) {
    if (next.thumbUp >= 0) {
      next.thumbUp = next.thumbUp + 1;
    }
    post.likeCommentStatus = true;
    post.unlikeCommentStatus = false;
  } else {
    if (next.thumbUp > 0) {
      next.thumbUp = next.thumbUp - 1;
    }
    post.likeCommentStatus = false;
  }
  return next;
}

/** 回复成功后父评论的「展开 N 条回复」+1 */
export function applyReplyIncrement(comment: VideoComment): VideoComment {
  const next: VideoComment = copyVideoComment(comment);
  next.replyCount = next.replyCount + 1;
  next.hasMoreReplies = true;
  return next;
}

/** 评论列表的稳定 key：优先评论 id，缺失时用 username+date+content 组合 */
/**
 * 评论列表项 key。
 *
 * 注意：ArkUI `ForEach` 对相同 key 不会重建/更新子组件，而评论的「点赞数/点赞状态/
 * 回复数」是可变字段。因此 key 里必须带上这些字段，否则点赞/回复成功后界面不刷新
 * （详见 docs/CODE_REVIEW.md P1-1）。
 */
export function commentKey(comment: VideoComment): string {
  const mutable: string = '|t' + comment.thumbUp + '|l' + (comment.post.likeCommentStatus ? 1 : 0) +
    '|u' + (comment.post.unlikeCommentStatus ? 1 : 0) + '|r' + comment.replyCount;
  const id: string = comment.id;
  if (id.length > 0 && id !== '-1') {
    return 'id:' + id + mutable;
  }
  return 'k:' + comment.username + '|' + comment.date + '|' + comment.content + mutable;
}

/** 列表项 key（视频条目，HanimeInfo / HanimeVideo 都有 videoCode） */
export function videoCodeKey(videoCode: string): string {
  return videoCode;
}

/** 组装本地收藏/稍后再看/历史用的记录 */
export function buildLocalRecord(video: HanimeVideo): LocalVideoRecord {
  const genre: string = video.tags.length > 0 ? video.tags[0] : '';
  const record: LocalVideoRecord = {
    videoCode: video.videoCode,
    title: video.title,
    coverUrl: video.coverUrl,
    uploadTime: video.uploadTime,
    genre: genre,
    addedAt: Date.now()
  };
  return record;
}

/**
 * 视频评分（赞/踩）成功后的本地状态更新，逻辑对齐 Android HanimeVideo.rateVideo：
 *  - 赞过再点赞 = 取消赞；未赞过点赞 = 赞 +1（若之前踩过要扣掉踩）；
 *  - 同理踩。
 */
export function applyVideoRating(video: HanimeVideo, isPositive: boolean): HanimeVideo {
  const liked: boolean = video.isFav;
  const unliked: boolean = video.isUnlike;
  let likes: number = video.favTimes > 0 ? video.favTimes : 0;
  let unlikes: number = video.unlikesCount > 0 ? video.unlikesCount : 0;
  let fav: boolean = liked;
  let unlike: boolean = unliked;
  if (isPositive) {
    if (liked) {
      likes = likes - 1;
      fav = false;
    } else {
      likes = likes + 1;
      if (unliked) {
        unlikes = unlikes - 1;
      }
      fav = true;
      unlike = false;
    }
  } else {
    if (unliked) {
      unlikes = unlikes - 1;
      unlike = false;
    } else {
      if (liked) {
        likes = likes - 1;
      }
      unlikes = unlikes + 1;
      fav = false;
      unlike = true;
    }
  }
  return copyVideoWithRating(video, likes < 0 ? 0 : likes, unlikes < 0 ? 0 : unlikes, fav, unlike);
}

/** 收藏（站点 like）成功后的本地状态更新 */
export function applyVideoFavorite(video: HanimeVideo, favorite: boolean): HanimeVideo {
  const likes: number = video.favTimes > 0 ? video.favTimes : 0;
  return copyVideoWithRating(video, favorite ? likes + 1 : (likes > 0 ? likes - 1 : 0),
    video.unlikesCount, favorite, favorite ? false : video.isUnlike);
}

function copyVideoWithRating(video: HanimeVideo, favTimes: number, unlikesCount: number,
  isFav: boolean, isUnlike: boolean): HanimeVideo {
  const next: HanimeVideo = {
    videoCode: video.videoCode,
    title: video.title,
    chineseTitle: video.chineseTitle,
    introduction: video.introduction,
    coverUrl: video.coverUrl,
    uploadTime: video.uploadTime,
    views: video.views,
    favTimes: favTimes,
    unlikesCount: unlikesCount,
    isFav: isFav,
    isUnlike: isUnlike,
    csrfToken: video.csrfToken,
    currentUserId: video.currentUserId,
    tags: video.tags,
    sources: video.sources,
    myList: video.myList,
    playlist: video.playlist,
    relatedHanimes: video.relatedHanimes,
    artist: video.artist,
    originalComic: video.originalComic,
    commentCount: video.commentCount
  };
  return next;
}

/** 清晰度文案：站点一般给 "1080P" 之类；空串时退回「线路 N」 */
export function sourceLabel(source: VideoSource, index: number): string {
  if (source.resolution.length > 0) {
    return source.resolution;
  }
  return '线路 ' + (index + 1);
}

/** 清晰度徽标（720P 这类）；无分辨率信息时用 type 或「自动」 */
export function sourceBadge(source: VideoSource): string {
  if (source.resolution.length > 0) {
    return source.resolution;
  }
  if (source.type.length > 0) {
    return source.type;
  }
  return '自动';
}

/**
 * 选择初始清晰度下标：
 *  - 设置项 qualityIndex >= 0 且不越界时使用；
 *  - 否则取第 0 条（站点 sources 一般按清晰度从高到低排列）。
 */
export function resolveInitialQuality(sources: VideoSource[], configured: number): number {
  if (sources.length === 0) {
    return 0;
  }
  if (configured >= 0 && configured < sources.length) {
    return configured;
  }
  return 0;
}

/** 播放器进度条上限：时长未知时给 1，避免 Slider max=0 崩溃 */
export function sliderMaxMs(durationMs: number): number {
  return durationMs > 0 ? durationMs : 1;
}

/** 是否是可播放的媒体地址（http/https/fd），用于判断是否需要降级 */
export function isPlayableUrl(url: string): boolean {
  const value: string = url.trim();
  return value.startsWith('http://') || value.startsWith('https://') || value.startsWith('fd://');
}

/** 从简介里裁掉过多空行，避免详情页被大量空行撑高 */
export function normalizeIntroduction(text: string): string {
  return text.replace(/\r\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
}
