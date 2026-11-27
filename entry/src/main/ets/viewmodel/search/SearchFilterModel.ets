/**
 * 搜索筛选条件模型 + 跨页面 JSON 约定。
 *
 * 跨页面契约（SearchPage / AdvancedSearchPage / 首页搜索入口共用）：
 *  - AppStorage 键：`searchFilterJson`（string）；
 *  - 值是下面 `SearchFilterJson` 的 `JSON.stringify` 结果，缺字段/非法 JSON 全部按默认值处理；
 *  - AdvancedSearchPage 写入，SearchPage 用 `@StorageLink('searchFilterJson') @Watch(...)` 接收并搜索。
 *
 * JSON 结构（字段与 `SearchRequest` 对齐）：
 * {
 *   "query":    "关键词",        // 可空串
 *   "genre":    "裏番",          // 类型 key，'' = 全部
 *   "sort":     "最新上市",      // 排序 key，'' = 全部
 *   "date":     "2024 年 1 月",  // 发布日期 key，'' = 全部
 *   "duration": "1-5 分钟",      // 时长 key，'' = 全部
 *   "broad":    false,           // 是否「广泛搜索」
 *   "tags":     ["巨乳"],        // 标签 key 数组，空数组 = 不筛选
 *   "brands":   ["メリー・ジェーン"] // 品牌 key 数组，空数组 = 不筛选
 * }
 *
 * ArkTS 注意：JSON.parse 的结果显式转成已声明接口；不使用对象展开/any/enum。
 */

import { SearchRequest } from '../../core/model/Models';

/** AppStorage 中筛选条件 JSON 的键名。 */
export const SEARCH_FILTER_KEY: string = 'searchFilterJson';

/** 列表里表示「全部」的展示文案。 */
export const ALL_OPTION_LABEL: string = '全部';

/** 站点筛选项里表示「全部」的 key（不同 json 里有 '' / '全部' 两种写法）。 */
export function isAllOptionKey(key: string): boolean {
  return key.length === 0 || key === ALL_OPTION_LABEL;
}

/** 站点 key → 搜索参数值（'' 表示不提交该筛选项）。 */
export function normalizeOptionKey(key: string): string {
  return isAllOptionKey(key) ? '' : key;
}

/** 筛选条件状态（UI 直接持有；字段类型与 SearchRequest 对齐）。 */
export class SearchFilter {
  query: string = '';
  genre: string = '';
  sort: string = '';
  date: string = '';
  duration: string = '';
  broad: boolean = false;
  tags: string[] = [];
  brands: string[] = [];
}

/** JSON 解析用的宽松接口：所有字段可缺省，兼容旧版本写入的数据。 */
interface SearchFilterJson {
  query?: string;
  genre?: string;
  sort?: string;
  date?: string;
  duration?: string;
  broad?: boolean;
  tags?: string[];
  brands?: string[];
}

export function emptySearchFilter(): SearchFilter {
  return new SearchFilter();
}

/** 深拷贝（数组单独复制，避免两个页面共享同一份 tags 数组）。 */
export function cloneSearchFilter(src: SearchFilter): SearchFilter {
  const filter: SearchFilter = new SearchFilter();
  filter.query = src.query;
  filter.genre = src.genre;
  filter.sort = src.sort;
  filter.date = src.date;
  filter.duration = src.duration;
  filter.broad = src.broad;
  filter.tags = src.tags.slice();
  filter.brands = src.brands.slice();
  return filter;
}

/** 是否设置了任何高级筛选项（不含关键词）。 */
export function hasAdvancedFilter(filter: SearchFilter): boolean {
  return filter.genre.length > 0 || filter.sort.length > 0 || filter.date.length > 0 ||
    filter.duration.length > 0 || filter.broad || filter.tags.length > 0 || filter.brands.length > 0;
}

/** 是否有可执行的搜索条件（关键词或高级筛选任一）。 */
export function hasSearchCondition(filter: SearchFilter): boolean {
  return filter.query.trim().length > 0 || hasAdvancedFilter(filter);
}

/** 序列化成 AppStorage 约定 JSON。 */
export function encodeSearchFilter(filter: SearchFilter): string {
  const json: SearchFilterJson = {
    query: filter.query,
    genre: filter.genre,
    sort: filter.sort,
    date: filter.date,
    duration: filter.duration,
    broad: filter.broad,
    tags: filter.tags,
    brands: filter.brands
  };
  return JSON.stringify(json);
}

/** 从 AppStorage JSON 还原；空串/非法 JSON 返回空筛选（不抛异常）。 */
export function decodeSearchFilter(json: string): SearchFilter {
  const filter: SearchFilter = new SearchFilter();
  if (json.length === 0) {
    return filter;
  }
  let raw: SearchFilterJson;
  try {
    raw = JSON.parse(json) as SearchFilterJson;
  } catch (err) {
    return filter;
  }
  if (raw === null || raw === undefined) {
    return filter;
  }
  if (raw.query !== undefined && raw.query !== null) {
    filter.query = raw.query;
  }
  if (raw.genre !== undefined && raw.genre !== null) {
    filter.genre = raw.genre;
  }
  if (raw.sort !== undefined && raw.sort !== null) {
    filter.sort = raw.sort;
  }
  if (raw.date !== undefined && raw.date !== null) {
    filter.date = raw.date;
  }
  if (raw.duration !== undefined && raw.duration !== null) {
    filter.duration = raw.duration;
  }
  if (raw.broad !== undefined && raw.broad !== null) {
    filter.broad = raw.broad;
  }
  if (Array.isArray(raw.tags)) {
    filter.tags = raw.tags.slice();
  }
  if (Array.isArray(raw.brands)) {
    filter.brands = raw.brands.slice();
  }
  return filter;
}

/** 组装 API 请求参数（page 从 1 开始）。 */
export function toSearchRequest(filter: SearchFilter, page: number): SearchRequest {
  const request: SearchRequest = {
    page: page,
    query: filter.query.trim(),
    genre: filter.genre,
    sort: filter.sort,
    broad: filter.broad,
    date: filter.date,
    duration: filter.duration,
    tags: filter.tags.slice(),
    brands: filter.brands.slice()
  };
  return request;
}

/** 筛选条件摘要（搜索结果页/搜索 Tab 顶部展示用，不查数据源只给数量）。 */
export function buildFilterSummary(filter: SearchFilter): string {
  const parts: string[] = [];
  if (filter.genre.length > 0) {
    parts.push('类型');
  }
  if (filter.sort.length > 0) {
    parts.push('排序');
  }
  if (filter.date.length > 0) {
    parts.push('日期');
  }
  if (filter.duration.length > 0) {
    parts.push('时长');
  }
  if (filter.brands.length > 0) {
    parts.push('品牌×' + filter.brands.length);
  }
  if (filter.tags.length > 0) {
    parts.push('标签×' + filter.tags.length);
  }
  if (filter.broad) {
    parts.push('广泛搜索');
  }
  if (parts.length === 0) {
    return '';
  }
  return '已筛选：' + parts.join(' · ');
}

/** 数组里是否包含某值。 */
export function containsValue(list: string[], value: string): boolean {
  for (let i = 0; i < list.length; i++) {
    if (list[i] === value) {
      return true;
    }
  }
  return false;
}

/** 从数组里移除给定值，返回新数组（ArkTS 状态更新必须整体重新赋值）。 */
export function removeValues(list: string[], values: string[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < list.length; i++) {
    if (!containsValue(values, list[i])) {
      result.push(list[i]);
    }
  }
  return result;
}
