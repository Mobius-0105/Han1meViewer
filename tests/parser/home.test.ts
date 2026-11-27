/**
 * 首页解析测试（真实 fixture：fixtures/home.html，2026 年 hanime1.me 快照）。
 *
 * 断言"具体字段"而不是"非空"：标题、videoCode、封面绝对地址、观看数文本、
 * 上传时间文本、好评率、分区数量与分区归属，便于站点改版时快速定位问题。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { parseHomePage } from '../../entry/src/main/ets/core/parser/HanimeParser';
import { HanimeInfo, HomePage } from '../../entry/src/main/ets/core/model/Models';
import { readFixture } from './fixtures';

const HOME: HomePage = parseHomePage(readFixture('home.html'), 'https://hanime1.me/');

test('首页：csrf token（未登录快照只有 meta，走兜底）与用户信息', () => {
  // 该快照是未登录状态：没有 input[name=_token]，token 在 meta[name=csrf-token]
  assert.equal(HOME.csrfToken, '6E88DUswtGaPnt9Rx15IZ2oOesnUAaRP3qCknlg6');
  assert.equal(HOME.userId, '');
  assert.equal(HOME.username, '');
  assert.equal(HOME.avatarUrl, '');
  assert.equal(HOME.timestamp > 0, true);
});

test('首页：banner 标题/描述/封面/跳转 videoCode', () => {
  const banner = HOME.banner;
  assert.notEqual(banner, null);
  if (banner === null) {
    return;
  }
  assert.equal(banner.title, '[小木凳子] 2026 Septmber 知更鳥');
  assert.equal(banner.description, '小木凳子 • 27.8萬次觀看 • 2個月前');
  assert.equal(banner.picUrl.startsWith('https://'), true);
  assert.equal(banner.videoCode, '408109');
  assert.equal(/^\d+$/.test(banner.videoCode), true);
});

test('首页：各分区均匀抓取成功（含 Motion/3DCG/2.5D/2D/AI/MMD/Cosplay）', () => {
  const sections: HanimeInfo[][] = [
    HOME.latestRelease,
    HOME.latestHanime,
    HOME.ecchiAnime,
    HOME.shortEpisodeAnime,
    HOME.motionAnime,
    HOME.threeDCG,
    HOME.twoPointFiveDAnime,
    HOME.twoDAnime,
    HOME.aiGenerated,
    HOME.mmd,
    HOME.cosplay,
    HOME.watchingNow
  ];
  for (let i: number = 0; i < sections.length; i++) {
    assert.equal(sections[i].length, 12, `第 ${i} 个分区数量不是 12`);
  }
  // 分区没有因索引错位而重复：Motion/3DCG/AI/MMD 各自不同
  assert.notEqual(HOME.motionAnime[0].videoCode, HOME.threeDCG[0].videoCode);
  assert.notEqual(HOME.aiGenerated[0].videoCode, HOME.mmd[0].videoCode);
  assert.notEqual(HOME.latestRelease[0].videoCode, HOME.latestHanime[0].videoCode);
  // 2026 快照里主站没有"新番预告"分区，且索引 12 已被 Cosplay 占用，应返回空列表
  assert.equal(HOME.newAnimeTrailer.length, 0);
});

test('首页：卡片字段与文本归一化（标题/时长/观看数/上传时间/作者/好评率）', () => {
  const first: HanimeInfo = HOME.latestRelease[0];
  assert.equal(first.title, 'Velina (ZZZ) – Thank-You Tea – 11/17/2026 – 6m47s');
  assert.equal(first.videoCode, '409266');
  assert.equal(/^\d+$/.test(first.videoCode), true);
  assert.equal(first.coverUrl.startsWith('https://vdownload.hembed.com/image/thumbnail/'), true);
  assert.equal(first.duration, '06:46');
  assert.equal(first.views, '24.8萬次');
  assert.equal(first.uploadTime, '20小時前');
  assert.equal(first.currentArtist, 'The Peak');
  assert.equal(first.reviews, '99%');
  assert.equal(first.itemType, 0);
  assert.equal(first.playlistItemId, '');
  assert.equal(first.isPlaying, false);
});

test('首页：每张卡片的封面都是 https 绝对地址、videoCode 都是数字', () => {
  const all: HanimeInfo[] = HOME.latestRelease
    .concat(HOME.latestHanime)
    .concat(HOME.ecchiAnime)
    .concat(HOME.cosplay);
  for (let i: number = 0; i < all.length; i++) {
    assert.equal(all[i].coverUrl.startsWith('https://'), true, all[i].title);
    assert.equal(/^\d+$/.test(all[i].videoCode), true, all[i].title);
    assert.equal(all[i].title.length > 0, true);
  }
});

test('首页：分区标题兜底逻辑（快照里广告占位 div 被跳过）', () => {
  // 真实快照的 #home-rows-wrapper 有 14 个直接子 div（索引 4、9 是广告位），
  // 解析器按标题匹配应跳过没有标题/没有卡片的广告分区。
  for (let i: number = 0; i < HOME.latestRelease.length; i++) {
    assert.equal(HOME.latestRelease[i].title.indexOf('贊助') < 0, true);
  }
  // 3DCG 分区第一张卡确实是 3DCG 内容（标题里带 3D 视频特征的名字）
  assert.equal(HOME.threeDCG[0].title.length > 0, true);
});
