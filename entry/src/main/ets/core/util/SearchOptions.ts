/**
 * 搜索筛选项 JSON 解析（纯逻辑，Node 可直接测试，也可被 ArkTS 编译）。
 *
 * 数据来源：上游 Android 的 `assets/search_options/*.json`，已原样复制到
 * `entry/src/main/resources/rawfile/search_options/`。
 *
 * JSON 有两种形态：
 *  1. 列表：`genre.json` / `genre_av.json` / `sort_option.json` / `duration.json`
 *     / `release_date.json` / `brands.json`，每项形如
 *     `{ "lang": { "zh-rCN": "...", "zh-rTW": "...", "en": "...", "ja": "..." },
 *        "name": "...", "search_key": "..." }`；
 *  2. 映射：`tags.json`，形如 `{ "video_attributes": [上述项], ... }`。
 *
 * 语义对齐上游 `SearchOption.kt`：
 *  - label：有 `lang` 时按当前语言取，取不到回退 `zh-rTW`（上游行为），
 *    再回退 `zh-rCN` / `en` / `ja` / `name` / `search_key`；无 `lang` 时取 `name`；
 *  - key：`search_key`，为 `null`/缺失时用空串（UI 以此表示"全部"，提交时忽略）。
 *
 * 注意：本文件必须遵守 ArkTS 限制（core/** 会被 ArkTS 编译）——
 * 不用 any / enum / 对象展开 / 动态属性访问（Record 除外）。
 */

import { SearchOptionItem } from '../model/Models';

/** 站点 JSON 里一项搜索筛选项的原始形态（字段可能缺失或为 null）。 */
export interface RawOption {
  lang?: Record<string, string> | null;
  name?: string | null;
  search_key?: string | null;
}

/** 站点支持的语言键，顺序即 label 的回退顺序（第一个是请求语言，特殊处理）。 */
const FALLBACK_LANGS: string[] = ['zh-rTW', 'zh-rCN', 'en', 'ja'];

export const SEARCH_OPTION_SCOPES: string[] = [
  'video_attributes',
  'character_relationships',
  'characteristics',
  'appearance_and_figure',
  'story_plot',
  'story_location',
  'sex_positions'
];

/**
 * 解析列表形态的搜索筛选项 JSON。
 * JSON 非法、不是数组时返回空数组（与上游 `loadAssetAs(...).orEmpty()` 一致）。
 */
export function parseOptionList(json: string, lang: string): SearchOptionItem[] {
  const parsed: Object | null = tryParseJson(json);
  if (parsed === null) {
    return [];
  }
  if (!Array.isArray(parsed)) {
    return [];
  }
  return parseRows(parsed as RawOption[], lang);
}

/**
 * 解析映射形态的搜索筛选项 JSON（tags.json：作用域 → 选项列表）。
 * JSON 非法、不是对象时返回空 Record；保持 JSON 内的作用域顺序。
 */
export function parseOptionMap(json: string, lang: string): Record<string, SearchOptionItem[]> {
  const result: Record<string, SearchOptionItem[]> = {};
  const parsed: Object | null = tryParseJson(json);
  if (parsed === null || Array.isArray(parsed)) {
    return result;
  }
  const map: Record<string, RawOption[]> = parsed as Record<string, RawOption[]>;
  const keys: string[] = Object.keys(map);
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const rows: RawOption[] = map[key];
    if (!Array.isArray(rows)) {
      continue;
    }
    result[key] = parseRows(rows, lang);
  }
  return result;
}

/** tags.json 的作用域键（保持 JSON 顺序）。 */
export function scopeKeys(map: Record<string, SearchOptionItem[]>): string[] {
  return Object.keys(map);
}

/** 把一组原始项转成 UI 用的 SearchOptionItem。 */
function parseRows(rows: RawOption[], lang: string): SearchOptionItem[] {
  const result: SearchOptionItem[] = [];
  for (let i = 0; i < rows.length; i++) {
    const raw: RawOption = rows[i];
    if (raw === null || raw === undefined) {
      continue;
    }
    const label: string = resolveLabel(raw, lang);
    const key: string = resolveKey(raw);
    const item: SearchOptionItem = { label: label, key: key };
    result.push(item);
  }
  return result;
}

/**
 * label 回退链：请求语言 → zh-rTW → zh-rCN → en → ja → name → search_key → ''。
 * 上游 `SearchOption.value` 在语言不匹配时固定回退 zh-rTW，这里保持一致；
 * 但部分文件（如 genre_av.json）缺 ja，故继续按顺序兜底，避免出现空标签。
 */
function resolveLabel(raw: RawOption, lang: string): string {
  const langs: Record<string, string> | null | undefined = raw.lang;
  if (langs !== null && langs !== undefined) {
    const primary: string | undefined = langs[lang];
    if (primary !== undefined && primary !== null && primary.length > 0) {
      return primary;
    }
    for (let i = 0; i < FALLBACK_LANGS.length; i++) {
      const value: string | undefined = langs[FALLBACK_LANGS[i]];
      if (value !== undefined && value !== null && value.length > 0) {
        return value;
      }
    }
  }
  const name: string | null | undefined = raw.name;
  if (name !== undefined && name !== null && name.length > 0) {
    return name;
  }
  const searchKey: string | null | undefined = raw.search_key;
  if (searchKey !== undefined && searchKey !== null) {
    return searchKey;
  }
  return '';
}

/** key 为 `search_key`；null/缺失 → 空串（= 全部，提交搜索时不带该参数）。 */
function resolveKey(raw: RawOption): string {
  const key: string | null | undefined = raw.search_key;
  if (key === undefined || key === null) {
    return '';
  }
  return key;
}

function tryParseJson(json: string): Object | null {
  if (json === undefined || json === null || json.length === 0) {
    return null;
  }
  try {
    return JSON.parse(json) as Object;
  } catch (err) {
    // JSON 非法：返回 null 由调用方给出空结果，避免启动期崩溃
    return null;
  }
}
