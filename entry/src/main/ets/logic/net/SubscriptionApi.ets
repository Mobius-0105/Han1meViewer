/**
 * 「我的订阅」网络接口（ArkTS）。
 *
 * 对应 Android 上游 `HanimeBaseService.getMySubscriptions`（`@GET("subscriptions")`
 * + `@Query("page")`）与 `NetworkRepo.getMySubscriptions`。
 *
 * 说明：
 *  - 不修改 `HanimeApi.ets`（避免并发任务冲突），本文件是订阅功能的独立网络入口；
 *  - headers 与 HanimeApi 的 HTML 请求保持一致：`Referer`；`Accept: text/html` 由
 *    HttpClient 的默认头提供，`X-Requested-With` 只给 JSON 接口用，这里不需要；
 *  - 错误语义对齐 `ResponseGuard`：
 *      401/419            → LoginExpiredError（登录态 / CSRF 失效）
 *      403 + CF 挑战页     → CloudflareChallengeError
 *      403 + block 页      → IpBlockedError（交给 ResponseGuard 判定）
 *      403 其它            → LoginExpiredError（订阅页未登录时站点也会 403）
 *      302/404/500 等      → 交给 ResponseGuard（guardHtml）
 *      200 但响应体是登录页 → LoginExpiredError（HttpClient 会跟随 302 到 /login）
 *      页面结构不符        → ParseError（交由纯 TS 解析器的 SubscriptionParseError 转换）
 */

import { MySubscriptions } from '../../core/model/Subscription';
import { isSubscriptionParseError, parseMySubscriptions } from '../../core/parser/SubscriptionParser';
import { normalizeBaseUrl } from '../../core/util/Urls';
import { AppSettings } from '../settings/AppSettings';
import { CloudflareChallengeError, LoginExpiredError, ParseError } from './Errors';
import { HttpClient, HttpResult } from './HttpClient';
import { detectCloudflare, guardHtml } from './ResponseGuard';

const HTTP_401: number = 401;
const HTTP_403: number = 403;
const HTTP_419: number = 419;

export class SubscriptionApi {
  private constructor() {
  }

  /**
   * GET `<baseUrl>subscriptions?page=<page>` 并解析页面。
   *
   * @param page 页码（从 1 开始；非法值回落到 1）
   * @throws LoginExpiredError       登录态失效 / 未登录
   * @throws CloudflareChallengeError 需要完成 Cloudflare 人机验证
   * @throws IpBlockedError          当前出口 IP 被 Cloudflare 拦截（ResponseGuard 抛）
   * @throws ParseError              页面结构不符（站点改版等）
   * @throws NetworkError            网络层失败（HttpClient 抛）
   */
  static async getMySubscriptions(page: number): Promise<MySubscriptions> {
    const safePage: number = page > 0 ? page : 1;
    const baseUrl: string = normalizeBaseUrl(AppSettings.getInstance().getBaseUrl());
    const url: string = baseUrl + 'subscriptions?page=' + safePage;
    const headers: Record<string, string> = {};
    headers['Referer'] = baseUrl;

    const result: HttpResult = await HttpClient.getInstance().get(url, headers);
    SubscriptionApi.assertStatus(result);
    const html: string = guardHtml(result);

    if (SubscriptionApi.looksLikeCloudflareChallenge(html)) {
      const challenge: CloudflareChallengeError =
        new CloudflareChallengeError('需要完成 Cloudflare 人机验证');
      challenge.code = result.code;
      throw challenge;
    }
    if (SubscriptionApi.looksLikeLoginPage(html)) {
      const expired: LoginExpiredError = new LoginExpiredError('登录状态已失效，请重新登录');
      expired.code = result.code;
      throw expired;
    }

    try {
      return parseMySubscriptions(html, baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      if (isSubscriptionParseError(error)) {
        // 纯 TS 解析层无法 import ArkTS 的 Errors.ets，这里统一转换成现有 ParseError
        throw new ParseError(error.message);
      }
      throw error;
    }
  }

  /** 401/403/419 的语义判定（其余状态码交给 ResponseGuard） */
  private static assertStatus(result: HttpResult): void {
    if (result.code === HTTP_401 || result.code === HTTP_419) {
      const expired: LoginExpiredError =
        new LoginExpiredError('登录状态或 CSRF 令牌已失效，请重新登录');
      expired.code = result.code;
      throw expired;
    }
    if (result.code === HTTP_403) {
      if (detectCloudflare(result)) {
        const challenge: CloudflareChallengeError =
          new CloudflareChallengeError('需要完成 Cloudflare 人机验证');
        challenge.code = HTTP_403;
        throw challenge;
      }
      // IP 黑名单页：交给 ResponseGuard 抛 IpBlockedError（文案与其它页面一致）
      if (result.body.indexOf('you have been blocked') >= 0 ||
        result.body.indexOf('You have been blocked') >= 0) {
        guardHtml(result);
      }
      const expired: LoginExpiredError = new LoginExpiredError('需要登录后才能查看订阅');
      expired.code = HTTP_403;
      throw expired;
    }
  }

  /** 200 但响应体是 Cloudflare "Just a moment" 验证页（个别节点不走 403） */
  private static looksLikeCloudflareChallenge(body: string): boolean {
    const lower: string = body.toLowerCase();
    return lower.indexOf('just a moment') >= 0 || lower.indexOf('cf-mitigated') >= 0;
  }

  /**
   * 登录页特征：有 password 输入框，且表单指向 /login 或带 name="email"。
   * 与 HanimeApi 的私有实现一致（这里独立复制，避免改 HanimeApi 触发并发冲突）。
   */
  private static looksLikeLoginPage(body: string): boolean {
    const lower: string = body.toLowerCase();
    const hasPassword: boolean =
      lower.indexOf('type="password"') >= 0 || lower.indexOf("type='password'") >= 0;
    if (!hasPassword) {
      return false;
    }
    return lower.indexOf('/login') >= 0 || lower.indexOf('name="email"') >= 0;
  }
}
