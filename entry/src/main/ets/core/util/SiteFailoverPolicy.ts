/**
 * 站点自动切换（failover）的纯逻辑。
 *
 * 为什么单独放在 core/util 下（不 import 任何 @kit / logic 模块）：
 * - Node 单测可以直接用 tsx 跑（tests/logic/site_failover.test.ts），不会接触网络；
 * - HttpClient 与 logic/net/SiteFailover.ets 共用同一套 URL 改写 / 触发判定 / 冷却规则，
 *   避免两份实现漂移，也让 HttpClient 不必 import SiteFailover（避免循环依赖）。
 *
 * 触发换站的条件（由 HttpClient 在 GET 失败时调用 shouldFailover 系列函数）：
 * - 底层网络异常 / 超时 / DNS（NetworkError，见 HttpClient.execute 的 catch 分支）；
 * - HTTP 403 / 429 / 500 / 502 / 503 / 504；
 * - 响应体或响应头带 Cloudflare 特征（Just a moment / cf-mitigated / you have been blocked）。
 * 以下情况**不**触发（保持现有错误 UI 语义）：401、404、419、3xx 登录跳转、2xx 正常响应。
 */

/** 自动切换成功后 60s 内不再自动切换（防抖，避免站点之间来回跳） */
export const FAILOVER_SWITCH_COOLDOWN_MS: number = 60000;

/** 一轮候选全部失败后 30s 内不再发起候选轮询（并发请求快速失败，避免反复打满超时） */
export const FAILOVER_RETRY_COOLDOWN_MS: number = 30000;

/** 命中即换站重试的 HTTP 状态码 */
const FAILOVER_STATUS_CODES: number[] = [403, 429, 500, 502, 503, 504];

/**
 * 明确不触发换站的状态码：
 * - 301/302/303/307/308：登录跳转（站点要求登录），换站也解决不了账号问题；
 * - 401/419：登录态 / CSRF 失效；
 * - 404：页面或影片不存在（由 ResponseGuard 转成 NotFoundError / LoginExpiredError）。
 */
const NON_FAILOVER_STATUS_CODES: number[] = [301, 302, 303, 307, 308, 401, 404, 419];

/** `scheme://host[:port]`，只认 http/https；host 不区分大小写 */
const ORIGIN_PATTERN: RegExp = /^(https?):\/\/([^\/?#]+)/i;

/** 响应体里的 Cloudflare 特征（统一转小写后比较） */
const CLOUDFLARE_BODY_MARKERS: string[] = [
  'just a moment',
  'cf-mitigated',
  'you have been blocked'
];

function contains(values: number[], target: number): boolean {
  for (let i = 0; i < values.length; i++) {
    if (values[i] === target) {
      return true;
    }
  }
  return false;
}

function containsOrigin(origins: string[], target: string): boolean {
  for (let i = 0; i < origins.length; i++) {
    if (origins[i] === target) {
      return true;
    }
  }
  return false;
}

/** HTML 类响应体处理：统一小写比较；超大响应体只取前 200KB，避免无谓的内存/CPU 开销 */
function lowerBody(body: string): string {
  const limit: number = 200 * 1024;
  const text: string = body.length > limit ? body.substring(0, limit) : body;
  return text.toLowerCase();
}

/** 该状态码是否属于「换站可能有用」的失败 */
export function isFailoverStatus(code: number): boolean {
  return contains(FAILOVER_STATUS_CODES, code);
}

/** 该状态码是否明确「换站也没用」（登录态 / 页面不存在 / 登录跳转） */
export function isNonFailoverStatus(code: number): boolean {
  return contains(NON_FAILOVER_STATUS_CODES, code);
}

/** 2xx 视为请求成功（只有成功响应才会采用候选站点并全局切换） */
export function isSuccessStatus(code: number): boolean {
  return code >= 200 && code <= 299;
}

/**
 * 提取请求 URL 的 origin（`https://host[:port]`，无尾斜杠，host 统一小写）。
 * 非 http(s) 绝对地址（相对路径 / 空串 / ftp）返回 ''。
 */
export function candidateOriginOf(url: string): string {
  const trimmed: string = url.trim();
  const match: RegExpMatchArray | null = trimmed.match(ORIGIN_PATTERN);
  if (match === null) {
    return '';
  }
  return match[1].toLowerCase() + '://' + match[2].toLowerCase();
}

/**
 * 把候选 origin 规范成 `https://host[:port]`：
 * - 已经是 http(s) 绝对地址：只去掉尾斜杠 / path；
 * - 裸 host（`hanime1.com` / `hanime1.com/`）：默认补 https。
 * 空串返回 ''。
 */
export function normalizeOrigin(origin: string): string {
  const trimmed: string = origin.trim();
  if (trimmed.length === 0) {
    return '';
  }
  const absolute: string = candidateOriginOf(trimmed);
  if (absolute.length > 0) {
    return absolute;
  }
  let bare: string = trimmed;
  while (bare.endsWith('/')) {
    bare = bare.substring(0, bare.length - 1);
  }
  if (bare.length === 0) {
    return '';
  }
  const slash: number = bare.indexOf('/');
  const hostPart: string = slash >= 0 ? bare.substring(0, slash) : bare;
  return 'https://' + hostPart.toLowerCase();
}

/** 从 origin 取纯 host（用于 Toast / AppStorage 展示，如 `hanime1.com`） */
export function hostOfOrigin(origin: string): string {
  const normalized: string = normalizeOrigin(origin);
  const schemeIndex: number = normalized.indexOf('://');
  if (schemeIndex < 0) {
    return '';
  }
  const authority: string = normalized.substring(schemeIndex + 3);
  const atIndex: number = authority.lastIndexOf('@');
  const hostAndPort: string = atIndex >= 0 ? authority.substring(atIndex + 1) : authority;
  const portIndex: number = hostAndPort.indexOf(':');
  return portIndex >= 0 ? hostAndPort.substring(0, portIndex) : hostAndPort;
}

/**
 * 在 BASE_URL_OPTIONS 里找到与 origin 对应的 baseUrl 条目（保留其尾斜杠写法）。
 * 找不到时返回 `origin + '/'`，保证 HanimeApi.configure 后拼出的 URL 仍是合法绝对地址。
 */
export function baseUrlForOrigin(options: string[], origin: string): string {
  const target: string = normalizeOrigin(origin);
  for (let i = 0; i < options.length; i++) {
    if (normalizeOrigin(options[i]) === target) {
      return options[i];
    }
  }
  return target.length > 0 ? target + '/' : '';
}

/**
 * 把绝对 URL 的 `scheme://host[:port]` 替换成候选 origin，**保留 path / query / hash**。
 * - 相对 URL 或空 origin 原样返回（调用方据此放弃该候选）；
 * - 只重写 origin，不改写路径大小写与转义。
 */
export function rewriteOrigin(url: string, origin: string): string {
  const targetOrigin: string = normalizeOrigin(origin);
  if (targetOrigin.length === 0) {
    return url;
  }
  const trimmed: string = url.trim();
  const match: RegExpMatchArray | null = trimmed.match(ORIGIN_PATTERN);
  if (match === null) {
    return url;
  }
  const rest: string = trimmed.substring(match[0].length);
  return targetOrigin + rest;
}

/** BASE_URL_OPTIONS 按 origin 去重后的候选列表（保持配置顺序） */
export function optionOrigins(options: string[]): string[] {
  const result: string[] = [];
  for (let i = 0; i < options.length; i++) {
    const origin: string = normalizeOrigin(options[i]);
    if (origin.length === 0) {
      continue;
    }
    let exists: boolean = false;
    for (let j = 0; j < result.length; j++) {
      if (result[j] === origin) {
        exists = true;
        break;
      }
    }
    if (!exists) {
      result.push(origin);
    }
  }
  return result;
}

/**
 * 候选轮询顺序：从失败 origin 的**下一个**站点开始环形轮询，排除失败 origin 本身。
 * 失败 origin 不在 BASE_URL_OPTIONS 里时从第一个开始（尽量救一次）。
 */
export function candidateOriginsAfter(options: string[], failedOrigin: string): string[] {
  const origins: string[] = optionOrigins(options);
  const target: string = normalizeOrigin(failedOrigin);
  let start: number = 0;
  for (let i = 0; i < origins.length; i++) {
    if (origins[i] === target) {
      start = i + 1;
      break;
    }
  }
  const result: string[] = [];
  for (let step = 0; step < origins.length; step++) {
    const origin: string = origins[(start + step) % origins.length];
    if (origin === target) {
      continue;
    }
    result.push(origin);
  }
  return result;
}

/**
 * 冷却判定：`lastAt` 之后 `cooldownMs` 内视为冷却中。
 * - `lastAt <= 0`（从未发生）不算冷却；
 * - 时钟回拨（now < lastAt）按冷却中处理，避免异常时间戳导致反复切换。
 */
export function cooldownActive(now: number, lastAt: number, cooldownMs: number): boolean {
  if (lastAt <= 0 || cooldownMs <= 0) {
    return false;
  }
  return now - lastAt < cooldownMs;
}

/**
 * 计算本次失败请求可尝试的候选 origin 列表（纯函数，全部状态由参数注入，便于单测）。
 *
 * 规则：
 * 1. 失败冷却中（一轮候选刚全部失败）→ []，不再发起候选轮询；
 * 2. 失败 URL 与当前站点都不是 BASE_URL_OPTIONS 里的站点（外部 URL，如 CDN / 第三方接口）
 *    且与当前站点也不同 → []，避免把外部地址硬改写到站点域名；
 * 3. 当前 baseUrl 的 origin 与失败 URL 的 origin 不同（并发请求已切换 / 用户手动切换）→
 *    只返回当前 origin：用当前站点重试一次，复用别人的切换结果，不连锁切到第三个站点；
 * 4. 切换冷却中（刚自动切换成功 60s 内）→ []，避免刚切换就被另一个请求又切走；
 * 5. 否则按 BASE_URL_OPTIONS 从失败站点之后开始轮询（不含失败站点）。
 */
export function resolveFailoverCandidates(
  options: string[],
  failedUrl: string,
  currentBaseUrl: string,
  now: number,
  lastSwitchAt: number,
  lastFailureAt: number,
  switchCooldownMs: number,
  failureCooldownMs: number
): string[] {
  if (cooldownActive(now, lastFailureAt, failureCooldownMs)) {
    return [];
  }
  const failedOrigin: string = candidateOriginOf(failedUrl);
  const currentOrigin: string = candidateOriginOf(currentBaseUrl);
  const knownOrigins: string[] = optionOrigins(options);
  const failedIsKnown: boolean = containsOrigin(knownOrigins, failedOrigin);
  if (failedOrigin.length > 0 && !failedIsKnown && failedOrigin !== currentOrigin) {
    return [];
  }
  if (failedOrigin.length > 0 && currentOrigin.length > 0 && failedOrigin !== currentOrigin) {
    return [currentOrigin];
  }
  if (cooldownActive(now, lastSwitchAt, switchCooldownMs)) {
    return [];
  }
  return candidateOriginsAfter(options, failedOrigin);
}

/** 是否命中 Cloudflare 特征（响应头 cf-mitigated 或响应体特征串） */
export function hasCloudflareSignature(headers: Record<string, string>, body: string): boolean {
  const mitigated: string = headers['cf-mitigated'];
  if (typeof mitigated === 'string' && mitigated.toLowerCase().indexOf('challenge') >= 0) {
    return true;
  }
  const text: string = lowerBody(body);
  for (let i = 0; i < CLOUDFLARE_BODY_MARKERS.length; i++) {
    if (text.indexOf(CLOUDFLARE_BODY_MARKERS[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/**
 * 非 2xx 响应是否值得换站重试：
 * - 401/404/419/3xx 登录跳转：false（换站解决不了）；
 * - 403/429/500/502/503/504：true；
 * - 任意状态码只要带 Cloudflare 特征：true（含 Cloudflare 返回 200 验证页的情况）。
 */
export function shouldFailoverResponse(
  code: number,
  body: string,
  headers: Record<string, string>
): boolean {
  if (isNonFailoverStatus(code)) {
    return false;
  }
  if (hasCloudflareSignature(headers, body)) {
    return true;
  }
  return isFailoverStatus(code);
}

/**
 * 自动切换成功后的 Toast 文案。
 * 登录态时追加「如登录失效请重新登录」——CookieStore 按 host 隔离，旧 host 的会话 cookie
 * 不会带到新站点，服务端会话通常需要重新登录。
 */
export function buildSiteSwitchToast(host: string, loggedIn: boolean): string {
  const message: string = '已自动切换到备用站点：' + host;
  if (loggedIn) {
    return message + '（如登录失效请重新登录）';
  }
  return message;
}
