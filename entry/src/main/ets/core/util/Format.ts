/**
 * 展示格式化工具（纯函数，可在 Node 中测试）。
 */

/** 把 "12:34" / "1:02:03" 转成毫秒；失败返回 0 */
export function durationTextToMs(text: string): number {
  const parts: string[] = text.trim().split(':');
  if (parts.length < 2 || parts.length > 3) {
    return 0;
  }
  let seconds: number = 0;
  for (let i = 0; i < parts.length; i++) {
    const value: number = parseInt(parts[i].trim(), 10);
    if (isNaN(value) || value < 0) {
      return 0;
    }
    seconds = seconds * 60 + value;
  }
  return seconds * 1000;
}

/** 毫秒 → "mm:ss" 或 "h:mm:ss" */
export function formatMs(ms: number): string {
  if (ms < 0 || isNaN(ms)) {
    return '00:00';
  }
  const totalSeconds: number = Math.floor(ms / 1000);
  const seconds: number = totalSeconds % 60;
  const minutes: number = Math.floor(totalSeconds / 60) % 60;
  const hours: number = Math.floor(totalSeconds / 3600);
  const ss: string = seconds < 10 ? '0' + seconds : '' + seconds;
  const mm: string = minutes < 10 ? '0' + minutes : '' + minutes;
  if (hours > 0) {
    return hours + ':' + mm + ':' + ss;
  }
  return mm + ':' + ss;
}

/** 播放���进展示：秒数，用于 AVPlayer seek */
export function msToSeconds(ms: number): number {
  return Math.max(0, Math.floor(ms / 1000));
}

/** 时间戳 → yyyy-MM-dd */
export function formatDate(timestamp: number): string {
  const date: Date = new Date(timestamp);
  const year: number = date.getFullYear();
  const month: number = date.getMonth() + 1;
  const day: number = date.getDate();
  const mm: string = month < 10 ? '0' + month : '' + month;
  const dd: string = day < 10 ? '0' + day : '' + day;
  return year + '-' + mm + '-' + dd;
}

/** 相对时间：刚刚 / x分钟前 / x小时前 / x天前 / yyyy-MM-dd */
export function formatRelativeTime(timestamp: number, now: number): string {
  const diff: number = now - timestamp;
  if (diff < 60 * 1000) {
    return '刚刚';
  }
  if (diff < 3600 * 1000) {
    return Math.floor(diff / (60 * 1000)) + ' 分钟前';
  }
  if (diff < 24 * 3600 * 1000) {
    return Math.floor(diff / (3600 * 1000)) + ' 小时前';
  }
  if (diff < 7 * 24 * 3600 * 1000) {
    return Math.floor(diff / (24 * 3600 * 1000)) + ' 天前';
  }
  return formatDate(timestamp);
}

/** 解析站点上的 "1234次" / "1.2万次" 等观看数文本为数字；失败返回 -1 */
export function parseViewsText(text: string): number {
  const value: string = text.trim();
  const match: RegExpMatchArray | null = value.match(/([\d.]+)\s*(万|萬|w|W)?/);
  if (match === null) {
    return -1;
  }
  const base: number = parseFloat(match[1]);
  if (isNaN(base)) {
    return -1;
  }
  if (match[2] !== undefined && match[2].length > 0) {
    return Math.floor(base * 10000);
  }
  return Math.floor(base);
}

/** 清除 HTML 文本里的多余空白 */
export function normalizeWhitespace(text: string): string {
  return text.replace(/\s+/g, ' ').trim();
}

/** 截断文本 */
export function truncate(text: string, maxLength: number): string {
  if (text.length <= maxLength) {
    return text;
  }
  return text.substring(0, maxLength) + '…';
}

/** 由标题生成"分享文本" */
export function buildShareText(title: string, videoCode: string, baseUrl: string): string {
  const url: string = baseUrl + 'watch?v=' + videoCode;
  return title + '\n' + url;
}
