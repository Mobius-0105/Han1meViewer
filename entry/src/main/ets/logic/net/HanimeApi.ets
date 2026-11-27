/**
 * 站点 API 门面（ArkTS）。
 *
 * 严格按 docs/ARKTS_GUIDE.md 第 4 节的签名实现（UI 层依赖这些签名，不要改）。
 * 每个方法：
 *  - 用 core/util/Urls.ts 拼 URL；
 *  - 用 HttpClient 发请求（自动带 cookie / UA）；
 *  - 非 2xx 统一交给 ResponseGuard 抛 Errors.ets 里的错误；
 *  - HTML 响应先 replaceBackupMediaCdn 再交给 core/parser 的解析函数；
 *  - 内部 try/catch 只做一件事：把 JSON 解析产生的 SyntaxError 包成 ParseError，
 *    其余 Error 原样抛出（不吞异常）。
 *
 * 与 Android NetworkRepo 的对应关系见各方法注释。`GET previews/{date}` 未实现：
 * 站点已把"新番预告"迁到 search，GUIDE 也没有 parsePreview 契约。
 */

import {
  HomePage,
  SearchPage,
  SearchRequest,
  HanimeVideo,
  VideoComments,
  PostCommentResult,
  MyListPage,
  PlaylistsPage,
  UserAccount
} from '../../core/model/Models';
import {
  parseHomePage,
  parseSearchPage,
  parseVideoPage,
  parseMyListPage,
  parsePlaylistsPage,
  parseUserAccount,
  extractCsrfFromLoginPage
} from '../../core/parser/HanimeParser';
import {
  parseComments,
  parseCommentsPage,
  parseReplies,
  parsePostComment,
  parsePostReply
} from '../../core/parser/CommentParser';
import {
  normalizeBaseUrl,
  buildSearchUrl,
  buildWatchUrl,
  buildCommentsUrl,
  buildRepliesUrl,
  buildUserListUrl,
  buildUserHistoryUrl,
  buildUserAccountUrl,
  buildPlaylistsUrl,
  buildPlaylistUrl,
  replaceBackupMediaCdn
} from '../../core/util/Urls';
import { COMMENT_TYPE_VIDEO, DEFAULT_BASE_URL, DEFAULT_USER_AGENT } from '../../core/util/Constants';
import {
  ParsedSetCookie,
  hostOfUrl,
  parseCookieString,
  parseResponseCookies,
  parseSetCookie
} from '../../core/util/CookieHeader';
import { HttpClient, HttpResult } from './HttpClient';
import { CookieStore } from './CookieStore';
import { guardHtml, assertOrThrow, detectCloudflare } from './ResponseGuard';
import {
  AppError,
  CloudflareChallengeError,
  IpBlockedError,
  LoginExpiredError,
  ParseError
} from './Errors';

const JSON_ACCEPT: string = 'application/json, text/javascript, */*; q=0.01';
/** 创建播放列表时站点偶发 500（但实际已创建成功），Android 端把 500 当成功 */
const HTTP_500: number = 500;
const HTTP_OK_MIN: number = 200;
const HTTP_OK_MAX: number = 299;
const HTTP_200: number = 200;
const HTTP_403: number = 403;
const HTTP_404: number = 404;

/** verifyLoginLoose 命中的校验方式（仅诊断/提示用，不参与业务判断） */
const LOGIN_METHOD_LOGIN_404: string = 'login404';
const LOGIN_METHOD_HOME: string = 'home';
const LOGIN_METHOD_SUBSCRIPTIONS: string = 'subscriptions';
const LOGIN_METHOD_NONE: string = 'none';

/** 登录表单特征：`<form ... action=".../login">`（相对或绝对地址都算） */
const LOGIN_FORM_ACTION: RegExp = /<form[^>]*action\s*=\s*["'][^"']*\/login/i;

/** 站点登录会话 cookie 名（Laravel 会话；密码登录成功后必须拿到它） */
const LOGIN_SESSION_COOKIE: string = 'hanime1_session';

/**
 * 账号密码登录被站点明确拒绝（邮箱/密码错误，或 POST 被 401/419/422 拒绝、
 * 或响应体仍是登录表单）。LoginPage 据此显示「账号或密码错误」，
 * 与「站点未确认登录状态」（LoginExpiredError）区分开。
 */
export class PasswordLoginError extends AppError {
  constructor(message: string) {
    super(message);
    this.name = 'PasswordLoginError';
  }
}

/**
 * 增强版登录态校验结果。
 *
 * 为什么需要它：`checkLoginState()` 只返回 boolean，但首页回退校验解析出的
 * userId/username/avatarUrl 恰好可以省掉一次 getHome()，也让登录页能立即把
 * 账号信息写入 AppState。
 */
export interface LoginVerifyResult {
  loggedIn: boolean;
  userId: string;
  username: string;
  avatarUrl: string;
  /** 命中的校验方式：login404 / home / subscriptions / none（诊断用） */
  method: string;
}

function emptyLoginVerifyResult(): LoginVerifyResult {
  const result: LoginVerifyResult = {
    loggedIn: false,
    userId: '',
    username: '',
    avatarUrl: '',
    method: LOGIN_METHOD_NONE
  };
  return result;
}

let apiInstance: HanimeApi | null = null;

export class HanimeApi {
  private baseUrl: string = DEFAULT_BASE_URL;
  private userAgent: string = DEFAULT_USER_AGENT;
  /** 是否启用备用媒体 CDN（对应 Android Preferences.useBackupMediaCdn） */
  private backupCdn: boolean = false;
  private client: HttpClient = HttpClient.getInstance();

  private constructor() {
  }

  static getInstance(): HanimeApi {
    let instance: HanimeApi | null = apiInstance;
    if (instance === null) {
      instance = new HanimeApi();
      apiInstance = instance;
    }
    return instance;
  }

  /** 设置 baseUrl / UA / 备用 CDN。设置页变更域名或 UA 后调用。 */
  configure(baseUrl: string, userAgent: string, backupCdn: boolean): void {
    this.baseUrl = normalizeBaseUrl(baseUrl);
    this.userAgent = userAgent.trim().length > 0 ? userAgent.trim() : DEFAULT_USER_AGENT;
    this.backupCdn = backupCdn;
    this.client.setUserAgent(this.userAgent);
  }

  // ---------------------------------------------------------------------------
  // 首页 / 搜索 / 视频 / 预告
  // ---------------------------------------------------------------------------

  /** GET `/`（Android: Parser.homePageVer2） */
  async getHome(): Promise<HomePage> {
    try {
      const result: HttpResult = await this.client.get(this.baseUrl, this.htmlHeaders());
      const html: string = this.htmlBody(result);
      return parseHomePage(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `/search?page&query&genre&sort&broad&date&duration&tags[]&brands[]` */
  async search(req: SearchRequest): Promise<SearchPage> {
    try {
      const url: string = buildSearchUrl(this.baseUrl, req);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.htmlBody(result);
      return parseSearchPage(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `/watch?v=`（403/500 表示影片不存在，由 ResponseGuard 抛 NotFoundError） */
  async getVideo(videoCode: string): Promise<HanimeVideo> {
    try {
      const url: string = buildWatchUrl(this.baseUrl, videoCode);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.htmlBody(result);
      return parseVideoPage(html, this.baseUrl, videoCode);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /**
   * 增强版登录态校验（宽松判定），按三级顺序：
   *  1) `GET /login` 返回 404 → 已登录（对齐上游 NetworkRepo.login 的密码登录判定，保留）；
   *  2) 回退 `GET /`：首页解析出登录用户的 `userId` / `username`（任一非空）→ 已登录，
   *     同时把账号信息带回（首页解析见 core/parser/HanimeParser.parseHomePage）；
   *  3) 回退 `GET /subscriptions`：返回 200、body 不是登录表单（不含 name="email" /
   *     name="password" / `<form action=".../login">`）、且含订阅页特征
   *     （`subscriptions-nav` 或 `content-padding-new`）→ 已登录。
   *
   * 为什么不能只看 404：`@ohos.net.http` 的 request 会自动跟随 302（见 HttpClient 注释），
   * 站点已登录时 `GET /login` 很可能被跟随到首页后返回 200 首页，而不是 404；
   * 只判 404 就会误报“未检测到有效登录状态”。第 2/3 级回退正是为此兜底。
   *
   * 站点是 Laravel 应用，**游客也会拿到 hanime1_session 会话 cookie**，
   * 所以本方法不使用“cookie 里存在 session 名”作为判定依据（由调用方按信任策略处理）。
   *
   * @returns 校验结果；`loggedIn=false` 表示站点明确未登录
   * @throws CloudflareChallengeError 任一请求被 Cloudflare 挑战页拦截时（code 为 HTTP 状态码）
   * @throws IpBlockedError 403 且是 Cloudflare “you have been blocked” 拦截页时
   * @throws NetworkError 请求因 DNS/连接/超时等网络原因失败时（调用方据此区分“网络失败”）
   */
  async verifyLoginLoose(): Promise<LoginVerifyResult> {
    const result: LoginVerifyResult = emptyLoginVerifyResult();

    // 1) GET /login：站点已登录时 Laravel 返回 404
    const loginUrl: string = this.baseUrl + 'login';
    const loginResult: HttpResult = await this.client.get(loginUrl, this.htmlHeaders());
    if (loginResult.code === HTTP_404) {
      result.loggedIn = true;
      result.method = LOGIN_METHOD_LOGIN_404;
      return result;
    }
    this.throwIfBlocked(loginResult);

    // 2) 回退 GET /：首页里能解析出登录用户的 userId / username
    const homeResult: HttpResult = await this.client.get(this.baseUrl, this.htmlHeaders());
    this.throwIfBlocked(homeResult);
    const home: HomePage | null = this.tryParseHomeForLogin(homeResult);
    if (home !== null && (home.userId.length > 0 || home.username.length > 0)) {
      result.loggedIn = true;
      result.userId = home.userId;
      result.username = home.username;
      result.avatarUrl = home.avatarUrl;
      result.method = LOGIN_METHOD_HOME;
      return result;
    }

    // 3) 回退 GET /subscriptions：登录后才有订阅页
    if (await this.subscriptionsIndicateLogin()) {
      result.loggedIn = true;
      result.method = LOGIN_METHOD_SUBSCRIPTIONS;
    }
    return result;
  }

  /**
   * 登录态校验入口（保留原 boolean 签名）。
   * 语义已改为“宽松校验”，实现委托给 `verifyLoginLoose()`（404 → 首页 → 订阅页）。
   *
   * @returns true=已登录；false=未登录
   * @throws CloudflareChallengeError / IpBlockedError / NetworkError 同 verifyLoginLoose
   */
  async checkLoginState(): Promise<boolean> {
    const result: LoginVerifyResult = await this.verifyLoginLoose();
    return result.loggedIn;
  }

  // ---------------------------------------------------------------------------
  // 账号密码登录（对齐 Android NetworkRepo.login）
  // ---------------------------------------------------------------------------

  /**
   * 账号密码登录。
   *
   * 流程（对应 Android `NetworkRepo.login(email, password)`）：
   *  1) GET `/login` 取 HTML，用 extractCsrfFromLoginPage 取 Laravel `_token`
   *     （同时把游客会话 cookie 写入 CookieStore，POST 需要它才能通过 CSRF 校验）；
   *  2) POST `/login`，表单 `_token` / `email` / `password`，并带 `X-CSRF-TOKEN`
   *     （与站内其它 POST 一致，见 postComment）；
   *  3) 登录态校验：原版是“再次 GET /login 期望 404”，这里委托 `verifyLoginLoose()`
   *     （404 → 首页解析 → 订阅页，兼容 @ohos.net.http 自动跟随 302 后返回 200 首页的情况）；
   *  4) 汇总响应 `result.cookies` / `result.headers['set-cookie']` 里的 `name=value`，
   *     再用 CookieStore 里该 host 的 cookie 补齐缺失项（校验成功即证明该 cookie 可用，
   *     可兜住“302 中间响应 Set-Cookie 未被最终响应带回”的情况），得到整串 cookie。
   *
   * @param email 站点登录邮箱（前后空白会被去掉）
   * @param password 站点登录密码（原样提交，不做 trim）
   * @returns 形如 `hanime1_session=...; XSRF-TOKEN=...` 的整串 cookie，可直接交给 SessionActions
   * @throws PasswordLoginError 账号或密码错误（含 401/419/422 与响应体仍是登录表单）
   * @throws LoginExpiredError 站点未确认登录状态 / 未取到会话 Cookie
   * @throws CloudflareChallengeError Cloudflare 人机验证拦截
   * @throws IpBlockedError 当前 IP 被 Cloudflare 屏蔽
   * @throws NetworkError 网络不可用 / 超时
   */
  async loginWithPassword(email: string, password: string): Promise<string> {
    const account: string = email.trim();
    if (account.length === 0 || password.length === 0) {
      throw new PasswordLoginError('请输入邮箱和密码');
    }

    // 1) GET /login 取 CSRF token（游客会话 cookie 由 HttpClient 自动写入 CookieStore）
    const loginUrl: string = this.baseUrl + 'login';
    const pageResult: HttpResult = await this.client.get(loginUrl, this.htmlHeaders());
    // 403 的 Cloudflare 挑战 / IP 拦截要先抛（此时页面没有可用 token）
    this.throwIfBlocked(pageResult);
    if (pageResult.code === HTTP_404) {
      // 站点已登录时 /login 返回 404：原版同样无法在此状态下切换账号，提示先退出登录
      throw new LoginExpiredError('当前已是登录状态，如需切换账号请先退出登录后再试');
    }
    const pageHtml: string = this.htmlBody(pageResult);
    if (!this.looksLikeLoginFormBody(pageHtml)) {
      // 已登录时 GET /login 也可能被 302 跟随成 200 首页，页面里没有登录表单
      throw new LoginExpiredError('当前可能已是登录状态（未取到登录表单），如需切换账号请先退出登录');
    }
    const token: string = extractCsrfFromLoginPage(pageHtml);
    if (token.length === 0) {
      throw new ParseError('登录页未找到 CSRF 令牌，站点可能已改版；可改用「网页登录」');
    }

    // 2) POST /login：表单字段与 Android HanimeBaseService.login 保持一致
    const form: Record<string, string> = {};
    form['_token'] = token;
    form['email'] = account;
    form['password'] = password;
    const postResult: HttpResult =
      await this.client.postForm(loginUrl, form, this.csrfHeaders(token));
    this.throwIfBlocked(postResult);

    // 3) 先按原版语义判定 POST 是否被拒（Android: !req.isSuccessful → 账号密码错误；
    //    302 回登录页被 http 跟随成 200 时响应体仍是登录表单，同样视为被拒），
    //    再用 verifyLoginLoose 复核登录态（对齐“再次 GET /login 期望 404”的判定）
    const rejected: boolean = !this.isSuccessCode(postResult.code) ||
      this.looksLikeLoginFormBody(postResult.body);
    if (rejected) {
      throw new PasswordLoginError('账号或密码错误，请检查邮箱与密码后重试');
    }
    const verified: LoginVerifyResult = await this.verifyLoginLoose();
    if (!verified.loggedIn) {
      throw new LoginExpiredError('站点未确认登录状态，请稍后重试或改用「网页登录」');
    }

    // 4) 汇总 cookie（至少包含 hanime1_session）
    const cookie: string = this.loginCookieString(postResult);
    if (cookie.length === 0 || cookie.indexOf(LOGIN_SESSION_COOKIE + '=') < 0) {
      throw new LoginExpiredError('登录已通过，但未取到站点会话 Cookie，请改用「网页登录」');
    }
    return cookie;
  }

  /**
   * 汇总密码登录后的整串 cookie：先响应里的 Set-Cookie / cookies 字段，
   * 再补 CookieStore 中缺失的项（响应顺序优先，避免旧会话覆盖新会话）。
   */
  private loginCookieString(result: HttpResult): string {
    const cookies: Map<string, string> = new Map<string, string>();
    const setCookieHeader: string = this.headerValue(result, 'set-cookie');
    if (setCookieHeader.length > 0) {
      this.addResponseCookieLine(cookies, setCookieHeader, false);
    }
    const rawCookies: string[] | undefined = result.cookies;
    if (rawCookies !== undefined) {
      for (let i = 0; i < rawCookies.length; i++) {
        this.addResponseCookieLine(cookies, rawCookies[i], false);
      }
    }
    // 兜底：POST/校验期间 HttpClient 已把响应 cookie 持久化；校验通过说明它是可用的
    const stored: string = CookieStore.getInstance().getCookieHeader(this.baseUrl);
    this.addCookieHeaderString(cookies, stored, true);

    const parts: string[] = [];
    cookies.forEach((value: string, name: string): void => {
      parts.push(name + '=' + value);
    });
    return parts.join('; ');
  }

  /**
   * 解析一条原始响应 cookie：
   *  - 含 tab 的是 @ohos.http 的 curl/Netscape 行（domain/includeSubdomains/path/...）；
   *  - 否则是单条 Set-Cookie（可能带 Domain/Path/Expires 属性）。
   */
  private addResponseCookieLine(
    cookies: Map<string, string>,
    line: string,
    onlyIfMissing: boolean
  ): void {
    const raw: string = line.trim();
    if (raw.length === 0) {
      return;
    }
    const host: string = hostOfUrl(this.baseUrl);
    if (raw.indexOf('\t') >= 0) {
      const parsed: ParsedSetCookie[] = parseResponseCookies(raw, host);
      for (let i = 0; i < parsed.length; i++) {
        this.putCookie(cookies, parsed[i].name, parsed[i].value, onlyIfMissing);
      }
      return;
    }
    const cookie: ParsedSetCookie | null = parseSetCookie(raw, host);
    if (cookie !== null) {
      this.putCookie(cookies, cookie.name, cookie.value, onlyIfMissing);
    }
  }

  /** 解析 `a=1; b=2` 形式的 Cookie 头（CookieStore.getCookieHeader 的返回值） */
  private addCookieHeaderString(
    cookies: Map<string, string>,
    raw: string,
    onlyIfMissing: boolean
  ): void {
    const parsed: ParsedSetCookie[] = parseCookieString(raw);
    for (let i = 0; i < parsed.length; i++) {
      this.putCookie(cookies, parsed[i].name, parsed[i].value, onlyIfMissing);
    }
  }

  private putCookie(
    cookies: Map<string, string>,
    name: string,
    value: string,
    onlyIfMissing: boolean
  ): void {
    if (name.length === 0) {
      return;
    }
    if (onlyIfMissing && cookies.has(name)) {
      return;
    }
    cookies.set(name, value);
  }

  /** 读取响应头（键统一小写；缺失返回 ''） */
  private headerValue(result: HttpResult, key: string): string {
    const value: string = result.headers[key];
    return value === undefined ? '' : value;
  }

  // ---------------------------------------------------------------------------
  // 评论
  // ---------------------------------------------------------------------------

  /**
   * GET `/loadComment?type=video&id=&offset=`。
   * offset <= 0：首屏（Parser.comments），offset > 0：翻页（Parser.commentsPage）。
   */
  async getComments(videoCode: string, offset: number): Promise<VideoComments> {
    try {
      const safeOffset: number = offset > 0 ? offset : -1;
      const url: string = buildCommentsUrl(this.baseUrl, COMMENT_TYPE_VIDEO, videoCode, safeOffset);
      const result: HttpResult = await this.client.get(url, this.jsonHeaders());
      const body: string = this.jsonBody(result);
      if (safeOffset > 0) {
        return parseCommentsPage(body);
      }
      return parseComments(body);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `/loadReplies?id=` */
  async getReplies(commentId: string): Promise<VideoComments> {
    try {
      const url: string = buildRepliesUrl(this.baseUrl, commentId);
      const result: HttpResult = await this.client.get(url, this.jsonHeaders());
      const body: string = this.jsonBody(result);
      return parseReplies(body);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /**
   * POST `/createComment`（表单 + X-CSRF-TOKEN）。
   * @param targetId Android 里是目标用户 id（评论所属对象），form 字段 comment-foreign-id
   */
  async postComment(
    text: string,
    currentUserId: string,
    targetId: string,
    token: string
  ): Promise<PostCommentResult> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['comment-user-id'] = currentUserId;
      form['comment-type'] = COMMENT_TYPE_VIDEO;
      form['comment-foreign-id'] = targetId;
      form['comment-text'] = text;
      form['comment-count'] = '1';
      const url: string = this.baseUrl + 'createComment';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      const body: string = this.jsonBody(result);
      return parsePostComment(body);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** POST `/replyComment` */
  async postReply(commentId: string, text: string, token: string): Promise<PostCommentResult> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['reply-comment-id'] = commentId;
      form['reply-comment-text'] = text;
      const url: string = this.baseUrl + 'replyComment';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      const body: string = this.jsonBody(result);
      return parsePostReply(body);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** POST `/commentLike`（点赞/点踩评论） */
  async likeComment(
    token: string,
    type: string,
    foreignId: string,
    isPositive: boolean,
    likesCount: number,
    likesSum: number,
    likeStatus: boolean,
    unlikeStatus: boolean
  ): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['foreign_type'] = type;
      form['foreign_id'] = foreignId;
      form['is_positive'] = isPositive ? '1' : '0';
      form['comment-likes-count'] = '' + likesCount;
      form['comment-likes-sum'] = '' + likesSum;
      form['like-comment-status'] = likeStatus ? '1' : '0';
      form['unlike-comment-status'] = unlikeStatus ? '1' : '0';
      const url: string = this.baseUrl + 'commentLike';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  // ---------------------------------------------------------------------------
  // 收藏 / 评分 / 举报
  // ---------------------------------------------------------------------------

  /** POST `/like`：收藏（cancel=false）/ 取消收藏（cancel=true） */
  async favVideo(videoCode: string, cancel: boolean, userId: string, token: string): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['like-foreign-id'] = videoCode;
      form['like-status'] = cancel ? '1' : '';
      form['_token'] = token;
      form['like-user-id'] = userId;
      form['like-is-positive'] = '1';
      const url: string = this.baseUrl + 'like';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /**
   * POST `/subscribe`：关注 / 取消关注作者（对齐上游 `HanimeSubscriptionService.subscribeArtist`）。
   *
   * 表单字段与上游逐字段一致（Kotlin：`logic/network/service/HanimeSubscriptionService.kt:13-19`）：
   *  - `_token` CSRF；
   *  - `subscribe-user-id` / `subscribe-artist-id` 来自视频页 `#video-subscribe-form` 的两个 hidden input
   *    （由 HanimeParser.parseArtist 解析进 Artist.userId / Artist.artistId）；
   *  - `subscribe-status`：**未订阅时发空串，已订阅发 `1`**，所以「关注」= 空串、取消关注 = '1'；
   *  - 请求头同时带 `X-CSRF-TOKEN`（与站内其它 POST 一致）。
   */
  async subscribeArtist(userId: string, artistId: string, subscribed: boolean, token: string): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['subscribe-user-id'] = userId;
      form['subscribe-artist-id'] = artistId;
      form['subscribe-status'] = subscribed ? '1' : '';
      const url: string = this.baseUrl + 'subscribe';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** POST `/like`：给影片点赞/点踩 */
  async rateVideo(
    videoCode: string,
    positive: boolean,
    likeStatus: boolean,
    unlikeStatus: boolean,
    likesCount: number,
    unlikesCount: number,
    userId: string,
    token: string
  ): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['like-foreign-id'] = videoCode;
      form['like-is-positive'] = positive ? '1' : '0';
      form['like-status'] = likeStatus ? '1' : '';
      form['unlike-status'] = unlikeStatus ? '1' : '';
      form['likes-count'] = '' + likesCount;
      form['unlikes-count'] = '' + unlikesCount;
      form['_token'] = token;
      form['like-user-id'] = userId;
      const url: string = this.baseUrl + 'like';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /**
   * POST `/user/{userId}/report`：举报评论 / 子回复。
   *
   * 对齐上游 `logic/network/service/HanimeCommentService.kt submitReport` 与
   * `logic/NetworkRepo.kt reportComment`：
   *  - 路径参数 userId = 当前登录用户 id（`comment-user-id`，来自 loadComment 响应）；
   *  - 表单字段：`_token`(csrf)、`redirect-url`(当前视频页地址)、`reportable-id`、
   *    `reportable-type`(comment / reply)、`reason`(举报理由，取上游 report_reason.json 的 reason_key)；
   *  - 请求头 X-CSRF-TOKEN（与站内其它 POST 一致）。
   * 站点对该接口只返回"已处理"提示（上游 Parser.reportCommentResponse 也无法可靠判断成功），
   * 因此这里按表单写操作的通用语义处理：HTTP 2xx 且不是登录页即视为提交成功。
   */
  async reportComment(
    token: string,
    userId: string,
    redirectUrl: string,
    reportableType: string,
    reportableId: string,
    reason: string
  ): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['redirect-url'] = redirectUrl;
      form['reportable-id'] = reportableId;
      form['reportable-type'] = reportableType;
      form['reason'] = reason;
      const url: string = this.baseUrl + 'user/' + encodeURIComponent(userId) + '/report';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  // ---------------------------------------------------------------------------
  // 我的清单 / 播放列表 / 历史 / 账号
  // ---------------------------------------------------------------------------

  /** GET `user/{userId}/{type}?page=`（type 为 likes / saves 等） */
  async getMyList(userId: string, type: string, page: number): Promise<MyListPage> {
    try {
      const url: string = buildUserListUrl(this.baseUrl, userId, type, page);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.loginRequiredHtml(result);
      return parseMyListPage(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `user/{userId}/playlists?page=` */
  async getPlaylists(userId: string, page: number): Promise<PlaylistsPage> {
    try {
      const url: string = buildPlaylistsUrl(this.baseUrl, userId, page);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.loginRequiredHtml(result);
      return parsePlaylistsPage(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `playlist?list=&page=` */
  async getPlaylistItems(listCode: string, page: number): Promise<MyListPage> {
    try {
      const url: string = buildPlaylistUrl(this.baseUrl, listCode, page);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.loginRequiredHtml(result);
      return parseMyListPage(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `user/{userId}/histories?sort=&page=` */
  async getOnlineHistory(userId: string, sort: string, page: number): Promise<MyListPage> {
    try {
      const url: string = buildUserHistoryUrl(this.baseUrl, userId, sort, page);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.loginRequiredHtml(result);
      return parseMyListPage(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `user/{userId}/edit` */
  async getUserAccount(userId: string): Promise<UserAccount> {
    try {
      const url: string = buildUserAccountUrl(this.baseUrl, userId);
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.loginRequiredHtml(result);
      return parseUserAccount(html, this.baseUrl);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** GET `login` 并从登录页 `<input name="_token">` 取 CSRF token（密码登录第一步） */
  async getLoginPageToken(): Promise<string> {
    try {
      const url: string = this.baseUrl + 'login';
      const result: HttpResult = await this.client.get(url, this.htmlHeaders());
      const html: string = this.htmlBody(result);
      return extractCsrfFromLoginPage(html);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  // ---------------------------------------------------------------------------
  // 写操作（GUIDE 签名之外但 UI 需要；保持与 Android service 的字段一致）
  // ---------------------------------------------------------------------------

  /** POST `createPlaylist`（Android 把 500 也视为成功） */
  async createPlaylist(
    videoCode: string,
    title: string,
    description: string,
    token: string
  ): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['create-playlist-video-id'] = videoCode;
      form['playlist-title'] = title;
      form['playlist-description'] = description;
      const url: string = this.baseUrl + 'createPlaylist';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      if (result.code !== HTTP_500) {
        this.assertPostOk(result);
      }
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** POST `playlist/{listCode}`（删除时 playlist-delete=on；成功可能返回 302） */
  async modifyPlaylist(
    listCode: string,
    title: string,
    description: string,
    deletePlaylist: boolean,
    token: string
  ): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['playlist-title'] = title;
      form['playlist-description'] = description;
      form['_token'] = token;
      form['_method'] = 'PUT';
      if (deletePlaylist) {
        form['playlist-delete'] = 'on';
      }
      const url: string = this.baseUrl + 'playlist/' + encodeURIComponent(listCode);
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      assertOrThrow(result, true);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** POST `save`：把影片加入/移出自定义播放列表 */
  async addToMyList(
    listCode: string,
    videoCode: string,
    isChecked: boolean,
    token: string
  ): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['input_id'] = listCode;
      form['video_id'] = videoCode;
      form['is_checked'] = isChecked ? 'true' : 'false';
      form['user_id'] = '';
      const url: string = this.baseUrl + 'save';
      const result: HttpResult = await this.client.postForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** DELETE `user/tab-item/{videoCode}` + form(tab=histories) */
  async deleteHistory(videoCode: string, token: string): Promise<void> {
    try {
      const form: Record<string, string> = {};
      form['_token'] = token;
      form['tab'] = 'histories';
      const url: string = this.baseUrl + 'user/tab-item/' + encodeURIComponent(videoCode);
      const result: HttpResult = await this.client.deleteForm(url, form, this.csrfHeaders(token));
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  /** DELETE `playlist/items/{itemId}`（JSON 响应，删除"我的清单"里的条目） */
  async deleteMyListItem(itemId: string, token: string): Promise<void> {
    try {
      const headers: Record<string, string> = this.jsonHeaders();
      if (token.length > 0) {
        headers['X-CSRF-TOKEN'] = token;
      }
      const url: string = this.baseUrl + 'playlist/items/' + encodeURIComponent(itemId);
      const result: HttpResult = await this.client.deleteForm(url, {}, headers);
      this.assertPostOk(result);
    } catch (rawError) {
      const error: Error = rawError as Error;
      throw this.parseErrorOf(error);
    }
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  private htmlHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['Referer'] = this.baseUrl;
    return headers;
  }

  private jsonHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['Referer'] = this.baseUrl;
    headers['Accept'] = JSON_ACCEPT;
    headers['X-Requested-With'] = 'XMLHttpRequest';
    return headers;
  }

  private csrfHeaders(token: string): Record<string, string> {
    const headers: Record<string, string> = this.jsonHeaders();
    if (token.length > 0) {
      headers['X-CSRF-TOKEN'] = token;
    }
    return headers;
  }

  /** HTML 响应：状态判定 + 备用 CDN 替换 */
  private htmlBody(result: HttpResult): string {
    const body: string = guardHtml(result);
    return replaceBackupMediaCdn(body, this.backupCdn);
  }

  /** 需要登录态的 HTML 页面：额外识别"被重定向到登录页"的情况 */
  private loginRequiredHtml(result: HttpResult): string {
    const html: string = this.htmlBody(result);
    this.assertNotLoginHtml(html);
    return html;
  }

  /** JSON 响应：状态判定 + 备用 CDN 替换 + 是否合法 JSON 的校验 */
  private jsonBody(result: HttpResult): string {
    const body: string = replaceBackupMediaCdn(guardHtml(result), this.backupCdn);
    const trimmed: string = body.trim();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      return body;
    }
    if (this.looksLikeLoginPage(trimmed)) {
      const expired: LoginExpiredError = new LoginExpiredError('登录状态已失效，请重新登录');
      expired.code = 302;
      throw expired;
    }
    throw new ParseError('接口返回的不是 JSON 数据，可能登录状态已失效或站点已改版');
  }

  /** 表单类写操作：HTTP 成功即可，但要拦截"登录页伪装成功"的情况 */
  private assertPostOk(result: HttpResult): void {
    guardHtml(result);
    this.assertNotLoginHtml(result.body);
  }

  private assertNotLoginHtml(body: string): void {
    if (this.looksLikeLoginPage(body)) {
      const expired: LoginExpiredError = new LoginExpiredError('登录状态已失效，请重新登录');
      expired.code = 302;
      throw expired;
    }
  }

  /** 登录页特征：有 password 输入框，且表单指向 /login 或带 name="email" */
  private looksLikeLoginPage(body: string): boolean {
    const lower: string = body.toLowerCase();
    const hasPassword: boolean =
      lower.indexOf('type="password"') >= 0 || lower.indexOf("type='password'") >= 0;
    if (!hasPassword) {
      return false;
    }
    return lower.indexOf('/login') >= 0 || lower.indexOf('name="email"') >= 0;
  }

  // ---------------------------------------------------------------------------
  // 登录态宽松校验的内部实现
  // ---------------------------------------------------------------------------

  /** 2xx 判定（verifyLoginLoose 只对 2xx 响应做解析） */
  private isSuccessCode(code: number): boolean {
    return code >= HTTP_OK_MIN && code <= HTTP_OK_MAX;
  }

  /** Cloudflare 挑战 / IP 拦截：抛错交给登录页区分“被拦截”与“未登录/网络失败” */
  private throwIfBlocked(result: HttpResult): void {
    if (detectCloudflare(result)) {
      const challenge: CloudflareChallengeError =
        new CloudflareChallengeError('需要完成 Cloudflare 人机验证');
      challenge.code = result.code;
      throw challenge;
    }
    if (result.code === HTTP_403) {
      const body: string = result.body;
      if (body.indexOf('you have been blocked') >= 0 ||
        body.indexOf('You have been blocked') >= 0) {
        const blocked: IpBlockedError = new IpBlockedError('检测到当前 IP 被 Cloudflare 屏蔽');
        blocked.code = result.code;
        throw blocked;
      }
    }
  }

  /**
   * 把 home 响应解析成 HomePage（仅 2xx；解析异常/非首页结构一律返回 null，
   * 让校验继续回退到订阅页，而不是把“解析失败”当成网络错误抛给用户）。
   */
  private tryParseHomeForLogin(result: HttpResult): HomePage | null {
    if (!this.isSuccessCode(result.code)) {
      return null;
    }
    try {
      return parseHomePage(result.body, this.baseUrl);
    } catch (rawError) {
      return null;
    }
  }

  /**
   * `GET /subscriptions` 是否表明已登录：
   * 200 + 不是登录表单 + 含订阅页特征（`subscriptions-nav` / `content-padding-new`）。
   * 游客访问订阅页会被 302 到 /login（http 自动跟随），最终 body 是登录表单，故判定失败。
   */
  private async subscriptionsIndicateLogin(): Promise<boolean> {
    const url: string = this.baseUrl + 'subscriptions';
    const result: HttpResult = await this.client.get(url, this.htmlHeaders());
    this.throwIfBlocked(result);
    if (result.code !== HTTP_200) {
      return false;
    }
    if (this.looksLikeLoginFormBody(result.body)) {
      return false;
    }
    const body: string = result.body;
    return body.indexOf('subscriptions-nav') >= 0 || body.indexOf('content-padding-new') >= 0;
  }

  /**
   * 响应体是否像站点登录表单：
   * 含 `name="email"` / `name="password"`，或 `<form ... action=".../login">`。
   */
  private looksLikeLoginFormBody(body: string): boolean {
    const lower: string = body.toLowerCase();
    if (lower.indexOf('name="email"') >= 0 || lower.indexOf("name='email'") >= 0) {
      return true;
    }
    if (lower.indexOf('name="password"') >= 0 || lower.indexOf("name='password'") >= 0) {
      return true;
    }
    LOGIN_FORM_ACTION.lastIndex = 0;
    return LOGIN_FORM_ACTION.test(body);
  }

  /** 只处理 SyntaxError（JSON.parse 失败），其余错误原样返回 */
  private parseErrorOf(error: Error): Error {
    if (error instanceof SyntaxError) {
      return new ParseError('接口响应不是合法 JSON，站点结构可能已变化');
    }
    return error;
  }
}
