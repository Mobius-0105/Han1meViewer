/**
 * 搜索页解析测试：真实 fixture（javchu.com 搜索结果）+ 合成简化版式。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import { parseSearchPage } from '../../entry/src/main/ets/core/parser/HanimeParser';
import { HanimeInfo, SearchPage } from '../../entry/src/main/ets/core/model/Models';
import { readFixture } from './fixtures';

test('搜索页（真实 javchu 快照）：列表数量、最大页码、首条字段', () => {
  const page: SearchPage = parseSearchPage(readFixture('search.html'), 'https://javchu.com/');
  // 61 个 horizontal-card 里含 2 个 EROLABS 广告卡（没有 watch?v= 链接），应被过滤
  assert.equal(page.list.length, 59);
  assert.equal(page.maxPage, 1654);

  const first: HanimeInfo = page.list[0];
  assert.equal(first.title, 'MIDA-474 跟青梅竹馬辣妹見面內射14次的鄉村生活-Unpai');
  assert.equal(first.videoCode, '404523');
  assert.equal(first.duration, '02:29:45');
  assert.equal(first.views, '32.4萬次');
  assert.equal(first.uploadTime, '10個月前');
  assert.equal(first.currentArtist, 'Moodyz');
  assert.equal(first.reviews, '100%');
  assert.equal(first.coverUrl.startsWith('https://'), true);
  assert.equal(first.itemType, 0);
});

test('搜索页（真实 javchu 快照）：广告卡被过滤、全部卡片字段合法', () => {
  const page: SearchPage = parseSearchPage(readFixture('search.html'), 'https://javchu.com/');
  for (let i: number = 0; i < page.list.length; i++) {
    const item: HanimeInfo = page.list[i];
    assert.equal(/^\d+$/.test(item.videoCode), true, item.title);
    assert.equal(item.coverUrl.startsWith('https://'), true, item.title);
    assert.equal(item.title.indexOf('贊助') < 0, true);
    assert.equal(item.title.indexOf('ERO LABS') < 0, true);
  }
});

test('搜索页（合成简化版式）：home-rows-videos-wrapper 子元素解析', () => {
  const page: SearchPage = parseSearchPage(
    readFixture('search_simplified.html'), 'https://hanime1.me/'
  );
  assert.equal(page.list.length, 2);
  assert.equal(page.maxPage, 3);

  const first: HanimeInfo = page.list[0];
  assert.equal(first.title, '預告片甲');
  assert.equal(first.videoCode, '555555');
  assert.equal(first.coverUrl, 'https://vdownload.hembed.com/image/thumbnail/555555l.jpg');
  assert.equal(first.uploadTime, '11月27日');
  assert.equal(first.itemType, 1);
  assert.equal(first.duration, '');
  assert.equal(first.views, '');
});

test('搜索页：空/异常 HTML 不抛异常，返回空列表 + maxPage=1', () => {
  const page: SearchPage = parseSearchPage('<html><body>403 Forbidden</body></html>', 'https://hanime1.me/');
  assert.equal(page.list.length, 0);
  assert.equal(page.maxPage, 1);
});
