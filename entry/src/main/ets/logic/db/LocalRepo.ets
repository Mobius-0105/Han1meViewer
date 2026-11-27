/**
 * 本地收藏 / 稍后再看 / 观看历史的 UI 友好封装。
 *
 * 页面只依赖本类与 `AppSettings`，不直接碰 `AppDb`：
 *  - 收藏/稍后才看用 `setFavorite(item, true/false)` 这类布尔语义，避免页面到处写 if；
 *  - 历史列表一条记录既用于展示，也用于续播（positionMs/durationMs）；
 *  - 页面永远从本类读到的都是已排序结果（收藏/稍后再看按 addedAt 倒序，历史按 updatedAt 倒序）。
 *
 * init 方式：EntryAbility.onCreate 里 `await LocalRepo.getInstance().init(context)`。
 * 本类不缓存 context，所有数据访问都转给 AppDb 单例。
 */

import { common } from '@kit.AbilityKit';
import { HistoryRecord, LocalVideoRecord } from '../../core/model/Models';
import { AppSettings } from '../settings/AppSettings';
import { AppDb } from './AppDb';
import { WatchProgress } from './WatchProgress';

export class LocalRepo {
  private static instance: LocalRepo | null = null;

  private constructor() {
  }

  static getInstance(): LocalRepo {
    if (LocalRepo.instance === null) {
      LocalRepo.instance = new LocalRepo();
    }
    return LocalRepo.instance;
  }

  /** 打开数据库（幂等）。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    await AppDb.getInstance().init(context);
  }

  // ---------------------------------------------------------------------------
  // 收藏
  // ---------------------------------------------------------------------------

  async setFavorite(item: LocalVideoRecord, favorite: boolean): Promise<void> {
    const db: AppDb = AppDb.getInstance();
    if (favorite) {
      await db.addFavorite(item);
    } else {
      await db.removeFavorite(item.videoCode);
    }
  }

  async isFavorited(videoCode: string): Promise<boolean> {
    return AppDb.getInstance().isFavorite(videoCode);
  }

  async listFavoritesSorted(): Promise<LocalVideoRecord[]> {
    return AppDb.getInstance().listFavorites();
  }

  // ---------------------------------------------------------------------------
  // 稍后再看
  // ---------------------------------------------------------------------------

  async setWatchLater(item: LocalVideoRecord, watchLater: boolean): Promise<void> {
    const db: AppDb = AppDb.getInstance();
    if (watchLater) {
      await db.addWatchLater(item);
    } else {
      await db.removeWatchLater(item.videoCode);
    }
  }

  async isWatchLater(videoCode: string): Promise<boolean> {
    return AppDb.getInstance().isWatchLater(videoCode);
  }

  async listWatchLaterSorted(): Promise<LocalVideoRecord[]> {
    return AppDb.getInstance().listWatchLater();
  }

  // ---------------------------------------------------------------------------
  // 观看历史 / 播放进度
  // ---------------------------------------------------------------------------

  /**
   * 记录一次观看：写标题/封面与当前进度。受设置「记录观看历史」控制，
   * 关闭时直接跳过（不写库）。
   */
  async recordWatch(
    videoCode: string,
    title: string,
    coverUrl: string,
    positionMs: number,
    durationMs: number
  ): Promise<void> {
    if (videoCode.length === 0) {
      return;
    }
    if (!AppSettings.getInstance().getWatchHistoryEnabled()) {
      return;
    }
    const record: HistoryRecord = {
      videoCode: videoCode,
      title: title,
      coverUrl: coverUrl,
      positionMs: positionMs > 0 ? positionMs : 0,
      durationMs: durationMs > 0 ? durationMs : 0,
      updatedAt: Date.now()
    };
    await AppDb.getInstance().upsertHistory(record);
  }

  /**
   * 详情页进入时「记录一条历史」：只更新标题 / 封面 / 时间戳，**不碰播放进度**。
   *
   * 与 `recordWatch` 的区别：不再往 `upsertHistory` 传 positionMs=0（那条路径是
   * 「读旧行再整行写回」的读-改-写，与播放器 5s 节流落盘并发时可能把旧进度写回，
   * 且 ≥95% 规则还可能把刚保存的进度归零）。进度只由播放器 `saveProgress` 写。
   */
  async touchHistory(videoCode: string, title: string, coverUrl: string): Promise<void> {
    if (videoCode.length === 0) {
      return;
    }
    if (!AppSettings.getInstance().getWatchHistoryEnabled()) {
      return;
    }
    await AppDb.getInstance().touchHistory(videoCode, title, coverUrl);
  }

  /** 历史列表（updatedAt 倒序，默认最多 500 条）。 */
  async listHistorySorted(): Promise<HistoryRecord[]> {
    return AppDb.getInstance().listHistory(0);
  }

  async deleteHistory(videoCode: string): Promise<void> {
    return AppDb.getInstance().deleteHistory(videoCode);
  }

  async clearHistory(): Promise<void> {
    return AppDb.getInstance().clearHistory();
  }

  /** 续播位置（毫秒），无记录为 0。 */
  async getResumePosition(videoCode: string): Promise<number> {
    return WatchProgress.getInstance().getProgress(videoCode);
  }

  /**
   * 保存播放进度（播放器 5s 节流 / 暂停 / 退出时调用）。
   *
   * 直接写进度列（`AppDb.updateProgress`，一条 UPDATE 精确写，不做读-改-写），
   * 因此不会与详情页入口写历史互相覆盖；`positionMs > 0` 才写（播放器初始 0 不落盘），
   * 进度 ≥95% 视为看完、归 0（下次从头播，避免「打开就是最后一帧」）。
   *
   * 是否允许「新建历史行」跟随「记录观看历史」设置：关闭时只更新已有记录
   * （已经看过、需要续播的视频仍能记住进度），不产生新的历史条目。
   */
  async saveProgress(videoCode: string, positionMs: number, durationMs: number): Promise<void> {
    if (videoCode.length === 0 || positionMs <= 0) {
      return;
    }
    const duration: number = durationMs > 0 ? Math.round(durationMs) : 0;
    let position: number = Math.round(positionMs);
    if (duration > 0 && position >= duration * 0.95) {
      position = 0;
    }
    await AppDb.getInstance().updateProgress(videoCode, position, duration,
      AppSettings.getInstance().getWatchHistoryEnabled());
  }

  /**
   * 显式把进度归零（用户点「从头播放」）。
   *
   * 普通 `saveProgress` 的合并语义不会把 0 写进库（0 会被当成「没有值」保留旧进度），
   * 所以这里走精确写入：让「从头播放」真正落库，避免下次进入又续播回旧位置。
   */
  async resetProgress(videoCode: string): Promise<void> {
    if (videoCode.length === 0) {
      return;
    }
    await AppDb.getInstance().updateProgress(videoCode, 0, 0, false);
  }
}
