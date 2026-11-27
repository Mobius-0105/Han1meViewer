/**
 * “我的” Tab 与收藏 / 历史页共用的纯逻辑工具（不持有页面状态）。
 *
 * 这里只做三件事：
 *  1. 把本地库记录（LocalVideoRecord / HistoryRecord）转换成公共组件 VideoListTile /
 *     VideoCard 需要的 HanimeInfo（ArkTS 禁止对象展开，字段逐个显式赋值；本地历史缺少站点
 *     播放量 / 上传者 / 上传时间时做降级映射，避免内容库「最近观看」卡片出现空白行）；
 *  2. 生成列表副标题（收藏时间 / 观看进度 / 相对时间）；
 *  3. 维护 AppStorage 里的 “本地库版本号”：收藏/历史/设置页改动本地库后自增，
 *     “我的” Tab 用 @StorageLink + @Watch 监听并刷新计数。
 *
 * 说明：Router 没有独立的“在线历史/在线收藏/在线稍后再看/我的清单”路由，这三类在线
 * 列表都复用 FavoritesPage，通过 RouteParam.title 传模式常量进入（见 ContentLibraryPage /
 * LibraryPage）；站点收藏与稍后再看分别对应 `user/{userId}/likes` 与 `user/{userId}/saves`。
 */

import { HanimeInfo, HistoryRecord, LocalVideoRecord, emptyHanimeInfo } from '../../core/model/Models';
import { formatMs, formatRelativeTime } from '../../core/util/Format';

/** AppStorage 键：本地库变动版本号 */
export const LIBRARY_VERSION_KEY: string = 'libraryVersion';

/** FavoritesPage 的“在线历史”模式标记（透传在 RouteParam.title） */
export const FAVORITES_MODE_ONLINE: string = 'online';

/** FavoritesPage 打开时默认选中“稍后再看”Tab 的标记（透传在 RouteParam.title） */
export const FAVORITES_MODE_WATCH_LATER: string = 'watchLater';

/**
 * FavoritesPage 的“站点收藏 / 站点稍后再看”在线模式标记（透传在 RouteParam.title）。
 *
 * 与本地模式的区别：数据来自站点账号（需要登录），不是本机 LocalRepo；
 * 对应接口为 `GET user/{userId}/likes?page=` 与 `GET user/{userId}/saves?page=`，
 * 即 Android 上游 MyListType.FAV_VIDEO("likes") / WATCH_LATER("saves")。
 */
export const FAVORITES_MODE_ONLINE_LIKES: string = 'onlineLikes';
export const FAVORITES_MODE_ONLINE_WATCH_LATER: string = 'onlineWatchLater';

/** 站点“我的清单”类型参数（getMyList 的 type） */
export const MY_LIST_TYPE_LIKES: string = 'likes';
export const MY_LIST_TYPE_SAVES: string = 'saves';

/** 是否为站点在线列表模式（在线历史 / 在线收藏 / 在线稍后再看） */
export function isOnlineListMode(mode: string): boolean {
  return mode === FAVORITES_MODE_ONLINE || mode === FAVORITES_MODE_ONLINE_LIKES ||
    mode === FAVORITES_MODE_ONLINE_WATCH_LATER;
}

/** 在线列表模式的页面标题；未知模式回退到“在线历史” */
export function onlineListTitle(mode: string): string {
  if (mode === FAVORITES_MODE_ONLINE_LIKES) {
    return '收藏';
  }
  if (mode === FAVORITES_MODE_ONLINE_WATCH_LATER) {
    return '稍后再看';
  }
  return '在线历史';
}

/** getMyList 的清单类型：在线稍后再看用 saves，在线收藏用 likes */
export function onlineListType(mode: string): string {
  return mode === FAVORITES_MODE_ONLINE_WATCH_LATER ? MY_LIST_TYPE_SAVES : MY_LIST_TYPE_LIKES;
}

/** 未登录引导卡的标题（在线收藏 / 在线稍后再看 / 在线历史） */
export function onlineListLoginTitle(mode: string): string {
  if (mode === FAVORITES_MODE_ONLINE) {
    return '登录后可查看在线历史';
  }
  if (mode === FAVORITES_MODE_ONLINE_WATCH_LATER) {
    return '登录后可查看站点稍后再看';
  }
  return '登录后可查看站点收藏';
}

/** 未登录引导卡的说明文字 */
export function onlineListLoginHint(mode: string): string {
  if (mode === FAVORITES_MODE_ONLINE) {
    return '观看历史同步在站点账号中，登录后自动加载到本页';
  }
  if (mode === FAVORITES_MODE_ONLINE_WATCH_LATER) {
    return '稍后再看保存在站点账号中，登录后自动同步到本页';
  }
  return '收藏保存在站点账号中，登录后自动同步到本页';
}

/** 在线列表的空态文案（列表已加载但没有任何条目） */
export function onlineListEmptyText(mode: string): string {
  if (mode === FAVORITES_MODE_ONLINE_LIKES) {
    return '还没有收藏';
  }
  if (mode === FAVORITES_MODE_ONLINE_WATCH_LATER) {
    return '稍后再看是空的';
  }
  return '在线历史为空';
}

/** 在线列表空态的第二行提示 */
export function onlineListEmptyHint(mode: string): string {
  if (mode === FAVORITES_MODE_ONLINE_LIKES) {
    return '在站点上收藏影片后会出现在这里';
  }
  if (mode === FAVORITES_MODE_ONLINE_WATCH_LATER) {
    return '在站点上加入稍后再看后会出现在这里';
  }
  return '在站点上观看影片后会出现在这里';
}

/** 站点在线历史的排序参数（对应 Android OnlineWatchHistorySort） */
export const ONLINE_SORT_LATEST: string = 'latest';
export const ONLINE_SORT_POPULAR: string = 'popular';
export const ONLINE_SORT_OLDEST: string = 'oldest';

/** “我的” Tab 上要展示的本地计数 */
export class LibraryCounts {
  favorites: number = 0;
  watchLater: number = 0;
  history: number = 0;
}

/**
 * 通知“我的” Tab 刷新计数（收藏/稍后再看/历史/登录态变化后调用）。
 * AppStorage 是 ArkUI 全局对象，可在非组件文件里读写（common/Theme.ets 同样用法）。
 */
export function notifyLibraryChanged(): void {
  const current: number | undefined = AppStorage.get<number>(LIBRARY_VERSION_KEY);
  const next: number = (current === undefined ? 0 : current) + 1;
  AppStorage.setOrCreate<number>(LIBRARY_VERSION_KEY, next);
}

/** 计数值 → 行尾展示文本；0 条时不显示，避免出现一屏 “0 项” */
export function countValueText(count: number): string {
  if (count <= 0) {
    return '';
  }
  return count + ' 项';
}

/** 本地收藏 / 稍后再看记录 → 列表条目 */
export function localToHanime(record: LocalVideoRecord): HanimeInfo {
  const info: HanimeInfo = emptyHanimeInfo();
  info.videoCode = record.videoCode;
  info.title = record.title;
  info.coverUrl = record.coverUrl;
  info.uploadTime = record.uploadTime;
  info.genre = record.genre;
  return info;
}

/** 观看进度百分比（0..100）；时长未知返回 0 */
export function historyProgressPercent(record: HistoryRecord): number {
  if (record.durationMs <= 0 || record.positionMs <= 0) {
    return 0;
  }
  const ratio: number = record.positionMs * 100 / record.durationMs;
  if (ratio < 0) {
    return 0;
  }
  if (ratio > 100) {
    return 100;
  }
  return Math.floor(ratio);
}

/**
 * 最近观看卡片的进度文案（填进 VideoCard 元信息行左侧的「上传者/分类」槽位）。
 *
 * 本地观看历史只持久化 videoCode/title/coverUrl/positionMs/durationMs/updatedAt（见 Models.HistoryRecord），
 * 没有站点上传者/分类字段，因此用本机确实有的观看进度做降级展示，避免卡片元信息行出现一行空白：
 *  - 有时长且位置 > 0：`已看 68%`；
 *  - 有时长但位置被重置为 0（AppDb 在进度 >= 95% 时会把位置归 0，下次从头播）：`已看完`；
 *  - 无时长但有位置：`看到 12:30`；
 *  - 只打开过详情、从未播放：`未播放`。
 */
export function historyProgressLabel(record: HistoryRecord): string {
  if (record.durationMs > 0) {
    if (record.positionMs <= 0) {
      return '已看完';
    }
    return '已看 ' + historyProgressPercent(record) + '%';
  }
  if (record.positionMs > 0) {
    return '看到 ' + formatMs(record.positionMs);
  }
  return '未播放';
}

/**
 * 本地历史记录 → 横向卡片条目（内容库「最近观看」用）。
 *
 * 首页卡片的数据来自站点 HTML（播放量 / 时长 / 上传者 / 上传时间齐全），本地历史只能存
 * videoCode/title/coverUrl/positionMs/durationMs/updatedAt，因此这里按「能补的补、补不了的降级」映射：
 *  - 封面右下角时长：总时长已知时展示（`mm:ss`）；
 *  - 封面左下角播放量：本地没有该数据，留空（VideoCard 对空串不渲染该组控件，不会留下空白行）；
 *  - 元信息行左槽（currentArtist / genre 槽位）：展示本机观看进度（historyProgressLabel）；
 *  - 元信息行右槽（uploadTime 槽位）：展示相对当前时间的最近观看时间，如 `3 小时前看过`，
 *    与「最近观看」语义一致，也避免右槽整块空白。
 *
 * @param now 当前时间戳（同一批卡片统一传入，保证相对时间基准一致）
 */
export function historyToHanime(record: HistoryRecord, now: number): HanimeInfo {
  const info: HanimeInfo = emptyHanimeInfo();
  info.videoCode = record.videoCode;
  info.title = record.title;
  info.coverUrl = record.coverUrl;
  if (record.durationMs > 0) {
    info.duration = formatMs(record.durationMs);
  }
  info.genre = historyProgressLabel(record);
  info.uploadTime = formatRelativeTime(record.updatedAt, now) + '看过';
  return info;
}

/** 收藏行的副标题：收藏时间（相对时间） */
export function favoriteSubtitle(record: LocalVideoRecord, now: number): string {
  const when: string = formatRelativeTime(record.addedAt, now);
  if (record.genre.length > 0) {
    return record.genre + ' · 收藏于 ' + when;
  }
  return '收藏于 ' + when;
}

/** 历史行的副标题：`12:30 / 24:00 · 68% · 3 小时前`（时长未知时省略进度部分） */
export function historySubtitle(record: HistoryRecord, now: number): string {
  const when: string = formatRelativeTime(record.updatedAt, now);
  if (record.durationMs > 0) {
    const percent: number = historyProgressPercent(record);
    return formatMs(record.positionMs) + ' / ' + formatMs(record.durationMs) +
      ' · ' + percent + '% · ' + when;
  }
  if (record.positionMs > 0) {
    return '看到 ' + formatMs(record.positionMs) + ' · ' + when;
  }
  return when;
}

/** 播放清单条目的数量文案：`共 12 部` */
export function playlistCountText(total: number): string {
  if (total <= 0) {
    return '清单为空';
  }
  return '共 ' + total + ' 部';
}

/** 账号页统计：订阅 / 视频数 */
export function accountStatText(label: string, value: number): string {
  return label + ' ' + (value < 0 ? '-' : value);
}
