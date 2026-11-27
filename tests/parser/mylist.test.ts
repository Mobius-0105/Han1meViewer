/**
 * 我的清单 / 播放清单 / 账号资料 / 登录页 token 解析测试。
 *
 *  - fixtures/user_lists.html：SYNTHETIC（登录后才有的"我的清单"页，手写）；
 *  - fixtures/playlist_items.html、fixtures/playlists.html：真实 javchu.com 快照；
 *  - fixtures/user_account.html：SYNTHETIC（/edit 需登录）；
 *  - fixtures/login.html：真实 javchu.com 登录页（用于 csrf 提取）。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import {
  extractCsrfFromLoginPage,
  parseMyListPage,
  parsePlaylistsPage,
  parseUserAccount
} from '../../entry/src/main/ets/core/parser/HanimeParser';
import {
  HanimeInfo,
  MyListPage,
  PlaylistsPage,
  UserAccount
} from '../../entry/src/main/ets/core/model/Models';
import { readFixture } from './fixtures';

test('我的清单（SYNTHETIC）：csrf / 描述 / 条目 / 总页数', () => {
  const page: MyListPage = parseMyListPage(readFixture('user_lists.html'), 'https://hanime1.me/');
  assert.equal(page.csrfToken, 'MYLIST-CSRF');
  assert.equal(page.desc, '我的最愛清單說明（合成）');
  assert.equal(page.maxPage, 7);
  assert.equal(page.items.length, 2);

  const first: HanimeInfo = page.items[0];
  assert.equal(first.title, '清單影片一');
  assert.equal(first.videoCode, '111111');
  assert.equal(first.coverUrl, 'https://vdownload.hembed.com/image/thumbnail/111111l.jpg');
  assert.equal(first.duration, '24:00');
  assert.equal(first.views, '3.4萬次');
  assert.equal(first.uploadTime, '3天前');
  assert.equal(first.currentArtist, '作者B');
  assert.equal(first.reviews, '97%');
  assert.equal(first.itemType, 0);
});

test('我的清单：播放清单详情页（真实）：.playlist-video-list 兜底路径', () => {
  const page: MyListPage = parseMyListPage(
    readFixture('playlist_items.html'), 'https://javchu.com/'
  );
  assert.equal(page.items.length, 1);
  assert.equal(page.maxPage, 1);
  const first: HanimeInfo = page.items[0];
  assert.equal(first.videoCode, '403593');
  assert.equal(first.title.indexOf('517MQXT-007') >= 0, true);
  assert.equal(first.duration, '42:12');
  assert.equal(first.views, '2970次');
  // 播放清单条目的 DOM id 形如 playlist-item-20910915
  assert.equal(first.playlistItemId, '20910915');
  assert.equal(first.coverUrl.startsWith('https://'), true);
});

test('我的播放清单列表（真实）：数量 / 总页数 / 首项字段', () => {
  const page: PlaylistsPage = parsePlaylistsPage(
    readFixture('playlists.html'), 'https://javchu.com/'
  );
  assert.equal(page.playlists.length, 60);
  assert.equal(page.maxPage, 17);
  assert.equal(page.csrfToken.length > 0, true);

  const first = page.playlists[0];
  assert.equal(first.listCode, '703938');
  assert.equal(first.title, '女体昇天映像社');
  assert.equal(first.total, 1);
  assert.equal(first.coverUrl.startsWith('https://'), true);
});

test('账号资料（SYNTHETIC）：头像/用户名/email 只读/统计数字', () => {
  const account: UserAccount = parseUserAccount(
    readFixture('user_account.html'), 'https://hanime1.me/'
  );
  assert.equal(account.csrfToken, 'ACCOUNT-CSRF');
  assert.equal(account.avatarUrl, 'https://vdownload.hembed.com/image/avatar/123456.jpeg');
  assert.equal(account.username, '合成用戶名');
  assert.equal(account.email, 'user@example.com');
  assert.equal(account.emailEditable, false);
  assert.equal(account.userId, '1001450');
  assert.equal(account.joinedLabel, '加入於 2024-01-02');
  assert.equal(account.subscriberCount, 12);
  assert.equal(account.videoCount, 34);
});

test('登录页（真实）：input[name=_token] 提取 csrf', () => {
  const token: string = extractCsrfFromLoginPage(readFixture('login.html'));
  assert.equal(token, 'F1ovnfzRsIPqI5oxVwiCYlmxciFRhPNoGZ8HI4XD');
  // 没有表单时返回空串（Android 侧抛异常，这里交给网络层判断）
  assert.equal(extractCsrfFromLoginPage('<html><body>no form</body></html>'), '');
});

test('列表/账号解析：空 HTML 返回默认空对象，不抛异常', () => {
  const myList: MyListPage = parseMyListPage('', 'https://hanime1.me/');
  assert.equal(myList.items.length, 0);
  assert.equal(myList.csrfToken, '');
  assert.equal(myList.maxPage, 1);

  const playlists: PlaylistsPage = parsePlaylistsPage('', 'https://hanime1.me/');
  assert.equal(playlists.playlists.length, 0);
  assert.equal(playlists.maxPage, 1);

  const account: UserAccount = parseUserAccount('', 'https://hanime1.me/');
  assert.equal(account.username, '');
  assert.equal(account.emailEditable, false);
  assert.equal(account.userId, '');
});
