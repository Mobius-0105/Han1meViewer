/**
 * Cookie 头解析与构造（纯 TypeScript，可在 Node 中直接测试）。
 *
 * 站点（Laravel + Cloudflare）会下发 `hanime1_session`、`XSRF-TOKEN`、`cf_clearance`
 * 等多种 cookie。其中 Set-Cookie 可能带 `Expires=Wed, 21 Oct 2015 07:28:00 GMT`
 * 这种含逗号的日期，因此不能简单地用 `split(',')` 去拆分多个 Set-Cookie；
 * 本文件按 RFC 6265 处理单个 Set-Cookie 串，由调用方负责多值拆分。
 *
 * 注意：本文件属于 core/**，禁止 import 任何 @ohos.* / @kit.*。
 */

/** 一条已解析的 cookie（足够站点使用；不保存 Secure/HttpOnly 等属性） */
export interface ParsedSetCookie {
  name: string;
  value: string;
  /** 规范化为小写、去掉前导点的主机名；空串表示"手动导入，对所有主机发送" */
  domain: string;
  /** 生效路径，默认 '/' */
  path: string;
  /** 过期时间（毫秒时间戳），0 表示 session cookie（关掉应用即失效） */
  expiresAt: number;
}

const DEFAULT_PATH: string = '/';
const HTTP_ONLY_PREFIX: string = '#HttpOnly_';

/** 规范化主机名：小写、去掉首尾的点 */
function normalizeDomain(domain: string): string {
  let value: string = domain.trim().toLowerCase();
  while (value.startsWith('.')) {
    value = value.substring(1);
  }
  while (value.endsWith('.')) {
    value = value.substring(0, value.length - 1);
  }
  return value;
}

/** 去掉 cookie 值两端成对的双引号 */
function stripQuotes(value: string): string {
  if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
    return value.substring(1, value.length - 1);
  }
  return value;
}

/**
 * 解析单个 Set-Cookie 串。
 *
 * 例：`sid=abc; Domain=.hanime1.me; Path=/; Expires=Wed, 21 Oct 2035 07:28:00 GMT; HttpOnly`
 *
 * @param headerValue 单个 Set-Cookie 头的值（不要传多个头拼起来的串）
 * @param requestHost 发起请求的主机名，作为缺省 Domain
 * @returns 解析失败（没有 name=value）返回 null
 */
export function parseSetCookie(headerValue: string, requestHost: string): ParsedSetCookie | null {
  const raw: string = headerValue.trim();
  if (raw.length === 0) {
    return null;
  }
  // 只按 ';' 拆属性：Expires 里的逗号不会出现在分号边界上，因此是安全的
  const segments: string[] = raw.split(';');
  const pair: string = segments[0].trim();
  const equalsIndex: number = pair.indexOf('=');
  if (equalsIndex <= 0) {
    return null;
  }
  const name: string = pair.substring(0, equalsIndex).trim();
  if (name.length === 0) {
    return null;
  }
  const value: string = stripQuotes(pair.substring(equalsIndex + 1).trim());

  let domain: string = normalizeDomain(requestHost);
  let path: string = DEFAULT_PATH;
  let expiresAt: number = 0;
  // Max-Age 与 Expires 同时存在时 Max-Age 优先（RFC 6265 5.3）
  let hasMaxAge: boolean = false;
  let maxAgeSeconds: number = 0;
  const parsedAt: number = Date.now();

  for (let i = 1; i < segments.length; i++) {
    const attribute: string = segments[i].trim();
    if (attribute.length === 0) {
      continue;
    }
    const attrEquals: number = attribute.indexOf('=');
    const attrName: string = (attrEquals >= 0 ? attribute.substring(0, attrEquals) : attribute)
      .trim().toLowerCase();
    const attrValue: string = attrEquals >= 0 ? attribute.substring(attrEquals + 1).trim() : '';

    if (attrName === 'domain') {
      const candidate: string = normalizeDomain(attrValue);
      if (candidate.length > 0) {
        domain = candidate;
      }
    } else if (attrName === 'path') {
      // 不合法（不以 / 开头）时忽略，保留缺省 '/'
      if (attrValue.startsWith('/')) {
        path = attrValue;
      }
    } else if (attrName === 'max-age') {
      const seconds: number = parseInt(attrValue, 10);
      if (!isNaN(seconds)) {
        hasMaxAge = true;
        maxAgeSeconds = seconds;
      }
    } else if (attrName === 'expires') {
      const timestamp: number = Date.parse(attrValue);
      if (!isNaN(timestamp)) {
        expiresAt = timestamp;
      }
    }
  }

  if (hasMaxAge) {
    // Max-Age<=0 立即失效；用一个已过去的正数表示（0 在本模块里表示 session cookie）
    expiresAt = maxAgeSeconds <= 0 ? 1 : parsedAt + maxAgeSeconds * 1000;
  }

  return {
    name: name,
    value: value,
    domain: domain,
    path: path,
    expiresAt: expiresAt
  };
}

/**
 * 解析手动粘贴/整串保存的 cookie。形如 `a=1; b=2`。
 * 返回的 domain / path 均为空（表示对任意站点都发送，等价 Android 的 CookieString）。
 */
export function parseCookieString(raw: string): ParsedSetCookie[] {
  const result: ParsedSetCookie[] = [];
  const text: string = raw.trim();
  if (text.length === 0) {
    return result;
  }
  const segments: string[] = text.split(';');
  for (let i = 0; i < segments.length; i++) {
    const segment: string = segments[i].trim();
    if (segment.length === 0) {
      continue;
    }
    const equalsIndex: number = segment.indexOf('=');
    if (equalsIndex <= 0) {
      continue;
    }
    const name: string = segment.substring(0, equalsIndex).trim();
    if (name.length === 0) {
      continue;
    }
    const value: string = stripQuotes(segment.substring(equalsIndex + 1).trim());
    result.push({
      name: name,
      value: value,
      domain: '',
      path: '',
      expiresAt: 0
    });
  }
  return result;
}

/** 主机名匹配：domain 为空表示任意主机都匹配 */
function domainMatches(host: string, domain: string): boolean {
  const target: string = normalizeDomain(domain);
  if (target.length === 0) {
    return true;
  }
  if (host.length === 0) {
    return false;
  }
  if (host === target) {
    return true;
  }
  return host.endsWith('.' + target);
}

/** 路径匹配（RFC 6265 5.1.4） */
function pathMatches(requestPath: string, cookiePath: string): boolean {
  if (cookiePath.length === 0) {
    return true;
  }
  if (requestPath === cookiePath) {
    return true;
  }
  if (!cookiePath.startsWith('/')) {
    return true;
  }
  if (!requestPath.startsWith(cookiePath)) {
    return false;
  }
  if (cookiePath.endsWith('/')) {
    return true;
  }
  return requestPath.charAt(cookiePath.length) === '/';
}

/**
 * 构造 Cookie 请求头值。
 *
 * - 过滤已过期（expiresAt > 0 且 <= now）的 cookie；
 * - 按 host / path 过滤；
 * - 同名 cookie 后者覆盖前者（RFC 6265 中同请求头出现多个同名时右侧优先）。
 *
 * @returns 形如 `a=1; b=2`，无可用 cookie 时返回 ''
 */
export function buildCookieHeader(
  cookies: ParsedSetCookie[],
  host: string,
  path: string,
  now: number
): string {
  const requestHost: string = normalizeDomain(host);
  const requestPath: string = path.length > 0 ? path : DEFAULT_PATH;
  const names: string[] = [];
  const values: string[] = [];

  for (let i = 0; i < cookies.length; i++) {
    const cookie: ParsedSetCookie = cookies[i];
    if (cookie.expiresAt > 0 && cookie.expiresAt <= now) {
      continue;
    }
    if (!domainMatches(requestHost, cookie.domain)) {
      continue;
    }
    if (!pathMatches(requestPath, cookie.path)) {
      continue;
    }
    const existingIndex: number = names.indexOf(cookie.name);
    if (existingIndex >= 0) {
      // 同名覆盖：保留首次出现的位置，值取最新一条
      values[existingIndex] = cookie.value;
    } else {
      names.push(cookie.name);
      values.push(cookie.value);
    }
  }

  const parts: string[] = [];
  for (let i = 0; i < names.length; i++) {
    parts.push(names[i] + '=' + values[i]);
  }
  return parts.join('; ');
}

/** 序列化为 JSON（CookieStore 持久化用） */
export function serializeCookies(cookies: ParsedSetCookie[]): string {
  return JSON.stringify(cookies);
}

/** 反序列化；坏数据一律丢弃，绝不抛异常（持久化文件可能被用户/旧版本破坏） */
export function deserializeCookies(json: string): ParsedSetCookie[] {
  const result: ParsedSetCookie[] = [];
  if (json.trim().length === 0) {
    return result;
  }
  let parsed: ParsedSetCookie[];
  try {
    parsed = JSON.parse(json) as ParsedSetCookie[];
  } catch (error) {
    return result;
  }
  if (!Array.isArray(parsed)) {
    return result;
  }
  for (let i = 0; i < parsed.length; i++) {
    const item: ParsedSetCookie = parsed[i];
    if (item === null || item === undefined) {
      continue;
    }
    const name: string = typeof item.name === 'string' ? item.name : '';
    if (name.length === 0) {
      continue;
    }
    result.push({
      name: name,
      value: typeof item.value === 'string' ? item.value : '',
      domain: normalizeDomain(typeof item.domain === 'string' ? item.domain : ''),
      path: typeof item.path === 'string' ? item.path : DEFAULT_PATH,
      expiresAt: typeof item.expiresAt === 'number' ? item.expiresAt : 0
    });
  }
  return result;
}

/** 从 URL 中取出小写主机名（去掉端口与 userinfo）；无法解析返回 '' */
export function hostOfUrl(url: string): string {
  const match: RegExpMatchArray | null = url.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/([^\/?#]+)/);
  if (match === null) {
    return '';
  }
  let host: string = match[1];
  const atIndex: number = host.lastIndexOf('@');
  if (atIndex >= 0) {
    host = host.substring(atIndex + 1);
  }
  if (host.startsWith('[')) {
    // IPv6 字面量，保留方括号（用作 Map key / 匹配时保持原样即可）
    const endIndex: number = host.indexOf(']');
    return endIndex >= 0 ? host.substring(0, endIndex + 1).toLowerCase() : host.toLowerCase();
  }
  const colonIndex: number = host.indexOf(':');
  if (colonIndex >= 0) {
    host = host.substring(0, colonIndex);
  }
  return normalizeDomain(host);
}

/** 从 URL 中取出路径部分（不含 query / hash）；无路径返回 '/' */
export function pathOfUrl(url: string): string {
  const match: RegExpMatchArray | null = url.match(/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\/?#]+/);
  const rest: string = match === null ? url : url.substring(match[0].length);
  if (!rest.startsWith('/')) {
    return DEFAULT_PATH;
  }
  const endIndex: number = rest.search(/[?#]/);
  return endIndex >= 0 ? rest.substring(0, endIndex) : rest;
}

/**
 * 解析 `@ohos.net.http` 的 `HttpResponse.cookies` 原始字符串。
 *
 * 该字段返回的是 curl/Netscape 风格的 cookie 列表：一行一条，7 个 tab 字段
 *   domain  includeSubdomains  path  secure  expiresEpochSeconds  name  value
 * 例如：
 *   `www.hanime1.me\tFALSE\t/\tFALSE\t1706255412\thanime1_session\txxxx`
 *   `#HttpOnly_www.hanime1.me\tFALSE\t/\tTRUE\t0\tcf_clearance\txxxx`
 *
 * 同时兼容 `a=1; b=2` 这种简单格式（此时 domain 取请求主机）。
 * 注意：不要指望 HttpRespone.header 里的 set-cookie —— 多个 Set-Cookie 时
 * 原生实现只会保留一条，response.cookies 才是完整的。
 */
export function parseResponseCookies(raw: string, requestHost: string): ParsedSetCookie[] {
  const result: ParsedSetCookie[] = [];
  const text: string = raw.trim();
  if (text.length === 0) {
    return result;
  }
  const lines: string[] = text.split(/\r\n|\n|\r/);
  let matchedList: boolean = false;

  for (let i = 0; i < lines.length; i++) {
    const line: string = lines[i];
    if (line.indexOf('\t') < 0) {
      continue;
    }
    const fields: string[] = line.split('\t');
    if (fields.length < 7) {
      continue;
    }
    matchedList = true;
    let domain: string = fields[0].trim();
    if (domain.startsWith(HTTP_ONLY_PREFIX)) {
      domain = domain.substring(HTTP_ONLY_PREFIX.length);
    }
    domain = normalizeDomain(domain);
    let path: string = fields[2].trim();
    if (!path.startsWith('/')) {
      path = DEFAULT_PATH;
    }
    const expiresSeconds: number = parseInt(fields[4].trim(), 10);
    const expiresAt: number = isNaN(expiresSeconds) || expiresSeconds <= 0 ? 0 : expiresSeconds * 1000;
    const name: string = fields[5].trim();
    if (name.length === 0) {
      continue;
    }
    const value: string = fields.length > 7 ? fields.slice(6).join('\t') : fields[6];
    result.push({
      name: name,
      value: value,
      domain: domain.length > 0 ? domain : normalizeDomain(requestHost),
      path: path,
      expiresAt: expiresAt
    });
  }
  if (matchedList) {
    return result;
  }

  // 兼容多行 Set-Cookie（每行一条完整 Set-Cookie，带属性）
  if (lines.length > 1) {
    for (let i = 0; i < lines.length; i++) {
      const parsedLine: ParsedSetCookie | null = parseSetCookie(lines[i], requestHost);
      if (parsedLine !== null) {
        result.push(parsedLine);
      }
    }
    if (result.length > 0) {
      return result;
    }
  }

  // 最后回退到 `a=1; b=2`
  const simple: ParsedSetCookie[] = parseCookieString(text);
  const host: string = normalizeDomain(requestHost);
  for (let i = 0; i < simple.length; i++) {
    simple[i].domain = host;
    simple[i].path = DEFAULT_PATH;
  }
  return simple;
}
