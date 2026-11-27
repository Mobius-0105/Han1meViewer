/**
 * 「我的订阅」页面解析测试（合成 HTML）。
 *
 * 站点 `/subscriptions` 需要登录，无法在开发环境抓真实快照，因此这里按 Android 上游
 * `Parser.getMySubscriptions` 用到的选择器手写合成 HTML，覆盖：
 *  - 作者卡片（头像取第 2 个 img、作者名取 card-mobile-title、缺头像的卡片跳过）；
 *  - 视频卡片（`•` 版式 / 无 `•` 版式的 subtitle、广告卡与缺封面卡跳过、reviews ownText）；
 *  - 相对地址转绝对地址、maxPage（ul.pagination 最大页码）；
 *  - 空列表返回空数组；结构不符抛 name='ParseError' 的错误。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import {
  isSubscriptionParseError,
  parseMySubscriptions
} from '../entry/src/main/ets/core/parser/SubscriptionParser';
import {
  MySubscriptions,
  SubscriptionArtist,
  SubscriptionVideo
} from '../entry/src/main/ets/core/model/Subscription';

/** 合成页面：2 个有效作者 + 1 个缺头像作者；2 个有效视频 + 广告卡 + 缺封面卡 */
const SYNTHETIC_PAGE: string = `<!DOCTYPE html>
<html>
<head><title>我的订阅</title></head>
<body>
  <div class="subscriptions-nav">
    <div class="subscriptions-artist-card">
      <img src="https://vdownload.hembed.com/image/cover/artist-cover.jpg">
      <img src="//vdownload.hembed.com/image/avatar/1001.jpeg">
      <div class="card-mobile-title"> 合成 作者A </div>
    </div>
    <div class="subscriptions-artist-card">
      <img src="/image/cover/artist-cover-2.jpg">
      <img src="/image/avatar/1002.jpeg">
      <div class="card-mobile-title">合成作者B</div>
    </div>
    <div class="subscriptions-artist-card">
      <img src="/image/avatar/only-one.jpeg">
      <div class="card-mobile-title">只有一个 img 的作者</div>
    </div>
  </div>

  <div class="content-padding-new">
    <div class="row no-gutter">
      <div title="新番第一話" class="video-item-container">
        <div class="horizontal-card">
          <a href="https://hanime1.me/watch?v=111111" class="video-link">
            <div class="thumb-container">
              <img class="main-thumb" src="https://vdownload.hembed.com/image/thumbnail/111111l.jpg">
              <div class="duration"> 24:00 </div>
              <div class="stats-container">
                <div class="stat-item"><i class="material-icons">thumb_up</i> 97%</div>
                <div class="stat-item">3.4萬次</div>
              </div>
            </div>
            <div class="title">新番第一話</div>
          </a>
          <div class="subtitle">
            <a href="https://hanime1.me/search?query=A">合成作者A</a>
            <span class="subtitle-time">&nbsp;• 3天前</span>
          </div>
        </div>
      </div>

      <div title="舊版式影片" class="video-item-container">
        <div class="horizontal-card">
          <a href="/watch?v=222222" class="video-link">
            <div class="thumb-container">
              <img class="main-thumb" src="/image/thumbnail/222222l.jpg">
              <div class="duration">12:34</div>
              <div class="stats-container">
                <div class="stat-item"><i class="material-icons">thumb_up</i> 88%</div>
                <div class="stat-item">2970次</div>
              </div>
            </div>
            <div class="title">舊版式影片</div>
          </a>
          <div class="subtitle">
            <a href="/search?query=B">合成作者B</a>
            <span class="subtitle-time">2024-01-02</span>
          </div>
        </div>
      </div>

      <div title="贊助商" class="video-item-container">
        <div class="horizontal-card">
          <a href="https://l.erodalabs.com/s/1L6gaU" class="video-link">
            <div class="thumb-container">
              <img class="main-thumb" src="https://vdownload.hembed.com/image/icon/ad.jpg">
              <div class="stats-container"><div class="stat-item">贊助商</div></div>
            </div>
          </a>
          <div class="subtitle"><a href="https://l.erodalabs.com/s/1L6gaU">EROLABS</a></div>
        </div>
      </div>

      <div title="缺封面" class="video-item-container">
        <div class="horizontal-card">
          <a href="/watch?v=333333" class="video-link">
            <div class="thumb-container"></div>
          </a>
        </div>
      </div>
    </div>
  </div>

  <ul class="pagination">
    <li><a class="page-link" href="?page=1">1</a></li>
    <li><a class="page-link" href="?page=2">2</a></li>
    <li><a class="page-link" href="?page=5">5</a></li>
  </ul>
</body>
</html>`;

const BASE_URL: string = 'https://hanime1.me/';

/** 执行回调并返回抛出的错误（不抛时返回 null），避免依赖 assert.throws 的校验器重载 */
function captureError(fn: () => void): Error | null {
  try {
    fn();
  } catch (rawError) {
    return rawError as Error;
  }
  return null;
}

test('订阅作者：头像取第 2 个 img、名字取 card-mobile-title、缺头像跳过', () => {
  const page: MySubscriptions = parseMySubscriptions(SYNTHETIC_PAGE, BASE_URL);
  assert.equal(page.artists.length, 2);

  const first: SubscriptionArtist = page.artists[0];
  assert.equal(first.artistName, '合成 作者A');
  // 协议相对地址按 baseUrl 的 scheme 补成 https
  assert.equal(first.avatar, 'https://vdownload.hembed.com/image/avatar/1001.jpeg');

  const second: SubscriptionArtist = page.artists[1];
  assert.equal(second.artistName, '合成作者B');
  // 相对路径按 baseUrl 的 origin 转绝对地址
  assert.equal(second.avatar, 'https://hanime1.me/image/avatar/1002.jpeg');
});

test('订阅视频：• 分隔版式的作者/上传时间、时长/播放量/好评率', () => {
  const page: MySubscriptions = parseMySubscriptions(SYNTHETIC_PAGE, BASE_URL);
  assert.equal(page.videos.length, 2);

  const video: SubscriptionVideo = page.videos[0];
  assert.equal(video.title, '新番第一話');
  assert.equal(video.videoCode, '111111');
  assert.equal(video.coverUrl, 'https://vdownload.hembed.com/image/thumbnail/111111l.jpg');
  assert.equal(video.duration, '24:00');
  assert.equal(video.views, '3.4萬次');
  assert.equal(video.reviews, '97%');
  assert.equal(video.currentArtist, '合成作者A');
  assert.equal(video.uploadTime, '3天前');
});

test('订阅视频：无 • 版式回退 a / span 文本，相对地址转绝对地址', () => {
  const page: MySubscriptions = parseMySubscriptions(SYNTHETIC_PAGE, BASE_URL);
  const video: SubscriptionVideo = page.videos[1];
  assert.equal(video.title, '舊版式影片');
  assert.equal(video.videoCode, '222222');
  assert.equal(video.coverUrl, 'https://hanime1.me/image/thumbnail/222222l.jpg');
  assert.equal(video.duration, '12:34');
  assert.equal(video.views, '2970次');
  assert.equal(video.reviews, '88%');
  assert.equal(video.currentArtist, '合成作者B');
  assert.equal(video.uploadTime, '2024-01-02');
});

test('广告卡（无 watch?v=）与缺封面卡被跳过', () => {
  const page: MySubscriptions = parseMySubscriptions(SYNTHETIC_PAGE, BASE_URL);
  const codes: string[] = [page.videos[0].videoCode, page.videos[1].videoCode];
  assert.equal(codes.indexOf('333333'), -1);
  assert.equal(codes.length, 2);
  for (let i: number = 0; i < page.videos.length; i++) {
    assert.equal(page.videos[i].currentArtist.indexOf('EROLABS'), -1);
  }
});

test('maxPage：取 ul.pagination 里最大页码', () => {
  const page: MySubscriptions = parseMySubscriptions(SYNTHETIC_PAGE, BASE_URL);
  assert.equal(page.maxPage, 5);
});

test('空列表：作者/视频区域存在但没有卡片时返回空数组，maxPage 默认 1', () => {
  const html: string = `<html><body>
    <div class="subscriptions-nav"></div>
    <div class="content-padding-new"><div class="row"></div></div>
  </body></html>`;
  const page: MySubscriptions = parseMySubscriptions(html, BASE_URL);
  assert.equal(page.artists.length, 0);
  assert.equal(page.videos.length, 0);
  assert.equal(page.maxPage, 1);
});

test('结构不符：缺少 subscriptions-nav / content-padding-new 时抛 ParseError', () => {
  const missingVideos: string = `<html><body>
    <div class="subscriptions-nav"><div class="subscriptions-artist-card"></div></div>
  </body></html>`;
  const error1: Error | null = captureError(() => {
    parseMySubscriptions(missingVideos, BASE_URL);
  });
  assert.notEqual(error1, null);
  assert.equal((error1 as Error).name, 'ParseError');
  assert.equal(isSubscriptionParseError(error1 as Error), true);

  // 空 HTML（未登录被重定向到登录页等情况）同样判为结构不符
  const error2: Error | null = captureError(() => {
    parseMySubscriptions('', BASE_URL);
  });
  assert.notEqual(error2, null);
  assert.equal((error2 as Error).name, 'ParseError');
});
