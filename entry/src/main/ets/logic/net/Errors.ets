/**
 * 网络层错误类型（ArkTS）。
 *
 * 对应 Android 侧 logic/exception/*：所有页面/UI 只依赖本文件里的错误类型，
 * 通过 `describeError` 转成可以直接 toast 的中文文案。
 *
 * 与 Android 的差异：
 * - Android 的 IPBlockedException 继承 CloudFlareBlockedException；这里按文档契约
 *   让 IpBlockedError / CloudflareChallengeError 都直接继承 AppError（契约不允许改继承），
 *   文案上仍把 IP 被封归入 Cloudflare 类原因。
 * - `code` 默认 -1；ResponseGuard/HttpClient 在抛错前会写入 HTTP 状态码或 BusinessError.code，
 *   方便 UI 侧埋点/诊断，不影响 describeError 的文案选择。
 */

/** 未知错误码 */
export const ERROR_CODE_UNKNOWN: number = -1;

/** 所有业务错误的基类 */
export class AppError extends Error {
  code: number = ERROR_CODE_UNKNOWN;

  constructor(message: string) {
    super(message);
    this.name = 'AppError';
  }
}

/** 网络不可用 / 超时 / 底层 http 调用失败 */
export class NetworkError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'NetworkError';
  }
}

/** 403 + cf-mitigated: challenge（或响应体是 Cloudflare 的 "Just a moment" 验证页） */
export class CloudflareChallengeError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'CloudflareChallengeError';
  }
}

/** 403 + "you have been blocked"：IP 被 Cloudflare 屏蔽 */
export class IpBlockedError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'IpBlockedError';
  }
}

/** 403/404/500：影片或页面不存在 */
export class NotFoundError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'NotFoundError';
  }
}

/** 登录态失效：站点把需要登录的页面 302 到 /login，或返回登录页 */
export class LoginExpiredError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'LoginExpiredError';
  }
}

/** 页面/JSON 解析失败（站点结构变化、Cloudflare 返回了非预期页面等） */
export class ParseError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'ParseError';
  }
}

/** 空字符串兜底，避免 toast 出现空白 */
function fallback(message: string, defaultText: string): string {
  return message.trim().length > 0 ? message : defaultText;
}

/**
 * 把任意 Error 转成适合 toast 的中文文案。永远返回非空字符串。
 *
 * 注意顺序：IpBlockedError 与 CloudflareChallengeError 是并列关系，
 * 两者都要求提示"网页中完成验证"（IP 被封时验证通常也过不去，文案里同时给出切换网络的建议）。
 */
export function describeError(err: Error): string {
  if (err instanceof CloudflareChallengeError) {
    return '当前网络未能通过 Cloudflare 验证。点「去验证」打开网页完成验证后会自动重试；' +
      '若验证循环/一直不通过，可尝试切换 VPN 节点、换网络或换一个备用域名。';
  }
  if (err instanceof IpBlockedError) {
    return '站点返回了 Cloudflare 的 IP 拦截页（不是 App 的问题）：当前出口 IP 被判定为高风险，' +
      '常见于部分 VPN/机房 IP。请依次尝试：① 切换 VPN 节点或换网络（优先住宅/原生 IP）；' +
      '② 点下方「换个域名」或到 设置 → 网络 → 站点域名 切换备用域名后重试（不同域名风控不同）；' +
      '③ 若刚换过 IP/节点，先「我的 → 退出登录」清掉旧的 Cloudflare 验证 Cookie 再试。';
  }
  if (err instanceof LoginExpiredError) {
    return fallback(err.message, '登录状态已失效，请重新登录');
  }
  if (err instanceof NotFoundError) {
    return fallback(err.message, '可能该影片或页面不存在');
  }
  if (err instanceof ParseError) {
    return '页面解析失败，站点结构可能已变化（' + fallback(err.message, '解析失败') + '）';
  }
  if (err instanceof NetworkError) {
    const detail: string = fallback(err.message, '网络连接失败');
    const codeText: string = err.code > 0 ? '，错误码 ' + err.code : '';
    return detail + codeText + '。请检查网络、代理或系统时间后重试。';
  }
  if (err instanceof AppError) {
    return fallback(err.message, '发生未知错误，请稍后重试');
  }
  return fallback(err.message, '发生未知错误，请稍后重试');
}
