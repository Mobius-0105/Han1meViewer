/**
 * 视频详情页解析测试。
 *
 *  - fixtures/watch.html：真实 javchu.com（AV 站）快照，验证标题/日期/观看数/
 *    script 兜底播放源/新版系列播放列表/相关推荐/作者/评论数；
 *  - fixtures/watch_synthetic_hanime.html：SYNTHETIC（主站版式），验证
 *    `<source size=...>` 清晰度列表、AV CDN 修正、我的清单、旧版系列播放列表、
 *    中文标题/简介/原作漫画等真实快照拿不到（未登录/主站被 CF 拦截）的路径。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { fixAvCdnHost, parseVideoPage } from '../../entry/src/main/ets/core/parser/HanimeParser';
import { HanimeInfo, HanimeVideo, VideoSource } from '../../entry/src/main/ets/core/model/Models';
import { readFixture } from './fixtures';

const REAL: HanimeVideo = parseVideoPage(
  readFixture('watch.html'), 'https://javchu.com/', '404507'
);

test('视频页（真实 AV 站）：标题 / 观看数 / 上传时间', () => {
  assert.equal(REAL.videoCode, '404507');
  assert.equal(REAL.title, 'FC2PPV-2800788 純真無邪的十八歲畢業生乃木坂系巨乳美少女正逐漸沉迷情慾');
  assert.equal(REAL.uploadTime, '2026-02-06');
  assert.equal(REAL.views, '16.9萬次');
  assert.equal(REAL.coverUrl.startsWith('https://'), true);
  assert.equal(REAL.introduction, '');
  assert.equal(REAL.chineseTitle.length > 0, true);
});

test('视频页（真实 AV 站）：未登录状态下的点赞/清单字段', () => {
  assert.equal(REAL.isFav, false);
  assert.equal(REAL.isUnlike, false);
  assert.equal(REAL.favTimes, -1);
  assert.equal(REAL.unlikesCount, -1);
  assert.equal(REAL.currentUserId, '');
  assert.equal(REAL.csrfToken.length > 0, true);
  assert.notEqual(REAL.myList, null);
  if (REAL.myList !== null) {
    assert.equal(REAL.myList.isWatchLater, false);
    assert.equal(REAL.myList.myListInfo.length, 0);
  }
  assert.deepEqual(REAL.tags, []);
  assert.equal(REAL.originalComic, '');
});

test('视频页（真实 AV 站）：script 兜底播放源 + CDN 主机', () => {
  assert.equal(REAL.sources.length, 1);
  const source: VideoSource = REAL.sources[0];
  assert.equal(source.resolution, 'auto');
  assert.equal(source.url, 'https://t33.cdn2020.com/video/m3u8/2026/02/06/5a7d3f35/index.m3u8');
  assert.equal(source.url.indexOf('cdn2020.com') >= 0, true);
});

test('视频页（真实 AV 站）：新版系列播放列表（playlist-hover-wrap）', () => {
  assert.notEqual(REAL.playlist, null);
  if (REAL.playlist === null) {
    return;
  }
  assert.equal(REAL.playlist.playlistName, 'HSCK');
  assert.equal(REAL.playlist.video.length, 41);
  const first: HanimeInfo = REAL.playlist.video[0];
  assert.equal(first.videoCode, '404507');
  assert.equal(first.isPlaying, true);
  assert.equal(first.duration, '01:33:12');
  assert.equal(first.views, '16.9萬次');
  assert.equal(first.genre, '高清無碼');
  assert.equal(first.currentArtist, 'HSCK');
  assert.equal(first.coverUrl.startsWith('https://'), true);
});

test('视频页（真实 AV 站）：相关推荐 / 作者 / 评论总数', () => {
  assert.equal(REAL.relatedHanimes.length, 59);
  const related: HanimeInfo = REAL.relatedHanimes[0];
  assert.equal(related.title, 'DVAJ-025 第一次嘗試黑人肉棒-葵つかさ');
  assert.equal(/^\d+$/.test(related.videoCode), true);
  assert.equal(related.coverUrl.startsWith('https://'), true);

  assert.notEqual(REAL.artist, null);
  if (REAL.artist !== null) {
    assert.equal(REAL.artist.name, 'HSCK');
    assert.equal(REAL.artist.genre, '高清無碼');
    assert.equal(REAL.artist.avatarUrl, 'https://i.imgur.com/mS6Fdr2b.png');
    assert.equal(REAL.artist.isSubscribed, false);
  }
  assert.equal(REAL.commentCount, 11);
});

test('fixAvCdnHost：仅 javchu.com 生效（t26/t27 → t33）', () => {
  assert.equal(
    fixAvCdnHost('//t26.cdn2020.com/video/a.m3u8', 'https://javchu.com/'),
    '//t33.cdn2020.com/video/a.m3u8'
  );
  assert.equal(
    fixAvCdnHost(' https://t27.cdn2020.com/video/a.m3u8', 'https://javchu.com/'),
    ' https://t33.cdn2020.com/video/a.m3u8'
  );
  // 非 AV 站不修正
  assert.equal(
    fixAvCdnHost('//t26.cdn2020.com/video/a.m3u8', 'https://hanime1.me/'),
    '//t26.cdn2020.com/video/a.m3u8'
  );
  assert.equal(fixAvCdnHost('', 'https://javchu.com/'), '');
});

test('视频页（合成主站版式）：标题/中文标题/简介/时间/点赞/标签', () => {
  const video: HanimeVideo = parseVideoPage(
    readFixture('watch_synthetic_hanime.html'), 'https://javchu.com/', '999999'
  );
  assert.equal(video.title, '合成測試影片 第一話');
  assert.equal(video.chineseTitle, '合成測試影片（中文字幕）');
  assert.equal(video.introduction, '這是一段簡介文本。');
  assert.equal(video.uploadTime, '2025-12-24');
  assert.equal(video.views, '1.2萬次');
  assert.equal(video.favTimes, 128);
  assert.equal(video.unlikesCount, 5);
  assert.equal(video.isFav, true);
  assert.equal(video.isUnlike, false);
  assert.equal(video.csrfToken, 'SYNTH-CSRF-TOKEN');
  assert.equal(video.currentUserId, '777001');
  assert.deepEqual(video.tags, ['巨乳', '中文字幕']);
  assert.equal(video.originalComic, 'https://example.com/comic/999999');
  assert.equal(video.commentCount, 42);
  assert.equal(video.coverUrl, 'https://vdownload.hembed.com/image/poster/999999.jpg');
});

test('视频页（合成主站版式）：<source size> 清晰度列表 + CDN 修正', () => {
  const video: HanimeVideo = parseVideoPage(
    readFixture('watch_synthetic_hanime.html'), 'https://javchu.com/', '999999'
  );
  assert.equal(video.sources.length, 3);
  assert.deepEqual(
    video.sources.map((source: VideoSource): string => source.resolution),
    ['1080P', '720P', '480P']
  );
  assert.equal(
    video.sources[0].url,
    'https://t33.cdn2020.com/video/m3u8/999999/1080/index.m3u8'
  );
  // //t26... 被修正为 t33（AV 站）
  assert.equal(
    video.sources[1].url,
    'https://t33.cdn2020.com/video/m3u8/999999/720/index.m3u8'
  );
  assert.equal(video.sources[1].type, 'video/mp4');
  // 站内相对地址转绝对
  assert.equal(video.sources[2].url, 'https://javchu.com/media/999999/480.mp4');

  // 非 AV 站不修正 CDN 主机
  const nonAv: HanimeVideo = parseVideoPage(
    readFixture('watch_synthetic_hanime.html'), 'https://hanime1.me/', '999999'
  );
  assert.equal(nonAv.sources[1].url.indexOf('t26.cdn2020.com') >= 0, true);
  assert.equal(nonAv.sources[2].url, 'https://hanime1.me/media/999999/480.mp4');
});

test('视频页（合成主站版式）：我的清单 / 稍后再看', () => {
  const video: HanimeVideo = parseVideoPage(
    readFixture('watch_synthetic_hanime.html'), 'https://hanime1.me/', '999999'
  );
  assert.notEqual(video.myList, null);
  if (video.myList === null) {
    return;
  }
  assert.equal(video.myList.isWatchLater, true);
  assert.equal(video.myList.myListInfo.length, 2);
  assert.equal(video.myList.myListInfo[0].code, 'list-code-love');
  assert.equal(video.myList.myListInfo[0].title, '我的最愛');
  assert.equal(video.myList.myListInfo[0].isSelected, true);
  assert.equal(video.myList.myListInfo[1].isSelected, false);
});

test('视频页（合成主站版式）：旧版系列播放列表 + 作者 + 相关推荐', () => {
  const video: HanimeVideo = parseVideoPage(
    readFixture('watch_synthetic_hanime.html'), 'https://hanime1.me/', '999999'
  );
  assert.notEqual(video.playlist, null);
  if (video.playlist === null) {
    return;
  }
  assert.equal(video.playlist.playlistName, '合成系列播放清單');
  assert.equal(video.playlist.video.length, 2);
  assert.equal(video.playlist.video[0].title, '系列第一話');
  assert.equal(video.playlist.video[0].isPlaying, true);
  assert.equal(video.playlist.video[0].duration, '12:34');
  assert.equal(video.playlist.video[0].views, '1.5萬次');
  assert.equal(video.playlist.video[0].reviews, '98%');
  assert.equal(video.playlist.video[1].title, '系列第二話');
  assert.equal(video.playlist.video[1].isPlaying, false);

  assert.notEqual(video.artist, null);
  if (video.artist !== null) {
    assert.equal(video.artist.name, '作者合成');
    assert.equal(video.artist.genre, '裏番');
    assert.equal(video.artist.avatarUrl, 'https://i.imgur.com/avatar999.png');
    assert.equal(video.artist.isSubscribed, true);
    assert.equal(video.artist.userId, '777001');
    assert.equal(video.artist.artistId, '123456');
  }

  assert.equal(video.relatedHanimes.length, 2);
  assert.equal(video.relatedHanimes[0].title, '相關影片一');
  assert.equal(video.relatedHanimes[0].videoCode, '333333');
  assert.equal(video.relatedHanimes[1].title, '相關影片二');
});

test('视频页：异常 HTML（403 挑战页）不抛异常，返回空标题/空播放源', () => {
  const video: HanimeVideo = parseVideoPage(
    '<html><body><h1>403 Forbidden</h1></body></html>', 'https://hanime1.me/', '123456'
  );
  assert.equal(video.videoCode, '123456');
  assert.equal(video.title, '');
  assert.equal(video.sources.length, 0);
  assert.equal(video.relatedHanimes.length, 0);
  assert.equal(video.playlist, null);
  assert.equal(video.artist, null);
  assert.equal(video.commentCount, 0);
});
