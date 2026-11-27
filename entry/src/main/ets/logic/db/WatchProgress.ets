/**
 * 播放进度（断点续播）。
 *
 * 进度直接复用观看历史表（history.positionMs / durationMs），避免再建一张表导致
 * "历史里显示看了 10 分钟、续播却从 0 开始"这类不一致。
 * 与 Android 的 `WatchHistoryDao.updateProgress` 语义一致：只更新进度，其他字段
 * （标题/封面）保留历史里已有的值。
 *
 * 与 `LocalRepo.recordWatch` 的分工：
 *  - recordWatch：写完整历史（受「记录观看历史」设置控制），UI 历史列表用；
 *  - saveProgress：只写进度（不检查设置），播放器定时/退出时调用。
 */

import { HistoryRecord } from '../../core/model/Models';
import { AppDb } from './AppDb';

export class WatchProgress {
  private static instance: WatchProgress | null = null;

  private constructor() {
  }

  static getInstance(): WatchProgress {
    if (WatchProgress.instance === null) {
      WatchProgress.instance = new WatchProgress();
    }
    return WatchProgress.instance;
  }

  /**
   * 保存播放位置。走 `AppDb.updateProgress` 的原子 UPDATE（只写 positionMs/durationMs/updatedAt）：
   * 不会与详情页入口写历史并发覆盖，也不会因为「0 值保留旧进度」的合并语义写不进显式归零。
   * 没有历史行时补一条最小记录（title/coverUrl 留空，之后 recordWatch/touchHistory 补全）。
   */
  async saveProgress(videoCode: string, positionMs: number, durationMs: number): Promise<void> {
    if (videoCode.length === 0) {
      return;
    }
    await AppDb.getInstance().updateProgress(videoCode, positionMs, durationMs, true);
  }

  /** 上次播放位置（毫秒）；无记录返回 0。 */
  async getProgress(videoCode: string): Promise<number> {
    if (videoCode.length === 0) {
      return 0;
    }
    const existing: HistoryRecord | null = await AppDb.getInstance().getHistory(videoCode);
    return existing !== null ? existing.positionMs : 0;
  }
}
