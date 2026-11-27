/**
 * 本地数据库入口（单例）。
 *
 * 技术选型：`@kit.ArkData` 的 `relationalStore`（SQLite），库名 `hanime.db`，
 * securityLevel S1。对应 Android 侧 `HistoryDatabase`（Room）里的搜索历史 /
 * 观看历史，外加本项目新增的「本地收藏 / 稍后再看」两张表。
 *
 * 初始化时序：EntryAbility.onCreate 里 `await AppDb.getInstance().init(context)`。
 * 所有公开方法内部都 `await this.ready`，因此即使 init 尚未完成（甚至尚未开始调用），
 * 调用方也不需要自己判空——它们会挂起等待 init 结束。若 init 未调用且永远不会调用，
 * 这些 Promise 会一直 pending，这是调用方的责任（启动时必须 init）。
 *
 * ArkTS 注意：ValuesBucket 用 `Record<string, relationalStore.ValueType>` 逐步赋值
 * （ArkTS 禁止动态属性访问，但 Record 是例外），避免对象字面量 + 动态键的写法。
 */

import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HistoryRecord, LocalVideoRecord } from '../../core/model/Models';
import {
  DB_NAME,
  HISTORY_LIMIT,
  SEARCH_HISTORY_LIMIT,
  SQL_CLEAR_HISTORY,
  SQL_CLEAR_SEARCH_HISTORY,
  SQL_INIT_STATEMENTS,
  SQL_TRIM_HISTORY,
  SQL_TRIM_SEARCH_HISTORY,
  TABLE_FAVORITES,
  TABLE_HISTORY,
  TABLE_SEARCH_HISTORY,
  TABLE_WATCH_LATER
} from './Schema';

const DOMAIN: number = 0x0001;
const TAG: string = 'AppDb';
/** init 未完成时数据库方法的最长等待时间：避免页面永久 loading */
const DB_INIT_TIMEOUT_MS: number = 8000;

const VIDEO_COLUMNS: string[] = ['videoCode', 'title', 'coverUrl', 'uploadTime', 'genre', 'addedAt'];
const HISTORY_COLUMNS: string[] = [
  'videoCode',
  'title',
  'coverUrl',
  'positionMs',
  'durationMs',
  'updatedAt'
];

export class AppDb {
  private static instance: AppDb | null = null;

  private store: relationalStore.RdbStore | null = null;
  /** init 完成（成功或失败）后 resolve；init 之前调用数据库方法会在这里等待。 */
  private ready: Promise<void>;
  private readyResolver: () => void = () => {};
  private initStarted: boolean = false;

  private constructor() {
    this.ready = new Promise<void>((resolve: () => void) => {
      this.readyResolver = resolve;
    });
  }

  static getInstance(): AppDb {
    if (AppDb.instance === null) {
      AppDb.instance = new AppDb();
    }
    return AppDb.instance;
  }

  /**
   * 打开数据库并建表。幂等：重复调用（含并发调用）只会初始化一次。
   * 初始化失败时只记录日志、不抛异常，后续数据库方法会抛「未初始化」错误。
   */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initStarted) {
      await this.ready;
      return;
    }
    this.initStarted = true;
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      for (let i = 0; i < SQL_INIT_STATEMENTS.length; i++) {
        await store.executeSql(SQL_INIT_STATEMENTS[i]);
      }
      this.store = store;
      hilog.info(DOMAIN, TAG, '本地数据库初始化完成');
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `本地数据库初始化失败: code=${error.code}, message=${error.message}`);
    } finally {
      this.resolveReady();
    }
  }

  // ---------------------------------------------------------------------------
  // 收藏
  // ---------------------------------------------------------------------------

  async addFavorite(item: LocalVideoRecord): Promise<void> {
    await this.insertVideoRecord(TABLE_FAVORITES, item);
  }

  async removeFavorite(videoCode: string): Promise<void> {
    await this.deleteVideoRecord(TABLE_FAVORITES, videoCode);
  }

  async isFavorite(videoCode: string): Promise<boolean> {
    return this.hasVideoRecord(TABLE_FAVORITES, videoCode);
  }

  async listFavorites(): Promise<LocalVideoRecord[]> {
    return this.listVideoRecords(TABLE_FAVORITES);
  }

  // ---------------------------------------------------------------------------
  // 稍后再看
  // ---------------------------------------------------------------------------

  async addWatchLater(item: LocalVideoRecord): Promise<void> {
    await this.insertVideoRecord(TABLE_WATCH_LATER, item);
  }

  async removeWatchLater(videoCode: string): Promise<void> {
    await this.deleteVideoRecord(TABLE_WATCH_LATER, videoCode);
  }

  async isWatchLater(videoCode: string): Promise<boolean> {
    return this.hasVideoRecord(TABLE_WATCH_LATER, videoCode);
  }

  async listWatchLater(): Promise<LocalVideoRecord[]> {
    return this.listVideoRecords(TABLE_WATCH_LATER);
  }

  // ---------------------------------------------------------------------------
  // 观看历史（同时保存播放进度）
  // ---------------------------------------------------------------------------

  /**
   * 写入/更新观看历史（videoCode 唯一）。
   *
   * 合并语义（对齐上游 Room `WatchHistoryDao.insertOrUpdate`）：
   *  - 详情页进入时会以 positionMs=0/durationMs=0 记录历史，**不能覆盖**已有进度；
   *  - 播放器节流写进度时 title/coverUrl 可能为空，也不能覆盖已有元信息；
   *  - 进度接近结尾（>=95%）视为看完，把进度归 0，下次从头播（避免"打开就是最后一帧"）。
   * 最后按 updatedAt 裁剪到 HISTORY_LIMIT 条。
   */
  async upsertHistory(rec: HistoryRecord): Promise<void> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const existing: HistoryRecord | null = await this.getHistory(rec.videoCode);
    let positionMs: number = rec.positionMs;
    let durationMs: number = rec.durationMs;
    let title: string = rec.title;
    let coverUrl: string = rec.coverUrl;
    if (existing !== null) {
      if (positionMs <= 0 && existing.positionMs > 0) {
        positionMs = existing.positionMs;
      }
      if (durationMs <= 0 && existing.durationMs > 0) {
        durationMs = existing.durationMs;
      }
      if (title.length === 0) {
        title = existing.title;
      }
      if (coverUrl.length === 0) {
        coverUrl = existing.coverUrl;
      }
    }
    // 已看完：重置为从头开始（仅在能确定总时长时）
    if (durationMs > 0 && positionMs >= durationMs * 0.95) {
      positionMs = 0;
    }
    const values: Record<string, relationalStore.ValueType> = {};
    values['videoCode'] = rec.videoCode;
    values['title'] = title;
    values['coverUrl'] = coverUrl;
    values['positionMs'] = positionMs;
    values['durationMs'] = durationMs;
    values['updatedAt'] = rec.updatedAt;
    await store.insert(TABLE_HISTORY, values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
    await store.executeSql(SQL_TRIM_HISTORY);
  }

  /**
   * 原子写播放进度（断点续播的落盘入口）。
   *
   * 为什么不复用 `upsertHistory`：后者是「先读旧行再整行 REPLACE」的读-改-写，
   * 详情页入口写历史与播放器 5s 节流落盘并发时，后写的那次会带着它读到的旧值覆盖新进度；
   * 而且它的「positionMs 为 0 时保留旧值」合并语义会让「从头播放」写 0 永远不生效。
   * 这里用一条 UPDATE 精确写 positionMs/durationMs/updatedAt：
   *  - 只动进度列，title/coverUrl 等元信息完全不动（不会被空串覆盖）；
   *  - positionMs 按调用方给的值精确写入（0 也写，代表显式归零）；
   *  - durationMs <= 0 时只更新位置、保留旧时长；
   *  - 没有历史行且 createIfMissing=true 时插入一条只有进度的最小记录（元信息由详情页补全）。
   * @returns 是否命中已有历史行
   */
  async updateProgress(videoCode: string, positionMs: number, durationMs: number,
    createIfMissing: boolean): Promise<boolean> {
    if (videoCode.length === 0) {
      return false;
    }
    const store: relationalStore.RdbStore = await this.waitStore();
    const position: number = positionMs > 0 ? Math.round(positionMs) : 0;
    const values: Record<string, relationalStore.ValueType> = {};
    values['positionMs'] = position;
    if (durationMs > 0) {
      values['durationMs'] = Math.round(durationMs);
    }
    values['updatedAt'] = Date.now();
    const predicates = new relationalStore.RdbPredicates(TABLE_HISTORY);
    predicates.equalTo('videoCode', videoCode);
    const rows: number = await store.update(values, predicates);
    if (rows > 0) {
      return true;
    }
    if (!createIfMissing) {
      return false;
    }
    const insertValues: Record<string, relationalStore.ValueType> = {};
    insertValues['videoCode'] = videoCode;
    insertValues['title'] = '';
    insertValues['coverUrl'] = '';
    insertValues['positionMs'] = position;
    insertValues['durationMs'] = durationMs > 0 ? Math.round(durationMs) : 0;
    insertValues['updatedAt'] = Date.now();
    try {
      await store.insert(TABLE_HISTORY, insertValues);
    } catch (e) {
      // 并发下另一条写路径刚插入了同一行：改成 UPDATE 把进度写进去（不整行 REPLACE 覆盖元信息）
      await store.update(values, predicates);
    }
    await store.executeSql(SQL_TRIM_HISTORY);
    return true;
  }

  /**
   * 详情页进入时「记录一条历史」：只刷新 title / coverUrl / updatedAt，
   * **绝不写 positionMs / durationMs**（进度只由播放器写）。
   *
   * 已有行用一条 UPDATE 原子完成，不存在「读到旧进度再写回」的窗口；
   * 没有行才插入 0 进度记录（插入不带冲突替换，避免并发下用 0 覆盖别处刚写入的进度）。
   */
  async touchHistory(videoCode: string, title: string, coverUrl: string): Promise<void> {
    if (videoCode.length === 0) {
      return;
    }
    const store: relationalStore.RdbStore = await this.waitStore();
    const now: number = Date.now();
    const updateValues: Record<string, relationalStore.ValueType> = {};
    updateValues['updatedAt'] = now;
    if (title.length > 0) {
      updateValues['title'] = title;
    }
    if (coverUrl.length > 0) {
      updateValues['coverUrl'] = coverUrl;
    }
    const predicates = new relationalStore.RdbPredicates(TABLE_HISTORY);
    predicates.equalTo('videoCode', videoCode);
    const rows: number = await store.update(updateValues, predicates);
    if (rows > 0) {
      return;
    }
    const values: Record<string, relationalStore.ValueType> = {};
    values['videoCode'] = videoCode;
    values['title'] = title;
    values['coverUrl'] = coverUrl;
    values['positionMs'] = 0;
    values['durationMs'] = 0;
    values['updatedAt'] = now;
    try {
      await store.insert(TABLE_HISTORY, values);
    } catch (e) {
      // 并发下已有其它写路径插入了这一行：忽略即可（不能用 REPLACE，否则会把刚写入的进度清成 0）
    }
    await store.executeSql(SQL_TRIM_HISTORY);
  }

  /** 按 updatedAt 倒序；limit <= 0 时使用默认上限 HISTORY_LIMIT。 */
  async listHistory(limit: number): Promise<HistoryRecord[]> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const count: number = limit > 0 ? limit : HISTORY_LIMIT;
    const predicates = new relationalStore.RdbPredicates(TABLE_HISTORY);
    predicates.orderByDesc('updatedAt');
    predicates.limitAs(count);
    const resultSet: relationalStore.ResultSet = await store.query(predicates, HISTORY_COLUMNS);
    const list: HistoryRecord[] = [];
    try {
      while (resultSet.goToNextRow()) {
        list.push(this.readHistoryRecord(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return list;
  }

  /** 单条历史（播放器恢复进度用）；不存在返回 null。 */
  async getHistory(videoCode: string): Promise<HistoryRecord | null> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(TABLE_HISTORY);
    predicates.equalTo('videoCode', videoCode);
    const resultSet: relationalStore.ResultSet = await store.query(predicates, HISTORY_COLUMNS);
    try {
      if (resultSet.goToNextRow()) {
        return this.readHistoryRecord(resultSet);
      }
      return null;
    } finally {
      resultSet.close();
    }
  }

  async deleteHistory(videoCode: string): Promise<void> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(TABLE_HISTORY);
    predicates.equalTo('videoCode', videoCode);
    await store.delete(predicates);
  }

  async clearHistory(): Promise<void> {
    const store: relationalStore.RdbStore = await this.waitStore();
    await store.executeSql(SQL_CLEAR_HISTORY);
  }

  // ---------------------------------------------------------------------------
  // 搜索历史（去重 + 最多 50 条 + 时间倒序）
  // ---------------------------------------------------------------------------

  async addSearchHistory(keyword: string): Promise<void> {
    const trimmed: string = keyword.trim();
    if (trimmed.length === 0) {
      return;
    }
    const store: relationalStore.RdbStore = await this.waitStore();
    // 先删旧记录，保证「同关键词只保留最新一条」且时间戳刷新
    const predicates = new relationalStore.RdbPredicates(TABLE_SEARCH_HISTORY);
    predicates.equalTo('keyword', trimmed);
    await store.delete(predicates);
    const values: Record<string, relationalStore.ValueType> = {};
    values['keyword'] = trimmed;
    values['createdAt'] = Date.now();
    await store.insert(TABLE_SEARCH_HISTORY, values);
    await store.executeSql(SQL_TRIM_SEARCH_HISTORY);
  }

  async listSearchHistory(): Promise<string[]> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(TABLE_SEARCH_HISTORY);
    predicates.orderByDesc('createdAt');
    predicates.limitAs(SEARCH_HISTORY_LIMIT);
    const resultSet: relationalStore.ResultSet = await store.query(predicates, ['keyword']);
    const list: string[] = [];
    try {
      while (resultSet.goToNextRow()) {
        list.push(resultSet.getString(resultSet.getColumnIndex('keyword')));
      }
    } finally {
      resultSet.close();
    }
    return list;
  }

  /** 删除单条搜索历史（大小写/空白敏感度与 addSearchHistory 的 trim 保持一致）。 */
  async deleteSearchHistory(keyword: string): Promise<void> {
    const trimmed: string = keyword.trim();
    if (trimmed.length === 0) {
      return;
    }
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(TABLE_SEARCH_HISTORY);
    predicates.equalTo('keyword', trimmed);
    await store.delete(predicates);
  }

  async clearSearchHistory(): Promise<void> {
    const store: relationalStore.RdbStore = await this.waitStore();
    await store.executeSql(SQL_CLEAR_SEARCH_HISTORY);
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /** 等待 init 完成并返回 store；init 失败、未调用或超时（8s）时抛错，避免调用方永久挂起。 */
  private async waitStore(): Promise<relationalStore.RdbStore> {
    await this.waitReadyWithTimeout();
    const store: relationalStore.RdbStore | null = this.store;
    if (store === null) {
      throw new Error('本地数据库未初始化：请先调用 AppDb.getInstance().init(context)');
    }
    return store;
  }

  /** `ready` 加上 8 秒超时：即使 init 从未被调用（启动链路中断），也不会让页面永久 loading。 */
  private async waitReadyWithTimeout(): Promise<void> {
    const ready: Promise<void> = this.ready;
    let timer: number = -1;
    const timeout: Promise<void> = new Promise<void>((resolve: (value: void) => void) => {
      timer = setTimeout(() => {
        resolve();
      }, DB_INIT_TIMEOUT_MS);
    });
    await Promise.race([ready, timeout]);
    if (timer !== -1) {
      clearTimeout(timer);
    }
  }

  private resolveReady(): void {
    const resolver: () => void = this.readyResolver;
    this.readyResolver = () => {};
    resolver();
  }

  private async insertVideoRecord(table: string, item: LocalVideoRecord): Promise<void> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const values: Record<string, relationalStore.ValueType> = {};
    values['videoCode'] = item.videoCode;
    values['title'] = item.title;
    values['coverUrl'] = item.coverUrl;
    values['uploadTime'] = item.uploadTime;
    values['genre'] = item.genre;
    values['addedAt'] = item.addedAt;
    await store.insert(table, values, relationalStore.ConflictResolution.ON_CONFLICT_REPLACE);
  }

  private async deleteVideoRecord(table: string, videoCode: string): Promise<void> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('videoCode', videoCode);
    await store.delete(predicates);
  }

  private async hasVideoRecord(table: string, videoCode: string): Promise<boolean> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.equalTo('videoCode', videoCode);
    const resultSet: relationalStore.ResultSet = await store.query(predicates, ['videoCode']);
    try {
      return resultSet.goToNextRow();
    } finally {
      resultSet.close();
    }
  }

  private async listVideoRecords(table: string): Promise<LocalVideoRecord[]> {
    const store: relationalStore.RdbStore = await this.waitStore();
    const predicates = new relationalStore.RdbPredicates(table);
    predicates.orderByDesc('addedAt');
    const resultSet: relationalStore.ResultSet = await store.query(predicates, VIDEO_COLUMNS);
    const list: LocalVideoRecord[] = [];
    try {
      while (resultSet.goToNextRow()) {
        list.push(this.readVideoRecord(resultSet));
      }
    } finally {
      resultSet.close();
    }
    return list;
  }

  private readVideoRecord(resultSet: relationalStore.ResultSet): LocalVideoRecord {
    const record: LocalVideoRecord = {
      videoCode: resultSet.getString(resultSet.getColumnIndex('videoCode')),
      title: resultSet.getString(resultSet.getColumnIndex('title')),
      coverUrl: resultSet.getString(resultSet.getColumnIndex('coverUrl')),
      uploadTime: resultSet.getString(resultSet.getColumnIndex('uploadTime')),
      genre: resultSet.getString(resultSet.getColumnIndex('genre')),
      addedAt: resultSet.getLong(resultSet.getColumnIndex('addedAt'))
    };
    return record;
  }

  private readHistoryRecord(resultSet: relationalStore.ResultSet): HistoryRecord {
    const record: HistoryRecord = {
      videoCode: resultSet.getString(resultSet.getColumnIndex('videoCode')),
      title: resultSet.getString(resultSet.getColumnIndex('title')),
      coverUrl: resultSet.getString(resultSet.getColumnIndex('coverUrl')),
      positionMs: resultSet.getLong(resultSet.getColumnIndex('positionMs')),
      durationMs: resultSet.getLong(resultSet.getColumnIndex('durationMs')),
      updatedAt: resultSet.getLong(resultSet.getColumnIndex('updatedAt'))
    };
    return record;
  }
}
