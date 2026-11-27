/**
 * 视频分享文本（纯 TypeScript，可在 Node 中测试，也可被 ArkTS 编译）。
 *
 * 对齐 Android 上游 `HanimeManager.kt`：
 *   fun getHanimeShareText(title, videoCode) = buildString {
 *       appendLine(title)
 *       appendLine(getHanimeVideoLink(videoCode))   // HANIME_BASE_URL + "watch?v=" + code
 *       append("- From Han1meViewer -")
 *   }
 * 即三行：视频标题 / 视频链接 / 来源署名（行尾不带换行）。
 * 本移植版站点域名可配置（AppSettings.getBaseUrl），因此链接按传入 baseUrl 生成。
 */

import { buildWatchUrl } from './Urls';

/** 对齐上游的分享文本署名行 */
const SHARE_SIGNATURE: string = '- From Han1meViewer -';

/**
 * 生成视频分享文本。
 * @param title 视频标题（上游用的是 HanimeVideo.title）
 * @param videoCode 视频编号（数字串）
 * @param baseUrl 当前站点域名（AppSettings.getBaseUrl）
 */
export function buildVideoShareText(title: string, videoCode: string, baseUrl: string): string {
  const name: string = title.trim();
  const url: string = buildWatchUrl(baseUrl, videoCode);
  if (name.length === 0) {
    return url + '\n' + SHARE_SIGNATURE;
  }
  return name + '\n' + url + '\n' + SHARE_SIGNATURE;
}
