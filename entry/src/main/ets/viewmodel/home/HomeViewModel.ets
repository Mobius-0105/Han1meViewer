/**
 * 首页数据整形（ViewModel 层，纯逻辑，不做网络请求）。
 *
 * 职责：
 *  - 把 `HomePage` 解析结果整理成 UI 可直接渲染的「banner + 分区行」；
 *  - 分区顺序与站点固定栏目的对应关系集中在这里（标题 → 高级搜索参数）；
 *  - 为「更多」跳转的 `SearchResultPage` 提供按标题反查搜索参数的能力。
 *
 * 为什么单独放一份分区定义：
 *  - 首页只拿得到 `HomePage` 的各个数组字段，不知道它们对应的站点筛选参数；
 *  - 搜索结果页通过 `Router.openSearchResult(分区标题)` 进入，只带得了一个字符串，
 *    必须能在本地把标题还原成 genre/sort/tags，才能得到正确的分区结果。
 *
 * 注意：站点搜索参数使用站点自身的繁体/日文键（如「裏番」「最新上傳」），
 * 与展示标题（简体）不是一回事，不要混用。
 */

import { HanimeInfo, HomePage } from '../../core/model/Models';
import { NEW_ANIME_PREVIEW_GENRE } from '../../core/util/Constants';

/** 首页 banner 的展示状态（用 class 而不是可空对象，方便 ArkUI @State 整体替换）。 */
export class BannerState {
  title: string = '';
  description: string = '';
  picUrl: string = '';
  videoCode: string = '';
  hasValue: boolean = false;
}

/** 首页一个横向卡片分区。 */
export class HomeSection {
  /** 展示标题；也是「更多」跳转时传给 SearchResultPage 的 query */
  title: string = '';
  /** 站点高级搜索的「类型」参数；空串表示不限定 */
  genre: string = '';
  /** 站点高级搜索的「排序」参数；空串表示不限定 */
  sort: string = '';
  /** 站点高级搜索的「标签」参数 */
  tags: string[] = [];
  /** 该分区要展示的视频 */
  items: HanimeInfo[] = [];
  /**
   * 数据版本（取首页解析时间戳）。
   * 用作 ForEach 的 key：下拉刷新后即使分区标题不变，也能让横向列表整体重建，
   * 避免 @Builder 按值传参导致的旧卡片残留。
   */
  version: number = 0;
}

/** 分区静态定义（标题 + 站点搜索参数）。 */
class HomeSectionSpec {
  title: string = '';
  genre: string = '';
  sort: string = '';
  tags: string[] = [];
}

function spec(title: string, genre: string, sort: string, tags: string[]): HomeSectionSpec {
  const item: HomeSectionSpec = new HomeSectionSpec();
  item.title = title;
  item.genre = genre;
  item.sort = sort;
  item.tags = tags;
  return item;
}

/**
 * 分区顺序（与任务要求的展示顺序一致）：
 * 最新上市 → 最新上传 → 里番 → 泡面番 → Motion Anime → 3DCG → 2.5D → 2D
 * → AI生成 → MMD → Cosplay → 他们在看 → 新番预告
 */
const SECTION_SPECS: HomeSectionSpec[] = [
  spec('最新上市', '', '最新上市', []),
  spec('最新上传', '', '最新上傳', []),
  spec('里番', '裏番', '', []),
  spec('泡面番', '泡麵番', '最新上傳', []),
  spec('Motion Anime', 'Motion Anime', '最新上傳', []),
  spec('3DCG', '3DCG', '最新上傳', []),
  spec('2.5D', '2.5D', '最新上傳', []),
  spec('2D', '2D動畫', '最新上傳', []),
  spec('AI生成', 'AI生成', '最新上傳', []),
  spec('MMD', 'MMD', '最新上傳', []),
  spec('Cosplay', 'Cosplay', '最新上傳', []),
  spec('他们在看', '', '他們在看', []),
  spec('新番预告', NEW_ANIME_PREVIEW_GENRE, '', [])
];

/** 空的筛选键（站点列表里表示「全部」的键可能是 '全部' 或 null → ''）。 */
function isEmptyKey(key: string): boolean {
  return key.length === 0 || key === '全部';
}

/** 由静态定义生成一个空分区（items 由调用者填）。 */
function sectionFromSpec(item: HomeSectionSpec): HomeSection {
  const section: HomeSection = new HomeSection();
  section.title = item.title;
  section.genre = item.genre;
  section.sort = item.sort;
  section.tags = item.tags;
  return section;
}

/**
 * 把解析结果整理成分区列表。
 * 空分区直接跳过（站点改版/解析字段缺失时首页依然可用）。
 * @param version 数据版本，用于 ForEach key；每次成功加载传一个新的值即可让列表重建。
 */
export function buildHomeSections(page: HomePage, version: number = 0): HomeSection[] {
  const groups: HanimeInfo[][] = [
    page.latestRelease,
    page.latestHanime,
    page.ecchiAnime,
    page.shortEpisodeAnime,
    page.motionAnime,
    page.threeDCG,
    page.twoPointFiveDAnime,
    page.twoDAnime,
    page.aiGenerated,
    page.mmd,
    page.cosplay,
    page.watchingNow,
    page.newAnimeTrailer
  ];
  const sections: HomeSection[] = [];
  const count: number = SECTION_SPECS.length < groups.length ? SECTION_SPECS.length : groups.length;
  for (let i = 0; i < count; i++) {
    const items: HanimeInfo[] = groups[i];
    if (items.length === 0) {
      continue;
    }
    const section: HomeSection = sectionFromSpec(SECTION_SPECS[i]);
    section.items = items;
    section.version = version > 0 ? version : page.timestamp;
    sections.push(section);
  }
  return sections;
}

/**
 * 按展示标题（或站点参数键）反查分区，用于 SearchResultPage 把
 * `Router.openSearchResult(分区标题)` 还原成正确的搜索参数。
 * 找不到时返回 null（调用方按普通关键词搜索处理）。
 */
export function findHomeSectionByTitle(title: string): HomeSection | null {
  const target: string = title.trim();
  if (target.length === 0) {
    return null;
  }
  for (let i = 0; i < SECTION_SPECS.length; i++) {
    if (SECTION_SPECS[i].title === target) {
      return sectionFromSpec(SECTION_SPECS[i]);
    }
  }
  // 兼容直接传站点键（繁体）的情况
  for (let i = 0; i < SECTION_SPECS.length; i++) {
    const genre: string = SECTION_SPECS[i].genre;
    if (genre.length > 0 && !isEmptyKey(genre) && genre === target) {
      return sectionFromSpec(SECTION_SPECS[i]);
    }
  }
  return null;
}

/** 视频的副标题：「作者 · 播放量 · 上传时间」。 */
function videoSubtitle(item: HanimeInfo): string {
  const parts: string[] = [];
  if (item.currentArtist.length > 0) {
    parts.push(item.currentArtist);
  }
  if (item.views.length > 0) {
    parts.push(item.views);
  }
  if (item.uploadTime.length > 0) {
    parts.push(item.uploadTime);
  }
  return parts.join(' · ');
}

/** 从各分区里挑第一个可用视频，作为 banner 缺失时的兜底大图。 */
function firstAvailableVideo(page: HomePage): HanimeInfo | null {
  const groups: HanimeInfo[][] = [
    page.watchingNow,
    page.latestRelease,
    page.latestHanime,
    page.ecchiAnime,
    page.shortEpisodeAnime,
    page.motionAnime,
    page.threeDCG,
    page.twoPointFiveDAnime,
    page.twoDAnime,
    page.aiGenerated,
    page.mmd,
    page.cosplay,
    page.newAnimeTrailer
  ];
  for (let i = 0; i < groups.length; i++) {
    if (groups[i].length > 0) {
      return groups[i][0];
    }
  }
  return null;
}

/**
 * 构建 banner 展示状态。
 * 站点运营位存在则优先使用；解析缺失时用「他们在看」等分区的第一条视频兜底，
 * 避免首页顶部出现大片空白。
 */
export function buildBanner(page: HomePage): BannerState {
  const state: BannerState = new BannerState();
  const banner = page.banner;
  if (banner !== null && banner.picUrl.length > 0) {
    state.title = banner.title;
    state.description = banner.description;
    state.picUrl = banner.picUrl;
    state.videoCode = banner.videoCode;
    state.hasValue = true;
    return state;
  }
  const fallback: HanimeInfo | null = firstAvailableVideo(page);
  if (fallback !== null && fallback.coverUrl.length > 0) {
    state.title = fallback.title;
    state.description = videoSubtitle(fallback);
    state.picUrl = fallback.coverUrl;
    state.videoCode = fallback.videoCode;
    state.hasValue = true;
  }
  return state;
}

/** 判断首页是否完全没有内容（用于空态判定）。 */
export function isHomePageEmpty(page: HomePage): boolean {
  const banner = page.banner;
  if (banner !== null && banner.picUrl.length > 0) {
    return false;
  }
  return buildHomeSections(page).length === 0;
}
