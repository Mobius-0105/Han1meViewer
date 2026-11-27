/**
 * 本地 SQLite 库结构（`hanime.db`）。
 *
 * 表与 `core/model/Models.ts` 的 `LocalVideoRecord` / `HistoryRecord` 一一对应：
 *  - favorites       本地收藏（videoCode 唯一键）
 *  - watch_later     稍后再看（videoCode 唯一键）
 *  - history         观看历史 + 播放进度（videoCode 唯一键，updatedAt 倒序）
 *  - search_history  搜索历史（keyword 唯一，createdAt 倒序，最多 50 条）
 *
 * 所有建表语句都是 `CREATE TABLE IF NOT EXISTS`，init 时逐条 executeSql 即可，
 * 不需要额外的版本迁移（后续加字段时用 ALTER TABLE 兜底）。
 */

export const DB_NAME: string = 'hanime.db';

export const TABLE_FAVORITES: string = 'favorites';
export const TABLE_WATCH_LATER: string = 'watch_later';
export const TABLE_HISTORY: string = 'history';
export const TABLE_SEARCH_HISTORY: string = 'search_history';

/** 观看历史最多保留条数，超出按 updatedAt 裁剪（对应上游 Room 里无限增长的历史，这里做上限保护）。 */
export const HISTORY_LIMIT: number = 500;

/** 搜索历史最多保留条数。 */
export const SEARCH_HISTORY_LIMIT: number = 50;

export const SQL_CREATE_FAVORITES: string =
  'CREATE TABLE IF NOT EXISTS favorites (' +
  'videoCode TEXT PRIMARY KEY NOT NULL, ' +
  "title TEXT NOT NULL DEFAULT '', " +
  "coverUrl TEXT NOT NULL DEFAULT '', " +
  "uploadTime TEXT NOT NULL DEFAULT '', " +
  "genre TEXT NOT NULL DEFAULT '', " +
  'addedAt INTEGER NOT NULL DEFAULT 0)';

export const SQL_CREATE_WATCH_LATER: string =
  'CREATE TABLE IF NOT EXISTS watch_later (' +
  'videoCode TEXT PRIMARY KEY NOT NULL, ' +
  "title TEXT NOT NULL DEFAULT '', " +
  "coverUrl TEXT NOT NULL DEFAULT '', " +
  "uploadTime TEXT NOT NULL DEFAULT '', " +
  "genre TEXT NOT NULL DEFAULT '', " +
  'addedAt INTEGER NOT NULL DEFAULT 0)';

export const SQL_CREATE_HISTORY: string =
  'CREATE TABLE IF NOT EXISTS history (' +
  'videoCode TEXT PRIMARY KEY NOT NULL, ' +
  "title TEXT NOT NULL DEFAULT '', " +
  "coverUrl TEXT NOT NULL DEFAULT '', " +
  'positionMs INTEGER NOT NULL DEFAULT 0, ' +
  'durationMs INTEGER NOT NULL DEFAULT 0, ' +
  'updatedAt INTEGER NOT NULL DEFAULT 0)';

export const SQL_CREATE_SEARCH_HISTORY: string =
  'CREATE TABLE IF NOT EXISTS search_history (' +
  'id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
  "keyword TEXT NOT NULL UNIQUE, " +
  'createdAt INTEGER NOT NULL DEFAULT 0)';

/** 收藏 / 稍后再看 / 历史都按时间倒序展示。 */
export const SQL_CREATE_INDEX_FAVORITES: string =
  'CREATE INDEX IF NOT EXISTS idx_favorites_addedAt ON favorites (addedAt DESC)';
export const SQL_CREATE_INDEX_WATCH_LATER: string =
  'CREATE INDEX IF NOT EXISTS idx_watch_later_addedAt ON watch_later (addedAt DESC)';
export const SQL_CREATE_INDEX_HISTORY: string =
  'CREATE INDEX IF NOT EXISTS idx_history_updatedAt ON history (updatedAt DESC)';
export const SQL_CREATE_INDEX_SEARCH_HISTORY: string =
  'CREATE INDEX IF NOT EXISTS idx_search_history_createdAt ON search_history (createdAt DESC)';

/** 历史裁剪：只保留最近 HISTORY_LIMIT 条。 */
export const SQL_TRIM_HISTORY: string =
  'DELETE FROM history WHERE videoCode NOT IN ' +
  '(SELECT videoCode FROM history ORDER BY updatedAt DESC LIMIT ' + HISTORY_LIMIT.toString() + ')';

/** 搜索历史裁剪：只保留最近 SEARCH_HISTORY_LIMIT 条。 */
export const SQL_TRIM_SEARCH_HISTORY: string =
  'DELETE FROM search_history WHERE id NOT IN ' +
  '(SELECT id FROM search_history ORDER BY createdAt DESC, id DESC LIMIT ' +
  SEARCH_HISTORY_LIMIT.toString() + ')';

export const SQL_CLEAR_HISTORY: string = 'DELETE FROM history';
export const SQL_CLEAR_SEARCH_HISTORY: string = 'DELETE FROM search_history';

/** init 时按顺序执行的建表 / 建索引语句。 */
export const SQL_INIT_STATEMENTS: string[] = [
  SQL_CREATE_FAVORITES,
  SQL_CREATE_WATCH_LATER,
  SQL_CREATE_HISTORY,
  SQL_CREATE_SEARCH_HISTORY,
  SQL_CREATE_INDEX_FAVORITES,
  SQL_CREATE_INDEX_WATCH_LATER,
  SQL_CREATE_INDEX_HISTORY,
  SQL_CREATE_INDEX_SEARCH_HISTORY
];
