/**
 * Hanime 站点 HTML 解析器（纯 TypeScript，ArkTS 可编译）。
 *
 * 对应上游 Android `logic/Parser.kt` 的以下函数：
 *  - `extractCsrfFromLoginPage` ← `extractTokenFromLoginPage`
 *  - `parseHomePage`          ← `homePageVer2`
 *  - `parseSearchPage`        ← `hanimeSearch`
 *  - `parseVideoPage`         ← `hanimeVideoVer2`
 *  - `parseMyListPage`        ← `myListItems` / `myPlayListItems` / `onlineWatchHistoryItems`
 *  - `parsePlaylistsPage`     ← `playlists`
 *  - `parseUserAccount`       ← `userAccountPage`
 *
 * 与 Android 侧的关键差异（容错策略，见 docs/parser-notes.md）：
 *  1. 上游用 `throwIfParseNull` 在关键字段缺失时抛异常；这里改为"返回尽量完整的
 *     对象 + 空串/空数组"，由网络层根据 `title`/`sources` 是否为空决定是否报错；
 *  2. 首页分区优先按标题匹配、其次按 Android 的索引兜底。2026-11 的真实首页快照
 *     中 `div[id=home-rows-wrapper] > div` 有 14 个直接子 div（索引 4、9 是广告位），
 *     与 Android 索引一致；但站点一旦增删分区，标题兜底可以避免整页错位；
 *  3. `absUrl` 统一转绝对地址（封面、封面兜底 src、originalComic 等），避免
 *     ArkUI `Image` 组件拿到相对地址加载失败。
 */

import {
  Artist,
  Banner,
  HanimeInfo,
  HanimeVideo,
  HomePage,
  ITEM_TYPE_NORMAL,
  ITEM_TYPE_SIMPLIFIED,
  MyList,
  MyListInfo,
  MyListPage,
  Playlist,
  PlaylistSummary,
  PlaylistsPage,
  SearchPage,
  UserAccount,
  VideoSource,
  emptyHanimeVideo,
  emptyHomePage
} from '../model/Models';
import { toVideoCode } from '../util/Urls';
import { HtmlDocument, HtmlNode, parseHtml } from './HtmlDom';

/** javchu.com 是 AV 站（Android `HANIME_URL[3]`），个别解析分支/CDN 修正需要区分 */
const AV_SITE_HOST: string = 'javchu.com';

/** 首页分区标题（与 Android 的索引语义保持一致，用于标题兜底） */
const HOME_SECTION_KEYS: string[] = [
  '最新上市',
  '最新上傳',
  '裏番',
  '泡麵番',
  'Motion Anime',
  '3DCG',
  '2.5D',
  '2D',
  'AI生成',
  'MMD',
  'Cosplay',
  '他們在看',
  '新番預告'
];

/** 空对象工厂：只在本文件内做局部兜底 */
function emptySearchPage(): SearchPage {
  const page: SearchPage = { list: [], maxPage: 1 };
  return page;
}

function emptyMyListPage(): MyListPage {
  const page: MyListPage = { items: [], desc: '', csrfToken: '', maxPage: 1 };
  return page;
}

function emptyPlaylistsPage(): PlaylistsPage {
  const page: PlaylistsPage = { playlists: [], csrfToken: '', maxPage: 1 };
  return page;
}

/** 是否 AV 站（javchu.com 的页面结构与主站略有差异） */
export function isAvSite(baseUrl: string): boolean {
  return baseUrl.indexOf(AV_SITE_HOST) >= 0;
}

/** 文本节点文本（null 安全） */
function textOf(node: HtmlNode | null): string {
  return node !== null ? node.text() : '';
}

/** 只取直接文本（Jsoup ownText 语义，null 安全） */
function ownTextOf(node: HtmlNode | null): string {
  return node !== null ? node.ownText() : '';
}

/** 元素属性（null 安全），返回原样字符串 */
function attrOf(node: HtmlNode | null, name: string): string {
  return node !== null ? node.attr(name) : '';
}

/** 属性转绝对地址；Jsoup absUrl 失败时回退原值（站点偶发 data: / 绝对路径异常） */
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

/** 解析整数，失败返回 fallback */
function parseIntOr(raw: string, fallback: number): number {
  const value: string = raw.trim();
  if (value.length === 0) {
    return fallback;
  }
  const parsed: number = parseInt(value, 10);
  return isNaN(parsed) ? fallback : parsed;
}

/** 取字符串里第一段连续数字 */
function firstNumberText(raw: string): string {
  const match: RegExpMatchArray | null = raw.match(/\d+/);
  return match !== null ? match[0] : '';
}

/**
 * 提取 csrf token：优先 `input[name=_token]`（表单），回退
 * `meta[name=csrf-token]`（2026 年快照里未登录首页只有 meta 里带 token，
 * Android 只读 input 会得到 null，这里做兼容）。
 */
function extractCsrf(body: HtmlNode, doc: HtmlDocument): string {
  const input: HtmlNode | null = body.selectFirst('input[name=_token]');
  if (input !== null) {
    const value: string = input.attr('value').trim();
    if (value.length > 0) {
      return value;
    }
  }
  const meta: HtmlNode | null = doc.selectFirst('meta[name=csrf-token]');
  return attrOf(meta, 'content').trim();
}

/** 从 URL 里提取 `/user/(\d+)` */
function extractUserIdFromHref(href: string): string {
  const match: RegExpMatchArray | null = href.match(/\/user\/(\d+)/);
  return match !== null ? match[1] : '';
}

/**
 * 修正 AV 站视频 CDN 主机：`//t26.cdn2020.com` / `https://t27.cdn2020.com` → t33。
 * 对应 Parser.kt 的 `fixAvCdnHost`（仅 javchu.com 生效）。
 */
export function fixAvCdnHost(url: string, baseUrl: string): string {
  if (!isAvSite(baseUrl) || url.length === 0) {
    return url;
  }
  return url.replace(/^(\s*(?:https?:)?\/\/)t\d+\.cdn2020\.com(?=[\/:]|$)/i, '$1t33.cdn2020.com');
}

// ----------------------------------------------------------------------
// 列表卡片（HanimeInfo）
// ----------------------------------------------------------------------

/**
 * 普通版式视频卡片（Android `hanimeNormalItemVer2`）。
 * 关键字段（标题/封面/视频码）任一缺失返回 null——广告卡片、占位卡片会被过滤。
 */
export function parseNormalHanimeItem(item: HtmlNode): HanimeInfo | null {
  const titleNode: HtmlNode | null = item.selectFirst('div.title, h4.video-title');
  const title: string = textOf(titleNode).trim();
  const images: HtmlNode[] = item.select('img');
  const coverUrl: string = images.length > 0 ? absOrRaw(images[0], 'src') : '';
  const anchors: HtmlNode[] = item.select('a');
  const href: string = anchors.length > 0 ? absOrRaw(anchors[0], 'href') : '';
  const videoCode: string = toVideoCode(href);
  if (title.length === 0 || coverUrl.length === 0 || videoCode.length === 0) {
    return null;
  }

  // 时长 + 播放数在 thumb-container 里
  let duration: string = '';
  let views: string = '';
  const thumbContainers: HtmlNode[] = item.select('div[class^=thumb-container]');
  for (let i: number = 0; i < thumbContainers.length; i++) {
    if (duration.length === 0) {
      const durationNode: HtmlNode | null = thumbContainers[i].selectFirst('div[class^=duration]');
      duration = textOf(durationNode).trim();
    }
    if (views.length === 0) {
      const statItems: HtmlNode[] = thumbContainers[i].select('div[class^=stat-item]');
      if (statItems.length > 1) {
        views = textOf(statItems[1]).trim();
      }
    }
    if (duration.length > 0 && views.length > 0) {
      break;
    }
  }

  // 作者 + 上传时间：新版 "作者 • 时间" 在同一行；旧版分开在 a / span 里
  const subtitle: HtmlNode | null = item.selectFirst('div.subtitle, div.video-meta-data');
  const subtitleText: string = textOf(subtitle).trim();
  let artist: string = '';
  let uploadTime: string = '';
  if (subtitleText.indexOf('•') >= 0) {
    const parts: string[] = subtitleText.split('•');
    artist = parts.length > 0 ? parts[0].trim() : '';
    uploadTime = parts.length > 1 ? parts[1].trim() : '';
  } else if (subtitle !== null) {
    artist = textOf(subtitle.selectFirst('a')).trim();
    uploadTime = textOf(subtitle.selectFirst('span.subtitle-time, span')).trim();
  }

  const reviews: string = ownTextOf(item.selectFirst('.stats-container .stat-item')).trim();
  const itemId: string = item.id();
  const playlistItemId: string = itemId.startsWith('playlist-item-')
    ? itemId.substring('playlist-item-'.length)
    : '';

  const info: HanimeInfo = {
    title: title,
    coverUrl: coverUrl,
    videoCode: videoCode,
    duration: duration,
    views: views,
    uploadTime: uploadTime,
    genre: '',
    reviews: reviews,
    currentArtist: artist,
    itemType: ITEM_TYPE_NORMAL,
    playlistItemId: playlistItemId,
    isPlaying: false
  };
  return info;
}

/**
 * 简化版式视频卡片（Android `hanimeSimplifiedItem`）：整张卡片就是一个 `<a>`，
 * 常见于"新番预告"搜索结果；`uploadTime` 位置显示发布日期。
 */
export function parseSimplifiedHanimeItem(item: HtmlNode): HanimeInfo | null {
  const anchor: HtmlNode = item.tagName === 'a' ? item : (item.selectFirst('a') !== null
    ? item.selectFirst('a') as HtmlNode
    : item);
  const videoCode: string = toVideoCode(absOrRaw(anchor, 'href'));
  const coverUrl: string = absOrRaw(anchor.selectFirst('img'), 'src');
  let title: string = textOf(anchor.selectFirst('div[class=home-rows-videos-title]')).trim();
  if (title.length === 0) {
    title = textOf(anchor.selectFirst('div[class$=title]')).trim();
  }
  if (videoCode.length === 0 || coverUrl.length === 0 || title.length === 0) {
    return null;
  }
  const uploadTime: string = textOf(
    anchor.selectFirst('div.video-card-inner > div.hidden-xs')
  ).trim();
  const info: HanimeInfo = {
    title: title,
    coverUrl: coverUrl,
    videoCode: videoCode,
    duration: '',
    views: '',
    uploadTime: uploadTime,
    genre: '',
    reviews: '',
    currentArtist: '',
    itemType: ITEM_TYPE_SIMPLIFIED,
    playlistItemId: '',
    isPlaying: false
  };
  return info;
}

/** 从 root 下按选择器批量抽取普通版式卡片 */
export function extractHanimeInfos(root: HtmlNode | null, selector: string): HanimeInfo[] {
  const result: HanimeInfo[] = [];
  if (root === null) {
    return result;
  }
  const items: HtmlNode[] = root.select(selector);
  for (let i: number = 0; i < items.length; i++) {
    const info: HanimeInfo | null = parseNormalHanimeItem(items[i]);
    if (info !== null) {
      result.push(info);
    }
  }
  return result;
}

/** 从 root 下的 `<a>` 批量抽取简化版式卡片（新番预告等） */
function extractSimplifiedHanimeInfos(root: HtmlNode | null): HanimeInfo[] {
  const result: HanimeInfo[] = [];
  if (root === null) {
    return result;
  }
  const anchors: HtmlNode[] = root.select('a');
  for (let i: number = 0; i < anchors.length; i++) {
    const info: HanimeInfo | null = parseSimplifiedHanimeItem(anchors[i]);
    if (info !== null) {
      result.push(info);
    }
  }
  return result;
}

// ----------------------------------------------------------------------
// 首页
// ----------------------------------------------------------------------

/** 首页一个分区：直接子 div + 从前面兄弟标题里解析出的分区名 */
interface HomeSectionEntry {
  node: HtmlNode;
  title: string;
}

/** 读取首页分区数组（`div[id=home-rows-wrapper] > div`）及其标题 */
function loadHomeSections(body: HtmlNode): HomeSectionEntry[] {
  const entries: HomeSectionEntry[] = [];
  const nodes: HtmlNode[] = body.select('div[id=home-rows-wrapper] > div');
  for (let i: number = 0; i < nodes.length; i++) {
    const node: HtmlNode = nodes[i];
    let title: string = '';
    // 真实站点：标题 <a class=horizontal-row-title><h3>…</h3></a> 是分区 div 的前一个兄弟
    const previous: HtmlNode | null = node.previousElementSibling();
    if (previous !== null) {
      const h3: HtmlNode | null = previous.selectFirst('h3');
      if (h3 !== null) {
        title = h3.ownText();
      } else if (previous.hasClass('horizontal-row-title')) {
        title = previous.text();
      }
    }
    if (title.length === 0) {
      // 兜底：标题可能被套在分区 div 内部
      title = ownTextOf(node.selectFirst('h3'));
    }
    const entry: HomeSectionEntry = { node: node, title: title.trim() };
    entries.push(entry);
  }
  return entries;
}

/** 标题包含任一关键词（大小写不敏感，用于分区识别兜底） */
function sectionTitleMatches(title: string, keywords: string[]): boolean {
  if (title.length === 0) {
    return false;
  }
  const lower: string = title.toLowerCase();
  for (let i: number = 0; i < keywords.length; i++) {
    if (lower.indexOf(keywords[i].toLowerCase()) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 选择一个分区：优先按标题识别，识别不到再用 Android 的索引兜底。
 *
 * 为什么标题优先：站点改版时分区可能增删/换位（例如插入广告 div、去掉某个分区），
 * 纯按索引会让"Motion Anime"拿到"3DCG"的数据；而标题是页面上稳定可见的语义。
 * 索引兜底用于站点把标题文案改成非中文/未知内容时保持 Android 的旧行为。
 */
function pickHomeSection(
  entries: HomeSectionEntry[],
  keywords: string[],
  fallbackIndex: number,
  used: boolean[]
): HtmlNode | null {
  for (let i: number = 0; i < entries.length; i++) {
    if (used[i]) {
      continue;
    }
    if (sectionTitleMatches(entries[i].title, keywords)) {
      used[i] = true;
      return entries[i].node;
    }
  }
  if (fallbackIndex >= 0 && fallbackIndex < entries.length && !used[fallbackIndex]) {
    used[fallbackIndex] = true;
    return entries[fallbackIndex].node;
  }
  return null;
}

/** 解析首页 banner（头图 + 标题 + 描述 + 广告跳转 videoCode） */
function parseBanner(body: HtmlNode): Banner | null {
  const wrapper: HtmlNode | null = body.selectFirst('div[id=home-banner-wrapper]');
  if (wrapper === null) {
    return null;
  }
  const bannerImg: HtmlNode | null = wrapper.previousElementSibling();
  if (bannerImg === null) {
    return null;
  }
  const title: string = attrOf(bannerImg.selectFirst('img'), 'alt');
  // Android：优先第二张 img（第一张往往是渐变遮罩/占位），没有就用第一张
  const images: HtmlNode[] = bannerImg.select('img');
  let picUrl: string = '';
  if (images.length > 1) {
    picUrl = absOrRaw(images[1], 'src');
  }
  if (picUrl.length === 0 && images.length > 0) {
    picUrl = absOrRaw(images[0], 'src');
  }
  const description: string = ownTextOf(wrapper.selectFirst('h4'));
  if (title.length === 0 || picUrl.length === 0) {
    return null;
  }

  // banner 的跳转 videoCode：先找 script 里的 watch?v=，再兜底找注释里的链接
  let videoCode: string = '';
  const scripts: HtmlNode[] = body.select('script');
  for (let i: number = 0; i < scripts.length; i++) {
    const data: string = scripts[i].data();
    if (data.indexOf('watch?v=') < 0) {
      continue;
    }
    const match: RegExpMatchArray | null = data.match(/watch\?v=(\d+)/);
    if (match !== null) {
      videoCode = match[1];
      break;
    }
  }
  if (videoCode.length === 0) {
    const commentTexts: string[] = wrapper.commentTexts();
    for (let i: number = 0; i < commentTexts.length; i++) {
      const code: string = toVideoCode(commentTexts[i]);
      if (code.length > 0) {
        videoCode = code;
        break;
      }
    }
  }

  const banner: Banner = {
    title: title,
    description: description,
    picUrl: picUrl,
    videoCode: videoCode
  };
  return banner;
}

/**
 * 首页解析（对应 Parser.kt `homePageVer2`）。
 *
 * 分区索引（Android 原版；2026-11 快照下索引 4、9 是广告位）：
 * 0 最新上市 / 1 最新上傳 / 2 裏番 / 3 泡麵番 / 5 Motion / 6 3DCG /
 * 7 2.5D / 8 2D / 10 AI / 11 MMD / 12 Cosplay / 13 他們在看；
 * 新番预告在 AV 站取 13、主站取 12（Android 的历史行为，这里保留为兜底索引，
 * 但先按标题"新番預告"识别，识别不到且索引分区已被别的字段占用时返回空，
 * 避免把 Cosplay/他們在看的卡片重复塞进新番预告）。
 */
export function parseHomePage(html: string, baseUrl: string): HomePage {
  const page: HomePage = emptyHomePage();
  const av: boolean = isAvSite(baseUrl);
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();

  page.csrfToken = extractCsrf(body, doc);

  // 用户信息（未登录时是空的，由网络层决定是否提示登录过期）
  const userInfo: HtmlNode | null = body.selectFirst('div[id=user-modal-dp-wrapper]');
  page.avatarUrl = absOrRaw(userInfo !== null ? userInfo.selectFirst('img') : null, 'src');
  page.username = textOf(body.getElementById('user-modal-name')).trim();
  const userHomePageLink: string = attrOf(body.getElementById('user-modal-trigger'), 'href');
  page.userId = extractUserIdFromHref(userHomePageLink);

  // banner
  page.banner = parseBanner(body);

  // 分区列表
  const entries: HomeSectionEntry[] = loadHomeSections(body);
  const used: boolean[] = [];
  for (let i: number = 0; i < entries.length; i++) {
    used.push(false);
  }
  const horizontalSelector: string = 'div[class^=horizontal-card]';

  const latestRelease: HtmlNode | null = pickHomeSection(entries, ['最新上市', '最新上架'], 0, used);
  const latestHanime: HtmlNode | null = pickHomeSection(entries, ['最新上傳', '最新上传'], 1, used);
  const ecchiAnime: HtmlNode | null = pickHomeSection(entries, ['裏番', '里番'], 2, used);
  const shortEpisodeAnime: HtmlNode | null = pickHomeSection(entries, ['泡麵番', '泡面番'], 3, used);
  const motionAnime: HtmlNode | null = pickHomeSection(entries, ['Motion Anime', 'Motion'], 5, used);
  const threeDCG: HtmlNode | null = pickHomeSection(entries, ['3DCG', '3D CG'], 6, used);
  const twoPointFiveDAnime: HtmlNode | null = pickHomeSection(entries, ['2.5D'], 7, used);
  const twoDAnime: HtmlNode | null = pickHomeSection(entries, ['2D'], 8, used);
  const aiGenerated: HtmlNode | null = pickHomeSection(entries, ['AI生成'], 10, used);
  const mmd: HtmlNode | null = pickHomeSection(entries, ['MMD'], 11, used);
  const cosplay: HtmlNode | null = pickHomeSection(entries, ['Cosplay'], 12, used);
  const watchingNow: HtmlNode | null = pickHomeSection(entries, ['他們在看', '他们在看'], 13, used);

  page.latestRelease = extractHanimeInfos(latestRelease, horizontalSelector);
  page.latestHanime = extractHanimeInfos(latestHanime, horizontalSelector);
  page.ecchiAnime = extractHanimeInfos(ecchiAnime, horizontalSelector);
  page.shortEpisodeAnime = extractHanimeInfos(shortEpisodeAnime, horizontalSelector);
  page.motionAnime = extractHanimeInfos(motionAnime, horizontalSelector);
  page.threeDCG = extractHanimeInfos(threeDCG, horizontalSelector);
  page.twoPointFiveDAnime = extractHanimeInfos(twoPointFiveDAnime, horizontalSelector);
  page.twoDAnime = extractHanimeInfos(twoDAnime, horizontalSelector);
  page.aiGenerated = extractHanimeInfos(aiGenerated, horizontalSelector);
  page.mmd = extractHanimeInfos(mmd, horizontalSelector);
  page.cosplay = extractHanimeInfos(cosplay, horizontalSelector);
  page.watchingNow = extractHanimeInfos(watchingNow, horizontalSelector);

  // 新番预告（AV 站用普通卡片；主站历史上是简化卡片）
  const trailerSection: HtmlNode | null = pickHomeSection(
    entries, ['新番預告', '新番预告', '預告片', '预告片'], av ? 13 : 12, used
  );
  if (trailerSection !== null) {
    if (av) {
      page.newAnimeTrailer = extractHanimeInfos(trailerSection, horizontalSelector);
    } else {
      page.newAnimeTrailer = extractHanimeInfos(trailerSection, horizontalSelector);
      if (page.newAnimeTrailer.length === 0) {
        page.newAnimeTrailer = extractSimplifiedHanimeInfos(trailerSection);
      }
    }
  }

  page.timestamp = Date.now();
  return page;
}

// ----------------------------------------------------------------------
// 搜索页
// ----------------------------------------------------------------------

/**
 * 分页上限：列表页 `ul.pagination` 里最大的 `page=` 参数。
 * 对应 Parser.kt `parseMaxPage`。
 */
export function parsePaginationMaxPage(body: HtmlNode): number {
  const paginations: HtmlNode[] = body.select('ul.pagination');
  if (paginations.length === 0) {
    return 1;
  }
  const last: HtmlNode = paginations[paginations.length - 1];
  const links: HtmlNode[] = last.select('a.page-link[href]');
  let maxPage: number = 1;
  for (let i: number = 0; i < links.length; i++) {
    const href: string = links[i].attr('href');
    const match: RegExpMatchArray | null = href.match(/[?&]page=(\d+)/);
    if (match !== null) {
      const value: number = parseIntOr(match[1], 1);
      if (value > maxPage) {
        maxPage = value;
      }
    }
  }
  return maxPage;
}

/**
 * 搜索页总页数：没有静态分页列表，页数藏在"跳到指定页"输入框的 oninput 里。
 * 对应 Parser.kt `parseSearchMaxPage`。
 */
export function parseSearchMaxPage(body: HtmlNode): number {
  const input: HtmlNode | null = body.selectFirst('input#skip-page-input');
  if (input === null) {
    return 1;
  }
  const match: RegExpMatchArray | null = input.attr('oninput')
    .match(/validateNumberInput\(this,\s*\d+,\s*(\d+)\)/);
  return match !== null ? parseIntOr(match[1], 1) : 1;
}

/** 列表页总页数：优先"跳到指定页"，否则回退 `ul.pagination`（对应 `parseListMaxPage`） */
export function parseListMaxPage(body: HtmlNode): number {
  const searchMax: number = parseSearchMaxPage(body);
  if (searchMax > 1) {
    return searchMax;
  }
  return parsePaginationMaxPage(body);
}

/**
 * 搜索页解析（对应 Parser.kt `hanimeSearch`）。
 * 页面有两种版式：普通卡片（`.content-padding-new` 下）与简化卡片
 * （`.home-rows-videos-wrapper` 的子元素，整张卡片是 `<a>`）。
 */
export function parseSearchPage(html: string, baseUrl: string): SearchPage {
  const page: SearchPage = emptySearchPage();
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();
  page.maxPage = parseSearchMaxPage(body);

  const normalRoots: HtmlNode[] = body.getElementsByClass('content-padding-new');
  const simplifiedRoots: HtmlNode[] = body.getElementsByClass('home-rows-videos-wrapper');

  if (normalRoots.length > 0) {
    page.list = extractHanimeInfos(normalRoots[0], 'div[class^=horizontal-card]');
    return page;
  }
  if (simplifiedRoots.length > 0) {
    const children: HtmlNode[] = simplifiedRoots[0].children();
    for (let i: number = 0; i < children.length; i++) {
      const info: HanimeInfo | null = parseSimplifiedHanimeItem(children[i]);
      if (info !== null) {
        page.list.push(info);
      }
    }
    return page;
  }
  return page;
}

// ----------------------------------------------------------------------
// 视频详情页
// ----------------------------------------------------------------------

/** 清理分辨率标签：`1080` → `1080P`，`1080p` → `1080P`，空 → `auto` */
function normalizeResolution(sizeText: string): string {
  const value: string = sizeText.trim();
  if (value.length === 0) {
    return 'auto';
  }
  if (value.endsWith('p') || value.endsWith('P')) {
    return value.toUpperCase();
  }
  return value + 'P';
}

/** 分辨率排序权重（数字越大越靠前；auto/未知排最后） */
function resolutionRank(resolution: string): number {
  const match: RegExpMatchArray | null = resolution.match(/\d+/);
  return match !== null ? parseIntOr(match[0], 0) : 0;
}

/** 解析播放源：优先 `<video id=player>` 下的 `<source>`，否则从播放器脚本里取 */
function parseVideoSources(body: HtmlNode, baseUrl: string): VideoSource[] {
  const sources: VideoSource[] = [];
  const player: HtmlNode | null = body.selectFirst('video[id=player]');
  if (player !== null) {
    const children: HtmlNode[] = player.children();
    for (let i: number = 0; i < children.length; i++) {
      const source: HtmlNode = children[i];
      const url: string = fixAvCdnHost(absOrRaw(source, 'src'), baseUrl);
      if (url.length === 0) {
        continue;
      }
      const sourceInfo: VideoSource = {
        resolution: normalizeResolution(source.attr('size')),
        url: url,
        type: source.attr('type').trim()
      };
      sources.push(sourceInfo);
    }
  }

  if (sources.length === 0) {
    // 兜底：新版播放器把地址写在 `const source = '...'` 里（AV 站常见）
    const scriptWrappers: HtmlNode[] = body.select('div[id=player-div-wrapper]');
    if (scriptWrappers.length > 0) {
      const scripts: HtmlNode[] = scriptWrappers[0].select('script');
      for (let i: number = 0; i < scripts.length; i++) {
        const data: string = scripts[i].data();
        if (data.trim().length === 0) {
          continue;
        }
        const match: RegExpMatchArray | null = data.match(/const source = '(.+)'/);
        if (match === null) {
          continue;
        }
        const sourceInfo: VideoSource = {
          resolution: 'auto',
          url: fixAvCdnHost(match[1], baseUrl),
          type: ''
        };
        sources.push(sourceInfo);
        break;
      }
    }
  }

  // 按分辨率从高到低排序（Android 固定 1080/720/480/240 顺序），同分辨率去重
  const sorted: VideoSource[] = [];
  for (let i: number = 0; i < sources.length; i++) {
    let insertAt: number = sorted.length;
    const rank: number = resolutionRank(sources[i].resolution);
    let duplicated: boolean = false;
    for (let s: number = 0; s < sorted.length; s++) {
      if (sorted[s].resolution === sources[i].resolution) {
        duplicated = true;
        break;
      }
      if (resolutionRank(sorted[s].resolution) < rank) {
        insertAt = s;
        break;
      }
    }
    if (duplicated) {
      continue;
    }
    sorted.splice(insertAt, 0, sources[i]);
  }
  return sorted;
}

/** 解析系列播放列表（新版 `playlist-hover-wrap` / 旧版 `card-mobile-panel` 两种版式） */
function parseVideoPlaylist(wrapper: HtmlNode): Playlist | null {
  const scroll: HtmlNode | null = wrapper.getElementById('playlist-scroll');
  if (scroll === null) {
    return null;
  }
  const children: HtmlNode[] = scroll.children();
  const videos: HanimeInfo[] = [];
  const first: HtmlNode | null = children.length > 0 ? children[0] : null;
  let playlistName: string = '';

  if (first !== null && first.hasClass('playlist-hover-wrap')) {
    // 新版页面结构
    playlistName = textOf(wrapper.selectFirst('#playlist-top-block h4 a')).trim();
    for (let i: number = 0; i < children.length; i++) {
      const child: HtmlNode = children[i];
      const videoCode: string = toVideoCode(child.attr('data-href'));
      if (videoCode.length === 0) {
        continue;
      }
      const thumb: HtmlNode | null = child.selectFirst('.thumb-container');
      const coverUrl: string = absOrRaw(
        thumb !== null ? thumb.selectFirst('img.main-thumb') : null, 'src'
      );
      const title: string = textOf(child.selectFirst('h4.video-title a')).trim();
      if (title.length === 0 || coverUrl.length === 0) {
        continue;
      }
      const duration: string = textOf(
        thumb !== null ? thumb.selectFirst('.duration') : null
      ).trim();
      let reviews: string = '';
      let views: string = '';
      if (thumb !== null) {
        const statItems: HtmlNode[] = thumb.select('.stat-item');
        if (statItems.length > 0) {
          reviews = statItems[0].ownText().trim();
        }
        if (statItems.length > 1) {
          views = statItems[1].text().trim();
        }
      }
      const info: HanimeInfo = {
        title: title,
        coverUrl: coverUrl,
        videoCode: videoCode,
        duration: duration,
        views: views,
        uploadTime: textOf(child.selectFirst('.meta-stats span')).trim(),
        genre: textOf(child.selectFirst('.meta-stats a')).trim(),
        reviews: reviews,
        currentArtist: textOf(child.selectFirst('.meta-author a')).trim(),
        itemType: ITEM_TYPE_NORMAL,
        playlistItemId: '',
        isPlaying: child.hasClass('videos-scroll')
      };
      videos.push(info);
    }
    const playlist: Playlist = { playlistName: playlistName, video: videos };
    return playlist;
  }

  // 旧版页面结构（兼容兜底）
  playlistName = textOf(wrapper.selectFirst('div > div > h4')).trim();
  for (let i: number = 0; i < children.length; i++) {
    const parent: HtmlNode = children[i];
    if (parent.tagName === 'a') {
      continue;
    }
    const link: HtmlNode | null = parent.selectFirst('div > a');
    const videoCode: string = toVideoCode(absOrRaw(link, 'href'));
    if (videoCode.length === 0) {
      continue;
    }
    const panel: HtmlNode | null = parent.selectFirst('div[class^=card-mobile-panel]');
    if (panel === null) {
      continue;
    }
    const coverImgs: HtmlNode[] = panel.select('div > div > div > img');
    const coverImg: HtmlNode | null = coverImgs.length > 1 ? coverImgs[1] : null;
    const coverUrl: string = absOrRaw(coverImg, 'src');
    const title: string = attrOf(coverImg, 'alt').trim();
    if (title.length === 0 || coverUrl.length === 0) {
      continue;
    }
    const playingCandidates: HtmlNode[] = panel.select('div > div > div > div');
    let isPlaying: boolean = false;
    if (playingCandidates.length > 0) {
      isPlaying = playingCandidates[0].text().indexOf('播放') >= 0;
    }
    const durations: HtmlNode[] = panel.select('div[class*=card-mobile-duration]');
    const duration: string = durations.length > 0 ? durations[0].text().trim() : '';
    const views: string = durations.length > 2 ? durations[2].text().trim() : '';
    const infoBoxes: HtmlNode[] = panel.select('div.card-mobile-duration.card-playlist-large');
    const reviews: string = infoBoxes.length > 0 ? infoBoxes[0].ownText().trim() : '';
    const info: HanimeInfo = {
      title: title,
      coverUrl: coverUrl,
      videoCode: videoCode,
      duration: duration,
      views: views,
      uploadTime: '',
      genre: '',
      reviews: reviews,
      currentArtist: textOf(panel.selectFirst('a.card-mobile-user')).trim(),
      itemType: ITEM_TYPE_NORMAL,
      playlistItemId: '',
      isPlaying: isPlaying
    };
    videos.push(info);
  }
  const playlist: Playlist = { playlistName: playlistName, video: videos };
  return playlist;
}

/** 解析相关推荐（普通卡片 / 简化卡片两种版式） */
function parseRelatedHanimes(body: HtmlNode): HanimeInfo[] {
  const related: HanimeInfo[] = [];
  const relatedTabContent: HtmlNode | null = body.getElementById('related-tabcontent');
  if (relatedTabContent === null) {
    return related;
  }
  const firstChild: HtmlNode | null = relatedTabContent.childOrNull(0);
  const children: HtmlNode[] = firstChild !== null ? firstChild.children() : [];
  let isSimplified: boolean = false;
  if (children.length > 0) {
    const firstAnchor: HtmlNode | null = children[0].selectFirst('a');
    if (firstAnchor !== null && firstAnchor.getElementsByClass('home-rows-videos-div').length > 0) {
      isSimplified = true;
    }
  }
  if (isSimplified) {
    for (let i: number = 0; i < children.length; i++) {
      const eachContent: HtmlNode | null = children[i].selectFirst('a');
      if (eachContent === null) {
        continue;
      }
      const videoDivs: HtmlNode[] = eachContent.getElementsByClass('home-rows-videos-div');
      if (videoDivs.length === 0) {
        continue;
      }
      const itemRoot: HtmlNode = videoDivs[0];
      const videoCode: string = toVideoCode(eachContent.absUrl('href'));
      if (videoCode.length === 0) {
        continue;
      }
      const coverUrl: string = absOrRaw(itemRoot.selectFirst('img'), 'src');
      const title: string = textOf(itemRoot.selectFirst('div[class$=title]')).trim();
      if (title.length === 0 || coverUrl.length === 0) {
        continue;
      }
      const info: HanimeInfo = {
        title: title,
        coverUrl: coverUrl,
        videoCode: videoCode,
        duration: '',
        views: '',
        uploadTime: '',
        genre: '',
        reviews: '',
        currentArtist: '',
        itemType: ITEM_TYPE_SIMPLIFIED,
        playlistItemId: '',
        isPlaying: false
      };
      related.push(info);
    }
    return related;
  }
  return extractHanimeInfos(relatedTabContent, 'div[class^=horizontal-card]');
}

/** 解析作者区（头像/名字/类型/订阅表单） */
function parseArtist(body: HtmlNode): Artist | null {
  const avatarNode: HtmlNode | null = body.selectFirst(
    "div.video-details-wrapper > div > a > div > img[style*='position: absolute'][style*='border-radius: 50%']"
  );
  const avatarUrl: string = absOrRaw(avatarNode, 'src');
  const artistNameNode: HtmlNode | null = body.getElementById('video-artist-name');
  const name: string = textOf(artistNameNode).trim();
  const genre: string = textOf(
    artistNameNode !== null ? artistNameNode.nextElementSibling() : null
  ).trim();
  if (name.length === 0 || genre.length === 0) {
    return null;
  }
  let userId: string = '';
  let artistId: string = '';
  let isSubscribed: boolean = false;
  const subscribeForm: HtmlNode | null = body.getElementById('video-subscribe-form');
  if (subscribeForm !== null) {
    const userIdNode: HtmlNode | null = subscribeForm.selectFirst('input[name=subscribe-user-id]');
    const artistIdNode: HtmlNode | null = subscribeForm.selectFirst('input[name=subscribe-artist-id]');
    const statusNode: HtmlNode | null = subscribeForm.selectFirst('input[name=subscribe-status]');
    if (userIdNode !== null && artistIdNode !== null && statusNode !== null) {
      userId = userIdNode.attr('value');
      artistId = artistIdNode.attr('value');
      isSubscribed = statusNode.attr('value') === '1';
    }
  }
  const artist: Artist = {
    name: name,
    avatarUrl: avatarUrl,
    genre: genre,
    userId: userId,
    artistId: artistId,
    isSubscribed: isSubscribed
  };
  return artist;
}

/** 解析"我的清单"勾选框 */
function parseVideoMyList(body: HtmlNode): MyList {
  const infos: MyListInfo[] = [];
  const wrappers: HtmlNode[] = body.select('div[class~=playlist-checkbox-wrapper]');
  for (let i: number = 0; i < wrappers.length; i++) {
    const span: HtmlNode | null = wrappers[i].selectFirst('span');
    const input: HtmlNode | null = wrappers[i].selectFirst('input');
    if (span === null || input === null) {
      continue;
    }
    const code: string = input.attr('id');
    if (code.length === 0) {
      continue;
    }
    const info: MyListInfo = {
      code: code,
      title: span.ownText().trim(),
      isSelected: input.hasAttr('checked')
    };
    infos.push(info);
  }
  const saveCheckbox: HtmlNode | null = body.getElementById('playlist-save-checkbox');
  const isWatchLater: boolean = saveCheckbox !== null &&
    saveCheckbox.selectFirst('input') !== null &&
    (saveCheckbox.selectFirst('input') as HtmlNode).hasAttr('checked');
  const myList: MyList = { isWatchLater: isWatchLater, myListInfo: infos };
  return myList;
}

/**
 * 视频详情页解析（对应 Parser.kt `hanimeVideoVer2`）。
 *
 * 关键点：
 *  - `video#player` 的 `<source size=1080 src=...>` → 清晰度列表；AV 站没有
 *    `<source>`，地址在 `const source = '...'` 脚本里，需要脚本兜底；
 *  - `fixAvCdnHost` 只对 javchu.com 生效（t26/t27 → t33）；
 *  - 登录态相关字段（点赞状态、我的清单）未登录时为空，此时 `favTimes`/`unlikesCount`
 *    用 -1 表示"未解析到"；
 *  - 解析失败不抛异常：返回尽量完整的对象，标题/播放源为空由网络层判定。
 */
export function parseVideoPage(html: string, baseUrl: string, videoCode: string): HanimeVideo {
  const video: HanimeVideo = emptyHanimeVideo();
  video.videoCode = videoCode;
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();

  // token / 当前用户 / 点赞状态
  video.csrfToken = extractCsrf(body, doc);
  video.currentUserId = attrOf(body.selectFirst('input[name=like-user-id]'), 'value').trim();

  const likeStatusValue: string = attrOf(body.selectFirst('[name=like-status]'), 'value');
  video.isFav = likeStatusValue.length > 0;
  const unlikeStatusValue: string = attrOf(body.selectFirst('[name=unlike-status]'), 'value');
  video.isUnlike = unlikeStatusValue.length > 0;
  video.favTimes = parseIntOr(
    attrOf(body.selectFirst('input[name=likes-count]'), 'value'), -1
  );
  video.unlikesCount = parseIntOr(
    attrOf(body.selectFirst('input[name=unlikes-count]'), 'value'), -1
  );

  // 标题（#shareBtn-title）
  video.title = textOf(body.getElementById('shareBtn-title')).trim();

  // 简介区
  const detailWrapper: HtmlNode | null = body.selectFirst('div[class=video-details-wrapper]');
  const captionNode: HtmlNode | null = detailWrapper !== null
    ? detailWrapper.selectFirst('div[class^=video-caption-text]')
    : null;
  video.chineseTitle = captionNode !== null
    ? ownTextOf(captionNode.previousElementSibling()).trim()
    : '';
  video.introduction = ownTextOf(captionNode).trim();

  // 上传时间 / 观看数："觀看次數：16.9萬次 2026-02-06"
  const uploadTimeWithViews: string = detailWrapper !== null
    ? textOf(detailWrapper.selectFirst('div > div > div'))
    : '';
  const timeMatch: RegExpMatchArray | null = uploadTimeWithViews
    .match(/(觀看次數|观看次数)：(.+?次)[\s\u00A0]*(\d{4}-\d{2}-\d{2})/);
  video.views = timeMatch !== null ? timeMatch[2].trim() : '';
  video.uploadTime = timeMatch !== null ? timeMatch[3].trim() : '';

  // 播放源 + 封面
  const player: HtmlNode | null = body.selectFirst('video[id=player]');
  video.coverUrl = player !== null ? player.absUrl('poster') : '';
  video.sources = parseVideoSources(body, baseUrl);

  // 标签（`#巨乳 (12)` → `巨乳`）
  const tags: string[] = [];
  const tagElements: HtmlNode[] = body.getElementsByClass('single-video-tag');
  for (let i: number = 0; i < tagElements.length; i++) {
    const child: HtmlNode | null = tagElements[i].childOrNull(0);
    if (child === null || !child.hasAttr('href')) {
      continue;
    }
    const tagText: string = child.text().trim();
    const beforeCount: string = tagText.indexOf(' (') >= 0
      ? tagText.substring(0, tagText.indexOf(' ('))
      : tagText;
    const cleaned: string = beforeCount.startsWith('#')
      ? beforeCount.substring(1).trim()
      : beforeCount.trim();
    if (cleaned.length > 0) {
      tags.push(cleaned);
    }
  }
  video.tags = tags;

  // 我的清单 / 稍后再看
  video.myList = parseVideoMyList(body);

  // 系列播放列表
  let playlistWrapper: HtmlNode | null = body.selectFirst('div.video-playlist-wrapper');
  if (playlistWrapper === null) {
    playlistWrapper = body.selectFirst('div[id=video-playlist-wrapper]');
  }
  video.playlist = playlistWrapper !== null
    ? parseVideoPlaylist(playlistWrapper)
    : null;

  // 相关推荐 / 作者 / 原作漫画 / 评论总数
  video.relatedHanimes = parseRelatedHanimes(body);
  video.artist = parseArtist(body);
  const comicNode: HtmlNode | null = body.selectFirst('a.video-comic-btn');
  video.originalComic = comicNode !== null ? absOrRaw(comicNode, 'href') : '';
  video.commentCount = parseIntOr(
    textOf(body.selectFirst('#tab-comments-count')).trim(), 0
  );

  return video;
}

// ----------------------------------------------------------------------
// 我的清单 / 播放清单 / 账号
// ----------------------------------------------------------------------

/**
 * 我的清单 / 在线历史 / 播放清单内视频 解析
 * （对应 `myListItems` + `myPlayListItems` + `onlineWatchHistoryItems`）。
 *
 * 三种页面共用同一个返回模型 MyListPage，选择器按上游顺序尝试：
 *  1. `.horizontal-row` 下 `div[class^=user-tab-item-wrapper]`（我的清单/历史）；
 *  2. `.playlist-video-list` 下同样结构（播放清单详情页）。
 */
export function parseMyListPage(html: string, baseUrl: string): MyListPage {
  const page: MyListPage = emptyMyListPage();
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();

  page.csrfToken = extractCsrf(body, doc);

  // 描述：我的清单用 #playlist-show-description，播放清单用 p.playlist-description
  const showDescription: HtmlNode | null = body.getElementById('playlist-show-description');
  if (showDescription !== null) {
    page.desc = showDescription.ownText().trim();
  }
  if (page.desc.length === 0) {
    const playlistDescriptions: HtmlNode[] = body.select('p.playlist-description');
    if (playlistDescriptions.length > 0) {
      page.desc = playlistDescriptions[0].text().trim();
    }
  }

  const selector: string = 'div[class^=user-tab-item-wrapper]';
  const horizontalRows: HtmlNode[] = body.getElementsByClass('horizontal-row');
  if (horizontalRows.length > 0) {
    page.items = extractHanimeInfos(horizontalRows[0], selector);
  }
  if (page.items.length === 0) {
    const playlistLists: HtmlNode[] = body.getElementsByClass('playlist-video-list');
    if (playlistLists.length > 0) {
      page.items = extractHanimeInfos(playlistLists[0], selector);
    }
  }

  page.maxPage = parseListMaxPage(body);
  return page;
}

/**
 * 我的播放清单列表页解析（对应 Parser.kt `playlists`）。
 * 每个 `user-tab-item-wrapper` 是一个播放清单卡片。
 */
export function parsePlaylistsPage(html: string, baseUrl: string): PlaylistsPage {
  const page: PlaylistsPage = emptyPlaylistsPage();
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();

  page.csrfToken = extractCsrf(body, doc);

  const wrappers: HtmlNode[] = body.getElementsByClass('user-tab-item-wrapper');
  for (let i: number = 0; i < wrappers.length; i++) {
    const wrapper: HtmlNode = wrappers[i];
    const link: HtmlNode | null = wrapper.selectFirst('a[class=video-link]');
    const href: string = absOrRaw(link, 'href');
    const equalsIndex: number = href.indexOf('=');
    const listCode: string = equalsIndex >= 0 ? href.substring(equalsIndex + 1) : '';
    const title: string = ownTextOf(wrapper.selectFirst('div[class=title]')).trim();
    if (listCode.length === 0 || title.length === 0) {
      continue;
    }
    const totalText: string = textOf(wrapper.selectFirst('div[class=stat-item]'));
    const digits: string = totalText.replace(/[^\d]/g, '');
    const total: number = digits.length > 0 ? parseIntOr(digits, -1) : -1;
    const covers: HtmlNode[] = wrapper.select('img[class=main-thumb]');
    const coverUrl: string = covers.length > 0 ? absOrRaw(covers[0], 'src') : '';
    const summary: PlaylistSummary = {
      listCode: listCode,
      title: title,
      total: total,
      coverUrl: coverUrl
    };
    page.playlists.push(summary);
  }

  page.maxPage = parseListMaxPage(body);
  return page;
}

/**
 * 账号资料页解析（对应 Parser.kt `userAccountPage`）。
 *
 * 2026-11 改版后 email 输入框变成 `id=email` 且 disabled（只读），
 * 因此这里先找 `#email`，再回退旧版 `input[name=email]`。
 */
export function parseUserAccount(html: string, baseUrl: string): UserAccount {
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
  const doc: HtmlDocument = parseHtml(html, baseUrl);
  const body: HtmlNode = doc.body();

  account.csrfToken = extractCsrf(body, doc);

  const avatarNode: HtmlNode | null = body.selectFirst('img#playlist-avatar');
  account.avatarUrl = absOrRaw(avatarNode, 'src');
  account.username = attrOf(body.selectFirst('input[name=name]'), 'value').trim();

  let emailInput: HtmlNode | null = body.selectFirst('#email');
  if (emailInput === null) {
    emailInput = body.selectFirst('input[name=email]');
  }
  if (emailInput !== null) {
    account.email = emailInput.attr('value').trim();
    account.emailEditable = !emailInput.hasAttr('disabled');
  }

  account.userId = firstNumberText(textOf(body.selectFirst('div.profile-sub-stats-id')));
  account.joinedLabel = textOf(body.selectFirst('#user-modal-created')).trim();

  // 资料页统计行："訂閱 12  影片 34"，按出现顺序取前两个数字
  const statsText: string = textOf(body.selectFirst('div.profile-sub-stats-new-line'));
  const statMatches: RegExpMatchArray | null = statsText.match(/\d+/g);
  if (statMatches !== null) {
    account.subscriberCount = statMatches.length > 0 ? parseIntOr(statMatches[0], 0) : 0;
    account.videoCount = statMatches.length > 1 ? parseIntOr(statMatches[1], 0) : 0;
  }
  return account;
}

/**
 * 从登录页提取 csrf token（对应 Parser.kt `extractTokenFromLoginPage`）。
 * 找不到时返回空串，由网络层决定是否重试（Android 侧会抛 ParseException）。
 */
export function extractCsrfFromLoginPage(html: string): string {
  const doc: HtmlDocument = parseHtml(html, '');
  const input: HtmlNode | null = doc.body().selectFirst('input[name=_token]');
  return attrOf(input, 'value').trim();
}

/** 供测试/调试：把解析结果里的分区标题取出来（保持 Android 的语义顺序） */
export function homeSectionTitles(): string[] {
  const result: string[] = [];
  for (let i: number = 0; i < HOME_SECTION_KEYS.length; i++) {
    result.push(HOME_SECTION_KEYS[i]);
  }
  return result;
}

