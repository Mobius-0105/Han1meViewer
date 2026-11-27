/**
 * URL 构造与工具。对应 Android 侧的 Parser 中 `toVideoCode`、
 * `absUrl` 以及各 Service 的 @GET/@Query 拼装。
 */

import { SearchRequest } from '../model/Models';
import { BACKUP_MEDIA_CDN_HOST, MEDIA_CDN_HOST } from './Constants';

/** 把相对地址解析成绝对地址；无法解析时返回空串（与 Jsoup.absUrl 行为一致） */
export function resolveUrl(baseUrl: string, relative: string): string {
  const rel: string = relative.trim();
  if (rel.length === 0) {
    return '';
  }
  if (rel.startsWith('//')) {
    const scheme: string = baseUrl.startsWith('https://') ? 'https:' : 'http:';
    return scheme + rel;
  }
  if (rel.startsWith('http://') || rel.startsWith('https://')) {
    return rel;
  }
  const origin: string = originOf(baseUrl);
  if (rel.startsWith('/')) {
    return origin + rel;
  }
  if (rel.startsWith('?') || rel.startsWith('#')) {
    return baseUrl.split('#')[0].split('?')[0] + rel;
  }
  const path: string = baseUrl.split('#')[0].split('?')[0];
  const slash: number = path.lastIndexOf('/');
  const dir: string = slash >= 0 ? path.substring(0, slash + 1) : origin + '/';
  return normalizePath(dir + rel);
}

function originOf(url: string): string {
  const match: RegExpMatchArray | null = url.match(/^(https?:\/\/[^\/]+)/);
  return match !== null ? match[1] : 'https://hanime1.me';
}

/** 展开 `/a/../b` 之类的路径（保留 query 与 hash） */
function normalizePath(url: string): string {
  const schemeMatch: RegExpMatchArray | null = url.match(/^(https?:\/\/[^\/]+)(.*)$/);
  if (schemeMatch === null) {
    return url;
  }
  const prefix: string = schemeMatch[1];
  const rest: string = schemeMatch[2];
  const hashIndex: number = rest.indexOf('#');
  const beforeHash: string = hashIndex >= 0 ? rest.substring(0, hashIndex) : rest;
  const hash: string = hashIndex >= 0 ? rest.substring(hashIndex) : '';
  const qIndex: number = beforeHash.indexOf('?');
  const pathPart: string = qIndex >= 0 ? beforeHash.substring(0, qIndex) : beforeHash;
  const query: string = qIndex >= 0 ? beforeHash.substring(qIndex) : '';
  const leadingSlash: boolean = pathPart.startsWith('/');
  const segments: string[] = pathPart.split('/');
  const stack: string[] = [];
  for (let i = 0; i < segments.length; i++) {
    const seg: string = segments[i];
    if (seg.length === 0 || seg === '.') {
      continue;
    }
    if (seg === '..') {
      if (stack.length > 0) {
        stack.pop();
      }
      continue;
    }
    stack.push(seg);
  }
  const joined: string = stack.join('/');
  return prefix + (leadingSlash ? '/' : '') + joined + query + hash;
}

/** 从任意 URL / href 中提取 videoCode（数字） */
export function toVideoCode(url: string): string {
  const match: RegExpMatchArray | null = url.match(/[?&]v=(\d+)/);
  if (match !== null) {
    return match[1];
  }
  const match2: RegExpMatchArray | null = url.match(/\/watch\/(\d+)/);
  if (match2 !== null) {
    return match2[1];
  }
  return '';
}

/** 规范化 base URL（保证以 / 结尾） */
export function normalizeBaseUrl(url: string): string {
  let value: string = url.trim();
  if (value.length === 0) {
    return 'https://hanime1.me/';
  }
  if (!value.startsWith('http://') && !value.startsWith('https://')) {
    value = 'https://' + value;
  }
  if (!value.endsWith('/')) {
    value = value + '/';
  }
  return value;
}

/** 站点 `/search` 请求地址 */
export function buildSearchUrl(baseUrl: string, req: SearchRequest): string {
  const params: string[] = [];
  params.push(`page=${req.page}`);
  if (req.query.length > 0) {
    params.push('query=' + encodeURIComponent(req.query));
  }
  if (req.genre.length > 0) {
    params.push('genre=' + encodeURIComponent(req.genre));
  }
  if (req.sort.length > 0) {
    params.push('sort=' + encodeURIComponent(req.sort));
  }
  if (req.broad) {
    params.push('broad=on');
  }
  if (req.date.length > 0) {
    params.push('date=' + encodeURIComponent(req.date));
  }
  if (req.duration.length > 0) {
    params.push('duration=' + encodeURIComponent(req.duration));
  }
  for (let i = 0; i < req.tags.length; i++) {
    params.push('tags%5B%5D=' + encodeURIComponent(req.tags[i]));
  }
  for (let i = 0; i < req.brands.length; i++) {
    params.push('brands%5B%5D=' + encodeURIComponent(req.brands[i]));
  }
  return normalizeBaseUrl(baseUrl) + 'search?' + params.join('&');
}

/** `/watch?v=code` */
export function buildWatchUrl(baseUrl: string, videoCode: string): string {
  return normalizeBaseUrl(baseUrl) + 'watch?v=' + encodeURIComponent(videoCode);
}

/** `/loadComment?type=video&id=code[&offset=n]` */
export function buildCommentsUrl(baseUrl: string, type: string, id: string, offset: number): string {
  let url: string = normalizeBaseUrl(baseUrl) + 'loadComment?type=' + encodeURIComponent(type) +
    '&id=' + encodeURIComponent(id);
  if (offset >= 0) {
    url += '&offset=' + offset;
  }
  return url;
}

/** `/loadReplies?id=commentId` */
export function buildRepliesUrl(baseUrl: string, commentId: string): string {
  return normalizeBaseUrl(baseUrl) + 'loadReplies?id=' + encodeURIComponent(commentId);
}

/** 开启备用媒体 CDN 时替换响应中的媒体主机 */
export function replaceBackupMediaCdn(url: string, enabled: boolean): string {
  if (!enabled || url.length === 0) {
    return url;
  }
  return url.split(MEDIA_CDN_HOST).join(BACKUP_MEDIA_CDN_HOST);
}

/** 站点 user 主页地址 */
export function buildUserListUrl(baseUrl: string, userId: string, type: string, page: number): string {
  return normalizeBaseUrl(baseUrl) + 'user/' + encodeURIComponent(userId) + '/' +
    encodeURIComponent(type) + '?page=' + page;
}

export function buildUserHistoryUrl(baseUrl: string, userId: string, sort: string, page: number): string {
  return normalizeBaseUrl(baseUrl) + 'user/' + encodeURIComponent(userId) +
    '/histories?sort=' + encodeURIComponent(sort) + '&page=' + page;
}

export function buildUserAccountUrl(baseUrl: string, userId: string): string {
  return normalizeBaseUrl(baseUrl) + 'user/' + encodeURIComponent(userId) + '/edit';
}

export function buildPlaylistsUrl(baseUrl: string, userId: string, page: number): string {
  return normalizeBaseUrl(baseUrl) + 'user/' + encodeURIComponent(userId) +
    '/playlists?page=' + page;
}

export function buildPlaylistUrl(baseUrl: string, listCode: string, page: number): string {
  return normalizeBaseUrl(baseUrl) + 'playlist?list=' + encodeURIComponent(listCode) +
    '&page=' + page;
}
