/**
 * Cookie 持久化（ArkTS）。
 *
 * 对应 Android 侧的 HCookieJar + Preferences.loginCookie/cloudFlareCookie：
 * - 自动保存站点/Cloudflare 下发的 cookie（含 cf_clearance），按 host 分组持久化到 preferences；
 * - 支持登录时手动整串导入 cookie（形如 `a=1; b=2`）；
 * - 请求前按 URL 的 host/path 拼接 Cookie 请求头。
 *
 * 使用方式：Application/EntryAbility 启动时调用一次 `await CookieStore.getInstance().init(ctx)`，
 * 之后 HttpClient 会自动读写。初始化完成前的请求不会带 cookie（但不会崩溃）。
 *
 * 纯逻辑（Set-Cookie 解析、host/path 匹配）在 core/util/CookieHeader.ts，本文件只负责
 * 存储结构 + @kit.ArkData preferences I/O。
 */

import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import {
  ParsedSetCookie,
  parseSetCookie,
  parseCookieString,
  buildCookieHeader,
  serializeCookies,
  deserializeCookies,
  hostOfUrl,
  pathOfUrl
} from '../../core/util/CookieHeader';

const PREF_NAME: string = 'hanime_cookie_store';
const KEY_HOSTS: string = 'hosts';
const KEY_LOGIN: string = 'login_cookie';
/** 无法确定 domain 时的兜底分组 */
const DEFAULT_BUCKET: string = 'default';
const LOG_DOMAIN: number = 0x0001;
const TAG: string = 'CookieStore';

export class CookieStore {
  private static instance: CookieStore | null = null;

  private prefs: preferences.Preferences | null = null;
  private initialized: boolean = false;
  /** host（已规范化，不含前导点）→ 该 host 下保存的 cookie 列表 */
  private hostCookies: Map<string, ParsedSetCookie[]> = new Map<string, ParsedSetCookie[]>();
  /** 手动导入/密码登录保存的 cookie（domain 为空 → 对所有 host 发送） */
  private loginCookies: ParsedSetCookie[] = [];
  private loginCookieRaw: string = '';

  private constructor() {
  }

  static getInstance(): CookieStore {
    let instance: CookieStore | null = CookieStore.instance;
    if (instance === null) {
      instance = new CookieStore();
      CookieStore.instance = instance;
    }
    return instance;
  }

  /**
   * 从 preferences 读取持久化 cookie。重复调用直接返回。
   * 必须在发起任何网络请求前调用一次（EntryAbility.onCreate 即可）。
   */
  async init(ctx: common.UIAbilityContext): Promise<void> {
    if (this.initialized) {
      return;
    }
    try {
      const store: preferences.Preferences = await preferences.getPreferences(ctx, PREF_NAME);
      this.prefs = store;

      const hostsJson: string = await this.readString(store, KEY_HOSTS, '');
      this.loadHostCookies(hostsJson);

      const loginRaw: string = await this.readString(store, KEY_LOGIN, '');
      this.loginCookieRaw = loginRaw;
      this.loginCookies = parseCookieString(loginRaw);
      this.initialized = true;
    } catch (rawError) {
      const error: BusinessError = rawError as BusinessError;
      // preferences 打不开不应该导致 App 起不来：退化为纯内存 cookie
      hilog.error(LOG_DOMAIN, TAG, 'init failed: %{public}s', this.messageOf(error));
    }
  }

  /**
   * 返回该 URL 应携带的 Cookie 请求头值，无则 ''。
   * 已过期 / host 不匹配 / path 不匹配的 cookie 会被过滤。
   */
  getCookieHeader(url: string): string {
    const cookies: ParsedSetCookie[] = this.collectCookies();
    if (cookies.length === 0) {
      return '';
    }
    const host: string = hostOfUrl(url);
    const path: string = pathOfUrl(url);
    return buildCookieHeader(cookies, host, path, Date.now());
  }

  /**
   * 解析 Set-Cookie 头（可能多条）并持久化。
   * @param url 发起请求的 URL（用于缺省 Domain/Path）
   * @param setCookieValues 单条 Set-Cookie 的值数组（header 里可能是数组也可能是字符串）
   */
  saveFromResponse(url: string, setCookieValues: string[]): void {
    if (setCookieValues.length === 0) {
      return;
    }
    const requestHost: string = hostOfUrl(url);
    let changed: boolean = false;
    for (let i = 0; i < setCookieValues.length; i++) {
      const parsed: ParsedSetCookie | null = parseSetCookie(setCookieValues[i], requestHost);
      if (parsed === null) {
        continue;
      }
      const bucketKey: string = this.bucketKeyOf(parsed, requestHost);
      this.mergeCookie(bucketKey, parsed);
      changed = true;
    }
    if (changed) {
      this.persistHosts();
    }
  }

  /**
   * 保存已经解析好的 cookie（HttpClient 从 `HttpResponse.cookies`
   * 的 curl 风格列表解析出来的那部分，包含 cf_clearance 等全部 Set-Cookie）。
   */
  saveParsedCookies(cookies: ParsedSetCookie[]): void {
    if (cookies.length === 0) {
      return;
    }
    for (let i = 0; i < cookies.length; i++) {
      const cookie: ParsedSetCookie = cookies[i];
      const bucketKey: string = this.bucketKeyOf(cookie, '');
      this.mergeCookie(bucketKey, cookie);
    }
    this.persistHosts();
  }

  /** 手动设置（登录/粘贴 cookie 用），字符串形如 "a=1; b=2" */
  setCookieString(raw: string): void {
    this.loginCookieRaw = raw.trim();
    this.loginCookies = parseCookieString(this.loginCookieRaw);
    const store: preferences.Preferences | null = this.prefs;
    if (store !== null) {
      this.writeString(store, KEY_LOGIN, this.loginCookieRaw);
    }
  }

  /** 当前手动保存的登录 cookie 整串；未登录返回 '' */
  getCookieString(): string {
    if (this.loginCookieRaw.length > 0) {
      return this.loginCookieRaw;
    }
    if (this.loginCookies.length === 0) {
      return '';
    }
    const parts: string[] = [];
    for (let i = 0; i < this.loginCookies.length; i++) {
      const cookie: ParsedSetCookie = this.loginCookies[i];
      parts.push(cookie.name + '=' + cookie.value);
    }
    return parts.join('; ');
  }

  /** 是否保存了"登录 cookie"（ResponseGuard 用它区分 404 语义、判断登录态） */
  hasLoginCookie(): boolean {
    return this.loginCookies.length > 0;
  }

  /** 清空所有 cookie（内存 + preferences）。退出登录时调用。 */
  clear(): void {
    this.hostCookies.clear();
    this.loginCookies = [];
    this.loginCookieRaw = '';
    const store: preferences.Preferences | null = this.prefs;
    if (store !== null) {
      this.writeString(store, KEY_HOSTS, '{}');
      this.writeString(store, KEY_LOGIN, '');
    }
  }

  // ---------------------------------------------------------------------------
  // 内部实现
  // ---------------------------------------------------------------------------

  /** 收集所有分组里的 cookie + 手动 cookie（过期过滤交给 buildCookieHeader） */
  private collectCookies(): ParsedSetCookie[] {
    const result: ParsedSetCookie[] = [];
    this.hostCookies.forEach((bucket: ParsedSetCookie[]): void => {
      for (let i = 0; i < bucket.length; i++) {
        result.push(bucket[i]);
      }
    });
    for (let i = 0; i < this.loginCookies.length; i++) {
      result.push(this.loginCookies[i]);
    }
    return result;
  }

  private bucketKeyOf(cookie: ParsedSetCookie, requestHost: string): string {
    if (cookie.domain.length > 0) {
      return cookie.domain;
    }
    if (requestHost.length > 0) {
      return requestHost;
    }
    return DEFAULT_BUCKET;
  }

  /** 同名同 path 覆盖；Max-Age<=0 的删除型 Set-Cookie 直接从分组里移除 */
  private mergeCookie(bucketKey: string, cookie: ParsedSetCookie): void {
    let bucket: ParsedSetCookie[] | undefined = this.hostCookies.get(bucketKey);
    if (bucket === undefined) {
      bucket = [];
    }
    const now: number = Date.now();
    const expired: boolean = cookie.expiresAt > 0 && cookie.expiresAt <= now;
    const next: ParsedSetCookie[] = [];
    for (let i = 0; i < bucket.length; i++) {
      const existing: ParsedSetCookie = bucket[i];
      if (existing.name === cookie.name && existing.path === cookie.path) {
        continue;
      }
      if (existing.expiresAt > 0 && existing.expiresAt <= now) {
        continue;
      }
      next.push(existing);
    }
    if (!expired) {
      next.push(cookie);
    }
    this.hostCookies.set(bucketKey, next);
  }

  private loadHostCookies(json: string): void {
    this.hostCookies.clear();
    if (json.trim().length === 0) {
      return;
    }
    let parsed: Record<string, Object>;
    try {
      parsed = JSON.parse(json) as Record<string, Object>;
    } catch (rawError) {
      // 持久化数据损坏时按空的处理，不要影响正常使用
      return;
    }
    const hosts: string[] = Object.keys(parsed);
    for (let i = 0; i < hosts.length; i++) {
      const host: string = hosts[i];
      const cookiesValue: Object = parsed[host];
      if (typeof cookiesValue !== 'string') {
        continue;
      }
      const cookies: ParsedSetCookie[] = deserializeCookies(cookiesValue);
      if (cookies.length > 0) {
        this.hostCookies.set(host, cookies);
      }
    }
  }

  private buildHostsJson(): string {
    const now: number = Date.now();
    const record: Record<string, string> = {};
    this.hostCookies.forEach((bucket: ParsedSetCookie[], host: string): void => {
      const alive: ParsedSetCookie[] = [];
      for (let i = 0; i < bucket.length; i++) {
        const cookie: ParsedSetCookie = bucket[i];
        if (cookie.expiresAt > 0 && cookie.expiresAt <= now) {
          continue;
        }
        alive.push(cookie);
      }
      if (alive.length > 0) {
        record[host] = serializeCookies(alive);
      }
    });
    return JSON.stringify(record);
  }

  private persistHosts(): void {
    const store: preferences.Preferences | null = this.prefs;
    if (store === null) {
      return;
    }
    this.writeString(store, KEY_HOSTS, this.buildHostsJson());
  }

  private async readString(store: preferences.Preferences, key: string, fallback: string): Promise<string> {
    const value: string = await store.get(key, fallback) as string;
    return typeof value === 'string' ? value : fallback;
  }

  private writeString(store: preferences.Preferences, key: string, value: string): void {
    store.put(key, value).then((): void => {
      store.flush().catch((error: BusinessError): void => {
        hilog.error(LOG_DOMAIN, TAG, 'flush %{public}s failed: %{public}s', key, this.messageOf(error));
      });
    }).catch((error: BusinessError): void => {
      hilog.error(LOG_DOMAIN, TAG, 'put %{public}s failed: %{public}s', key, this.messageOf(error));
    });
  }

  private messageOf(error: Error): string {
    return error.message.length > 0 ? error.message : 'unknown error';
  }
}
