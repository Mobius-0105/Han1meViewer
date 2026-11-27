/**
 * HTTP 客户端（ArkTS，基于 @kit.NetworkKit 的 http）。
 *
 * 对应 Android 的 OkHttpClient + UserAgentInterceptor + HCookieJar：
 * - 统一加 User-Agent / Accept-Language / Accept / Cookie；
 * - 超时 15s、expectDataType=STRING、usingCache=true；
 * - HTTP 非 2xx **不抛异常**，交给 logic/net/ResponseGuard.ets 统一判定；
 * - 底层调用失败（DNS/连接/超时/证书）包装成 NetworkError（保留 BusinessError.code）；
 * - 响应里的 Set-Cookie 与 `HttpResponse.cookies` 都会交给 CookieStore 持久化；
 * - GET 失败时可通过 HttpFailoverHook（logic/net/SiteFailover.ets 注册）自动换备用站点重试
 *   一轮；写操作永不重试（避免重复提交）。
 *
 * 关于 @ohos.net.http 的两个坑（API 12）：
 * 1) `HttpResponse.header` 类型是 Object（JSON 格式字符串，需自己解析），且多个
 *    Set-Cookie 时 header 里通常只剩一条 —— 完整 cookie 列表要从 `HttpResponse.cookies`
 *    取（API 8+，curl/Netscape 风格，见 core/util/CookieHeader.parseResponseCookies）；
 * 2) `request()` 内部会自动跟随 302，所以无法可靠拿到重定向状态码，登录页识别见
 *    HanimeApi/ResponseGuard 的注释。
 */

import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { DEFAULT_USER_AGENT } from '../../core/util/Constants';
import { encodeForm } from '../../core/util/Form';
import { ParsedSetCookie, hostOfUrl, parseResponseCookies } from '../../core/util/CookieHeader';
import { isSuccessStatus, rewriteOrigin } from '../../core/util/SiteFailoverPolicy';
import { CookieStore } from './CookieStore';
import { NetworkError } from './Errors';

/** 请求结果（ResponseGuard/HanimeApi 使用；headers 的键统一小写） */
export interface HttpResult {
  code: number;
  body: string;
  headers: Record<string, string>;
  /**
   * 服务端本次下发的 cookie 原始值（用于保存/诊断，可能是 Set-Cookie 串或 curl cookie 行）。
   * 可选字段：GUIDE 的契约只有 code/body/headers，这里只做附加信息，不参与响应判定。
   */
  cookies?: string[];
}

/**
 * 站点自动切换钩子（由 logic/net/SiteFailover 注册）。
 *
 * 为什么用接口注入而不是 HttpClient 直接 import SiteFailover：SiteFailover 需要 import
 * HttpClient 来拿到 HttpResult / setFailoverHook，反向 import 会形成循环依赖。这里只声明
 * 「何时值得换站 / 候选 origin / 切换成功的通知」，实际的 URL 改写与重试留在 HttpClient，
 * URL 改写规则来自 core/util/SiteFailoverPolicy（两边共用，不循环）。
 */
export interface HttpFailoverHook {
  /**
   * 该次失败是否值得换站重试（只对 GET；写操作永远返回 false）。
   * @param result null 表示底层网络异常（NetworkError/超时/DNS）
   */
  shouldRetry(method: http.RequestMethod, result: HttpResult | null): boolean;

  /** 按轮询顺序返回候选 origin（如 `https://hanime1.com`）；空数组表示本轮放弃 */
  candidatesFor(url: string): string[];

  /** 某个候选 origin 重试成功：由钩子负责持久化新站点 + Toast/AppStorage 通知 */
  onSuccess(origin: string): void;

  /** 候选全部失败：钩子据此设置失败冷却，避免并发请求反复触发轮询 */
  onExhausted(url: string): void;
}

const TIMEOUT_MS: number = 15000;
const ACCEPT_LANGUAGE: string = 'zh-TW,zh;q=0.9,en;q=0.8';
const ACCEPT_HTML: string =
  'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8';
const LOG_DOMAIN: number = 0x0001;
const TAG: string = 'HttpClient';

export class HttpClient {
  private static instance: HttpClient | null = null;

  private userAgent: string = DEFAULT_USER_AGENT;

  /** 站点自动切换钩子；未注册（EntryAbility 初始化前）时行为与旧版完全一致 */
  private failoverHook: HttpFailoverHook | null = null;

  /**
   * 候选轮询串行链：同一时刻只允许一个 failover 流程。
   * 并发 GET 同时失败时排队，后到者等前一轮结束后再重新取候选（可能已被切成新站点）。
   */
  private failoverChain: Promise<void> = Promise.resolve();

  private constructor() {
  }

  static getInstance(): HttpClient {
    let instance: HttpClient | null = HttpClient.instance;
    if (instance === null) {
      instance = new HttpClient();
      HttpClient.instance = instance;
    }
    return instance;
  }

  /** 外部注入 User-Agent（界面设置里自定义 UA 时用）；传空串恢复默认 */
  setUserAgent(ua: string): void {
    this.userAgent = ua.trim().length > 0 ? ua.trim() : DEFAULT_USER_AGENT;
  }

  /** 注册 / 注销站点自动切换钩子（SiteFailover.install 调用；传 null 注销） */
  setFailoverHook(hook: HttpFailoverHook | null): void {
    this.failoverHook = hook;
  }

  /** GET 请求；headers 里的同名键会覆盖默认头 */
  async get(url: string, headers: Record<string, string>): Promise<HttpResult> {
    return this.execute(http.RequestMethod.GET, url, '', headers);
  }

  /** POST application/x-www-form-urlencoded */
  async postForm(
    url: string,
    form: Record<string, string>,
    headers: Record<string, string>
  ): Promise<HttpResult> {
    const body: string = encodeForm(form);
    const merged: Record<string, string> = this.withHeader(
      headers, 'Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    return this.execute(http.RequestMethod.POST, url, body, merged);
  }

  /** POST application/json（预留：站点部分接口可能以 JSON 提交） */
  async postJson(
    url: string,
    jsonBody: string,
    headers: Record<string, string>
  ): Promise<HttpResult> {
    const merged: Record<string, string> = this.withHeader(
      headers, 'Content-Type', 'application/json; charset=UTF-8');
    return this.execute(http.RequestMethod.POST, url, jsonBody, merged);
  }

  /**
   * DELETE + form body。站点 `DELETE user/tab-item/{id}` 需要带 tab、_token 字段
   * （Android 侧是 @HTTP(method="DELETE", hasBody=true)）。
   */
  async deleteForm(
    url: string,
    form: Record<string, string>,
    headers: Record<string, string>
  ): Promise<HttpResult> {
    const body: string = encodeForm(form);
    const merged: Record<string, string> = this.withHeader(
      headers, 'Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
    return this.execute(http.RequestMethod.DELETE, url, body, merged);
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /**
   * 统一请求入口：先正常发一次；命中 failover 触发条件（仅 GET）时做**一轮**候选轮询。
   *
   * 收尾语义（保持改动前的错误 UI 行为）：
   * - 候选全部失败：网络错误路径抛**原始** NetworkError；响应路径返回**首个**响应
   *   （由 ResponseGuard 照旧判定 403/500 等并抛具体错误）；
   * - POST/PUT/DELETE 永不重试，避免重复提交（评论 / 点赞 / 收藏等写操作）。
   */
  private async execute(
    method: http.RequestMethod,
    url: string,
    body: string,
    extraHeaders: Record<string, string>
  ): Promise<HttpResult> {
    const hook: HttpFailoverHook | null = this.failoverHook;
    if (hook === null) {
      return this.performRequest(method, url, body, extraHeaders);
    }
    let firstResult: HttpResult;
    try {
      firstResult = await this.performRequest(method, url, body, extraHeaders);
    } catch (rawError) {
      const firstError: Error = rawError as Error;
      // 只有底层网络异常（超时 / DNS / 连接失败）才换站；result 传 null 表示这类错误。
      if (firstError instanceof NetworkError && hook.shouldRetry(method, null)) {
        const retried: HttpResult | null = await this.failoverOnce(method, url, body, extraHeaders, hook);
        if (retried !== null) {
          return retried;
        }
      }
      throw firstError;
    }
    if (hook.shouldRetry(method, firstResult)) {
      const retried: HttpResult | null = await this.failoverOnce(method, url, body, extraHeaders, hook);
      if (retried !== null) {
        return retried;
      }
    }
    return firstResult;
  }

  /** 真正发一次请求（不含 failover）：失败包装成 NetworkError，非 2xx 原样返回给 ResponseGuard */
  private async performRequest(
    method: http.RequestMethod,
    url: string,
    body: string,
    extraHeaders: Record<string, string>
  ): Promise<HttpResult> {
    const header: Record<string, string> = this.buildHeaders(url, extraHeaders);
    // 只对 GET 使用 HTTP 缓存：避免登录/评论等写操作被缓存影响。
    const useCache: boolean = method === http.RequestMethod.GET;
    const options: http.HttpRequestOptions = {
      method: method,
      header: header,
      expectDataType: http.HttpDataType.STRING,
      connectTimeout: TIMEOUT_MS,
      readTimeout: TIMEOUT_MS,
      usingCache: useCache
    };
    if (body.length > 0) {
      options.extraData = body;
    }

    const request: http.HttpRequest = http.createHttp();
    let response: http.HttpResponse;
    try {
      response = await request.request(url, options);
    } catch (rawError) {
      request.destroy();
      throw this.toNetworkError(url, rawError as BusinessError);
    }
    request.destroy();
    return this.toResult(url, response);
  }

  // ---------------------------------------------------------------------------
  // 站点自动切换：候选轮询（单飞）
  // ---------------------------------------------------------------------------

  /**
   * 排队执行一轮候选轮询：同一时刻只允许一个 failover 流程（Promise 链锁）。
   * 后到的请求等前一轮结束后再取候选 —— 若前一轮已切换成功，这里会优先用当前站点重试。
   */
  private failoverOnce(
    method: http.RequestMethod,
    url: string,
    body: string,
    extraHeaders: Record<string, string>,
    hook: HttpFailoverHook
  ): Promise<HttpResult | null> {
    const previous: Promise<void> = this.failoverChain;
    const run: Promise<HttpResult | null> = previous.then(
      (): Promise<HttpResult | null> => this.pollCandidates(method, url, body, extraHeaders, hook),
      (): Promise<HttpResult | null> => this.pollCandidates(method, url, body, extraHeaders, hook)
    );
    // 链本身永远 resolve，避免一次失败影响后续排队请求
    this.failoverChain = run.then((): void => {
    }, (): void => {
    });
    return run;
  }

  /**
   * 依次尝试候选 origin：只换 origin、保留 path/query，header 用新 URL 重建
   * （CookieStore 按 host 取，自动带新站点自己的 cookie；Referer 也改写到新 origin）。
   * 某个候选返回 2xx（且不是 Cloudflare 验证页）即认为换站成功，通知钩子并返回该响应；
   * 其余响应 / 网络错误都继续下一个候选，全部失败返回 null，由调用方保留首个结果。
   */
  private async pollCandidates(
    method: http.RequestMethod,
    url: string,
    body: string,
    extraHeaders: Record<string, string>,
    hook: HttpFailoverHook
  ): Promise<HttpResult | null> {
    const candidates: string[] = hook.candidatesFor(url);
    if (candidates.length === 0) {
      return null;
    }
    for (let i = 0; i < candidates.length; i++) {
      const origin: string = candidates[i];
      const targetUrl: string = rewriteOrigin(url, origin);
      if (targetUrl.length === 0 || targetUrl === url) {
        continue;
      }
      const headers: Record<string, string> = this.retryHeaders(extraHeaders, origin);
      try {
        const result: HttpResult = await this.performRequest(method, targetUrl, body, headers);
        if (hook.shouldRetry(method, result)) {
          hilog.warn(LOG_DOMAIN, TAG,
            'failover candidate rejected: %{public}s code=%{public}d', origin, result.code);
          continue;
        }
        if (!isSuccessStatus(result.code)) {
          // 候选站点能响应但非 2xx（404/401/登录跳转等）：不算换站成功，继续下一个候选，
          // 避免把「影片不存在 / 需要登录」误判成「站点可用」而全局切站。
          hilog.warn(LOG_DOMAIN, TAG,
            'failover candidate returned non-2xx: %{public}s code=%{public}d', origin, result.code);
          continue;
        }
        this.notifyFailoverSuccess(hook, origin);
        return result;
      } catch (rawError) {
        const error: Error = rawError as Error;
        hilog.warn(LOG_DOMAIN, TAG,
          'failover candidate failed: %{public}s %{public}s', origin, this.messageOf(error));
      }
    }
    this.notifyFailoverExhausted(hook, url);
    return null;
  }

  /** 换站重试时的附加头：Referer 指向旧站会引发风控，改写到候选 origin */
  private retryHeaders(extra: Record<string, string>, origin: string): Record<string, string> {
    const copy: Record<string, string> = {};
    const keys: string[] = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      copy[keys[i]] = extra[keys[i]];
    }
    const referer: string = copy['Referer'];
    if (referer !== undefined && referer.length > 0) {
      copy['Referer'] = rewriteOrigin(referer, origin);
    }
    return copy;
  }

  private notifyFailoverSuccess(hook: HttpFailoverHook, origin: string): void {
    try {
      hook.onSuccess(origin);
    } catch (rawError) {
      // 切站通知失败不应影响本次请求的响应
      const error: Error = rawError as Error;
      hilog.error(LOG_DOMAIN, TAG, 'failover onSuccess failed: %{public}s', this.messageOf(error));
    }
  }

  private notifyFailoverExhausted(hook: HttpFailoverHook, url: string): void {
    try {
      hook.onExhausted(url);
    } catch (rawError) {
      const error: Error = rawError as Error;
      hilog.error(LOG_DOMAIN, TAG, 'failover onExhausted failed: %{public}s', this.messageOf(error));
    }
  }

  /** 组装默认头 + Cookie + 调用方额外头（调用方优先） */
  private buildHeaders(url: string, extra: Record<string, string>): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['User-Agent'] = this.userAgent;
    headers['Accept-Language'] = ACCEPT_LANGUAGE;
    headers['Accept'] = ACCEPT_HTML;
    try {
      const cookie: string = CookieStore.getInstance().getCookieHeader(url);
      if (cookie.length > 0) {
        headers['Cookie'] = cookie;
      }
    } catch (rawError) {
      const error: Error = rawError as Error;
      // cookie 拼接失败不应该阻断请求
      hilog.error(LOG_DOMAIN, TAG, 'build cookie header failed: %{public}s', this.messageOf(error));
    }
    const keys: string[] = Object.keys(extra);
    for (let i = 0; i < keys.length; i++) {
      headers[keys[i]] = extra[keys[i]];
    }
    return headers;
  }

  private withHeader(
    base: Record<string, string>,
    key: string,
    value: string
  ): Record<string, string> {
    const copy: Record<string, string> = {};
    const keys: string[] = Object.keys(base);
    for (let i = 0; i < keys.length; i++) {
      copy[keys[i]] = base[keys[i]];
    }
    copy[key] = value;
    return copy;
  }

  /** 把 http.Response 转成 HttpResult，并顺手保存 cookie */
  private toResult(url: string, response: http.HttpResponse): HttpResult {
    const code: number = response.responseCode as number;
    const body: string = this.bodyOf(response.result);

    const rawHeaders: Record<string, Object> = response.header as Record<string, Object>;
    const headers: Record<string, string> = {};
    const setCookieHeaders: string[] = [];
    const headerKeys: string[] = Object.keys(rawHeaders);
    for (let i = 0; i < headerKeys.length; i++) {
      const key: string = headerKeys[i];
      const lowerKey: string = key.toLowerCase();
      const rawValue: Object = rawHeaders[key];
      if (typeof rawValue === 'string') {
        headers[lowerKey] = rawValue;
        if (lowerKey === 'set-cookie') {
          setCookieHeaders.push(rawValue);
        }
      } else if (Array.isArray(rawValue)) {
        // 部分实现下 set-cookie 会是 string[]
        const values: string[] = rawValue as string[];
        const parts: string[] = [];
        for (let j = 0; j < values.length; j++) {
          const item: string = values[j];
          parts.push(item);
          if (lowerKey === 'set-cookie') {
            setCookieHeaders.push(item);
          }
        }
        headers[lowerKey] = parts.join(', ');
      } else {
        headers[lowerKey] = JSON.stringify(rawValue);
      }
    }

    const store: CookieStore = CookieStore.getInstance();
    if (setCookieHeaders.length > 0) {
      store.saveFromResponse(url, setCookieHeaders);
    }

    // HttpResponse.cookies（API 8+/API 11 文档为 string）才是完整 cookie 列表
    // 某些实现/无 cookie 场景下该字段可能缺失，这里按 Object 判型避免运行时 TypeError。
    const rawCookieField: Object = response.cookies as Object;
    const cookieField: string = typeof rawCookieField === 'string' ? rawCookieField as string : '';
    const rawCookies: string[] = this.rawCookieLines(cookieField);
    const host: string = hostOfUrl(url);
    const parsedCookies: ParsedSetCookie[] = parseResponseCookies(rawCookies.join('\r\n'), host);
    if (parsedCookies.length > 0) {
      store.saveParsedCookies(parsedCookies);
    }

    const cookies: string[] = [];
    for (let i = 0; i < setCookieHeaders.length; i++) {
      cookies.push(setCookieHeaders[i]);
    }
    for (let i = 0; i < rawCookies.length; i++) {
      cookies.push(rawCookies[i]);
    }
    return {
      code: code,
      body: body,
      headers: headers,
      cookies: cookies
    };
  }

  private bodyOf(result: string | Object | ArrayBuffer): string {
    if (typeof result === 'string') {
      return result;
    }
    // expectDataType=STRING 时不会走到这里；保守兜底，避免返回 'undefined'
    return JSON.stringify(result);
  }

  /** HttpResponse.cookies 是换行分隔的原始 cookie 串，拆成非空行 */
  private rawCookieLines(cookieField: string): string[] {
    const result: string[] = [];
    const text: string = cookieField.trim();
    if (text.length === 0) {
      return result;
    }
    const lines: string[] = text.split(/\r\n|\n|\r/);
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length > 0) {
        result.push(line);
      }
    }
    return result;
  }

  private toNetworkError(url: string, error: BusinessError): NetworkError {
    const reason: string = error.message.length > 0 ? error.message : '未知网络错误';
    const networkError: NetworkError = new NetworkError('网络请求失败：' + reason + '（' + url + '）');
    if (error.code > 0) {
      networkError.code = error.code;
    }
    hilog.error(LOG_DOMAIN, TAG, 'request failed: %{public}s %{public}s', url, reason);
    return networkError;
  }

  private messageOf(error: Error): string {
    return error.message.length > 0 ? error.message : 'unknown error';
  }
}
