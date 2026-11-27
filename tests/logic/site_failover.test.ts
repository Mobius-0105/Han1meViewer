/**
 * 站点自动切换（failover）纯逻辑单元测试。
 *
 * 覆盖：origin 提取 / URL 改写（只换 origin 保留 path/query）、候选轮询顺序、
 * 冷却判定、触发状态码 / Cloudflare 特征、Toast 文案。
 * 全部为纯函数，不发起任何网络请求；HttpClient 的重试行为靠这些规则驱动。
 *
 * 运行：npx tsx --test tests/logic/site_failover.test.ts
 */
import { test } from 'node:test';
import assert from 'node:assert/strict';

import { BASE_URL_OPTIONS } from '../../entry/src/main/ets/core/util/Constants';
import {
  FAILOVER_RETRY_COOLDOWN_MS,
  FAILOVER_SWITCH_COOLDOWN_MS,
  baseUrlForOrigin,
  buildSiteSwitchToast,
  candidateOriginOf,
  candidateOriginsAfter,
  cooldownActive,
  hasCloudflareSignature,
  hostOfOrigin,
  isFailoverStatus,
  isNonFailoverStatus,
  isSuccessStatus,
  normalizeOrigin,
  optionOrigins,
  resolveFailoverCandidates,
  rewriteOrigin,
  shouldFailoverResponse
} from '../../entry/src/main/ets/core/util/SiteFailoverPolicy';

/** 与 Constants.BASE_URL_OPTIONS 对应的 origin（无尾斜杠）；AV 镜像站已从站点列表移除 */
const OPTION_ORIGINS: string[] = [
  'https://hanime1.me',
  'https://hanime1.com',
  'https://hanimeone.me'
];

const EMPTY_HEADERS: Record<string, string> = {};

// ---------------------------------------------------------------------------
// origin 提取 / 规范化
// ---------------------------------------------------------------------------

test('candidateOriginOf: 绝对 URL 提取 scheme+host（无尾斜杠、host 小写）', () => {
  assert.equal(candidateOriginOf('https://hanime1.me/'), 'https://hanime1.me');
  assert.equal(candidateOriginOf('https://hanime1.com/watch?v=123'), 'https://hanime1.com');
  assert.equal(candidateOriginOf('HTTPS://Hanime1.ME/Path/To'), 'https://hanime1.me');
  assert.equal(candidateOriginOf('https://hanime1.me:8443/x'), 'https://hanime1.me:8443');
  assert.equal(candidateOriginOf('http://hanime1.me/x'), 'http://hanime1.me');
  assert.equal(candidateOriginOf('  https://hanime1.me/a  '), 'https://hanime1.me');
});

test('candidateOriginOf: 相对路径 / 空串 / 非 http(s) 返回空串', () => {
  assert.equal(candidateOriginOf(''), '');
  assert.equal(candidateOriginOf('   '), '');
  assert.equal(candidateOriginOf('/watch?v=1'), '');
  assert.equal(candidateOriginOf('watch?v=1'), '');
  assert.equal(candidateOriginOf('ftp://hanime1.me/x'), '');
  assert.equal(candidateOriginOf('//hanime1.me/x'), '');
});

test('normalizeOrigin: 绝对地址去尾斜杠，裸 host 补 https', () => {
  assert.equal(normalizeOrigin('https://hanime1.com/'), 'https://hanime1.com');
  assert.equal(normalizeOrigin('https://hanime1.com/path?x=1'), 'https://hanime1.com');
  assert.equal(normalizeOrigin('hanime1.com'), 'https://hanime1.com');
  assert.equal(normalizeOrigin('hanime1.com/'), 'https://hanime1.com');
  assert.equal(normalizeOrigin(' Hanime1.COM/ '), 'https://hanime1.com');
  assert.equal(normalizeOrigin(''), '');
  assert.equal(normalizeOrigin('/'), '');
});

test('hostOfOrigin: 取纯 host（去掉 scheme / 端口 / userinfo）', () => {
  assert.equal(hostOfOrigin('https://hanime1.com/'), 'hanime1.com');
  assert.equal(hostOfOrigin('https://hanime1.com:8443/x'), 'hanime1.com');
  assert.equal(hostOfOrigin('https://user:pw@hanime1.me/'), 'hanime1.me');
  assert.equal(hostOfOrigin(''), '');
});

test('baseUrlForOrigin: 命中配置项时保留其尾斜杠写法，否则补 /', () => {
  assert.equal(baseUrlForOrigin(BASE_URL_OPTIONS, 'https://hanime1.com'), 'https://hanime1.com/');
  assert.equal(baseUrlForOrigin(BASE_URL_OPTIONS, 'https://hanime1.com/'), 'https://hanime1.com/');
  assert.equal(baseUrlForOrigin(BASE_URL_OPTIONS, 'https://example.org'), 'https://example.org/');
  assert.equal(baseUrlForOrigin(BASE_URL_OPTIONS, ''), '');
});

// ---------------------------------------------------------------------------
// URL 改写：只换 origin，保留 path/query/hash
// ---------------------------------------------------------------------------

test('rewriteOrigin: 保留 path 与 query', () => {
  assert.equal(
    rewriteOrigin('https://hanime1.me/search?query=abc&page=2', 'https://hanime1.com'),
    'https://hanime1.com/search?query=abc&page=2'
  );
  assert.equal(
    rewriteOrigin('https://hanime1.me/watch?v=1234', 'https://hanimeone.me/'),
    'https://hanimeone.me/watch?v=1234'
  );
});

test('rewriteOrigin: 保留 hash 与多级路径', () => {
  assert.equal(
    rewriteOrigin('https://hanime1.me/a/b/c?x=1&y=2#frag', 'https://hanimeone.me'),
    'https://hanimeone.me/a/b/c?x=1&y=2#frag'
  );
});

test('rewriteOrigin: 根路径 / 无 path / 带端口 URL', () => {
  assert.equal(rewriteOrigin('https://hanime1.me/', 'https://hanime1.com'), 'https://hanime1.com/');
  assert.equal(rewriteOrigin('https://hanime1.me', 'https://hanime1.com'), 'https://hanime1.com');
  assert.equal(rewriteOrigin('https://hanime1.me?x=1', 'https://hanime1.com'), 'https://hanime1.com?x=1');
  assert.equal(
    rewriteOrigin('https://hanime1.me:8443/watch?v=1', 'https://hanime1.com'),
    'https://hanime1.com/watch?v=1'
  );
});

test('rewriteOrigin: 相对 URL / 空 origin 原样返回（调用方会跳过该候选）', () => {
  assert.equal(rewriteOrigin('/watch?v=1', 'https://hanime1.com'), '/watch?v=1');
  assert.equal(rewriteOrigin('https://hanime1.me/watch?v=1', ''), 'https://hanime1.me/watch?v=1');
  assert.equal(rewriteOrigin('', 'https://hanime1.com'), '');
});

// ---------------------------------------------------------------------------
// 候选轮询顺序
// ---------------------------------------------------------------------------

test('optionOrigins: 按配置顺序去重并规范化', () => {
  assert.deepEqual(optionOrigins(BASE_URL_OPTIONS), OPTION_ORIGINS);
  assert.deepEqual(optionOrigins(['https://a.com/', 'https://a.com', 'https://b.com']),
    ['https://a.com', 'https://b.com']);
  assert.deepEqual(optionOrigins([]), []);
});

test('candidateOriginsAfter: 从失败站点之后开始环形轮询', () => {
  assert.deepEqual(
    candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.me'),
    ['https://hanime1.com', 'https://hanimeone.me']
  );
  // 最后一个站点回绕到第一个
  assert.deepEqual(
    candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanimeone.me/'),
    ['https://hanime1.me', 'https://hanime1.com']
  );
});

test('candidateOriginsAfter: 失败站点不在列表时从第一个开始；列表只有该站点时为空', () => {
  assert.deepEqual(
    candidateOriginsAfter(BASE_URL_OPTIONS, 'https://unknown.example'),
    OPTION_ORIGINS
  );
  assert.deepEqual(candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.me'), OPTION_ORIGINS.slice(1));
  assert.deepEqual(candidateOriginsAfter(['https://hanime1.me/'], 'https://hanime1.me'), []);
});

test('candidateOriginsAfter: 候选不含失败 origin（防御性）', () => {
  const candidates: string[] = candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.com');
  assert.equal(candidates.indexOf('https://hanime1.com'), -1);
  assert.equal(candidates.length, OPTION_ORIGINS.length - 1);
});

// ---------------------------------------------------------------------------
// 冷却
// ---------------------------------------------------------------------------

test('cooldownActive: 从未发生不算冷却；窗口内 / 边界 / 时钟回拨', () => {
  const now: number = 1_000_000;
  assert.equal(cooldownActive(now, 0, 60000), false);
  assert.equal(cooldownActive(now, now - 1, 60000), true);
  assert.equal(cooldownActive(now, now - 59999, 60000), true);
  assert.equal(cooldownActive(now, now - 60000, 60000), false);
  assert.equal(cooldownActive(now, now - 60001, 60000), false);
  // 时钟回拨（lastAt 在未来）按冷却中处理，避免异常时间戳反复切换
  assert.equal(cooldownActive(now, now + 5000, 60000), true);
  // 冷却时长为 0 视为不冷却
  assert.equal(cooldownActive(now, now - 1, 0), false);
});

test('resolveFailoverCandidates: 正常情况从失败站点之后轮询', () => {
  const now: number = 1_000_000;
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.me/', 'https://hanime1.me/',
      now, 0, 0, FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    ['https://hanime1.com', 'https://hanimeone.me']
  );
});

test('resolveFailoverCandidates: 当前 baseUrl 已被切到别的站点时只重试当前站点', () => {
  const now: number = 1_000_000;
  // 并发请求 A 已把 baseUrl 切到 hanime1.com，请求 B 的 URL 还指向 hanime1.me
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.me/watch?v=1',
      'https://hanime1.com/', now, now - 1000, 0,
      FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    ['https://hanime1.com']
  );
});

test('resolveFailoverCandidates: 冷却中返回空数组', () => {
  const now: number = 1_000_000;
  // 刚自动切换成功 60s 内
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.me/', 'https://hanime1.me/',
      now, now - 1000, 0, FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    []
  );
  // 一轮候选刚全部失败 30s 内
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.me/', 'https://hanime1.me/',
      now, 0, now - 1000, FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    []
  );
  // 冷却已过：恢复轮询
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.me/', 'https://hanime1.me/',
      now, now - FAILOVER_SWITCH_COOLDOWN_MS, now - FAILOVER_RETRY_COOLDOWN_MS,
      FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    ['https://hanime1.com', 'https://hanimeone.me']
  );
});

test('resolveFailoverCandidates: 外部域名 URL 不参与换站（避免把 CDN 地址改写到站点域名）', () => {
  const now: number = 1_000_000;
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://cdn.example.net/a.m3u8',
      'https://hanime1.me/', now, 0, 0,
      FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    []
  );
  // 当前站点已切到 hanime1.com，外部 URL 失败也不应被改写到 hanime1.com
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://cdn.example.net/a.m3u8',
      'https://hanime1.com/', now, 0, 0,
      FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    []
  );
  // 自定义 baseUrl（不在 BASE_URL_OPTIONS）失败时仍允许尝试官方备用站点
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://custom.example/a',
      'https://custom.example/', now, 0, 0,
      FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    OPTION_ORIGINS
  );
});

// ---------------------------------------------------------------------------
// 触发条件
// ---------------------------------------------------------------------------

test('isFailoverStatus: 403/429/5xx 触发，其余状态码不触发', () => {
  const triggers: number[] = [403, 429, 500, 502, 503, 504];
  for (let i = 0; i < triggers.length; i++) {
    assert.equal(isFailoverStatus(triggers[i]), true, 'code=' + triggers[i]);
  }
  const nonTriggers: number[] = [200, 201, 204, 301, 302, 400, 401, 404, 419, 422];
  for (let i = 0; i < nonTriggers.length; i++) {
    assert.equal(isFailoverStatus(nonTriggers[i]), false, 'code=' + nonTriggers[i]);
  }
});

test('isNonFailoverStatus: 登录态 / 页面不存在 / 登录跳转明确不换站', () => {
  const codes: number[] = [301, 302, 303, 307, 308, 401, 404, 419];
  for (let i = 0; i < codes.length; i++) {
    assert.equal(isNonFailoverStatus(codes[i]), true, 'code=' + codes[i]);
  }
  assert.equal(isNonFailoverStatus(403), false);
  assert.equal(isNonFailoverStatus(503), false);
});

test('hasCloudflareSignature: body 特征串 / cf-mitigated 头', () => {
  assert.equal(hasCloudflareSignature(EMPTY_HEADERS, '<html>Just a moment...</html>'), true);
  assert.equal(hasCloudflareSignature(EMPTY_HEADERS, 'just a moment'), true);
  assert.equal(hasCloudflareSignature(EMPTY_HEADERS, 'Sorry, you have been blocked'), true);
  assert.equal(hasCloudflareSignature(EMPTY_HEADERS, 'cf-mitigated'), true);
  assert.equal(hasCloudflareSignature({ 'cf-mitigated': 'challenge' }, ''), true);
  assert.equal(hasCloudflareSignature({ 'cf-mitigated': 'none' }, '<html>ok</html>'), false);
  assert.equal(hasCloudflareSignature(EMPTY_HEADERS, '<html>normal page</html>'), false);
});

test('shouldFailoverResponse: 403/429/5xx 与 CF 验证页触发；401/404/302 不触发', () => {
  assert.equal(shouldFailoverResponse(403, 'blocked', EMPTY_HEADERS), true);
  assert.equal(shouldFailoverResponse(429, 'too many requests', EMPTY_HEADERS), true);
  assert.equal(shouldFailoverResponse(500, '', EMPTY_HEADERS), true);
  assert.equal(shouldFailoverResponse(502, '', EMPTY_HEADERS), true);
  assert.equal(shouldFailoverResponse(503, '', EMPTY_HEADERS), true);
  assert.equal(shouldFailoverResponse(504, '', EMPTY_HEADERS), true);
  // Cloudflare 返回 200 验证页也要换站
  assert.equal(shouldFailoverResponse(200, '<title>Just a moment...</title>', EMPTY_HEADERS), true);
  // 登录页 / 登录跳转 / 页面不存在不换站
  assert.equal(shouldFailoverResponse(302, 'redirect to /login', EMPTY_HEADERS), false);
  assert.equal(shouldFailoverResponse(401, 'unauthorized', EMPTY_HEADERS), false);
  assert.equal(shouldFailoverResponse(404, 'not found', EMPTY_HEADERS), false);
  assert.equal(shouldFailoverResponse(419, 'csrf', EMPTY_HEADERS), false);
  assert.equal(shouldFailoverResponse(200, '<html>normal</html>', EMPTY_HEADERS), false);
});

test('shouldFailoverResponse: 404 即使带 CF 特征也不触发（页面不存在语义优先）', () => {
  assert.equal(shouldFailoverResponse(404, 'Just a moment', EMPTY_HEADERS), false);
});

// ---------------------------------------------------------------------------
// 候选轮询流程模拟（不发网络：用候选 origin → 假响应码 模拟 HttpClient 的重试循环）
// ---------------------------------------------------------------------------

/**
 * 模拟 HttpClient.pollCandidates 的决策流程：
 * - 依次把失败 URL 改写到候选 origin；
 * - 假响应命中 shouldFailoverResponse 则换下一个候选；
 * - 非 2xx（404/401/302）也不算换站成功，继续下一个候选；
 * - 2xx 且非 CF 验证页才采用该候选 origin。
 * 返回采用的 origin；全部失败返回 ''（= 保留原站点 / 原错误）。
 */
function simulateCandidatePoll(
  failedUrl: string,
  candidateOrigins: string[],
  fakeCodeOf: (origin: string) => number
): string {
  for (let i = 0; i < candidateOrigins.length; i++) {
    const origin: string = candidateOrigins[i];
    const rewritten: string = rewriteOrigin(failedUrl, origin);
    assert.notEqual(rewritten, failedUrl);
    assert.equal(candidateOriginOf(rewritten), origin);
    const code: number = fakeCodeOf(origin);
    if (shouldFailoverResponse(code, '', EMPTY_HEADERS)) {
      continue;
    }
    if (!isSuccessStatus(code)) {
      continue;
    }
    return origin;
  }
  return '';
}

test('候选轮询模拟: 跳过 503 的候选，采用第一个可用站点', () => {
  const failedUrl: string = 'https://hanime1.me/watch?v=123';
  const candidates: string[] = candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.me');
  const adopted: string = simulateCandidatePoll(failedUrl, candidates, (origin: string): number => {
    return origin === 'https://hanime1.com' ? 503 : 200;
  });
  assert.equal(adopted, 'https://hanimeone.me');
  assert.equal(rewriteOrigin(failedUrl, adopted), 'https://hanimeone.me/watch?v=123');
  assert.equal(baseUrlForOrigin(BASE_URL_OPTIONS, adopted), 'https://hanimeone.me/');
});

test('候选轮询模拟: 全部候选仍被拦/5xx 时不采用任何站点（不修改 baseUrl）', () => {
  const failedUrl: string = 'https://hanime1.me/';
  const candidates: string[] = candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.me');
  const adopted: string = simulateCandidatePoll(failedUrl, candidates, (): number => 403);
  assert.equal(adopted, '');
  // 403 属于换站触发条件，但候选全部失败 → 保留原站点
  assert.equal(candidateOriginOf(failedUrl), 'https://hanime1.me');
});

test('候选轮询模拟: 候选站点 404/401 不算换站成功，继续找 2xx 的候选', () => {
  const failedUrl: string = 'https://hanime1.me/watch?v=404';
  const candidates: string[] = candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.me');
  const adopted: string = simulateCandidatePoll(failedUrl, candidates, (origin: string): number => {
    return origin === 'https://hanime1.com' ? 404 : 200;
  });
  assert.equal(adopted, 'https://hanimeone.me');
});

test('候选轮询模拟: 候选全部返回 404 时不切站（保留原错误，避免误判站点可用）', () => {
  const failedUrl: string = 'https://hanime1.me/watch?v=404';
  const candidates: string[] = candidateOriginsAfter(BASE_URL_OPTIONS, 'https://hanime1.me');
  const adopted: string = simulateCandidatePoll(failedUrl, candidates, (): number => 404);
  assert.equal(adopted, '');
});

test('isSuccessStatus: 仅 2xx 视为成功', () => {
  assert.equal(isSuccessStatus(200), true);
  assert.equal(isSuccessStatus(204), true);
  assert.equal(isSuccessStatus(299), true);
  assert.equal(isSuccessStatus(199), false);
  assert.equal(isSuccessStatus(301), false);
  assert.equal(isSuccessStatus(302), false);
  assert.equal(isSuccessStatus(401), false);
  assert.equal(isSuccessStatus(404), false);
  assert.equal(isSuccessStatus(500), false);
});

test('切换冷却模拟: 切换成功后 60s 内不会继续切换，冷却结束后从新站点之后轮询', () => {
  const now: number = 10_000_000;
  // 刚自动切到 hanime1.com
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.me/', 'https://hanime1.com/',
      now, now - 1, 0, FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    ['https://hanime1.com'] // 仅允许「当前站点」修正旧 URL，不再切到第三个站点
  );
  // 冷却结束后，从当前站点（hanime1.com）之后继续轮询
  assert.deepEqual(
    resolveFailoverCandidates(BASE_URL_OPTIONS, 'https://hanime1.com/', 'https://hanime1.com/',
      now, now - FAILOVER_SWITCH_COOLDOWN_MS, 0,
      FAILOVER_SWITCH_COOLDOWN_MS, FAILOVER_RETRY_COOLDOWN_MS),
    ['https://hanimeone.me', 'https://hanime1.me']
  );
});

// ---------------------------------------------------------------------------
// Toast 文案
// ---------------------------------------------------------------------------

test('buildSiteSwitchToast: 未登录 / 已登录（追加重新登录提示）', () => {
  assert.equal(
    buildSiteSwitchToast('hanime1.com', false),
    '已自动切换到备用站点：hanime1.com'
  );
  assert.equal(
    buildSiteSwitchToast('hanime1.com', true),
    '已自动切换到备用站点：hanime1.com（如登录失效请重新登录）'
  );
});
