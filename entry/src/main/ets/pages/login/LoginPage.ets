/**
 * 登录页（对齐 Android LoginActivity / LoginScreen 的三种登录方式）。
 *
 * 三种方式（顶部胶囊 SegmentRow 切换）：
 *  1) 网页登录：`Web` 组件加载 `{siteBase}login`，用户正常登录（或先过 Cloudflare 验证）。
 *     onPageEnd 时用 `webview.WebCookieManager.fetchCookieSync(baseUrl)` 读取网页 cookie，
 *     cookie 里出现 `hanime1_session`（或 `remember_web_*`）就进入登录收尾；
 *  2) 账号密码：邮箱 + 密码直接调用 `HanimeApi.loginWithPassword()`
 *     （GET /login 取 CSRF token → POST /login → verifyLoginLoose 校验 → 汇总 cookie），
 *     成功后写入登录态、拉账号资料并返回（对应原版 LoginDialog）；
 *  3) 手动 Cookie：粘贴 `name=value; name2=value2` 形式的 cookie 串直接保存。
 *
 * 登录态判定（2026-11 修复“网页登录成功仍提示未检测到登录状态”）：
 *  - 先 `CookieStore.setCookieString(raw)`（校验请求要带上网页 cookie）；
 *  - 再 `HanimeApi.verifyLoginLoose()` 做三级校验：
 *      GET /login 404 → 已登录；否则回退 GET / 解析首页 userId/username；
 *      再回退 GET /subscriptions（200 且非登录表单且含订阅页特征）。
 *    - 站点已登录时 `GET /login` 可能被 http 自动跟随 302 后返回 200 首页（而非 404），
 *      只判 404 是旧版误报的根因，所以必须有首页/订阅页回退；
 *  - 校验失败（含 Cloudflare 拦截 / 网络异常）时，网页登录按上游行为**信任 Cookie**：
 *      a) 当前 WebView URL 已不在 /login（已跳转离开登录页）；
 *      b) cookie 含 `remember_web_`；
 *      c) cookie 里 `hanime1_session` 值非空且用户明确点了「我已完成登录」。
 *    手动 Cookie 模式**不做**该兜底，必须通过增强校验（不能只靠 cookie 名）。
 *  - 成功后双写 cookie、用 getHome 补齐 userId/username/avatarUrl，再 Router.pop()。
 *
 * 登录成功后必须**双写**：
 *  - `CookieStore.getInstance().setCookieString(cookie)`（网络层真正发请求用的存储）；
 *  - `AppSettings.getInstance().setCookieString(cookie)` + `setLoggedIn(true)`（历史遗留副本，
 *    只写这个会导致重启后网络层无 cookie、登录态丢失）。
 * 见 viewmodel/library/SessionActions.applyLoginCookie（两处一起写）。
 *
 * 诊断约定：提示/日志只输出 cookie 的**名字列表**（绝不输出值），便于用户反馈。
 *
 * API 版本：`Web` 组件的 onPageEnd 回调参数在 API 24 是 OnPageEndEvent（含 url 字段），
 * 这里不显式标注参数类型（由编译器上下文推断），避免 SDK 类型差异导致编译失败。
 */

import { webview } from '@kit.ArkWeb';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { HanimeApi, LoginVerifyResult, PasswordLoginError } from '../../logic/net/HanimeApi';
import {
  CloudflareChallengeError,
  IpBlockedError,
  LoginExpiredError,
  NetworkError,
  describeError
} from '../../logic/net/Errors';
import { AppSettings } from '../../logic/settings/AppSettings';
import { AppState } from '../../logic/state/AppState';
import { ParsedSetCookie, hostOfUrl, parseCookieString } from '../../core/util/CookieHeader';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { RouteParam, Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar } from '../../components/common/Widgets';
import { SegmentRow } from '../library/LibraryComponents';
import { SessionActions } from '../../viewmodel/library/SessionActions';
import { CookieStore } from '../../logic/net/CookieStore';

/** 登录模式（顶部 SegmentRow 下标） */
const MODE_WEB: number = 0;
const MODE_PASSWORD: number = 1;
const MODE_MANUAL: number = 2;
const MODE_LABELS: string[] = ['网页登录', '账号密码', '手动 Cookie'];
/** 站点登录 cookie 名（Laravel 会话）；值非空才认为可能已登录 */
const SESSION_COOKIE_NAME: string = 'hanime1_session';
/** “记住登录”cookie 前缀（Laravel：remember_web_<hash>） */
const REMEMBER_COOKIE_PREFIX: string = 'remember_web';
/** Cloudflare 通行证 cookie 名（诊断/手动 cookie 提示用） */
const CF_CLEARANCE_NAME: string = 'cf_clearance';
/** 网页 cookie 读不到时的兜底地址（用户可能从主站跳转到备用域名，或反之） */
const FALLBACK_COOKIE_URL: string = 'https://hanime1.me';
/** 提示里最多展示的 cookie 名数量，避免 toast/tip 过长 */
const MAX_COOKIE_NAMES: number = 12;
const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'LoginPage';

@Component
export struct LoginPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：内容顶部 spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State mode: number = MODE_WEB;
  @State progress: number = 0;
  @State currentUrl: string = '';
  @State manualCookie: string = '';
  @State tipText: string = '登录成功后会自动同步 Cookie 并返回。若出现 Cloudflare 人机验证，请先在网页内完成验证。';
  /** 账号密码登录：输入与状态 */
  @State email: string = '';
  @State password: string = '';
  @State passwordError: string = '';
  @State loggingIn: boolean = false;

  /** 站点根地址（带结尾 /），登录页固定用它；页面打开期间不跟随设置变化 */
  private baseUrl: string = '';
  private loginUrl: string = '';
  private controller: webview.WebviewController = new webview.WebviewController();
  private disposed: boolean = false;
  private finishing: boolean = false;
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    this.baseUrl = AppSettings.getInstance().getBaseUrl();
    this.loginUrl = this.baseUrl + 'login';
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /**
   * WebView 的 UA 必须与网络层（AppSettings.getUserAgent）一致：
   * Cloudflare 的 cf_clearance 与 UA 绑定，UA 不一致会导致“网页验证通过、
   * 原生请求仍被拦截”。在 onControllerAttached（官方推荐时机）设置。
   */
  private applyUserAgent(): void {
    const ua: string = AppSettings.getInstance().getUserAgent();
    if (ua.length === 0) {
      return;
    }
    try {
      this.controller.setCustomUserAgent(ua);
    } catch (e) {
      // 设置 UA 失败不影响网页加载
    }
  }

  // ---------------------------------------------------------------------------
  // Cookie 读取 / 判定
  // ---------------------------------------------------------------------------

  /** 读取指定 url 的 WebView cookie（失败返回 ''） */
  private fetchCookieOf(url: string): string {
    if (url.length === 0) {
      return '';
    }
    try {
      return webview.WebCookieManager.fetchCookieSync(url);
    } catch (e) {
      return '';
    }
  }

  /** 由 baseUrl 得到 host 形式的 URL（如 `https://hanime1.me`），用于 cookie 兜底读取 */
  private hostUrlOf(url: string): string {
    const host: string = hostOfUrl(url);
    if (host.length === 0) {
      return '';
    }
    const lower: string = url.trim().toLowerCase();
    const scheme: string = lower.startsWith('http://') ? 'http://' : 'https://';
    return scheme + host;
  }

  /**
   * 读取网页登录相关 cookie。
   *
   * 先读 baseUrl；读不到登录标识时再用 `https://hanime1.me` 与“当前 baseUrl 的 host”
   * 两种 URL 兜底（ArkWeb 的 fetchCookieSync 按传入 URL 过滤，用户从主站跳备用域名
   * 或反过来时，只读 baseUrl 可能拿不到会话 cookie）。
   * 优先返回含登录标识的 cookie 串；都不含时返回第一个非空结果，供提示/诊断。
   */
  private readWebCookie(): string {
    const primary: string = this.fetchCookieOf(this.baseUrl);
    if (this.hasSessionCookie(primary)) {
      return primary;
    }
    const fallbackUrls: string[] = [];
    if (FALLBACK_COOKIE_URL !== this.baseUrl) {
      fallbackUrls.push(FALLBACK_COOKIE_URL);
    }
    const hostUrl: string = this.hostUrlOf(this.baseUrl);
    if (hostUrl.length > 0 && hostUrl !== this.baseUrl && hostUrl !== FALLBACK_COOKIE_URL) {
      fallbackUrls.push(hostUrl);
    }
    let firstNonEmpty: string = '';
    for (let i = 0; i < fallbackUrls.length; i++) {
      const cookie: string = this.fetchCookieOf(fallbackUrls[i]);
      if (cookie.length === 0) {
        continue;
      }
      if (this.hasSessionCookie(cookie)) {
        return cookie;
      }
      if (firstNonEmpty.length === 0) {
        firstNonEmpty = cookie;
      }
    }
    if (primary.length > 0) {
      return primary;
    }
    return firstNonEmpty;
  }

  /** 解析 cookie 串（core/util/CookieHeader 的纯逻辑，可在 Node 测试里复用） */
  private cookiesOf(raw: string): ParsedSetCookie[] {
    return parseCookieString(raw);
  }

  /** cookie 串里是否存在指定名字且值非空的 cookie */
  private hasNonEmptyCookie(raw: string, name: string): boolean {
    const cookies: ParsedSetCookie[] = this.cookiesOf(raw);
    for (let i = 0; i < cookies.length; i++) {
      if (cookies[i].name === name && cookies[i].value.length > 0) {
        return true;
      }
    }
    return false;
  }

  /** cookie 串里是否有“记住登录”cookie（Laravel: remember_web_<hash>，值非空） */
  private hasRememberCookie(raw: string): boolean {
    const cookies: ParsedSetCookie[] = this.cookiesOf(raw);
    for (let i = 0; i < cookies.length; i++) {
      const name: string = cookies[i].name;
      if (name.startsWith(REMEMBER_COOKIE_PREFIX) && cookies[i].value.length > 0) {
        return true;
      }
    }
    return false;
  }

  /** cookie 串里是否有站点会话标识（hanime1_session 值非空，或 remember_web_*） */
  private hasSessionCookie(raw: string): boolean {
    return this.hasNonEmptyCookie(raw, SESSION_COOKIE_NAME) || this.hasRememberCookie(raw);
  }

  /** cookie 的名字列表（诊断用；只输出名字，绝不输出值） */
  private cookieNameList(raw: string): string {
    const cookies: ParsedSetCookie[] = this.cookiesOf(raw);
    const names: string[] = [];
    for (let i = 0; i < cookies.length; i++) {
      const name: string = cookies[i].name;
      if (name.length === 0 || names.indexOf(name) >= 0) {
        continue;
      }
      names.push(name);
    }
    if (names.length === 0) {
      return '无';
    }
    if (names.length > MAX_COOKIE_NAMES) {
      return names.slice(0, MAX_COOKIE_NAMES).join(', ') + ', …';
    }
    return names.join(', ');
  }

  /** 记录 cookie 名列表并返回，供提示文案复用 */
  private logCookieNames(raw: string): string {
    const names: string = this.cookieNameList(raw);
    try {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'cookie names: %{public}s', names);
    } catch (e) {
      // 日志失败不影响登录
    }
    return names;
  }

  /** 记录增强校验命中的方式（诊断用；不输出 cookie 值） */
  private logVerifyResult(result: LoginVerifyResult): void {
    try {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'login verify: method=%{public}s loggedIn=%{public}s',
        result.method, result.loggedIn ? 'true' : 'false');
    } catch (e) {
      // 日志失败不影响登录
    }
  }

  /** 记录增强校验异常类型（诊断用：区分 Cloudflare 拦截 / 网络失败） */
  private logVerifyError(error: Error): void {
    try {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'login verify failed: %{public}s: %{public}s',
        error.name, error.message);
    } catch (e) {
      // 日志失败不影响登录
    }
  }

  /** URL 是否是登录页（含 /login 路径） */
  private isLoginUrl(url: string): boolean {
    return url.toLowerCase().indexOf('/login') >= 0;
  }

  /** URL 是否是 Cloudflare 挑战/验证页（不是“已离开登录页”的登录成功信号） */
  private isChallengeUrl(url: string): boolean {
    const lower: string = url.toLowerCase();
    return lower.indexOf('cdn-cgi') >= 0 || lower.indexOf('challenge') >= 0;
  }

  /** URL 是否仍属于当前站点域（排除登录页里点外链跳走的情况） */
  private isSiteUrl(url: string): boolean {
    const siteHost: string = hostOfUrl(this.baseUrl);
    const targetHost: string = hostOfUrl(url);
    if (siteHost.length === 0 || targetHost.length === 0) {
      return false;
    }
    return targetHost === siteHost || targetHost.endsWith('.' + siteHost) ||
      siteHost.endsWith('.' + targetHost);
  }

  /** 把 cookie 串逐条注入 Web 组件（手动 cookie 登录后，网页播放才能带上登录态） */
  private injectCookieToWebView(raw: string): void {
    const pairs: string[] = raw.split(';');
    for (let i = 0; i < pairs.length; i++) {
      const pair: string = pairs[i].trim();
      if (pair.length === 0 || pair.indexOf('=') <= 0) {
        continue;
      }
      try {
        webview.WebCookieManager.configCookieSync(this.baseUrl, pair + '; Path=/');
      } catch (e) {
        // 单条注入失败忽略：不影响 CookieStore 里的登录态
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 登录流程
  // ---------------------------------------------------------------------------

  /**
   * 登录收尾：**先写 cookie → 增强校验 → 必要时信任 Cookie → 双写 + 拉资料 → 返回**。
   *
   * @param rawCookie 网页 cookie 串或手动粘贴的 cookie 串
   * @param fromWeb 是否来自网页登录（来自网页时不需要再注入 WebView，且可走 Cookie 信任兜底）
   * @param explicitClick 本次是否由用户明确点击「我已完成登录」触发（信任条件 c 需要）
   */
  private async applyLogin(rawCookie: string, fromWeb: boolean, explicitClick: boolean): Promise<void> {
    if (this.finishing) {
      return;
    }
    this.finishing = true;
    try {
      const raw: string = rawCookie.trim();
      if (raw.length === 0) {
        Toast.show('未读取到 Cookie：请等网页加载完成后再点「我已完成登录」');
        this.tipText = '未读取到网页 Cookie：请等登录页加载完成、完成登录（含 Cloudflare 验证）后再点「我已完成登录」。';
        return;
      }

      // 1) 先把网页 cookie 写入网络层：后面的校验请求必须带上它
      CookieStore.getInstance().setCookieString(raw);
      const cookieNames: string = this.logCookieNames(raw);

      // 2) 增强校验（GET /login 404 → GET / 首页 → GET /subscriptions）
      let verified: LoginVerifyResult | null = null;
      let verifyError: Error | null = null;
      try {
        verified = await this.api.verifyLoginLoose();
        this.logVerifyResult(verified);
      } catch (rawError) {
        verifyError = rawError as Error;
        this.logVerifyError(verifyError);
      }
      if (this.disposed) {
        return;
      }

      // 3) 判定：校验通过，或网页登录按 Cookie 兜底信任（对齐上游：同站重定向后直接信任 Cookie）
      const verifiedLoggedIn: boolean = verified !== null && verified.loggedIn;
      const trustedByCookie: boolean = this.shouldTrustCookie(raw, fromWeb, explicitClick);
      if (!verifiedLoggedIn && !trustedByCookie) {
        const message: string = fromWeb
          ? this.describeWebLoginFailure(verifyError, cookieNames)
          : this.describeManualLoginFailure(verifyError, cookieNames);
        Toast.show(message);
        this.tipText = message;
        return;
      }

      // 4) 写入登录态：双写 cookie + 标记登录 + 通知“我的”页刷新
      SessionActions.applyLoginCookie(raw);
      if (!fromWeb) {
        this.injectCookieToWebView(raw);
      }

      // 5) 补齐账号资料（getHome；校验阶段已解析到首页信息时作为兜底）
      await this.loadAccountInfo(verified);
      if (this.disposed) {
        return;
      }
      Toast.show(verifiedLoggedIn ? '登录成功' : '已登录（Cookie 判定）');
      Router.pop();
    } catch (rawError) {
      Toast.show(describeError(rawError as Error));
    } finally {
      this.finishing = false;
    }
  }

  /**
   * 网页登录的 Cookie 信任条件（仅 fromWeb 时生效；手动 Cookie 模式必须严格校验）。
   * 任一条件成立即视为登录成功（对齐上游 LoginActivity：同站重定向后直接信任 CookieManager）。
   *
   * a) 当前 WebView URL 已不在 /login（已跳转离开登录页，且仍在站点域内；排除 Cloudflare 验证页）；
   * b) cookie 含 `remember_web_`（用户勾选了“记住登录”）；
   * c) cookie 里 `hanime1_session` 值非空且本次是用户明确点击「我已完成登录」。
   */
  private shouldTrustCookie(raw: string, fromWeb: boolean, explicitClick: boolean): boolean {
    if (!fromWeb) {
      return false;
    }
    // a) 已离开登录页（同站跳转，排除 Cloudflare 验证页与外链）
    if (this.currentUrl.length > 0 && this.isSiteUrl(this.currentUrl) &&
      !this.isLoginUrl(this.currentUrl) && !this.isChallengeUrl(this.currentUrl)) {
      return true;
    }
    // b) 勾选了“记住登录”
    if (this.hasRememberCookie(raw)) {
      return true;
    }
    // c) 有非空会话 cookie + 用户明确点了按钮
    if (explicitClick && this.hasNonEmptyCookie(raw, SESSION_COOKIE_NAME)) {
      return true;
    }
    return false;
  }

  /** 网页登录校验失败文案：区分“未登录 / Cloudflare 拦截 / 网络失败”，并附 cookie 名字列表 */
  private describeWebLoginFailure(error: Error | null, cookieNames: string): string {
    const cookieText: string = '（已读取 Cookie：' + cookieNames + '）';
    if (error !== null) {
      if (error instanceof CloudflareChallengeError || error instanceof IpBlockedError) {
        return 'Cloudflare 拦截：未能确认登录状态' + cookieText +
          '。请先在网页中完成人机验证，再点「我已完成登录」。';
      }
      if (error instanceof NetworkError) {
        return '网络失败：未能确认登录状态' + cookieText +
          '。请检查网络/代理后重试；若网页里已显示登录成功，可直接再点一次「我已完成登录」。';
      }
      return '登录校验异常：' + describeError(error) + cookieText;
    }
    return '未登录：站点未确认登录状态' + cookieText +
      '。请确认已在网页中完成登录（含 Cloudflare 验证）；若已登录，请点「重新加载」加载一次首页后重试，或切换到「手动 Cookie」粘贴。';
  }

  /** 手动 Cookie 校验失败文案：给出可操作步骤（不能只靠 cookie 名，必须站点确认） */
  private describeManualLoginFailure(error: Error | null, cookieNames: string): string {
    const cookieText: string = '（已读取 Cookie：' + cookieNames + '）';
    if (error !== null) {
      if (error instanceof CloudflareChallengeError || error instanceof IpBlockedError) {
        return 'Cloudflare 拦截：手动 Cookie 未能通过站点验证' + cookieText +
          '。请先在网页中完成人机验证并确认已登录，再复制完整 Cookie（含 ' + CF_CLEARANCE_NAME +
          '），或改用「网页登录」。';
      }
      if (error instanceof NetworkError) {
        return '网络失败：无法校验手动 Cookie' + cookieText +
          '。请检查网络/代理后重试，或改用「网页登录」。';
      }
      return '手动 Cookie 校验异常：' + describeError(error) + cookieText;
    }
    return '手动 Cookie 校验未通过：站点未确认登录状态' + cookieText +
      '。请确认粘贴的是登录成功后的完整 Cookie（至少包含 ' + SESSION_COOKIE_NAME +
      '；若站点有 Cloudflare 验证还需 ' + CF_CLEARANCE_NAME + '），或改用「网页登录」。';
  }

  /**
   * 用首页接口补齐 userId / username / avatarUrl（失败不阻断登录）。
   * `fallback` 是增强校验阶段从首页解析到/或带回的账号信息，getHome 失败时用它兜底。
   */
  private async loadAccountInfo(fallback: LoginVerifyResult | null): Promise<void> {
    try {
      const home = await this.api.getHome();
      if (home.userId.length > 0 || home.username.length > 0) {
        AppState.setUser(home.userId, home.username, home.avatarUrl);
        return;
      }
    } catch (rawError) {
      // 登录已成功：资料抓取失败（如 Cloudflare 拦截）时留空，下次首页加载会再补
    }
    if (fallback !== null && (fallback.userId.length > 0 || fallback.username.length > 0)) {
      AppState.setUser(fallback.userId, fallback.username, fallback.avatarUrl);
    }
  }

  /** 网页加载结束后调用：已离开 login 页面且 cookie 出现会话标识则自动完成登录 */
  private onWebPageEnd(url: string): void {
    this.currentUrl = url;
    this.progress = 100;
    if (url.length === 0) {
      return;
    }
    if (this.isLoginUrl(url)) {
      this.tipText = '如出现 Cloudflare 人机验证，请先完成验证；登录成功后会自动返回。';
      return;
    }
    if (this.isChallengeUrl(url)) {
      this.tipText = '检测到 Cloudflare 人机验证：请在网页中完成验证，然后点「我已完成登录」。';
      return;
    }
    const cookie: string = this.readWebCookie();
    if (cookie.length > 0 && this.hasSessionCookie(cookie)) {
      this.applyLogin(cookie, true, false);
    }
  }

  /** “我已完成登录”按钮：主动读一次 cookie，有会话标识就进入收尾，否则给出可操作提示 */
  private checkLoggedIn(): void {
    const cookie: string = this.readWebCookie();
    const cookieNames: string = this.logCookieNames(cookie);
    if (cookie.length > 0 && this.hasSessionCookie(cookie)) {
      this.applyLogin(cookie, true, true);
      return;
    }
    const cookieText: string = '（已读取 Cookie：' + cookieNames + '）';
    Toast.show('未读取到登录会话 Cookie' + cookieText);
    this.tipText = '未读取到登录会话 Cookie' + cookieText +
      '。请确认网页已完成登录；若刚完成 Cloudflare 验证，请点「重新加载」加载一次首页后再点「我已完成登录」，' +
      '也可切换到「手动 Cookie」粘贴。';
  }

  private reloadWeb(): void {
    this.progress = 0;
    try {
      this.controller.loadUrl(this.loginUrl);
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  private saveManualCookie(): void {
    const raw: string = this.manualCookie.trim();
    if (raw.length === 0 || raw.indexOf('=') <= 0) {
      Toast.show('Cookie 格式不正确，应形如 name=value; name2=value2');
      return;
    }
    if (!this.hasSessionCookie(raw)) {
      Toast.show('Cookie 中未找到有效的登录会话标识（' + SESSION_COOKIE_NAME +
        ' / ' + REMEMBER_COOKIE_PREFIX + '），可能无法保持登录');
    }
    this.applyLogin(raw, false, false);
  }

  // ---------------------------------------------------------------------------
  // 账号密码登录（对应原版 LoginDialog；网络流程见 HanimeApi.loginWithPassword）
  // ---------------------------------------------------------------------------

  /**
   * 账号密码登录：校验输入 → `HanimeApi.loginWithPassword` → `applyPasswordLogin` 收尾。
   * 登录中禁用重复点击（loggingIn 双保险：按钮 enabled + 方法入口判断）。
   */
  private async submitPasswordLogin(): Promise<void> {
    if (this.loggingIn) {
      return;
    }
    const account: string = this.email.trim();
    const secret: string = this.password;
    if (account.length === 0) {
      this.passwordError = '请输入登录邮箱';
      return;
    }
    if (secret.length === 0) {
      this.passwordError = '请输入登录密码';
      return;
    }
    this.loggingIn = true;
    this.passwordError = '';
    try {
      const cookie: string = await this.api.loginWithPassword(account, secret);
      if (this.disposed) {
        return;
      }
      await this.applyPasswordLogin(cookie);
    } catch (rawError) {
      if (this.disposed) {
        return;
      }
      const message: string = this.describePasswordLoginFailure(rawError as Error);
      this.passwordError = message;
      Toast.show(message);
    } finally {
      this.loggingIn = false;
    }
  }

  /**
   * 密码登录收尾：写入登录态（双写 cookie + 通知“我的”页）→ 同步 WebView cookie →
   * 用 getHome 补齐账号资料 → Toast + 返回。
   * 不调用 `applyLogin`：cookie 已由 loginWithPassword 校验过，避免重复请求与重复校验。
   */
  private async applyPasswordLogin(cookie: string): Promise<void> {
    SessionActions.applyLoginCookie(cookie);
    this.injectCookieToWebView(cookie);
    await this.loadAccountInfo(null);
    if (this.disposed) {
      return;
    }
    Toast.show('登录成功');
    Router.pop();
  }

  /** 密码登录错误文案：网络 / Cloudflare / 账号密码错误 / 站点未确认登录 分开 */
  private describePasswordLoginFailure(error: Error): string {
    if (error instanceof PasswordLoginError) {
      return error.message.length > 0 ? error.message : '账号或密码错误，请检查邮箱与密码后重试';
    }
    if (error instanceof CloudflareChallengeError || error instanceof IpBlockedError) {
      return 'Cloudflare 拦截：账号密码登录请求被站点拦截。请切换到「网页登录」完成人机验证后再试。';
    }
    if (error instanceof NetworkError) {
      return '网络错误：无法连接站点，请检查网络/代理后重试。';
    }
    if (error instanceof LoginExpiredError) {
      return error.message.length > 0
        ? error.message
        : '站点未确认登录状态，请稍后重试或改用「网页登录」。';
    }
    return '登录失败：' + describeError(error);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /** 悬浮顶栏让位 spacer（放在滚动内容首部，随内容滚走） */
  @Builder
  topSpacer() {
    Row()
      .width('100%')
      .height(this.statusBarHeight + Dimens.topBarHeight);
  }

  /** 登录方式切换胶囊（横向 12 边距自带；放在滚动内容里会随内容一起滚到顶栏下方） */
  @Builder
  modeTabs() {
    Row() {
      SegmentRow({
        options: MODE_LABELS,
        selectedIndex: this.mode,
        onSelect: (index: number) => {
          this.mode = index;
          this.passwordError = '';
        }
      });
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 10, bottom: 8 });
  }

  @Builder
  webLoginView() {
    Column() {
      Text(this.tipText)
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .lineHeight(17)
        .width('100%')
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 2, bottom: 10 });

      // 网页登录区域：圆角 16 裁切 + 1vp 描边，顶部 primary 进度条
      Column() {
        Column() {
          Stack({ alignContent: Alignment.TopStart }) {
            Web({ src: this.loginUrl, controller: this.controller })
              .domStorageAccess(true)
              .javaScriptAccess(true)
              .mixedMode(MixedMode.All)
              .width('100%')
              .height('100%')
              .onControllerAttached(() => {
                this.applyUserAgent();
              })
              .onProgressChange((event) => {
                if (event) {
                  this.progress = event.newProgress;
                }
              })
              .onPageEnd((event) => {
                if (event) {
                  this.onWebPageEnd(event.url);
                }
              });

            Row()
              .width(this.progress + '%')
              .height(2)
              .backgroundColor(Theme.colors().primary);
          }
          .width('100%')
          .height('100%');
        }
        .width('100%')
        .layoutWeight(1)
        .borderRadius(16)
        .clip(true)
        .backgroundColor(Theme.colors().cardBg)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });

      Row() {
        Button('重新加载')
          .fontSize(Dimens.bodySize)
          .height(44)
          .layoutWeight(1)
          .backgroundColor(Theme.colors().chipTint)
          .fontColor(Theme.colors().textPrimary)
          .borderRadius(999)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .onClick(() => {
            this.reloadWeb();
          });
        Button('我已完成登录')
          .fontSize(Dimens.bodySize)
          .height(44)
          .layoutWeight(1)
          .margin({ left: 10 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .onClick(() => {
            this.checkLoggedIn();
          });
      }
      .width('100%')
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 10, bottom: 8 });

      // 登录方式说明：方式切换胶囊在滚动模式里随内容滚动，网页模式固定在悬浮顶栏下方，这里只做小字提示
      Text('三种登录方式：网页登录 / 账号密码 / 手动 Cookie，可在顶部切换。' +
        '网页登录被 Cloudflare 拦截时，也可改用账号密码登录。')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .lineHeight(16)
        .width('100%')
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, bottom: this.navBarHeight + 16 });
    }
    .width('100%')
    .layoutWeight(1);
  }

  @Builder
  passwordLoginView() {
    Scroll() {
      Column() {
        this.topSpacer();
        this.modeTabs();

        Column() {
          Text('账号密码登录')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .width('100%')
          .margin({ top: 6 });

        Text('使用站点注册邮箱和密码直接登录，无需打开网页。' +
          '若站点要求 Cloudflare 人机验证，请先切换到「网页登录」完成验证，再回来重试。')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .lineHeight(20)
          .width('100%')
          .margin({ top: 8 });

        Text('邮箱')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .width('100%')
          .margin({ top: 16, bottom: 6 });

        TextInput({ text: this.email, placeholder: 'you@example.com' })
          .type(InputType.Email)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textPrimary)
          .placeholderColor(Theme.colors().textHint)
          .height(44)
          .width('100%')
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.colors().chipTint)
          .borderRadius(Dimens.listRadius)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .enabled(!this.loggingIn)
          .onChange((value: string) => {
            this.email = value;
            this.passwordError = '';
          });

        Text('密码')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .width('100%')
          .margin({ top: 14, bottom: 6 });

        TextInput({ text: this.password, placeholder: '请输入密码' })
          .type(InputType.Password)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textPrimary)
          .placeholderColor(Theme.colors().textHint)
          .height(44)
          .width('100%')
          .padding({ left: 14, right: 14 })
          .backgroundColor(Theme.colors().chipTint)
          .borderRadius(Dimens.listRadius)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .enabled(!this.loggingIn)
          .onChange((value: string) => {
            this.password = value;
            this.passwordError = '';
          });

        if (this.passwordError.length > 0) {
          Text(this.passwordError)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().error)
            .lineHeight(17)
            .width('100%')
            .margin({ top: 10 });
        }

        Button(this.loggingIn ? '登录中…' : '登录')
          .fontSize(Dimens.bodySize)
          .height(44)
          .width('100%')
          .margin({ top: 16 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .enabled(!this.loggingIn)
          .opacity(this.loggingIn ? 0.6 : 1)
          .onClick(() => {
            this.submitPasswordLogin();
          });

        Button('改用网页登录')
          .fontSize(Dimens.bodySize)
          .height(44)
          .width('100%')
          .margin({ top: 10 })
          .backgroundColor(Theme.colors().chipTint)
          .fontColor(Theme.colors().textPrimary)
          .borderRadius(999)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .enabled(!this.loggingIn)
          .onClick(() => {
            this.mode = MODE_WEB;
          });

        Text('提示：密码仅用于向站点提交登录请求，不会保存在本机，也不会上传到任何第三方。' +
          '站点开启了两步验证或要求人机验证时，请使用「网页登录」。')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 14, bottom: 20 });
        }
        .width('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          bottom: this.navBarHeight + 16
        });
      }
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring);
  }

  @Builder
  manualCookieView() {
    Scroll() {
      Column() {
        this.topSpacer();
        this.modeTabs();

        Column() {
          Text('Cookie 格式')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .width('100%')
          .margin({ top: 6 });

        Text('name=value; name2=value2\n\n' +
          '示例：hanime1_session=xxxx; XSRF-TOKEN=yyyy; cf_clearance=zzzz\n\n' +
          '获取方式：在浏览器登录 hanime1.me 后，打开开发者工具 → Application（应用）→ ' +
          'Cookies → 选择站点域名，复制其中的关键项（至少需要 ' + SESSION_COOKIE_NAME + '）。')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .lineHeight(20)
          .width('100%')
          .margin({ top: 8 });

        // 手动 Cookie 输入：chipTint 输入卡（圆角 12 + 1vp 描边 + 内边距 12）
        TextArea({ text: this.manualCookie, placeholder: '粘贴完整 Cookie 字符串' })
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textPrimary)
          .placeholderColor(Theme.colors().textHint)
          .backgroundColor(Theme.colors().chipTint)
          .borderRadius(Dimens.listRadius)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .height(150)
          .width('100%')
          .padding(12)
          .margin({ top: 14 })
          .onChange((value: string) => {
            this.manualCookie = value;
          });

        Button('保存并登录')
          .fontSize(Dimens.bodySize)
          .height(44)
          .width('100%')
          .margin({ top: 16 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .onClick(() => {
            this.saveManualCookie();
          });

        Button('去首页看看')
          .fontSize(Dimens.bodySize)
          .height(44)
          .width('100%')
          .margin({ top: 10 })
          .backgroundColor(Theme.colors().chipTint)
          .fontColor(Theme.colors().textPrimary)
          .borderRadius(999)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .onClick(() => {
            Router.pop();
          });

        Text('提示：手动 Cookie 只保存在本机，不会上传到任何服务器；' +
          'Cookie 具有账号权限，请勿分享给他人。')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .lineHeight(17)
          .width('100%')
          .margin({ top: 14, bottom: 20 });
        }
        .width('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          bottom: this.navBarHeight + 16
        });
      }
      .width('100%');
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring);
  }

  build() {
    // 悬浮顶栏：内容铺满整页并在顶部用 spacer 让出状态栏 + 顶栏高度：
    //  - 网页登录：spacer + 方式胶囊固定在悬浮顶栏下方（WebView 不能滚动到顶栏下面）；
    //  - 账号密码 / 手动 Cookie：spacer + 方式胶囊在 Scroll 内部，随内容滚走（Bika 式）。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.mode === MODE_WEB) {
        Column() {
          this.topSpacer();
          this.modeTabs();
          this.webLoginView();
        }
        .width('100%')
        .height('100%');
      } else if (this.mode === MODE_PASSWORD) {
        this.passwordLoginView();
      } else {
        this.manualCookieView();
      }

      AppTopBar({
        title: '登录',
        showBack: true,
        actionText: '去首页看看',
        onAction: () => {
          Router.pop();
        }
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
