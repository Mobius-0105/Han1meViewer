/**
 * 「我的订阅」页面解析器（纯 TypeScript，ArkTS 可编译）。
 *
 * 对应 Android 上游 `logic/Parser.kt` 的 `getMySubscriptions`（约 1251 行）与
 * `parseMaxPage`；只移植「选择器 + 字段语义」，代码为本项目独立实现。
 *
 * 页面结构（2026-11 版式，登录后 `GET /subscriptions?page=N`）：
 *
 * ```html
 * <div class="subscriptions-nav">
 *   <div class="subscriptions-artist-card">
 *     <img ...>                     <!-- 第 1 张不是头像 -->
 *     <img src="...">               <!-- 第 2 张才是头像 -->
 *     <div class="card-mobile-title">作者名</div>
 *   </div>
 * </div>
 * <div class="content-padding-new">
 *   <div class="video-item-container" title="标题">
 *     <a class="video-link" href=".../watch?v=123">
 *       <div class="thumb-container">
 *         <img class="main-thumb" src="...">
 *         <div class="duration">02:29:45</div>
 *         <div class="stats-container">
 *           <div class="stat-item"><i>thumb_up</i> 100%</div>
 *           <div class="stat-item">32.4萬次</div>
 *         </div>
 *       </div>
 *     </a>
 *     <div class="subtitle"><a>作者</a><span class="subtitle-time">• 10個月前</span></div>
 *   </div>
 * </div>
 * <ul class="pagination"><li><a class="page-link" href="?page=2">2</a></li></ul>
 * ```
 *
 * 容错策略对齐上游：
 *  - 缺少 `div.subscriptions-nav` / `div.content-padding-new` → 抛解析错误
 *    （上游 `WebsiteState.Error(IllegalStateException(...))`）；
 *  - 单个作者卡片 / 视频卡片字段不全 → 跳过该条（上游 `mapNotNull`），不中断整页；
 *  - `maxPage` 缺失 → 1。
 *
 * 注意 ParseError 的边界：上游的 `ParseError` 在 `logic/net/Errors.ets`（ArkTS 文件），
 * 纯 TS 模块（core/**，会被 Node 测试直接 import）不能 import .ets。因此本文件抛
 * `SubscriptionParseError`（name 也是 'ParseError'），由 `SubscriptionApi.ets` 统一
 * 转换成现有的 `ParseError` 向上抛；UI 侧拿到的仍是现有错误类型。
 */

import {
  MySubscriptions,
  SubscriptionArtist,
  SubscriptionVideo
} from '../model/Subscription';
import { HtmlDocument, HtmlNode, parseHtml } from './HtmlDom';
import { parsePaginationMaxPage } from './HanimeParser';

/** 订阅页结构不符时抛出的解析错误（ArkTS 层会转换成 logic/net/Errors 的 ParseError） */
export class SubscriptionParseError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ParseError';
  }
}

/** 判断是否为订阅页解析错误（SubscriptionApi 用它决定是否包装成 ParseError） */
export function isSubscriptionParseError(error: Error): boolean {
  return error instanceof SubscriptionParseError;
}

/** null 安全取文本 */
function textOf(node: HtmlNode | null): string {
  return node !== null ? node.text() : '';
}

/** 属性转绝对地址；解析失败时回退原值（与 HanimeParser 的 absOrRaw 语义一致） */
function absOrRaw(node: HtmlNode | null, attrName: string): string {
  if (node === null) {
    return '';
  }
  const absolute: string = node.absUrl(attrName);
  if (absolute.length > 0) {
    return absolute;
  }
  return node.attr(attrName).trim();
}

/** 作者 + 上传时间（`div.subtitle` 的两种版式） */
interface ArtistAndTime {
  artist: string;
  uploadTime: string;
}

/**
 * 解析 `div.subtitle`：
 *  1. 新版把「作者 • 上传时间」放同一行（`<a>作者</a><span>• 10個月前</span>`）；
 *  2. 旧版没有 `•`，作者在 `<a>`、时间在 `span.subtitle-time` / 第一个 `<span>`。
 * 对应上游 `getMySubscriptions` 里 `artistAndUploadTime.contains("•")` 分支。
 */
function parseArtistAndTime(subtitle: HtmlNode | null): ArtistAndTime {
  const result: ArtistAndTime = { artist: '', uploadTime: '' };
  if (subtitle === null) {
    return result;
  }
  const subtitleText: string = subtitle.text().trim();
  if (subtitleText.indexOf('•') >= 0) {
    const parts: string[] = subtitleText.split('•');
    result.artist = parts.length > 0 ? parts[0].trim() : '';
    result.uploadTime = parts.length > 1 ? parts[1].trim() : '';
    return result;
  }
  result.artist = textOf(subtitle.selectFirst('a')).trim();
  result.uploadTime = textOf(subtitle.selectFirst('span.subtitle-time, span')).trim();
  return result;
}

/**
 * 解析订阅作者列表（`div.subscriptions-nav div.subscriptions-artist-card`）。
 *
 * 上游取卡片内第 2 个 `<img>` 作头像（第 1 个通常是卡片封面/占位图），
 * `div.card-mobile-title` 作文本名；任一缺失则跳过该卡片。
 */
function parseArtists(navRoot: HtmlNode): SubscriptionArtist[] {
  const artists: SubscriptionArtist[] = [];
  const cards: HtmlNode[] = navRoot.select('div.subscriptions-artist-card');
  for (let i: number = 0; i < cards.length; i++) {
    const card: HtmlNode = cards[i];
    const images: HtmlNode[] = card.select('img');
    if (images.length < 2) {
      continue;
    }
    const avatar: string = absOrRaw(images[1], 'src');
    const artistName: string = textOf(card.selectFirst('div.card-mobile-title')).trim();
    if (avatar.length === 0 || artistName.length === 0) {
      continue;
    }
    const artist: SubscriptionArtist = {
      artistName: artistName,
      avatar: avatar
    };
    artists.push(artist);
  }
  return artists;
}

/** 取 `root` 下 selector 匹配节点里第一段非空文本（对齐 Jsoup Elements.text() 的常用场景） */
function firstNonEmptyText(root: HtmlNode, selector: string): string {
  const nodes: HtmlNode[] = root.select(selector);
  for (let i: number = 0; i < nodes.length; i++) {
    const text: string = nodes[i].text().trim();
    if (text.length > 0) {
      return text;
    }
  }
  return '';
}

/** 解析单个视频卡片；字段不全（链接/视频编号/封面缺失）时返回 null */
function parseVideoCard(card: HtmlNode): SubscriptionVideo | null {
  const link: HtmlNode | null = card.selectFirst('a[class^=video-link]');
  const href: string = absOrRaw(link, 'href');
  // 上游用 watch?v=(\d+) 而不是通用的 v= 正则：广告卡的跳转链接不会误命中
  const codeMatch: RegExpMatchArray | null = href.match(/watch\?v=(\d+)/);
  if (codeMatch === null) {
    return null;
  }
  const videoCode: string = codeMatch[1];
  const coverUrl: string = absOrRaw(card.selectFirst('img[class^=main-thumb]'), 'src');
  if (videoCode.length === 0 || coverUrl.length === 0) {
    return null;
  }

  // 时长与播放量都在 thumb-container 内：时长取第一个 duration，播放量取第 2 个 stat-item
  const duration: string = firstNonEmptyText(card, 'div[class^=thumb-container] div[class^=duration]');
  let views: string = '';
  const statItems: HtmlNode[] = card.select('div[class^=thumb-container] div[class^=stat-item]');
  if (statItems.length > 1) {
    views = statItems[1].text().trim();
  }

  const artistAndTime: ArtistAndTime = parseArtistAndTime(card.selectFirst('div.subtitle'));
  // 好评率是 stat-item 的 ownText（内层 <i class=material-icons>thumb_up</i> 不计入）
  const reviewsNode: HtmlNode | null = card.selectFirst('.stats-container .stat-item');
  const reviews: string = reviewsNode !== null ? reviewsNode.ownText().trim() : '';

  const video: SubscriptionVideo = {
    title: card.attr('title').trim(),
    coverUrl: coverUrl,
    videoCode: videoCode,
    duration: duration,
    views: views,
    reviews: reviews,
    currentArtist: artistAndTime.artist,
    uploadTime: artistAndTime.uploadTime
  };
  return video;
}

/** 解析订阅视频更新列表（`div.content-padding-new div[class^=video-item-container]`） */
function parseVideos(videosRoot: HtmlNode): SubscriptionVideo[] {
  const videos: SubscriptionVideo[] = [];
  const cards: HtmlNode[] = videosRoot.select('div[class^=video-item-container]');
  for (let i: number = 0; i < cards.length; i++) {
    const video: SubscriptionVideo | null = parseVideoCard(cards[i]);
    if (video !== null) {
      videos.push(video);
    }
  }
  return videos;
}

/**
 * 解析「我的订阅」页面。
 *
 * @param html     `GET /subscriptions?page=N` 的响应 HTML
 * @param baseUrl  站点根地址（用于 `absUrl` 把封面/头像相对地址转绝对地址）
 * @throws SubscriptionParseError 页面结构不符（未登录被重定向、站点改版等）
 */
export function parseMySubscriptions(html: string, baseUrl: string): MySubscriptions {
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();

  const navRoot: HtmlNode | null = body.selectFirst('div.subscriptions-nav');
  const videosRoot: HtmlNode | null = body.selectFirst('div.content-padding-new');
  if (navRoot === null || videosRoot === null) {
    throw new SubscriptionParseError('找不到订阅页面结构（subscriptions-nav / content-padding-new）');
  }

  const result: MySubscriptions = {
    artists: parseArtists(navRoot),
    videos: parseVideos(videosRoot),
    // 订阅页没有「跳到指定页」输入框，直接用 ul.pagination 的最大页码；缺失为 1
    maxPage: parsePaginationMaxPage(body)
  };
  return result;
}
