/**
 * 设置页共用的常量与换算（页面只负责渲染，避免 build() 里出现复杂表达式）。
 *
 * 说明：
 *  - 默认清晰度在设置里存的是“清晰度列表下标”（AppSettings.getPlayerQualityIndex，
 *    -1 = 自动）。这里把它映射成 4 个展示档位（自动 / 1080P / 720P / 480P），
 *    实际视频源顺序以站点 `<source size>` 顺序为准（见 viewmodel/video/VideoUiUtils
 *    的 resolveInitialQuality）。
 *  - 站点域名 / UA / 备用 CDN 修改后必须调用 HanimeApi.configure，否则网络层仍用旧值。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { AppSettings } from '../../logic/settings/AppSettings';

/** 与 AppScope/app.json5 的 versionName 保持一致 */
export const APP_VERSION: string = '1.0.0';

export const THEME_COMMENT: string = '主题切换立即生效';
export const THEME_LABELS: string[] = ['跟随系统', '浅色', '深色'];

/** 默认清晰度档位（下标 0 = 自动） */
export const QUALITY_LABELS: string[] = ['自动（最高）', '1080P', '720P', '480P'];

/** 默认倍速档位 */
export const SPEED_LABELS: string[] = ['0.75x', '1.0x', '1.25x', '1.5x', '2.0x'];
const SPEED_VALUES: number[] = [0.75, 1.0, 1.25, 1.5, 2.0];

export class NetworkConfigurator {
  /** 把当前 AppSettings 的站点 / UA / 备用 CDN 同步给网络层（改完设置必须调用） */
  static apply(): void {
    const settings: AppSettings = AppSettings.getInstance();
    HanimeApi.getInstance().configure(
      settings.getBaseUrl(),
      settings.getUserAgent(),
      settings.getBackupCdn()
    );
  }
}

/** AppSettings 主题值 → SegmentRow 下标 */
export function themeSelection(mode: string): number {
  if (mode === 'light') {
    return 1;
  }
  if (mode === 'dark') {
    return 2;
  }
  return 0;
}

/** 默认清晰度下标（-1 自动）→ SegmentRow 下标 */
export function qualitySelection(index: number): number {
  if (index < 0) {
    return 0;
  }
  const selection: number = index + 1;
  return selection < QUALITY_LABELS.length ? selection : QUALITY_LABELS.length - 1;
}

/** SegmentRow 下标 → AppSettings 清晰度下标（0 → -1 自动） */
export function qualityIndex(selection: number): number {
  return selection <= 0 ? -1 : selection - 1;
}

/** 倍速值 → SegmentRow 下标（找不到时回退 1.0x） */
export function speedSelection(speed: number): number {
  for (let i = 0; i < SPEED_VALUES.length; i++) {
    if (Math.abs(SPEED_VALUES[i] - speed) < 0.001) {
      return i;
    }
  }
  return 1;
}

/** SegmentRow 下标 → 倍速值 */
export function speedValue(selection: number): number {
  if (selection < 0 || selection >= SPEED_VALUES.length) {
    return 1.0;
  }
  return SPEED_VALUES[selection];
}

/** 字节数 → 可读文本（B / KB / MB / GB） */
export function formatBytes(bytes: number): string {
  if (bytes <= 0) {
    return '0 B';
  }
  const kb: number = 1024;
  if (bytes < kb) {
    return bytes + ' B';
  }
  if (bytes < kb * kb) {
    return (bytes / kb).toFixed(1) + ' KB';
  }
  if (bytes < kb * kb * kb) {
    return (bytes / (kb * kb)).toFixed(1) + ' MB';
  }
  return (bytes / (kb * kb * kb)).toFixed(2) + ' GB';
}
