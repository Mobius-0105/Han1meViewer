/**
 * 评论区 JSON 解析器（纯 TypeScript，ArkTS 可编译）。
 *
 * 对应上游 Android `logic/Parser.kt` 的：
 *  - `parseComments`      ← `comments`        （首屏：{comments: "<html>"}）
 *  - `parseCommentsPage`  ← `commentsPage`    （{items_html, has_more, next_offset}）
 *  - `parseReplies`       ← `commentReply`    （{replies: "<html>"}）
 *  - `parsePostComment`   ← `postCommentResponse`
 *  - `parsePostReply`     ← `postReplyResponse`
 *  - `sortVideoComments`  ← `CommentScreen.sortComments`（客户端排序，见文件末尾）
 *  - `commentTimeToMinutes` ← `util/CommentUtils.kt parseTimeStrToMinutes`
 *
 * 站点 2025-11 改版后评论分批加载：首屏响应带 `#comment-scroll-sentinel`
 * （data-has-more / data-next-offset），之后按 offset 拉取；每条评论是完整的
 * `div.comment-item-block[data-comment-id]`。旧版"每 4 个兄弟节点一条评论"
 * 结构保留兼容解析。
 *
 * 子评论（loadReplies）是"基本信息 + 点赞表单"成对出现，按 2 个一组解析。
 *
 * 容错策略：JSON 非法/字段缺失时返回空评论列表，不抛异常（Android 里部分路径
 * 会抛 ParseException）；点赞数等未解析字段用 -1 表示"未知"。
 */

import {
  PostCommentResult,
  VideoComment,
  VideoCommentPost,
  VideoComments,
  emptyVideoComment
} from '../model/Models';
import { HtmlDocument, HtmlNode, parseHtml } from './HtmlDom';

/** 评论 HTML 片段里偶尔有相对地址（头像），用主站作为默认 baseUrl */
const COMMENT_BASE_URL: string = 'https://hanime1.me/';

function emptyVideoComments(): VideoComments {
  const comments: VideoComments = {
    comments: [],
    currentUserId: '',
    csrfToken: '',
    hasMoreComments: false,
    nextCommentOffset: -1
  };
  return comments;
}

function emptyPostCommentResult(): PostCommentResult {
  const result: PostCommentResult = {
    comment: null,
    commentCount: -1,
    parentCommentId: ''
  };
  return result;
}

// ----------------------------------------------------------------------
// JSON 字段工具（JSON.parse → Record<string, Object>，索引访问是 ArkTS 允许的）
// ----------------------------------------------------------------------

function parseJsonObject(json: string): Record<string, Object> | null {
  if (json === undefined || json === null || json.length === 0) {
    return null;
  }
  try {
    const parsed: Object = JSON.parse(json) as Object;
    if (parsed === null || typeof parsed !== 'object') {
      return null;
    }
    return parsed as Record<string, Object>;
  } catch (rawError) {
    // JSON 非法时返回 null，调用方给出空列表（避免评论区初始化崩溃）
    return null;
  }
}

function jsonString(obj: Record<string, Object>, key: string): string {
  const value: Object = obj[key];
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

function jsonNumber(obj: Record<string, Object>, key: string, fallback: number): number {
  const value: Object = obj[key];
  if (typeof value === 'number') {
    const num: number = value as number;
    return isNaN(num) ? fallback : Math.floor(num);
  }
  if (typeof value === 'string') {
    const parsed: number = parseInt(value as string, 10);
    return isNaN(parsed) ? fallback : parsed;
  }
  return fallback;
}

function jsonBoolean(obj: Record<string, Object>, key: string, fallback: boolean): boolean {
  const value: Object = obj[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  if (typeof value === 'number') {
    return (value as number) === 1;
  }
  if (typeof value === 'string') {
    const text: string = value as string;
    return text === '1' || text === 'true';
  }
  return fallback;
}

// ----------------------------------------------------------------------
// 小工具
// ----------------------------------------------------------------------

function attrOf(node: HtmlNode | null, name: string): string {
  return node !== null ? node.attr(name) : '';
}

function absOrRaw(node: HtmlNode | null, attrName: string): string {
  if (node === null) {
    return '';
  }
  const absolute: string = node.absUrl(attrName);
  if (absolute.length > 0) {
    return absolute;
  }
  return node.attr(attrName).trim();
}

function parseIntOr(raw: string, fallback: number): number {
  const value: string = raw.trim();
  if (value.length === 0) {
    return fallback;
  }
  const parsed: number = parseInt(value, 10);
  return isNaN(parsed) ? fallback : parsed;
}

/** 解析评论/回复所属的点赞表单（POST 数据） */
function parseCommentPost(scope: HtmlNode): VideoCommentPost {
  const post: VideoCommentPost = {
    foreignId: attrOf(scope.getElementById('foreign_id'), 'value').trim(),
    isPositive: attrOf(scope.getElementById('is_positive'), 'value') === '1',
    commentLikesCount: parseIntOr(
      attrOf(scope.selectFirst('input[name=comment-likes-count]'), 'value'), 0
    ),
    commentLikesSum: parseIntOr(
      attrOf(scope.selectFirst('input[name=comment-likes-sum]'), 'value'), 0
    ),
    likeCommentStatus: attrOf(
      scope.selectFirst('input[name=like-comment-status]'), 'value'
    ) === '1',
    unlikeCommentStatus: attrOf(
      scope.selectFirst('input[name=unlike-comment-status]'), 'value'
    ) === '1'
  };
  return post;
}

/** 点赞数：`#comment-like-form-wrapper` 里第二个带 style 的 span */
function parseThumbUp(likeWrapper: HtmlNode | null): number {
  if (likeWrapper === null) {
    return -1;
  }
  const spans: HtmlNode[] = likeWrapper.select('span[style]');
  if (spans.length < 2) {
    return -1;
  }
  return parseIntOr(spans[1].text().trim(), -1);
}

/** 举报相关属性 */
function parseReportInfo(scope: HtmlNode): string[] {
  const buttons: HtmlNode[] = scope.select('span.report-btn');
  const result: string[] = [];
  if (buttons.length === 0) {
    result.push('');
    result.push('');
    return result;
  }
  result.push(buttons[0].attr('data-reportable-id'));
  result.push(buttons[0].attr('data-reportable-type'));
  return result;
}

/**
 * 解析单个评论块 `div.comment-item-block`（新旧结构共用）。
 * 对应 Parser.kt `parseCommentBlock`。
 */
function parseCommentBlock(block: HtmlNode): VideoComment {
  const comment: VideoComment = emptyVideoComment();
  comment.avatar = absOrRaw(block.selectFirst('img'), 'src');

  const textNodes: HtmlNode[] = block.getElementsByClass('comment-index-text');
  const nameAndDate: HtmlNode | null = textNodes.length > 0 ? textNodes[0] : null;
  comment.username = nameAndDate !== null
    ? nameAndDate.selectFirst('a') !== null
      ? (nameAndDate.selectFirst('a') as HtmlNode).ownText().trim()
      : ''
    : '';
  comment.date = nameAndDate !== null
    ? nameAndDate.selectFirst('span') !== null
      ? (nameAndDate.selectFirst('span') as HtmlNode).ownText().trim()
      : ''
    : '';
  comment.content = textNodes.length > 1 ? textNodes[1].text() : '';

  comment.hasMoreReplies = block.selectFirst('div[class^=load-replies-btn]') !== null;
  comment.thumbUp = parseThumbUp(block.getElementById('comment-like-form-wrapper'));

  // 2025-11 改版：id 在 data-comment-id 上；旧版在 reply-section-wrapper-<id> 上
  let id: string = block.attr('data-comment-id').trim();
  if (id.length === 0) {
    const replySection: HtmlNode | null = block.selectFirst('div[id^=reply-section-wrapper]');
    if (replySection !== null) {
      const sectionId: string = replySection.id();
      const dash: number = sectionId.lastIndexOf('-');
      id = dash >= 0 ? sectionId.substring(dash + 1) : sectionId;
    }
  }
  comment.id = id;

  // 回复数：`查看 2 則回覆`
  const replyCountText: string = textOfFirst(block.select('div.load-replies-btn'));
  comment.replyCount = parseIntOr(firstNumber(replyCountText), 0);

  comment.post = parseCommentPost(block);
  const report: string[] = parseReportInfo(block);
  comment.reportableId = report[0];
  comment.reportableType = report[1];
  comment.isChildComment = false;
  comment.redirectUrl = '';
  return comment;
}

function textOfFirst(nodes: HtmlNode[]): string {
  return nodes.length > 0 ? nodes[0].text() : '';
}

function firstNumber(raw: string): string {
  const match: RegExpMatchArray | null = raw.match(/\d+/);
  return match !== null ? match[0] : '';
}

/**
 * 解析一条子评论（"基本信息 + 点赞表单"成对节点）。
 * 对应 Parser.kt `parseReplyPair`。
 */
function parseReplyPair(basic: HtmlNode, postScope: HtmlNode): VideoComment {
  const comment: VideoComment = emptyVideoComment();
  comment.avatar = absOrRaw(basic.selectFirst('img'), 'src');

  const textNodes: HtmlNode[] = basic.getElementsByClass('comment-index-text');
  const nameAndDate: HtmlNode | null = textNodes.length > 0 ? textNodes[0] : null;
  comment.username = nameAndDate !== null
    ? nameAndDate.selectFirst('a') !== null
      ? (nameAndDate.selectFirst('a') as HtmlNode).ownText().trim()
      : ''
    : '';
  comment.date = nameAndDate !== null
    ? nameAndDate.selectFirst('span') !== null
      ? (nameAndDate.selectFirst('span') as HtmlNode).ownText().trim()
      : ''
    : '';
  comment.content = textNodes.length > 1 ? textNodes[1].text() : '';

  const spans: HtmlNode[] = postScope.select('span[style]');
  comment.thumbUp = spans.length >= 2 ? parseIntOr(spans[1].text().trim(), -1) : -1;

  comment.id = '';
  comment.isChildComment = true;
  comment.hasMoreReplies = false;
  comment.replyCount = 0;
  comment.post = parseCommentPost(postScope);
  const report: string[] = parseReportInfo(basic);
  comment.reportableId = report[0];
  comment.reportableType = report[1];
  comment.redirectUrl = '';
  return comment;
}

/**
 * 首屏评论解析（`loadComment?type=video&id=...` 的响应）。
 * JSON 形态：`{ "comments": "<html>", "content": ... }`。
 */
export function parseComments(json: string): VideoComments {
  const result: VideoComments = emptyVideoComments();
  const obj: Record<string, Object> | null = parseJsonObject(json);
  if (obj === null) {
    return result;
  }
  const doc: HtmlDocument = parseHtml(jsonString(obj, 'comments'), COMMENT_BASE_URL);
  const body: HtmlNode = doc.body();
  result.csrfToken = attrOf(body.selectFirst('input[name=_token]'), 'value').trim();
  result.currentUserId = attrOf(body.selectFirst('input[name=comment-user-id]'), 'value').trim();

  const root: HtmlNode | null = body.getElementById('comment-start');
  if (root === null) {
    return result;
  }

  const blocks: HtmlNode[] = root.getElementsByClass('comment-item-block');
  if (blocks.length > 0) {
    for (let i: number = 0; i < blocks.length; i++) {
      result.comments.push(parseCommentBlock(blocks[i]));
    }
  } else {
    // 兼容旧版结构：每 4 个兄弟节点为一条评论，合成为一个虚拟 div 再解析
    const children: HtmlNode[] = root.children();
    for (let i: number = 0; i < children.length; i += 4) {
      const wrapper: HtmlNode = new HtmlNode('div');
      for (let j: number = 0; j < 4 && i + j < children.length; j++) {
        wrapper.appendChild(children[i + j]);
      }
      result.comments.push(parseCommentBlock(wrapper));
    }
  }

  const sentinel: HtmlNode | null = body.getElementById('comment-scroll-sentinel');
  const hasMore: boolean = attrOf(sentinel, 'data-has-more') === '1';
  result.hasMoreComments = hasMore;
  // UI 约定：nextCommentOffset 为 -1 表示"没有下一页"；站点在 has_more=0 时
  // 仍会带一个无意义的 data-next-offset（真实快照里是 11），这里统一归一为 -1。
  result.nextCommentOffset = hasMore
    ? parseIntOr(attrOf(sentinel, 'data-next-offset'), -1)
    : -1;
  return result;
}

/**
 * 分批评论页解析（`loadComment?...&offset=N` 的响应）。
 * JSON 形态：`{ "items_html": "<div class=comment-item-block>…", "has_more": bool,
 * "next_offset": int }`。
 */
export function parseCommentsPage(json: string): VideoComments {
  const result: VideoComments = emptyVideoComments();
  const obj: Record<string, Object> | null = parseJsonObject(json);
  if (obj === null) {
    return result;
  }
  const doc: HtmlDocument = parseHtml(jsonString(obj, 'items_html'), COMMENT_BASE_URL);
  const blocks: HtmlNode[] = doc.body().getElementsByClass('comment-item-block');
  for (let i: number = 0; i < blocks.length; i++) {
    result.comments.push(parseCommentBlock(blocks[i]));
  }
  const hasMore: boolean = jsonBoolean(obj, 'has_more', false);
  result.hasMoreComments = hasMore;
  // 同 parseComments：has_more=false 时 next_offset 没有意义，归一为 -1
  result.nextCommentOffset = hasMore ? jsonNumber(obj, 'next_offset', -1) : -1;
  return result;
}

/**
 * 子评论列表解析（`loadReplies?id=commentId` 的响应）。
 * JSON 形态：`{ "comment_id": "...", "replies": "<html>" }`；
 * replies 里是"基本信息 + 点赞表单"成对节点。
 */
export function parseReplies(json: string): VideoComments {
  const result: VideoComments = emptyVideoComments();
  const obj: Record<string, Object> | null = parseJsonObject(json);
  if (obj === null) {
    return result;
  }
  const doc: HtmlDocument = parseHtml(jsonString(obj, 'replies'), COMMENT_BASE_URL);
  const replyStart: HtmlNode | null = doc.body().selectFirst('div[id^=reply-start]');
  if (replyStart === null) {
    return result;
  }
  const children: HtmlNode[] = replyStart.children();
  for (let i: number = 0; i + 1 < children.length; i += 2) {
    result.comments.push(parseReplyPair(children[i], children[i + 1]));
  }
  return result;
}

/**
 * 发表评论的响应解析：`{ "single_video_comment": "<div class=comment-item-block>…",
 * "comment_count": N }`。解析失败返回 `{comment: null, commentCount: -1}`，
 * 上层据此退回"重新拉取列表"逻辑。
 */
export function parsePostComment(json: string): PostCommentResult {
  const result: PostCommentResult = emptyPostCommentResult();
  const obj: Record<string, Object> | null = parseJsonObject(json);
  if (obj === null) {
    return result;
  }
  result.commentCount = jsonNumber(obj, 'comment_count', -1);
  try {
    const doc: HtmlDocument = parseHtml(
      jsonString(obj, 'single_video_comment'), COMMENT_BASE_URL
    );
    const block: HtmlNode | null = doc.body().selectFirst('.comment-item-block');
    if (block !== null) {
      result.comment = parseCommentBlock(block);
    }
  } catch (rawError) {
    // 响应结构异常：保留 comment=null，上层退回"刷新列表"逻辑
    result.comment = null;
  }
  return result;
}

/**
 * 发表回复的响应解析：`{ "comment_id": "父评论 id",
 * "single_video_comment": "<成对回复节点>" }`。
 */
export function parsePostReply(json: string): PostCommentResult {
  const result: PostCommentResult = emptyPostCommentResult();
  const obj: Record<string, Object> | null = parseJsonObject(json);
  if (obj === null) {
    return result;
  }
  result.parentCommentId = jsonString(obj, 'comment_id').trim();
  try {
    const doc: HtmlDocument = parseHtml(
      jsonString(obj, 'single_video_comment'), COMMENT_BASE_URL
    );
    const children: HtmlNode[] = doc.body().children();
    if (children.length > 1) {
      result.comment = parseReplyPair(children[0], children[1]);
    } else if (children.length === 1) {
      // 少数情况下响应只包含"基本信息"节点，仍尝试解析（点赞字段留空）
      result.comment = parseReplyPair(children[0], children[0]);
    }
  } catch (rawError) {
    // 响应结构异常：保留 comment=null，上层退回刷新
    result.comment = null;
  }
  return result;
}

// ----------------------------------------------------------------------
// 评论排序（对齐上游 ui/screen/video/CommentSortType.kt + CommentScreen.sortComments）
//
// 上游是「客户端排序」：切换排序只对已加载的列表重新排序，不重新请求站点。
//  - LATEST        : parseTimeStrToMinutes(date) 升序（距今分钟数越小越新）
//  - EARLIEST      : parseTimeStrToMinutes(date) 降序
//  - MOST_REPLY    : replyCount 降序
//  - MOST_LIKES    : realLikesCount(thumbUp) 降序
//  - MOST_DISLIKES : realLikesCount(thumbUp) 升序
// 站点默认顺序（服务端返回顺序）在上游没有独立枚举项，这里额外提供 site 选项作为
// 默认值：选中时不重排，保证进入页面看到的顺序与站点完全一致。
// 子回复（上游 ChildCommentScreen）同样在客户端排序，因此本函数对主评论 / 回复通用。
// ----------------------------------------------------------------------

/** 站点原始顺序（默认；不重排，保持 loadComment / loadReplies 返回顺序） */
export const COMMENT_SORT_SITE: string = 'site';
/** 最新（对齐 CommentSortType.LATEST） */
export const COMMENT_SORT_LATEST: string = 'latest';
/** 最早（对齐 CommentSortType.EARLIEST） */
export const COMMENT_SORT_EARLIEST: string = 'earliest';
/** 回复最多（对齐 CommentSortType.MOST_REPLY） */
export const COMMENT_SORT_MOST_REPLY: string = 'mostReply';
/** 最多点赞（对齐 CommentSortType.MOST_LIKES） */
export const COMMENT_SORT_MOST_LIKES: string = 'mostLikes';
/** 最少点赞 / 最多点踩（对齐 CommentSortType.MOST_DISLIKES） */
export const COMMENT_SORT_MOST_DISLIKES: string = 'mostDislikes';

/** 排序文案（与上游 strings.xml 的 sort_by_newest 等一一对应） */
export function commentSortLabel(type: string): string {
  if (type === COMMENT_SORT_LATEST) {
    return '最新';
  }
  if (type === COMMENT_SORT_EARLIEST) {
    return '最早';
  }
  if (type === COMMENT_SORT_MOST_REPLY) {
    return '回复最多';
  }
  if (type === COMMENT_SORT_MOST_LIKES) {
    return '最多点赞';
  }
  if (type === COMMENT_SORT_MOST_DISLIKES) {
    return '最多点踩';
  }
  return '站点顺序';
}

/**
 * 站点相对时间文本 → 距今分钟数。
 * 对齐上游 `util/CommentUtils.kt parseTimeStrToMinutes`，并同时兼容繁体 / 简体单位
 * （站点会随语言返回「3個月前」「3个月前」两种文案）；无法识别时返回 0（视为最新）。
 */
export function commentTimeToMinutes(date: string): number {
  const text: string = date.trim();
  if (text.length === 0) {
    return 0;
  }
  const match: RegExpMatchArray | null =
    text.match(/(\d+)\s*(分鐘|分钟|小時|小时|天|週|周|個月|个月|年)前/);
  if (match === null) {
    return 0;
  }
  const amount: number = parseInt(match[1], 10);
  if (isNaN(amount)) {
    return 0;
  }
  const unit: string = match[2];
  if (unit === '分鐘' || unit === '分钟') {
    return amount;
  }
  if (unit === '小時' || unit === '小时') {
    return amount * 60;
  }
  if (unit === '天') {
    return amount * 60 * 24;
  }
  if (unit === '週' || unit === '周') {
    return amount * 60 * 24 * 7;
  }
  if (unit === '個月' || unit === '个月') {
    return amount * 60 * 24 * 30;
  }
  return amount * 60 * 24 * 365;
}

/**
 * 对已加载评论做客户端排序（对齐上游 CommentScreen.sortComments）。
 *
 * 返回新数组、不修改入参；同排序值保持站点原始顺序（Array.sort 稳定排序），
 * 主评论与子回复共用。
 */
export function sortVideoComments(comments: VideoComment[], type: string): VideoComment[] {
  const sorted: VideoComment[] = comments.slice();
  if (type === COMMENT_SORT_LATEST) {
    sorted.sort((a: VideoComment, b: VideoComment): number => {
      return commentTimeToMinutes(a.date) - commentTimeToMinutes(b.date);
    });
    return sorted;
  }
  if (type === COMMENT_SORT_EARLIEST) {
    sorted.sort((a: VideoComment, b: VideoComment): number => {
      return commentTimeToMinutes(b.date) - commentTimeToMinutes(a.date);
    });
    return sorted;
  }
  if (type === COMMENT_SORT_MOST_REPLY) {
    sorted.sort((a: VideoComment, b: VideoComment): number => {
      return b.replyCount - a.replyCount;
    });
    return sorted;
  }
  if (type === COMMENT_SORT_MOST_LIKES) {
    sorted.sort((a: VideoComment, b: VideoComment): number => {
      return b.thumbUp - a.thumbUp;
    });
    return sorted;
  }
  if (type === COMMENT_SORT_MOST_DISLIKES) {
    sorted.sort((a: VideoComment, b: VideoComment): number => {
      return a.thumbUp - b.thumbUp;
    });
    return sorted;
  }
  // 站点顺序 / 未知排序值：不重排
  return sorted;
}
