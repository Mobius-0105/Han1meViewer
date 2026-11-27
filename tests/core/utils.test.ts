/**
 * core/util 纯函数单测（URL 构造 / 格式化 / 常量），不依赖任何系统 API。
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
  toVideoCode,
  buildSearchUrl,
  buildWatchUrl,
  buildCommentsUrl,
  buildRepliesUrl,
  normalizeBaseUrl,
  resolveUrl,
  replaceBackupMediaCdn
} from '../../entry/src/main/ets/core/util/Urls';
import {
  durationTextToMs,
  formatMs,
  formatDate,
  formatRelativeTime,
  parseViewsText,
  truncate,
  normalizeWhitespace
} from '../../entry/src/main/ets/core/util/Format';
import { SearchRequest } from '../../entry/src/main/ets/core/model/Models';

function emptySearchRequest(): SearchRequest {
  const req: SearchRequest = {
    page: 1,
    query: '',
    genre: '',
    sort: '',
    broad: false,
    date: '',
    duration: '',
    tags: [],
    brands: []
  };
  return req;
}

test('toVideoCode：支持绝对/相对/带查询参数', () => {
  assert.equal(toVideoCode('/watch?v=409266'), '409266');
  assert.equal(toVideoCode('https://hanime1.me/watch?v=123&x=1'), '123');
  assert.equal(toVideoCode('/watch/456'), '456');
  assert.equal(toVideoCode('/search?query=abc'), '');
  assert.equal(toVideoCode(''), '');
});

test('normalizeBaseUrl：补 scheme 与结尾斜杠', () => {
  assert.equal(normalizeBaseUrl('hanime1.me'), 'https://hanime1.me/');
  assert.equal(normalizeBaseUrl('https://hanime1.com'), 'https://hanime1.com/');
  assert.equal(normalizeBaseUrl(''), 'https://hanime1.me/');
  assert.equal(normalizeBaseUrl('https://a.com/x/'), 'https://a.com/x/');
});

test('resolveUrl：Jsoup absUrl 等价行为', () => {
  assert.equal(resolveUrl('https://hanime1.me/watch?v=1', '/search?q=1'), 'https://hanime1.me/search?q=1');
  assert.equal(resolveUrl('https://hanime1.me/', '//cdn.example.com/a.png'), 'https://cdn.example.com/a.png');
  assert.equal(resolveUrl('https://hanime1.me/watch?v=1', 'https://cdn.x/a.png'), 'https://cdn.x/a.png');
  assert.equal(resolveUrl('https://hanime1.me/a/b/c', '../img/x.png'), 'https://hanime1.me/a/img/x.png');
  assert.equal(resolveUrl('https://hanime1.me/', 'img/x.png'), 'https://hanime1.me/img/x.png');
  assert.equal(resolveUrl('https://hanime1.me/', ''), '');
});

test('buildSearchUrl：完整参数 vs 默认参数', () => {
  const req: SearchRequest = emptySearchRequest();
  assert.equal(buildSearchUrl('https://hanime1.me/', req), 'https://hanime1.me/search?page=1');

  req.page = 2;
  req.query = '中文 词';
  req.genre = '裏番';
  req.sort = '最新上傳';
  req.broad = true;
  req.date = '過去 24 小時';
  req.duration = '10 分鐘 +';
  req.tags = ['無碼', '中文字幕'];
  req.brands = ['PoRO'];

  const url: string = buildSearchUrl('https://hanime1.me/', req);
  assert.ok(url.startsWith('https://hanime1.me/search?page=2'));
  assert.ok(url.includes('query=%E4%B8%AD%E6%96%87%20%E8%AF%8D'));
  assert.ok(url.includes('genre=%E8%A3%8F%E7%95%AA'));
  assert.ok(url.includes('broad=on'));
  assert.ok(url.includes('tags%5B%5D=%E7%84%A1%E7%A2%BC'));
  assert.ok(url.includes('brands%5B%5D=PoRO'));
});

test('buildWatchUrl / buildCommentsUrl / buildRepliesUrl', () => {
  assert.equal(buildWatchUrl('https://hanime1.me/', '42'), 'https://hanime1.me/watch?v=42');
  assert.equal(
    buildCommentsUrl('https://hanime1.me/', 'video', '42', -1),
    'https://hanime1.me/loadComment?type=video&id=42'
  );
  assert.ok(buildCommentsUrl('https://hanime1.me/', 'video', '42', 100).endsWith('&offset=100'));
  assert.equal(buildRepliesUrl('https://hanime1.me/', 'abc'), 'https://hanime1.me/loadReplies?id=abc');
});

test('replaceBackupMediaCdn：开关行为', () => {
  const url: string = 'https://vdownload.hembed.com/a.mp4';
  assert.equal(replaceBackupMediaCdn(url, false), url);
  assert.equal(replaceBackupMediaCdn(url, true), 'https://1497203185.rsc.cdn77.org/a.mp4');
  assert.equal(replaceBackupMediaCdn('', true), '');
});

test('durationTextToMs / formatMs 往返', () => {
  assert.equal(durationTextToMs('12:34'), 754000);
  assert.equal(durationTextToMs('1:02:03'), 3723000);
  assert.equal(durationTextToMs('abc'), 0);
  assert.equal(durationTextToMs('12'), 0);
  assert.equal(formatMs(754000), '12:34');
  assert.equal(formatMs(3723000), '1:02:03');
  assert.equal(formatMs(0), '00:00');
  assert.equal(formatMs(-1), '00:00');
});

test('formatDate / formatRelativeTime', () => {
  const ts: number = new Date(2026, 0, 5, 12, 0, 0).getTime();
  assert.equal(formatDate(ts), '2026-01-05');
  assert.equal(formatRelativeTime(ts, ts + 10 * 1000), '刚刚');
  assert.equal(formatRelativeTime(ts, ts + 5 * 60 * 1000), '5 分钟前');
  assert.equal(formatRelativeTime(ts, ts + 3 * 3600 * 1000), '3 小时前');
  assert.equal(formatRelativeTime(ts, ts + 3 * 24 * 3600 * 1000), '3 天前');
  assert.equal(formatRelativeTime(ts, ts + 30 * 24 * 3600 * 1000), '2026-01-05');
});

test('parseViewsText：常见观看数文本', () => {
  assert.equal(parseViewsText('1234次'), 1234);
  assert.equal(parseViewsText('1.2万次'), 12000);
  assert.equal(parseViewsText('3萬'), 30000);
  assert.equal(parseViewsText('1.5w'), 15000);
  assert.equal(parseViewsText(''), -1);
  assert.equal(parseViewsText('暂无'), -1);
});

test('normalizeWhitespace / truncate', () => {
  assert.equal(normalizeWhitespace('  a   b\n c '), 'a b c');
  assert.equal(truncate('abcdef', 3), 'abc…');
  assert.equal(truncate('abc', 3), 'abc');
});
