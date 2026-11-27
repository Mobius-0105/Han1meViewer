/**
 * 缓存目录统计 / 清理（设置页“存储”分组）。
 *
 * 只处理应用自身的 cacheDir（context.cacheDir，对应鸿蒙的
 * /data/storage/el2/base/haps/entry/cache）。递归统计文件大小、清空时保留目录本身：
 *  - fileIo.listFileSync(dir) 默认只列一层，所以这里自己做递归（限制 8 层防环）；
 *  - 单个文件 stat/删除失败直接跳过，不因为一个坏文件导致整次清理失败；
 *  - 清空逻辑故意用同步 API：cacheDir 通常很小，且设置页点击时阻塞几百毫秒可接受。
 *
 * 注意：ArkWeb（Web 组件）的网页缓存不在 cacheDir 的普通文件树里，清空后
 * 网页缓存仍可能保留，需要在网页设置里单独清理（见报告“未实现”说明）。
 */

import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'CacheManager';
const LOG_DOMAIN: number = 0x0001;
/** 递归深度上限，避免符号链接造成的环 */
const MAX_DEPTH: number = 8;

export class CacheManager {
  /** 统计 cacheDir 的总字节数（失败返回已统计到的部分） */
  static sizeBytes(ctx: common.UIAbilityContext): number {
    try {
      return CacheManager.dirSize(ctx.cacheDir, 0);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, TAG, '统计缓存大小失败');
      return 0;
    }
  }

  /** 清空 cacheDir 下的全部内容（保留 cacheDir 目录本身） */
  static clear(ctx: common.UIAbilityContext): void {
    try {
      CacheManager.clearDir(ctx.cacheDir, 0);
    } catch (e) {
      hilog.warn(LOG_DOMAIN, TAG, '清空缓存失败');
    }
  }

  private static dirSize(dir: string, depth: number): number {
    if (depth > MAX_DEPTH) {
      return 0;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return 0;
    }
    let total: number = 0;
    for (let i = 0; i < names.length; i++) {
      const full: string = dir + '/' + names[i];
      try {
        const stat: fileIo.Stat = fileIo.statSync(full);
        if (stat.isDirectory()) {
          total += CacheManager.dirSize(full, depth + 1);
        } else {
          total += stat.size;
        }
      } catch (e) {
        // 单个文件 stat 失败：跳过
      }
    }
    return total;
  }

  private static clearDir(dir: string, depth: number): void {
    if (depth > MAX_DEPTH) {
      return;
    }
    let names: string[] = [];
    try {
      names = fileIo.listFileSync(dir);
    } catch (e) {
      return;
    }
    for (let i = 0; i < names.length; i++) {
      const full: string = dir + '/' + names[i];
      try {
        const stat: fileIo.Stat = fileIo.statSync(full);
        if (stat.isDirectory()) {
          CacheManager.clearDir(full, depth + 1);
          fileIo.rmdirSync(full);
        } else {
          fileIo.unlinkSync(full);
        }
      } catch (e) {
        // 单个文件删除失败：跳过
      }
    }
  }
}
