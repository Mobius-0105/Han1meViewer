/**
 * 响应体判定（ArkTS）。
 *
 * 对应 Android NetworkRepo.throwRequestException() 的语义：
 * - 403：you have been blocked → IpBlockedError；Just a moment / cf-mitigated: challenge →
 *   CloudflareChallengeError；否则 NotFoundError（影片 v 号不存在时常是 403）。
 * - 500：NotFoundError（v 号过大时常是 500）。
 * - 404：未登录 → LoginExpiredError；已登录 → NotFoundError。
 * - 302：站点登录态失效时 user/... 会 302 到 /login；未放行时抛 LoginExpiredError。
 * - 其他：NetworkError。
 *
 * 注意：@ohos.net.http 的 request() 内部会自动跟随重定向，因此正常情况下拿不到 302；
 * 但登录页 200 响应仍是可能的（重定向跟随后的最终页面），所以站点要求登录的接口
 * 还要在 HanimeApi 里额外识别登录页 HTML。这里保留 302 判定作为兜底。
 */

import { HttpResult } from './HttpClient';
import {
  AppError,
  NetworkError,
  CloudflareChallengeError,
  IpBlockedError,
  NotFoundError,
  LoginExpiredError
} from './Errors';
import { CookieStore } from './CookieStore';

const HTTP_OK_MIN: number = 200;
const HTTP_OK_MAX: number = 299;
const HTTP_401: number = 401;
const HTTP_403: number = 403;
const HTTP_404: number = 404;
const HTTP_419: number = 419;
const HTTP_500: number = 500;
const HTTP_302: number = 302;

/** 读取响应头（键已是小写） */
function headerValue(result: HttpResult, key: string): string {
  const value: string = result.headers[key];
  return value === undefined ? '' : value;
}

/** 给错误标上来源状态码后抛出（便于 UI 埋点/诊断） */
function throwWithCode(error: AppError, code: number): void {
  error.code = code;
  throw error;
}

/**
 * 判断是否是 Cloudflare 人机验证页。
 * 契约：403 且 `cf-mitigated: challenge` 或 body 含 `Just a moment`。
 */
export function detectCloudflare(result: HttpResult): boolean {
  if (result.code !== HTTP_403) {
    return false;
  }
  const mitigated: string = headerValue(result, 'cf-mitigated').trim().toLowerCase();
  if (mitigated === 'challenge') {
    return true;
  }
  // Android 用的是 "Just a moment"；大小写保守地都判一次
  if (result.body.indexOf('Just a moment') >= 0 || result.body.indexOf('just a moment') >= 0) {
    return true;
  }
  return false;
}

/** 判断响应体像不像站点的登录页（登录态失效被重定向到 /login 时） */
function looksLikeLoginPage(body: string): boolean {
  const lower: string = body.toLowerCase();
  const hasPassword: boolean = lower.indexOf('type="password"') >= 0 || lower.indexOf("type='password'") >= 0;
  if (!hasPassword) {
    return false;
  }
  return lower.indexOf('/login') >= 0 || lower.indexOf('name="email"') >= 0;
}

/**
 * 校验响应是否为成功状态（2xx），否则抛出 Errors.ets 里的具体错误。
 */
export function assertOk(result: HttpResult): void {
  assertOrThrow(result, false);
}

/**
 * 校验响应状态。
 * @param permit302 是否允许 302（例如修改播放列表、修改账号资料接口把 302 当成功）
 */
export function assertOrThrow(result: HttpResult, permit302: boolean): void {
  const code: number = result.code;

  if (code >= HTTP_OK_MIN && code <= HTTP_OK_MAX) {
    return;
  }

  if (code === HTTP_302) {
    if (permit302) {
      return;
    }
    const location: string = headerValue(result, 'location');
    if (location.toLowerCase().indexOf('/login') >= 0 || looksLikeLoginPage(result.body)) {
      throwWithCode(new LoginExpiredError('登录状态已失效，请重新登录'), HTTP_302);
      return;
    }
    throwWithCode(new NetworkError('站点返回了重定向（302），可能登录状态已失效'), HTTP_302);
    return;
  }

  if (code === HTTP_403) {
    if (result.body.indexOf('you have been blocked') >= 0 ||
      result.body.indexOf('You have been blocked') >= 0) {
      throwWithCode(new IpBlockedError('检测到当前 IP 被 Cloudflare 屏蔽'), HTTP_403);
      return;
    }
    if (detectCloudflare(result)) {
      throwWithCode(new CloudflareChallengeError('需要完成 Cloudflare 人机验证'), HTTP_403);
      return;
    }
    throwWithCode(new NotFoundError('影片或页面不存在（403）'), HTTP_403);
    return;
  }

  if (code === HTTP_500) {
    throwWithCode(new NotFoundError('影片或页面不存在（500）'), HTTP_500);
    return;
  }

  if (code === HTTP_401 || code === HTTP_419) {
    // 401 Unauthorized / 419 Laravel CSRF token mismatch：本质是登录态/CSRF 失效
    throwWithCode(new LoginExpiredError('登录状态或 CSRF 令牌已失效，请重新登录'), code);
    return;
  }

  if (code === HTTP_404) {
    if (!CookieStore.getInstance().hasLoginCookie()) {
      throwWithCode(new LoginExpiredError('当前未登录，请先登录'), HTTP_404);
      return;
    }
    throwWithCode(new NotFoundError('页面不存在（404）'), HTTP_404);
    return;
  }

  throwWithCode(new NetworkError('网络请求失败（HTTP ' + code + '）'), code);
}

/**
 * 校验并返回 HTML 响应体。
 * 非成功状态会抛 Errors.ets 里的具体错误；成功则原样返回 body。
 */
export function guardHtml(result: HttpResult): string {
  assertOrThrow(result, false);
  return result.body;
}
