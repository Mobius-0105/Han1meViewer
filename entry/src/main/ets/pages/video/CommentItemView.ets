/**
 * 单条评论（含子回复）。
 *
 * 两个交互是本组件自包含的，避免父组件按评论维护多份状态：
 *  - 子回复加载：自己调 api.getReplies；**默认自动加载一次并展开前 2 条**（不再默认折叠全部），
 *    超出部分显示「查看更多回复（N）」，点击后展开全部已加载回复；子回复同样按父页面传入的
 *    sortType 客户端排序（对齐上游 ChildCommentScreen 对子评论的排序）；
 *  - 点赞：自己调 api.likeComment，成功后用 onLikeApplied 把新对象交回父组件
 *    （父组件整体替换数组，@Prop comment 更新后本组件随之刷新）；子回复点赞同样调
 *    api.likeComment（foreign_type='reply'，对齐上游 likeChildComment），乐观更新 + 失败回滚。
 *
 * 卡片视觉与设置页分组卡一致：cardBg 纯色 + 1vp glassBorder + 圆角 Dimens.listRadius(12)，
 * 无阴影、无背景模糊；回复子卡片用浅一档 surfaceVariant 底 + 同款描边。
 *
 * 「回复」按钮交给父组件 CommentSection：回复与发评论共用底部输入框；
 * 「举报」只对他人评论展示（按登录用户名判断），点击后由父组件弹理由选择并提交站点表单。
 */

import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { describeError } from '../../logic/net/Errors';
import {
  VideoComment,
  VideoComments,
  emptyVideoComment
} from '../../core/model/Models';
import {
  COMMENT_SORT_SITE,
  sortVideoComments
} from '../../core/parser/CommentParser';
import {
  applyCommentLike,
  commentKey
} from '../../viewmodel/video/VideoUiUtils';
import { InlineLoadingRow } from './StateViews';

const api: HanimeApi = HanimeApi.getInstance();

/** 默认自动展开的子回复条数：先展示前 2 条，其余折叠到「查看更多回复（N）」 */
const REPLY_PREVIEW_COUNT: number = 2;

/**
 * 子回复自动加载队列：首屏每条主评论都会自动拉一次回复，
 * 串行执行避免一口气并发几十个请求把站点打限流（只影响加载时机，不影响展示策略）。
 */
let replyAutoLoadChain: Promise<void> = Promise.resolve();

function enqueueReplyAutoLoad(task: () => Promise<void>): void {
  replyAutoLoadChain = replyAutoLoadChain.then((): Promise<void> => task()).catch((): void => {
  });
}

@Component
export struct CommentItemView {
  @Prop @Watch('onCommentChanged') comment: VideoComment = emptyVideoComment();
  /** 发表评论/回复所需的 CSRF token（未登录时为空串）——用 @Prop 保证登录后父组件刷新时同步更新 */
  @Prop token: string = '';
  @Prop loggedIn: boolean = false;
  /**
   * 评论排序（与 VideoPage 排序胶囊 / CommentSection 共用 AppStorage['commentSortType']）：
   * 子回复按同一规则客户端排序（默认站点顺序）。用 @StorageProp 是为了在 ForEach
   * 复用已渲染项（不会重新执行 itemGenerator）时也能响应排序切换。
   */
  @StorageProp('commentSortType') sortType: string = COMMENT_SORT_SITE;
  /** 点赞成功：把更新后的评论对象交回父组件替换 */
  onLikeApplied: (updated: VideoComment) => void = () => {
  };
  onReply: (comment: VideoComment) => void = () => {
  };
  onReport: (comment: VideoComment) => void = () => {
  };
  @StorageLink('themeMode') themeMode: string = 'system';
  /** 当前登录用户名：用于判断「他人评论」（站点评论块没有作者 id，只能按用户名近似判断） */
  @StorageProp('username') accountUsername: string = '';
  @State replyList: VideoComment[] = [];
  /** true = 展开全部已加载回复；false = 默认只展示前 REPLY_PREVIEW_COUNT 条 */
  @State replyExpanded: boolean = false;
  @State replyLoading: boolean = false;
  @State replyError: string = '';
  /** 是否已成功加载过一次子回复（自动 / 手动都算） */
  @State repliesLoaded: boolean = false;
  @State likeBusy: boolean = false;
  /** 子回复点赞请求在途（防连点；乐观更新已在点击时生效） */
  @State replyLikeBusy: boolean = false;
  private lastReplyCount: number = 0;
  private disposed: boolean = false;

  aboutToAppear(): void {
    this.lastReplyCount = this.comment.replyCount;
    // 默认展开策略：有子回复（或站点提示还有更多回复）时首屏自动加载一次，加载完直接展示前 2 条
    if (this.hasRepliesHint()) {
      this.requestReplies(true);
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** 是否有子回复需要展示：replyCount 或「还有更多回复」标记任一存在 */
  hasRepliesHint(): boolean {
    return this.comment.replyCount > 0 || this.comment.hasMoreReplies;
  }

  /** 父组件替换评论（例如回复成功后 replyCount +1）时刷新已加载的回复 */
  onCommentChanged(): void {
    if (this.comment.replyCount === this.lastReplyCount) {
      return;
    }
    this.lastReplyCount = this.comment.replyCount;
    if (this.repliesLoaded || this.replyExpanded) {
      this.requestReplies(false);
      return;
    }
    // 之前没有回复（未自动加载），现在有了：补一次加载，保证默认展开策略不落空
    if (this.hasRepliesHint()) {
      this.requestReplies(true);
    }
  }

  /** 首屏自动加载走串行队列（避免几十条评论同时请求）；用户主动展开时立即加载 */
  requestReplies(auto: boolean): void {
    if (auto) {
      enqueueReplyAutoLoad((): Promise<void> => this.loadReplies());
      return;
    }
    this.loadReplies();
  }

  async loadReplies(): Promise<void> {
    if (this.disposed || this.replyLoading) {
      return;
    }
    const replyId: string = this.replyId();
    if (replyId.length === 0) {
      this.replyError = '缺少评论 id，可能需要在网页端登录后再查看回复';
      return;
    }
    this.replyLoading = true;
    this.replyError = '';
    try {
      const page: VideoComments = await api.getReplies(replyId);
      if (this.disposed) {
        this.replyLoading = false;
        return;
      }
      this.replyList = page.comments;
      this.repliesLoaded = true;
      this.lastReplyCount = this.comment.replyCount;
    } catch (e) {
      if (!this.disposed) {
        this.replyError = describeError(e as Error);
      }
    }
    this.replyLoading = false;
  }

  /** 是否显示子回复区：默认展开（有回复提示 / 已加载 / 加载中 / 出错都显示） */
  showRepliesSection(): boolean {
    return this.hasRepliesHint() || this.repliesLoaded || this.replyLoading ||
      this.replyError.length > 0 || this.replyList.length > 0;
  }

  /** 子回复按父页面排序规则重排（对齐上游 ChildCommentScreen 对子评论的客户端排序） */
  sortedReplies(): VideoComment[] {
    return sortVideoComments(this.replyList, this.sortType);
  }

  /** 当前展示的回复：按 sortType 排序后，折叠时只展示前 REPLY_PREVIEW_COUNT 条 */
  visibleReplies(): VideoComment[] {
    const sorted: VideoComment[] = this.sortedReplies();
    if (this.replyExpanded) {
      return sorted;
    }
    return sorted.slice(0, REPLY_PREVIEW_COUNT);
  }

  /**
   * 是否本人评论：站点评论块没有解析作者 id（只有用户名），
   * 因此用「登录用户名 == 评论作者名」近似判断；登录名为空时一律视为他人。
   */
  isOwnComment(comment: VideoComment): boolean {
    const self: string = this.accountUsername.trim();
    if (self.length === 0) {
      return false;
    }
    return comment.username.trim() === self;
  }

  /** 是否展示「举报」：站点给了 reportableId 且不是本人评论（对齐上游只举报他人评论） */
  canReport(comment: VideoComment): boolean {
    return comment.reportableId.length > 0 && !this.isOwnComment(comment);
  }

  /** 子回复的稳定标识（用于点赞失败回滚时定位同一条回复） */
  replyIdentity(reply: VideoComment): string {
    if (reply.post.foreignId.length > 0) {
      return 'f:' + reply.post.foreignId;
    }
    return 'k:' + reply.username + '|' + reply.date + '|' + reply.content;
  }

  /** 折叠时还有多少条没展示（站点 replyCount 可能大于已加载条数，取较大值） */
  hiddenReplyCount(): number {
    let total: number = this.replyList.length;
    if (this.comment.replyCount > total) {
      total = this.comment.replyCount;
    }
    const hidden: number = total - REPLY_PREVIEW_COUNT;
    return hidden > 0 ? hidden : 0;
  }

  /** 点击「查看更多回复（N）」：展开全部；站点回复数大于已加载数时补拉一次 */
  expandReplies(): void {
    this.replyExpanded = true;
    if (this.comment.replyCount > this.replyList.length && !this.replyLoading) {
      this.loadReplies();
    }
  }

  collapseReplies(): void {
    this.replyExpanded = false;
  }

  /** 站点回复接口需要的评论 id；未登录时 id 可能是 -1，退回 post.foreignId */
  replyId(): string {
    if (this.comment.id.length > 0 && this.comment.id !== '-1') {
      return this.comment.id;
    }
    return this.comment.post.foreignId;
  }

  async toggleLike(): Promise<void> {
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    if (this.likeBusy) {
      return;
    }
    const post = this.comment.post;
    if (post.foreignId.length === 0) {
      Toast.show('该评论暂不支持点赞');
      return;
    }
    this.likeBusy = true;
    const wasLiked: boolean = post.likeCommentStatus;
    try {
      // type = 'comment'（主评论）；子评论站点用 'reply'
      await api.likeComment(this.token, 'comment', post.foreignId, true,
        post.commentLikesCount, post.commentLikesSum,
        post.likeCommentStatus, post.unlikeCommentStatus);
      const updated: VideoComment = applyCommentLike(this.comment, !wasLiked);
      this.onLikeApplied(updated);
      Toast.show(wasLiked ? '已取消点赞' : '已点赞');
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
    this.likeBusy = false;
  }

  /**
   * 子回复点赞 / 取消点赞（对齐上游 CommentViewModel.likeChildComment）：
   * 与主评论同一个 `/commentLike` 接口，foreign_type = 'reply'、目标 id 用回复的 post.foreignId；
   * 点击后**先乐观更新**回复计数与按钮状态，接口失败再回滚并提示（对齐任务要求的乐观更新 + 失败回滚）。
   */
  async toggleReplyLike(reply: VideoComment): Promise<void> {
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    if (this.replyLikeBusy) {
      return;
    }
    const post = reply.post;
    // 目标 id：优先用点赞表单里的 foreign_id（上游 likeChildComment 同款）；
    // 未登录 / 站点改版导致表单缺失时退回 data-reportable-id（回复自身的 id），
    // 保证「目标 id 用回复 id」而不是父评论 id。
    let targetId: string = post.foreignId;
    if (targetId.length === 0) {
      targetId = reply.reportableId;
    }
    if (targetId.length === 0) {
      Toast.show('该回复暂不支持点赞');
      return;
    }
    const identity: string = this.replyIdentity(reply);
    const prevReply: VideoComment = reply;
    const wasLiked: boolean = post.likeCommentStatus;
    this.replyLikeBusy = true;
    // 乐观更新：立即改本地回复列表（整体重赋值触发刷新）
    this.replyList = this.replyList.map((item: VideoComment): VideoComment => {
      return this.replyIdentity(item) === identity ? applyCommentLike(item, !wasLiked) : item;
    });
    try {
      await api.likeComment(this.token, 'reply', targetId, true,
        post.commentLikesCount, post.commentLikesSum,
        post.likeCommentStatus, post.unlikeCommentStatus);
      if (!this.disposed) {
        Toast.show(wasLiked ? '已取消点赞' : '已点赞');
      }
    } catch (e) {
      if (!this.disposed) {
        // 失败回滚：按稳定标识把该条回复恢复成点击前的对象
        this.replyList = this.replyList.map((item: VideoComment): VideoComment => {
          return this.replyIdentity(item) === identity ? prevReply : item;
        });
        Toast.show(describeError(e as Error));
      }
    }
    this.replyLikeBusy = false;
  }

  /**
   * 子回复区（默认展开）：先展示前 REPLY_PREVIEW_COUNT 条；
   * 折叠状态下多余回复折叠成「查看更多回复（N）」，点击展开全部（必要时补拉），展开后可收起。
   */
  @Builder
  repliesSection() {
    Column() {
      if (this.replyLoading && this.replyList.length === 0) {
        InlineLoadingRow({ text: '加载回复…' });
      } else if (this.replyError.length > 0 && this.replyList.length === 0) {
        Row() {
          Text(this.replyError)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().error)
            .layoutWeight(1)
            .maxLines(3);
          Text('重试')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().primary)
            .margin({ left: 8 })
            .onClick(() => {
              this.loadReplies();
            });
        }
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 8 });
      } else if (this.replyList.length === 0) {
        if (this.hasRepliesHint()) {
          Text('暂无回复')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .width('100%')
            .padding({ left: 8, top: 8, bottom: 8 });
        }
      } else {
        ForEach(this.visibleReplies(), (reply: VideoComment) => {
          this.replyRow(reply);
        }, (reply: VideoComment) => commentKey(reply));
        if (this.replyLoading) {
          InlineLoadingRow({ text: '加载回复…' });
        } else if (!this.replyExpanded && this.hiddenReplyCount() > 0) {
          Text('查看更多回复（' + this.hiddenReplyCount() + '）')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().primary)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.expandReplies();
            });
        } else if (this.replyExpanded && this.replyList.length > REPLY_PREVIEW_COUNT) {
          Text('收起回复')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
            .onClick(() => {
              this.collapseReplies();
            });
        }
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .margin({ top: 8 })
    .padding({ left: 6, right: 6, top: 4, bottom: 4 })
    .borderRadius(10)
    // 回复子卡片：内嵌浅一档背景 + 同款 1vp 描边（与设置卡一致，无阴影无模糊）
    .backgroundColor(Theme.colors().surfaceVariant)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
  }

  /** 回复行：内嵌在浅一档回复卡片里，不再用左侧竖线 */
  @Builder
  replyRow(reply: VideoComment) {
    Row() {
      Image(reply.avatar)
        .width(24)
        .height(24)
        .borderRadius(12)
        .objectFit(ImageFit.Cover)
        .backgroundColor(Theme.colors().surfaceVariant)
        .border({ width: 1, color: Theme.colors().glassBorder });
      Column() {
        Row() {
          Text(reply.username)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textSecondary)
            .maxLines(1)
            .layoutWeight(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
          Text(reply.date)
            .fontSize(10)
            .fontColor(Theme.colors().textHint)
            .margin({ left: 8 })
            .maxLines(1);
        }
        .width('100%');

        Text(reply.content)
          .fontSize(Dimens.captionSize + 1)
          .lineHeight(18)
          .fontColor(Theme.colors().textPrimary)
          .margin({ top: 3 })
          .width('100%')
          .maxLines(20)
          .textOverflow({ overflow: TextOverflow.Ellipsis });

        // 子回复操作行：点赞（与主评论同一个 /commentLike 接口，foreign_type='reply'）+ 举报他人回复
        Row() {
          Row() {
            Text('👍')
              .fontSize(10);
            Text(reply.thumbUp >= 0 ? '' + reply.thumbUp : '赞')
              .fontSize(10)
              .fontColor(reply.post.likeCommentStatus ? Theme.colors().primary : Theme.colors().textHint)
              .margin({ left: 3 });
          }
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .borderRadius(10)
          .backgroundColor(reply.post.likeCommentStatus ?
            Theme.colors().primaryContainer : Theme.colors().chipTint)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .opacity(this.replyLikeBusy ? 0.65 : 1)
          .onClick(() => {
            if (!this.replyLikeBusy) {
              this.toggleReplyLike(reply);
            }
          });

          if (this.canReport(reply)) {
            Text('举报')
              .fontSize(10)
              .fontColor(Theme.colors().textSecondary)
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .borderRadius(10)
              .backgroundColor(Theme.colors().chipTint)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .margin({ left: 6 })
              .onClick(() => {
                this.onReport(reply);
              });
          }
        }
        .width('100%')
        .margin({ top: 5 })
        .alignItems(VerticalAlign.Center);
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 8 });
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ left: 6, right: 6, top: 6, bottom: 6 });
  }

  build() {
    Column() {
      Column() {
        Row() {
          Image(this.comment.avatar)
            .width(32)
            .height(32)
            .borderRadius(16)
            .objectFit(ImageFit.Cover)
            .backgroundColor(Theme.colors().surfaceVariant)
            .border({ width: 1, color: Theme.colors().glassBorder });
          Column() {
            Row() {
              Text(this.comment.username.length > 0 ? this.comment.username : '匿名用户')
                .fontSize(Dimens.captionSize)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.colors().textSecondary)
                .maxLines(1)
                .layoutWeight(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
              Text(this.comment.date)
                .fontSize(Dimens.captionSize)
                .fontColor(Theme.colors().textHint)
                .margin({ left: 8 })
                .maxLines(1);
            }
            .width('100%');

            Text(this.comment.content)
              .fontSize(Dimens.bodySize)
              .fontColor(Theme.colors().textPrimary)
              .lineHeight(20)
              .margin({ top: 6 })
              .width('100%')
              .maxLines(30)
              .textOverflow({ overflow: TextOverflow.Ellipsis });

            Row() {
              // 点赞（站点登录前 thumbUp 为 -1，只显示「赞」）
              Row() {
                Text('👍')
                  .fontSize(11);
                Text(this.comment.thumbUp >= 0 ? this.comment.thumbUp.toString() : '赞')
                  .fontSize(11)
                  .fontColor(this.comment.post.likeCommentStatus ? Theme.colors().primary : Theme.colors().textHint)
                  .margin({ left: 3 });
                if (this.likeBusy) {
                  LoadingProgress()
                    .width(12)
                    .height(12)
                    .margin({ left: 3 })
                    .color(Theme.colors().primary);
                }
              }
              .padding({ left: 10, right: 10, top: 5, bottom: 5 })
              .borderRadius(12)
              .backgroundColor(this.comment.post.likeCommentStatus ?
                Theme.colors().primaryContainer : Theme.colors().chipTint)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .onClick(() => {
                if (!this.likeBusy) {
                  this.toggleLike();
                }
              });

              Text('回复')
                .fontSize(11)
                .fontColor(Theme.colors().textSecondary)
                .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                .borderRadius(12)
                .backgroundColor(Theme.colors().chipTint)
                .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
                .margin({ left: 8 })
                .onClick(() => {
                  this.onReply(this.comment);
                });

              if (this.canReport(this.comment)) {
                Text('举报')
                  .fontSize(11)
                  .fontColor(Theme.colors().textSecondary)
                  .padding({ left: 10, right: 10, top: 5, bottom: 5 })
                  .borderRadius(12)
                  .backgroundColor(Theme.colors().chipTint)
                  .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.onReport(this.comment);
                  });
              }
            }
            .width('100%')
            .margin({ top: 8 })
            .alignItems(VerticalAlign.Center);
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .margin({ left: 10 });
        }
        .width('100%')
        .alignItems(VerticalAlign.Top);

        if (this.showRepliesSection()) {
          this.repliesSection();
        }
      }
      .width('100%')
      .padding(12)
      .borderRadius(Dimens.listRadius)
      // 评论卡与设置页分组卡同款：cardBg 纯色 + 1vp glassBorder + 圆角 12，无阴影、无背景模糊
      .backgroundColor(Theme.colors().cardBg)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .padding({
      left: Dimens.pagePadding,
      right: Dimens.pagePadding,
      top: 4,
      bottom: 4
    });
  }
}
