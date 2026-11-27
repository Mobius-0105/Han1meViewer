/**
 * 评论区解析测试。
 *
 *  - comments.json / comments_page.json / replies.json：真实站点 API 响应
 *    （javchu.com，2026-02 抓取；登录态为未登录）；
 *  - comments_page_items.json / post_comment.json / post_reply.json：SYNTHETIC，
 *    用真实评论块 + 手写的假分页/假回复节点，覆盖真实响应拿不到的分支。
 */

import { test } from 'node:test';
import * as assert from 'node:assert/strict';

import {
  parseComments,
  parseCommentsPage,
  parsePostComment,
  parsePostReply,
  parseReplies
} from '../../entry/src/main/ets/core/parser/CommentParser';
import {
  PostCommentResult,
  VideoComment,
  VideoComments
} from '../../entry/src/main/ets/core/model/Models';
import { readFixture } from './fixtures';

test('首屏评论（真实）：数量 / 首条字段 / 点赞数 / 回复数 / 举报 id', () => {
  const page: VideoComments = parseComments(readFixture('comments.json'));
  assert.equal(page.comments.length, 11);
  // 未登录：没有 comment-user-id / _token 输入框
  assert.equal(page.currentUserId, '');
  assert.equal(page.csrfToken, '');
  // 真实响应 sentinel: data-has-more=0（虽然 data-next-offset=11）
  assert.equal(page.hasMoreComments, false);
  assert.equal(page.nextCommentOffset, -1);

  const first: VideoComment = page.comments[0];
  assert.equal(first.id, '493824');
  assert.equal(first.username, '无敌艾露猫');
  assert.equal(first.date, '3個月前');
  assert.equal(first.content, '实测这个站点梯子挂🇯🇵可以看');
  assert.equal(first.thumbUp, 5);
  assert.equal(first.hasMoreReplies, true);
  assert.equal(first.replyCount, 2);
  assert.equal(first.isChildComment, false);
  assert.equal(first.avatar.startsWith('https://'), true);
  assert.equal(first.reportableId, '493824');
  assert.equal(first.reportableType, 'comment');
  // 未登录时没有 foreign_id / is_positive 表单
  assert.equal(first.post.foreignId, '');
  assert.equal(first.post.isPositive, false);
});

test('首屏评论（真实）：所有评论 id 唯一、子评论标记为 false', () => {
  const page: VideoComments = parseComments(readFixture('comments.json'));
  const ids: string[] = page.comments.map((comment: VideoComment): string => comment.id);
  assert.equal(new Set(ids).size, 11);
  for (let i: number = 0; i < page.comments.length; i++) {
    assert.equal(page.comments[i].isChildComment, false);
    assert.equal(page.comments[i].username.length > 0, true);
    assert.equal(page.comments[i].content.length > 0, true);
  }
  // 有回复的评论数量与真实页面一致（6 条）
  const withReplies: number = page.comments.filter(
    (comment: VideoComment): boolean => comment.hasMoreReplies
  ).length;
  assert.equal(withReplies, 6);
});

test('评论点赞数：display:none 的 0 也能解析，-1 原样保留', () => {
  const page: VideoComments = parseComments(readFixture('comments.json'));
  const zero: VideoComment | undefined = page.comments.find(
    (comment: VideoComment): boolean => comment.id === '607816'
  );
  assert.notEqual(zero, undefined);
  assert.equal(zero?.thumbUp, 0);

  const negative: VideoComment | undefined = page.comments.find(
    (comment: VideoComment): boolean => comment.id === '419060'
  );
  assert.notEqual(negative, undefined);
  assert.equal(negative?.thumbUp, -1);
  assert.equal(negative?.replyCount, 4);
});

test('分批评论页（真实响应：items_html 为空）', () => {
  const page: VideoComments = parseCommentsPage(readFixture('comments_page.json'));
  assert.equal(page.comments.length, 0);
  assert.equal(page.hasMoreComments, false);
  assert.equal(page.nextCommentOffset, -1);
});

test('分批评论页（SYNTHETIC：items_html 非空 + has_more/next_offset）', () => {
  const page: VideoComments = parseCommentsPage(readFixture('comments_page_items.json'));
  assert.equal(page.comments.length, 2);
  assert.equal(page.hasMoreComments, true);
  assert.equal(page.nextCommentOffset, 111);
  assert.equal(page.comments[0].id, '493824');
  assert.equal(page.comments[0].username, '无敌艾露猫');
  assert.equal(page.comments[1].id.length > 0, true);
});

test('子评论（真实 loadReplies 响应）：成对节点解析', () => {
  const page: VideoComments = parseReplies(readFixture('replies.json'));
  assert.equal(page.comments.length, 2);
  const first: VideoComment = page.comments[0];
  assert.equal(first.username, '溪默');
  assert.equal(first.date, '3個月前');
  assert.equal(first.content, '我去神了！');
  assert.equal(first.isChildComment, true);
  assert.equal(first.id, '');
  assert.equal(first.hasMoreReplies, false);
  assert.equal(first.thumbUp, 0);
  assert.equal(first.reportableId, '247287');
  assert.equal(first.reportableType, 'reply');
  assert.equal(first.avatar.startsWith('https://'), true);
});

test('发表评论响应（SYNTHETIC）：新评论 + 新评论总数', () => {
  const result: PostCommentResult = parsePostComment(readFixture('post_comment.json'));
  assert.equal(result.commentCount, 12);
  assert.equal(result.parentCommentId, '');
  assert.notEqual(result.comment, null);
  if (result.comment !== null) {
    assert.equal(result.comment.id, '493824');
    assert.equal(result.comment.username, '无敌艾露猫');
    assert.equal(result.comment.thumbUp, 5);
    assert.equal(result.comment.isChildComment, false);
  }
});

test('发表回复响应（SYNTHETIC）：父评论 id + 回复节点 + 点赞表单', () => {
  const result: PostCommentResult = parsePostReply(readFixture('post_reply.json'));
  assert.equal(result.parentCommentId, '493824');
  assert.equal(result.commentCount, -1);
  assert.notEqual(result.comment, null);
  if (result.comment === null) {
    return;
  }
  const reply: VideoComment = result.comment;
  assert.equal(reply.username, '回覆者甲');
  assert.equal(reply.content, '這是合成回覆內容');
  assert.equal(reply.isChildComment, true);
  assert.equal(reply.thumbUp, 7);
  assert.equal(reply.reportableId, '247287');
  assert.equal(reply.post.foreignId, '493824');
  assert.equal(reply.post.isPositive, true);
  assert.equal(reply.post.commentLikesCount, 7);
  assert.equal(reply.post.commentLikesSum, 3);
  assert.equal(reply.post.likeCommentStatus, true);
  assert.equal(reply.post.unlikeCommentStatus, false);
});

test('旧版评论结构（SYNTHETIC）：每 4 个兄弟节点一条评论的兼容解析', () => {
  const page: VideoComments = parseComments(readFixture('comments_legacy.json'));
  assert.equal(page.comments.length, 2);
  assert.equal(page.comments[0].username, '舊版用戶');
  assert.equal(page.comments[0].date, '2個月前');
  assert.equal(page.comments[0].content, '舊版結構的評論內容');
  assert.equal(page.comments[0].thumbUp, 9);
  assert.equal(page.comments[0].avatar.startsWith('https://'), true);
  // 旧版结构没有 data-comment-id / reply-section-wrapper，id 为空串
  assert.equal(page.comments[0].id, '');
  assert.equal(page.comments[1].username, '第二位用戶');
  assert.equal(page.comments[1].thumbUp, 3);
  assert.equal(page.hasMoreComments, false);
  assert.equal(page.nextCommentOffset, -1);
});

test('非法 JSON / 空响应：返回空结果且不抛异常', () => {
  assert.equal(parseComments('not-json').comments.length, 0);
  assert.equal(parseComments('').comments.length, 0);
  assert.equal(parseComments('{"comments":"<div>no comment</div>"}').comments.length, 0);
  assert.equal(parseCommentsPage('{}').comments.length, 0);
  assert.equal(parseCommentsPage('{}').nextCommentOffset, -1);
  assert.equal(parseReplies('{"replies":"<div></div>"}').comments.length, 0);
  const post: PostCommentResult = parsePostComment('{}');
  assert.equal(post.comment, null);
  assert.equal(post.commentCount, -1);
  assert.equal(parsePostReply('{}').parentCommentId, '');
});
