/**
 * 评论客户端排序（对齐上游 CommentSortType / CommentScreen.sortComments）
 * 与分享文本（对齐上游 getHanimeShareText）的纯逻辑单测。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import {
  COMMENT_SORT_EARLIEST,
  COMMENT_SORT_LATEST,
  COMMENT_SORT_MOST_DISLIKES,
  COMMENT_SORT_MOST_LIKES,
  COMMENT_SORT_MOST_REPLY,
  COMMENT_SORT_SITE,
  commentSortLabel,
  commentTimeToMinutes,
  sortVideoComments
} from '../../entry/src/main/ets/core/parser/CommentParser';
import { VideoComment, emptyVideoComment } from '../../entry/src/main/ets/core/model/Models';
import { buildVideoShareText } from '../../entry/src/main/ets/core/util/ShareText';

function makeComment(username: string, date: string, thumbUp: number, replyCount: number): VideoComment {
  const comment: VideoComment = emptyVideoComment();
  comment.username = username;
  comment.date = date;
  comment.thumbUp = thumbUp;
  comment.replyCount = replyCount;
  return comment;
}

function names(list: VideoComment[]): string[] {
  return list.map((comment: VideoComment): string => comment.username);
}

test('commentTimeToMinutes：繁/简时间单位与上游 parseTimeStrToMinutes 一致', () => {
  assert.equal(commentTimeToMinutes('45分鐘前'), 45);
  assert.equal(commentTimeToMinutes('45分钟前'), 45);
  assert.equal(commentTimeToMinutes('2小時前'), 120);
  assert.equal(commentTimeToMinutes('2小时前'), 120);
  assert.equal(commentTimeToMinutes('5天前'), 7200);
  assert.equal(commentTimeToMinutes('2週前'), 20160);
  assert.equal(commentTimeToMinutes('2周前'), 20160);
  assert.equal(commentTimeToMinutes('3個月前'), 129600);
  assert.equal(commentTimeToMinutes('3个月前'), 129600);
  assert.equal(commentTimeToMinutes('1年前'), 525600);
  // 无法识别 / 空串：按「最新」处理（上游返回 0）
  assert.equal(commentTimeToMinutes('剛剛'), 0);
  assert.equal(commentTimeToMinutes(''), 0);
});

test('sortVideoComments：最新 / 最早按距今分钟数升 / 降序', () => {
  const list: VideoComment[] = [
    makeComment('old', '3個月前', 1, 0),
    makeComment('new', '45分鐘前', 1, 0),
    makeComment('mid', '2天前', 1, 0)
  ];
  assert.deepEqual(names(sortVideoComments(list, COMMENT_SORT_LATEST)), ['new', 'mid', 'old']);
  assert.deepEqual(names(sortVideoComments(list, COMMENT_SORT_EARLIEST)), ['old', 'mid', 'new']);
});

test('sortVideoComments：回复最多 / 最多点赞 / 最多点踩', () => {
  const list: VideoComment[] = [
    makeComment('a', '1天前', 3, 1),
    makeComment('b', '1天前', 10, 0),
    makeComment('c', '1天前', 0, 7)
  ];
  assert.deepEqual(names(sortVideoComments(list, COMMENT_SORT_MOST_REPLY)), ['c', 'a', 'b']);
  assert.deepEqual(names(sortVideoComments(list, COMMENT_SORT_MOST_LIKES)), ['b', 'a', 'c']);
  assert.deepEqual(names(sortVideoComments(list, COMMENT_SORT_MOST_DISLIKES)), ['c', 'a', 'b']);
});

test('sortVideoComments：默认站点顺序不重排、不修改入参、同值保持原顺序', () => {
  const list: VideoComment[] = [
    makeComment('first', '2天前', 5, 0),
    makeComment('second', '2天前', 5, 0),
    makeComment('third', '2天前', 5, 0)
  ];
  const sorted: VideoComment[] = sortVideoComments(list, COMMENT_SORT_SITE);
  assert.deepEqual(names(sorted), ['first', 'second', 'third']);
  // 返回新数组（UI 需要整体重赋值触发刷新）
  assert.notEqual(sorted, list);
  // 同排序值稳定：不会打乱站点顺序
  assert.deepEqual(names(sortVideoComments(list, COMMENT_SORT_MOST_LIKES)),
    ['first', 'second', 'third']);
});

test('commentSortLabel：六种排序项文案', () => {
  assert.equal(commentSortLabel(COMMENT_SORT_SITE), '站点顺序');
  assert.equal(commentSortLabel(COMMENT_SORT_LATEST), '最新');
  assert.equal(commentSortLabel(COMMENT_SORT_EARLIEST), '最早');
  assert.equal(commentSortLabel(COMMENT_SORT_MOST_REPLY), '回复最多');
  assert.equal(commentSortLabel(COMMENT_SORT_MOST_LIKES), '最多点赞');
  assert.equal(commentSortLabel(COMMENT_SORT_MOST_DISLIKES), '最多点踩');
});

test('buildVideoShareText：标题 + 链接 + 来源署名（对齐 getHanimeShareText）', () => {
  assert.equal(
    buildVideoShareText('測試影片', '123456', 'https://hanime1.me/'),
    '測試影片\nhttps://hanime1.me/watch?v=123456\n- From Han1meViewer -'
  );
  // 标题为空时至少给出链接与署名，不产生空白首行
  assert.equal(
    buildVideoShareText('  ', '42', 'https://example.com'),
    'https://example.com/watch?v=42\n- From Han1meViewer -'
  );
});
