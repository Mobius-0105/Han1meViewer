/**
 * CookieHeader（纯逻辑）单元测试。
 * 运行：npx tsx --test tests/net
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  parseSetCookie,
  parseCookieString,
  buildCookieHeader,
  serializeCookies,
  deserializeCookies,
  parseResponseCookies,
  hostOfUrl,
  pathOfUrl
} from '../../entry/src/main/ets/core/util/CookieHeader';
import type { ParsedSetCookie } from '../../entry/src/main/ets/core/util/CookieHeader';

/** 断言 parseSetCookie 非空并收窄类型 */
function mustParse(headerValue: string, requestHost: string): ParsedSetCookie {
  const result: ParsedSetCookie | null = parseSetCookie(headerValue, requestHost);
  assert.notEqual(result, null);
  return result as ParsedSetCookie;
}

test('parseSetCookie: 基本字段与缺省值', () => {
  const cookie: ParsedSetCookie = mustParse('hanime1_session=abc123; Path=/; Domain=.hanime1.me; HttpOnly', 'hanime1.me');
  assert.equal(cookie.name, 'hanime1_session');
  assert.equal(cookie.value, 'abc123');
  assert.equal(cookie.domain, 'hanime1.me'); // 前导点被规范化掉
  assert.equal(cookie.path, '/');
  assert.equal(cookie.expiresAt, 0); // session cookie

  const defaults: ParsedSetCookie = mustParse('a=1', 'www.hanime1.me');
  assert.equal(defaults.domain, 'www.hanime1.me');
  assert.equal(defaults.path, '/');
  assert.equal(defaults.expiresAt, 0);
});

test('parseSetCookie: Expires 里的逗号不会被当成分隔符', () => {
  const cookie: ParsedSetCookie = mustParse(
    'sid=abc; Path=/watch; Expires=Wed, 21 Oct 2035 07:28:00 GMT; Secure',
    'hanime1.me'
  );
  assert.equal(cookie.name, 'sid');
  assert.equal(cookie.value, 'abc'); // 没有被逗号截断
  assert.equal(cookie.path, '/watch');
  assert.equal(cookie.expiresAt, Date.parse('Wed, 21 Oct 2035 07:28:00 GMT'));
});

test('parseSetCookie: 引号包裹的值、等号与空值', () => {
  const quoted: ParsedSetCookie = mustParse('token="a=b c"', 'hanime1.me');
  assert.equal(quoted.name, 'token');
  assert.equal(quoted.value, 'a=b c');

  const empty: ParsedSetCookie = mustParse('empty=', 'hanime1.me');
  assert.equal(empty.value, '');

  assert.equal(parseSetCookie('', 'hanime1.me'), null);
  assert.equal(parseSetCookie('no-equals-sign', 'hanime1.me'), null);
  assert.equal(parseSetCookie('=novalue', 'hanime1.me'), null);
});

test('多 Set-Cookie 合并为 Cookie 头（保持下发顺序）', () => {
  const cookies: ParsedSetCookie[] = [
    mustParse('hanime1_session=abc; Path=/; Domain=.hanime1.me', 'hanime1.me'),
    mustParse('cf_clearance=xyz; Path=/; Domain=.hanime1.me; Max-Age=86400', 'hanime1.me'),
    mustParse('XSRF-TOKEN=tok%3D; Path=/', 'hanime1.me')
  ];
  assert.equal(
    buildCookieHeader(cookies, 'hanime1.me', '/watch?v=100', Date.now()),
    'hanime1_session=abc; cf_clearance=xyz; XSRF-TOKEN=tok%3D'
  );
});

test('过期剔除：Expires 过去 / Max-Age=0 / Max-Age 正数', () => {
  const past: ParsedSetCookie = mustParse(
    'old=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT',
    'hanime1.me'
  );
  assert.ok(past.expiresAt > 0 && past.expiresAt < Date.now());
  assert.equal(buildCookieHeader([past], 'hanime1.me', '/', Date.now()), '');

  const deleted: ParsedSetCookie = mustParse('gone=1; Max-Age=0', 'hanime1.me');
  assert.ok(deleted.expiresAt > 0 && deleted.expiresAt <= Date.now());
  assert.equal(buildCookieHeader([deleted], 'hanime1.me', '/', Date.now()), '');

  const alive: ParsedSetCookie = mustParse('alive=1; Max-Age=3600', 'hanime1.me');
  assert.ok(alive.expiresAt > Date.now());
  assert.equal(buildCookieHeader([alive], 'hanime1.me', '/', Date.now()), 'alive=1');

  // Max-Age 优先于 Expires
  const both: ParsedSetCookie = mustParse(
    'both=1; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Max-Age=3600',
    'hanime1.me'
  );
  assert.equal(buildCookieHeader([both], 'hanime1.me', '/', Date.now()), 'both=1');
});

test('host 匹配：域名后缀匹配，不匹配无关域名', () => {
  const domainCookie: ParsedSetCookie = mustParse('a=1; Domain=.example.com', 'example.com');
  assert.equal(buildCookieHeader([domainCookie], 'example.com', '/', 0), 'a=1');
  assert.equal(buildCookieHeader([domainCookie], 'sub.example.com', '/', 0), 'a=1');
  assert.equal(buildCookieHeader([domainCookie], 'notexample.com', '/', 0), '');
  assert.equal(buildCookieHeader([domainCookie], 'example.com.cn', '/', 0), '');

  // 没写 Domain 时绑定请求主机
  const hostOnly: ParsedSetCookie = mustParse('b=2', 'hanime1.me');
  assert.equal(buildCookieHeader([hostOnly], 'hanime1.me', '/', 0), 'b=2');
  assert.equal(buildCookieHeader([hostOnly], 'hanime1.com', '/', 0), '');

  // 手动导入的整串 cookie（domain 为空）对所有主机发送
  const manual: ParsedSetCookie[] = parseCookieString('hanime1_session=manual; XSRF-TOKEN=t');
  assert.equal(
    buildCookieHeader(manual, 'hanime1.com', '/watch', 0),
    'hanime1_session=manual; XSRF-TOKEN=t'
  );
});

test('path 匹配：默认 / 处处发送，具体路径按前缀匹配', () => {
  const root: ParsedSetCookie = mustParse('r=1', 'hanime1.me');
  const watch: ParsedSetCookie = mustParse('w=1; Path=/watch', 'hanime1.me');
  assert.equal(buildCookieHeader([root, watch], 'hanime1.me', '/search', 0), 'r=1');
  assert.equal(buildCookieHeader([root, watch], 'hanime1.me', '/watch', 0), 'r=1; w=1');
  assert.equal(buildCookieHeader([root, watch], 'hanime1.me', '/watch/100', 0), 'r=1; w=1');
  assert.equal(buildCookieHeader([root, watch], 'hanime1.me', '/watchlist', 0), 'r=1');
});

test('同名覆盖：后下发的值胜出且只出现一次', () => {
  const first: ParsedSetCookie = mustParse('dup=old; Path=/', 'hanime1.me');
  const second: ParsedSetCookie = mustParse('dup=new; Path=/', 'hanime1.me');
  const header: string = buildCookieHeader([first, second], 'hanime1.me', '/', 0);
  assert.equal(header, 'dup=new');
  assert.equal(header.split('dup=').length, 2); // 只出现一次

  // 其他 cookie 顺序不受影响
  const other: ParsedSetCookie = mustParse('keep=1', 'hanime1.me');
  assert.equal(buildCookieHeader([first, other, second], 'hanime1.me', '/', 0), 'dup=new; keep=1');
});

test('parseCookieString: 登录时整串保存的 cookie', () => {
  const cookies: ParsedSetCookie[] = parseCookieString(
    'hanime1_session=abc; XSRF-TOKEN=eyJpdiI6Ijx4%3D; remember_web=xyz=='
  );
  assert.equal(cookies.length, 3);
  assert.equal(cookies[0].name, 'hanime1_session');
  assert.equal(cookies[0].value, 'abc');
  assert.equal(cookies[1].name, 'XSRF-TOKEN');
  assert.equal(cookies[1].value, 'eyJpdiI6Ijx4%3D');
  assert.equal(cookies[2].value, 'xyz==');
  assert.equal(cookies[0].domain, '');
  assert.equal(cookies[0].expiresAt, 0);

  assert.deepEqual(parseCookieString('  '), []);
  assert.deepEqual(parseCookieString('badpair; =x'), []);
});

test('serializeCookies / deserializeCookies 往返', () => {
  const cookies: ParsedSetCookie[] = [
    mustParse('a=1; Domain=.hanime1.me; Path=/; Expires=Wed, 21 Oct 2035 07:28:00 GMT', 'hanime1.me'),
    mustParse('b=2; Max-Age=0', 'hanime1.me'),
    { name: 'manual', value: 'v', domain: '', path: '', expiresAt: 0 }
  ];
  const restored: ParsedSetCookie[] = deserializeCookies(serializeCookies(cookies));
  assert.deepEqual(restored, cookies);

  // 损坏 / 非法数据不应抛异常
  assert.deepEqual(deserializeCookies(''), []);
  assert.deepEqual(deserializeCookies('not json'), []);
  assert.deepEqual(deserializeCookies('"string"'), []);
  assert.deepEqual(deserializeCookies('[{"name":""}]'), []);
  const partial: ParsedSetCookie[] = deserializeCookies('[{"name":"x"}]');
  assert.equal(partial.length, 1);
  assert.equal(partial[0].value, '');
  assert.equal(partial[0].path, '/');
});

test('parseResponseCookies: @ohos.net.http 的 curl/Netscape cookie 列表', () => {
  const raw: string = [
    'www.hanime1.me\tFALSE\t/\tFALSE\t1706255412\thanime1_session\tabc123',
    '#HttpOnly_www.hanime1.me\tFALSE\t/\tTRUE\t0\tcf_clearance\tclearxyz',
    '.hanime1.me\tTRUE\t/users\tFALSE\t1706255412\tXSRF-TOKEN\ttok%3D'
  ].join('\r\n');
  const cookies: ParsedSetCookie[] = parseResponseCookies(raw, 'www.hanime1.me');
  assert.equal(cookies.length, 3);

  assert.equal(cookies[0].name, 'hanime1_session');
  assert.equal(cookies[0].value, 'abc123');
  assert.equal(cookies[0].domain, 'www.hanime1.me');
  assert.equal(cookies[0].path, '/');
  assert.equal(cookies[0].expiresAt, 1706255412 * 1000);

  assert.equal(cookies[1].name, 'cf_clearance');
  assert.equal(cookies[1].domain, 'www.hanime1.me'); // #HttpOnly_ 前缀被剥掉
  assert.equal(cookies[1].expiresAt, 0);

  assert.equal(cookies[2].name, 'XSRF-TOKEN');
  assert.equal(cookies[2].domain, 'hanime1.me');
  assert.equal(cookies[2].path, '/users');

  // 简单 `a=1; b=2` 格式的回退
  const simple: ParsedSetCookie[] = parseResponseCookies('a=1; b=2', 'hanime1.me');
  assert.equal(simple.length, 2);
  assert.equal(simple[0].domain, 'hanime1.me');
  assert.equal(simple[0].path, '/');
  assert.deepEqual(parseResponseCookies('', 'hanime1.me'), []);
});

test('hostOfUrl / pathOfUrl：从请求 URL 提取匹配信息', () => {
  assert.equal(hostOfUrl('https://hanime1.me/watch?v=100'), 'hanime1.me');
  assert.equal(hostOfUrl('https://WWW.Hanime1.ME:8080/search?page=1'), 'www.hanime1.me');
  assert.equal(hostOfUrl('http://user:pw@example.com/a'), 'example.com');
  assert.equal(hostOfUrl('/relative/path'), '');
  assert.equal(hostOfUrl('not a url'), '');

  assert.equal(pathOfUrl('https://hanime1.me/watch?v=100'), '/watch');
  assert.equal(pathOfUrl('https://hanime1.me/'), '/');
  assert.equal(pathOfUrl('https://hanime1.me'), '/');
  assert.equal(pathOfUrl('https://hanime1.me/a/b?x=1#h'), '/a/b');
});
