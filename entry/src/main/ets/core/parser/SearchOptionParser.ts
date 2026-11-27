/**
 * 搜索筛选项 JSON 解析（纯 TypeScript，ArkTS 可编译）。
 *
 * 契约：`parseOptionList(json, lang)` / `parseOptionMap(json, lang)`。
 *
 * 数据源与 Android `app/src/main/assets/search_options/*.json` 完全一致：
 *  - 列表形态（genre / genre_av / sort_option / duration / release_date / brands）：
 *    `[{ "lang": { "zh-rCN": "...", "zh-rTW": "...", "en": "...", "ja": "..." },
 *        "name": "...", "search_key": "..." }]`
 *  - 映射形态（tags.json）：`{ "video_attributes": [上述项], "character_relationships": [...] }`
 *
 * 语义对齐上游 `SearchOption.kt`：
 *  - `label`：优先 `lang[当前语言]`，该语言缺失时回退 `zh-rTW`，再回退 `name`；
 *  - `key`：取 `search_key`，为 null/缺失时用空串（空串 = "全部"，提交搜索时忽略）；
 *  - 语言键取值：`zh-rCN` / `zh-rTW` / `en` / `ja`。
 *
 * 注意：core 层不允许动态属性访问，但 JSON 解析结果显式转成 `Record<string, ...>`
 * 后索引访问是 ArkTS 允许的；对象字面量也都显式标注了接口类型。
 */

import { SearchOptionItem } from '../model/Models';

/** 站点搜索筛选项的原始 JSON 结构（字段可能缺失或为 null） */
interface RawOption {
  lang?: Record<string, string> | null;
  name?: string | null;
  search_key?: string | null;
}

/** 单条筛选项解析结果（内部用） */
interface ParsedOption {
  label: string;
  key: string;
}

/** `search_key` 缺失/为 null 时表示"全部" */
function resolveKey(raw: RawOption): string {
  const searchKey: string | null | undefined = raw.search_key;
  if (searchKey === undefined || searchKey === null) {
    return '';
  }
  return searchKey;
}

/** `label` 回退链：当前语言 → zh-rTW → name → '' */
function resolveLabel(raw: RawOption, lang: string): string {
  const langs: Record<string, string> | null | undefined = raw.lang;
  if (langs !== undefined && langs !== null) {
    const primary: string | undefined = langs[lang];
    if (primary !== undefined && primary !== null && primary.length > 0) {
      return primary;
    }
    const fallback: string | undefined = langs['zh-rTW'];
    if (fallback !== undefined && fallback !== null && fallback.length > 0) {
      return fallback;
    }
  }
  const name: string | null | undefined = raw.name;
  if (name !== undefined && name !== null && name.length > 0) {
    return name;
  }
  // 极少数数据只有 search_key，没有 name（例如 genre 的第一项）：用 key 兜底显示
  return resolveKey(raw);
}

/** 把一组原始项转成契约里的 SearchOptionItem */
function parseRows(rows: RawOption[], lang: string): SearchOptionItem[] {
  const result: SearchOptionItem[] = [];
  for (let i: number = 0; i < rows.length; i++) {
    const raw: RawOption = rows[i];
    if (raw === undefined || raw === null) {
      continue;
    }
    const label: string = resolveLabel(raw, lang);
    const key: string = resolveKey(raw);
    const item: SearchOptionItem = { label: label, key: key };
    result.push(item);
  }
  return result;
}

/** 安全 JSON 解析：失败返回 null（不抛异常，避免搜索页初始化崩溃） */
function tryParseJson(json: string): Object | null {
  if (json === undefined || json === null || json.length === 0) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(json) as Object;
    return parsed;
  } catch (rawError) {
    // JSON 非法：返回 null，由调用方给出空结果（避免搜索页初始化崩溃）
    return null;
  }
}

/**
 * 解析列表形态的搜索筛选项 JSON。
 * JSON 非法或不是数组时返回空数组（与上游 `loadAssetAs(...).orEmpty()` 一致）。
 */
export function parseOptionList(json: string, lang: string): SearchOptionItem[] {
  const parsed: Object | null = tryParseJson(json);
  if (parsed === null || !Array.isArray(parsed)) {
    return [];
  }
  return parseRows(parsed as RawOption[], lang);
}

/**
 * 解析映射形态的搜索筛选项 JSON（tags.json：作用域 → 选项列表）。
 * JSON 非法或不是对象时返回空 Record；保持 JSON 内的作用域顺序。
 */
export function parseOptionMap(json: string, lang: string): Record<string, SearchOptionItem[]> {
  const result: Record<string, SearchOptionItem[]> = {};
  const parsed: Object | null = tryParseJson(json);
  if (parsed === null || Array.isArray(parsed)) {
    return result;
  }
  const map: Record<string, RawOption[]> = parsed as Record<string, RawOption[]>;
  const keys: string[] = Object.keys(map);
  for (let i: number = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const rows: RawOption[] = map[key];
    if (rows === undefined || rows === null || !Array.isArray(rows)) {
      continue;
    }
    result[key] = parseRows(rows, lang);
  }
  return result;
}
