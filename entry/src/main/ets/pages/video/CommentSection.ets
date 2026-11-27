/**
 * 评论区：首屏 + 分页加载 + 发评论 + 回复 + 点赞 + 举报 + 客户端排序。
 *
 * 设计取舍：
 *  - 默认（embedded=false）评论区整体作为一个可增长 Column 放进详情页的 Scroll
 *    （不再套内层滚动容器，避免 Scroll 嵌套 Scroll）；
 *  - embedded=true（视频详情页「评论」Tab 使用）：只渲染「可独立滚动的评论列表」，
 *    底部悬浮评论输入框（评论数在输入框内左侧，其正上方一行左侧为排序胶囊、右侧为刷新圆钮）
 *    由视频详情页（VideoPage.commentTab）渲染（本组件通过 topInset / bottomInset 给滚动内容
 *    留出悬浮空间），本组件通过 CommentPanelHandle 把父页面的「发送 / 取消回复」转回内部逻辑；
 *  - 分页用「加载更多评论」按钮触发（首屏之外每批 100 条），不依赖外层滚动事件；
 *  - 评论排序（sortType）与视频页排序胶囊共用 AppStorage['commentSortType']：
 *    对齐上游 CommentSortType 客户端排序，只重排已加载的评论 / 子回复，不重新请求站点；
 *    默认站点顺序；
 *  - 评论点赞在 CommentItemView 内发起，成功后回传新对象由本组件整体替换数组；
 *  - 举报：ActionSheet 选理由（上游 report_reason.json 4 项）→ POST 站点举报表单，
 *    成功 Toast「已成功检举该则评论」，失败提示错误（无乐观 UI，不改变列表）；
 *  - CSRF / currentUserId 优先取 HanimeVideo（父组件传入），其次用 loadComment
 *    响应里的值（登录后刷新一次即可拿到最新的）。
 */

import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { describeError } from '../../logic/net/Errors';
import { AppSettings } from '../../logic/settings/AppSettings';
import {
  PostCommentResult,
  VideoComment,
  VideoComments
} from '../../core/model/Models';
import {
  COMMENT_SORT_SITE,
  sortVideoComments
} from '../../core/parser/CommentParser';
import { buildWatchUrl } from '../../core/util/Urls';
import {
  applyReplyIncrement,
  commentKey
} from '../../viewmodel/video/VideoUiUtils';
import { CommentInputBar } from './CommentInputBar';
import { CommentItemView } from './CommentItemView';
import { InlineEmptyRow, InlineErrorRow, InlineLoadingRow } from './StateViews';

const api: HanimeApi = HanimeApi.getInstance();

/**
 * 举报理由（对齐上游 assets/report_reason.json 与 logic/model/ReportReason.kt）：
 *  - label 是简体中文展示文案（上游按系统语言取 lang.zh-rCN）；
 *  - key 是提交给站点的 reason 值（上游 `ReportReason.reasonKey`，与 zh-rTW 文案一致）。
 * 站点举报接口只认 reasonKey，因此提交时用 key、展示时用 label。
 */
class ReportReasonItem {
  label: string = '';
  key: string = '';

  constructor(label: string, key: string) {
    this.label = label;
    this.key = key;
  }
}

const REPORT_REASONS: ReportReasonItem[] = [
  new ReportReasonItem('煽动仇恨或恶意内容', '煽動仇恨或惡意內容'),
  new ReportReasonItem('暴力或令人反感的内容', '暴力或令人反感的內容'),
  new ReportReasonItem('广告内容或垃圾内容', '廣告內容或垃圾內容'),
  new ReportReasonItem('其他举报理由', '其他檢舉理由')
];

/**
 * 宽屏右栏「内嵌模式」下父页面操作评论列表的句柄。
 *
 * 内嵌时标题栏与底部输入条由父页面（视频详情页）固定渲染，但发送/取消回复这两件事需要
 * 复用本组件里的状态（登录校验、回复目标、评论数组替换），而 ArkUI 父组件不能直接调用
 * 子组件方法，因此用「父页面持有句柄、子组件在 aboutToAppear 里注册实现」的方式回调。
 */
export class CommentPanelHandle {
  /** 发表评论 / 回复（内容来自父页面的固定输入条） */
  submit: (text: string) => void = () => {
  };
  /** 取消回复模式（父页面输入条点「取消回复」） */
  cancelReply: () => void = () => {
  };
}

@Component
export struct CommentSection {
  /** 以下三个属性用 @Prop：父页面登录后/刷新后会用新视频对象重新渲染，普通属性不会同步更新 */
  @Prop videoCode: string = '';
  /** 来自 HanimeVideo 的登录信息（登录后父页面会重新加载并更新） */
  @Prop currentUserId: string = '';
  @Prop csrfToken: string = '';
  /** 站点解析出的评论总数（#tab-comments-count），<=0 时用已加载条数代替 */
  @Prop commentCount: number = 0;
  /** 父页面每次下拉刷新 +1，用来触发评论区一起刷新 */
  @Prop @Watch('onReloadTokenChanged') reloadToken: number = 0;
  onCommentCountChange: (count: number) => void = () => {
  };
  /**
   * 宽屏右栏内嵌模式（默认 false 保持旧行为）：
   * true 时本组件只渲染「可独立滚动的评论列表」，标题栏 / 输入条由父页面固定提供，
   * 列表本身仍复用同一套加载/分页/回复/点赞逻辑，不再依赖外层 Scroll。
   */
  embedded: boolean = false;
  /**
   * 内嵌模式：列表内容顶部额外留白（评论数 / 刷新已移到底部悬浮输入框，这里只留少量呼吸间距）。
   * 只影响滚动内容的内边距，不改变分页 / 点赞 / 回复 / 发评论逻辑。
   */
  @Prop topInset: number = 0;
  /**
   * 内嵌模式：列表内容底部额外留白（悬浮评论输入框高度 + 间距）。
   * 只影响滚动内容的内边距，不改变分页 / 点赞 / 回复 / 发评论逻辑。
   */
  @Prop bottomInset: number = 0;
  /**
   * 评论排序（对齐上游 ui/screen/video/CommentSortType.kt）：默认站点顺序；
   * 切换后只对已加载评论做客户端重排（不重新请求），子回复同样按此排序。
   *
   * 与 VideoPage 的排序胶囊共用 AppStorage['commentSortType']：用 @StorageProp 而不是
   * @Prop，是为了让 ForEach 里已复用的评论项（CommentItemView）也能响应排序变化
   * （ForEach 不会为保留项重新执行 itemGenerator）。
   */
  @StorageProp('commentSortType') sortType: string = COMMENT_SORT_SITE;
  /** 内嵌模式：父页面通过该句柄触发写评论 / 取消回复 */
  panelHandle: CommentPanelHandle = new CommentPanelHandle();
  /** 内嵌模式：回复目标变化时通知父页面（输入条显示「回复 @xxx」） */
  onReplyNameChange: (name: string) => void = () => {
  };
  /** 内嵌模式：发送状态变化时通知父页面（输入条禁用发送按钮） */
  onSendingChange: (sending: boolean) => void = () => {
  };
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageProp('loggedIn') loggedIn: boolean = false;
  @State comments: VideoComment[] = [];
  @State loading: boolean = false;
  @State errorMsg: string = '';
  @State hasMore: boolean = false;
  @State nextOffset: number = -1;
  @State loadingMore: boolean = false;
  @State sending: boolean = false;
  @State replyingId: string = '';
  @State replyingKey: string = '';
  @State replyingName: string = '';
  @State responseUid: string = '';
  @State responseToken: string = '';
  private disposed: boolean = false;
  /** 举报请求是否在途（防连点；举报无乐观 UI，成功后只 Toast） */
  private reportBusy: boolean = false;

  aboutToAppear(): void {
    if (this.embedded) {
      // 内嵌模式下父页面固定输入条/标题栏，注册句柄让父页面能把用户操作转进来
      this.panelHandle.submit = (text: string) => {
        this.submit(text);
      };
      this.panelHandle.cancelReply = () => {
        this.cancelReply();
      };
    }
    this.loadFirst();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  onReloadTokenChanged(): void {
    this.loadFirst();
  }

  userId(): string {
    if (this.responseUid.length > 0) {
      return this.responseUid;
    }
    return this.currentUserId;
  }

  token(): string {
    if (this.responseToken.length > 0) {
      return this.responseToken;
    }
    return this.csrfToken;
  }

  displayCount(): number {
    if (this.commentCount > 0) {
      return this.commentCount;
    }
    return this.comments.length;
  }

  /**
   * 当前展示顺序：按共享的排序值 sortType 对已加载评论做客户端排序
   * （对齐上游 CommentScreen.sortComments，不重新请求站点）。
   * 默认 COMMENT_SORT_SITE 保持站点返回顺序，返回新数组供 ForEach 整体刷新。
   */
  displayComments(): VideoComment[] {
    return sortVideoComments(this.comments, this.sortType);
  }

  /**
   * ArkTS 规则：@StorageProp 变量不能直接赋给子组件的「常规」属性
   * （编译错误：The '@StorageProp' property 'loggedIn' cannot be assigned to the
   * 'regular' property）。这里转成普通值再传给 CommentItemView。
   */
  loginFlag(): boolean {
    return this.loggedIn;
  }

  async loadFirst(): Promise<void> {
    if (this.videoCode.length === 0) {
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    try {
      const page: VideoComments = await api.getComments(this.videoCode, -1);
      if (this.disposed) {
        return;
      }
      this.comments = page.comments;
      this.hasMore = page.hasMoreComments;
      this.nextOffset = page.nextCommentOffset;
      if (page.currentUserId.length > 0) {
        this.responseUid = page.currentUserId;
      }
      if (page.csrfToken.length > 0) {
        this.responseToken = page.csrfToken;
      }
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.errorMsg = describeError(e as Error);
    }
    this.loading = false;
  }

  async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore) {
      return;
    }
    // HanimeApi.getComments 内部把 offset <= 0 当作首屏（offset=-1 语义），
    // 因此只有 offset > 0 才是有效的「下一批」；否则停止分页，避免重复拉首屏。
    if (this.nextOffset <= 0) {
      this.hasMore = false;
      return;
    }
    this.loadingMore = true;
    try {
      const page: VideoComments = await api.getComments(this.videoCode, this.nextOffset);
      if (this.disposed) {
        return;
      }
      const existing: string[] = [];
      for (let i = 0; i < this.comments.length; i++) {
        existing.push(commentKey(this.comments[i]));
      }
      const merged: VideoComment[] = this.comments.slice();
      for (let i = 0; i < page.comments.length; i++) {
        const item: VideoComment = page.comments[i];
        if (existing.indexOf(commentKey(item)) < 0) {
          merged.push(item);
        }
      }
      this.comments = merged;
      this.hasMore = page.hasMoreComments;
      this.nextOffset = page.nextCommentOffset;
    } catch (e) {
      if (!this.disposed) {
        Toast.show(describeError(e as Error));
      }
    }
    this.loadingMore = false;
  }

  /** 点赞成功后替换列表里的那条评论（整体重赋值才会触发 UI 刷新） */
  replaceComment(updated: VideoComment): void {
    const key: string = commentKey(updated);
    this.comments = this.comments.map((item: VideoComment): VideoComment => {
      return commentKey(item) === key ? updated : item;
    });
  }

  startReply(comment: VideoComment): void {
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    let replyId: string = comment.id;
    if (replyId.length === 0 || replyId === '-1') {
      replyId = comment.post.foreignId;
    }
    if (replyId.length === 0) {
      Toast.show('该评论缺少 id，暂时无法回复');
      return;
    }
    this.replyingId = replyId;
    this.replyingKey = commentKey(comment);
    this.replyingName = comment.username;
    if (this.embedded) {
      this.onReplyNameChange(this.replyingName);
    }
  }

  cancelReply(): void {
    this.replyingId = '';
    this.replyingKey = '';
    this.replyingName = '';
    if (this.embedded) {
      this.onReplyNameChange('');
    }
  }

  /**
   * 举报入口（对齐上游 CommentScreen 的 onReport + CommentReportDialog）：
   * 未登录先引导登录；已登录弹举报理由选择（上游 report_reason.json 的 4 项），
   * 选中后提交站点举报表单（路径 / 字段见 HanimeApi.reportComment，对齐
   * HanimeCommentService.submitReport：csrf、redirect-url、reportable-id/type、reason、userId）。
   */
  reportComment(comment: VideoComment): void {
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    if (comment.reportableId.length === 0) {
      Toast.show('该评论暂不支持举报');
      return;
    }
    if (this.userId().length === 0 || this.token().length === 0) {
      Toast.show('登录状态已失效，请重新登录');
      Router.openLogin();
      return;
    }
    ActionSheet.show({
      title: '举报评论',
      message: '你觉得他咋了？请选择举报理由',
      autoCancel: true,
      cancel: () => {
      },
      sheets: [
        {
          title: REPORT_REASONS[0].label,
          action: () => {
            this.submitReport(comment, 0);
          }
        },
        {
          title: REPORT_REASONS[1].label,
          action: () => {
            this.submitReport(comment, 1);
          }
        },
        {
          title: REPORT_REASONS[2].label,
          action: () => {
            this.submitReport(comment, 2);
          }
        },
        {
          title: REPORT_REASONS[3].label,
          action: () => {
            this.submitReport(comment, 3);
          }
        }
      ]
    });
  }

  /**
   * 提交举报。成功 Toast「已成功检举该则评论」（对齐上游 Parser.reportCommentResponse 的文案）；
   * 举报没有乐观 UI，失败只提示错误、不改变列表。
   */
  async submitReport(comment: VideoComment, reasonIndex: number): Promise<void> {
    if (this.reportBusy || reasonIndex < 0 || reasonIndex >= REPORT_REASONS.length) {
      return;
    }
    const uid: string = this.userId();
    const token: string = this.token();
    if (uid.length === 0 || token.length === 0) {
      Toast.show('登录状态已失效，请重新登录');
      Router.openLogin();
      return;
    }
    this.reportBusy = true;
    try {
      // redirect-url 与上游一致：当前视频详情页地址（Preferences.baseUrl + watch?v=code）
      const redirectUrl: string = buildWatchUrl(AppSettings.getInstance().getBaseUrl(), this.videoCode);
      // reportable-type 优先用评论块上的 data-reportable-type（comment / reply），
      // 站点改版缺失时按是否子评论兜底。
      const reportableType: string = comment.reportableType.length > 0
        ? comment.reportableType
        : (comment.isChildComment ? 'reply' : 'comment');
      await api.reportComment(
        token,
        uid,
        redirectUrl,
        reportableType,
        comment.reportableId,
        REPORT_REASONS[reasonIndex].key
      );
      if (!this.disposed) {
        Toast.show('已成功检举该则评论');
      }
    } catch (e) {
      if (!this.disposed) {
        Toast.show(describeError(e as Error));
      }
    }
    this.reportBusy = false;
  }

  async submit(text: string): Promise<void> {
    const content: string = text.trim();
    if (content.length === 0 || this.sending) {
      return;
    }
    if (!this.loggedIn) {
      Toast.show('请先登录');
      Router.openLogin();
      return;
    }
    const uid: string = this.userId();
    const token: string = this.token();
    if (uid.length === 0 || token.length === 0) {
      Toast.show('登录状态已失效，请重新登录');
      Router.openLogin();
      return;
    }
    this.sending = true;
    if (this.embedded) {
      this.onSendingChange(true);
    }
    if (this.replyingId.length > 0) {
      const replyId: string = this.replyingId;
      const parentKey: string = this.replyingKey;
      try {
        await api.postReply(replyId, content, token);
        if (this.disposed) {
          return;
        }
        this.comments = this.comments.map((item: VideoComment): VideoComment => {
          return commentKey(item) === parentKey ? applyReplyIncrement(item) : item;
        });
        Toast.show('回复成功');
        this.cancelReply();
      } catch (e) {
        if (!this.disposed) {
          Toast.show(describeError(e as Error));
        }
      }
    } else {
      try {
        const result: PostCommentResult = await api.postComment(content, uid, this.videoCode, token);
        if (this.disposed) {
          return;
        }
        const newComment: VideoComment | null = result.comment;
        if (newComment !== null) {
          const key: string = commentKey(newComment);
          let duplicated: boolean = false;
          for (let i = 0; i < this.comments.length; i++) {
            if (commentKey(this.comments[i]) === key) {
              duplicated = true;
              break;
            }
          }
          if (!duplicated) {
            const next: VideoComment[] = [newComment];
            this.comments = next.concat(this.comments);
          }
        }
        const nextCount: number = result.commentCount > 0 ? result.commentCount : this.displayCount() + 1;
        this.onCommentCountChange(nextCount);
        Toast.show('评论已发布');
      } catch (e) {
        if (!this.disposed) {
          Toast.show(describeError(e as Error));
        }
      }
    }
    this.sending = false;
    if (this.embedded) {
      this.onSendingChange(false);
    }
  }

  @Builder
  header() {
    Row() {
      Row()
        .width(4)
        .height(17)
        .borderRadius(2)
        .linearGradient({
          angle: 180,
          colors: [[Theme.colors().primary, 0.0], [Theme.colors().secondary, 1.0]]
        })
        .margin({ right: 8 });
      Text('评论 (' + this.displayCount() + ')')
        .fontSize(Dimens.subtitleSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().textPrimary)
        .layoutWeight(1);
      if (this.loading) {
        LoadingProgress()
          .width(16)
          .height(16)
          .color(Theme.colors().primary);
      } else {
        Text('刷新')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .padding({ left: 12, right: 12, top: 5, bottom: 5 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .onClick(() => {
            this.loadFirst();
          });
      }
    }
    .width('100%')
    .padding({
      left: Dimens.pagePadding,
      right: Dimens.pagePadding,
      top: 16,
      bottom: 10
    })
    .alignItems(VerticalAlign.Center);
  }

  /** 列表本体：加载中 / 错误 / 空态 / 评论 / 分页按钮（窄屏单列与宽屏右栏共用） */
  @Builder
  listContent() {
    if (this.loading && this.comments.length === 0) {
      InlineLoadingRow({ text: '评论加载中…' });
    } else if (this.errorMsg.length > 0 && this.comments.length === 0) {
      InlineErrorRow({
        message: this.errorMsg,
        onRetry: () => {
          this.loadFirst();
        }
      });
    } else if (this.comments.length === 0) {
      InlineEmptyRow({ text: '还没有评论', hint: '来抢第一个沙发～' });
    } else {
      // 客户端排序：displayComments() 每次按 sortType 返回新顺序；ForEach 的 key 保持稳定
      // （commentKey 不掺排序值），框架只按新顺序移动已有组件，不会重建 —— 从而切换排序时
      // 既不重新请求主评论，也不会让 CommentItemView 重新触发子回复加载。
      ForEach(this.displayComments(), (comment: VideoComment) => {
        CommentItemView({
          comment: comment,
          token: this.token(),
          loggedIn: this.loginFlag(),
          onLikeApplied: (updated: VideoComment) => {
            this.replaceComment(updated);
          },
          onReply: (target: VideoComment) => {
            this.startReply(target);
          },
          onReport: (target: VideoComment) => {
            this.reportComment(target);
          }
        });
      }, (comment: VideoComment) => commentKey(comment));

      if (this.loadingMore) {
        InlineLoadingRow({ text: '加载更多评论…' });
      } else if (this.hasMore) {
        Row() {
          Button('加载更多评论')
            .fontSize(13)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Theme.colors().chipTint)
            .fontColor(Theme.colors().textPrimary)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
            .shadow(Glass.cardShadow(Theme.colors().glassShadow))
            .onClick(() => {
              this.loadMore();
            });
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ top: 14, bottom: 18 });
      } else {
        Text('没有更多评论了')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .width('100%')
          .textAlign(TextAlign.Center)
          .padding({ top: 14, bottom: 18 });
      }
    }
  }

  /** 旧行为（窄屏单列 / 详情页底部）：标题 + 输入条 + 列表顺序排列，整体放进页面外层 Scroll */
  @Builder
  standardBody() {
    Column() {
      this.header();

      if (this.loggedIn) {
        CommentInputBar({
          placeholder: this.replyingName.length > 0 ? ('回复 @' + this.replyingName + '…') : '说点什么…',
          replyToName: this.replyingName,
          sending: this.sending,
          onSend: (text: string) => {
            this.submit(text);
          },
          onCancelReply: () => {
            this.cancelReply();
          }
        });
      } else {
        Column() {
          Row() {
            Text('登录后参与评论')
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().textSecondary)
              .layoutWeight(1);
            Button('去登录')
              .fontSize(12)
              .height(30)
              .borderRadius(15)
              .backgroundColor(Theme.colors().primary)
              .fontColor(Theme.colors().onPrimary)
              .onClick(() => {
                Router.openLogin();
              });
          }
          .width('100%')
          .padding({ left: 14, right: 6, top: 5, bottom: 5 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .alignItems(VerticalAlign.Center);
        }
        .width('100%')
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 4, bottom: 6 });
      }

      this.listContent();
    }
    .width('100%');
  }

  build() {
    if (this.embedded) {
      // 宽屏右栏：只负责「独立滚动的列表」，悬浮输入框 / 刷新圆钮由视频详情页提供
      Scroll() {
        Column() {
          this.listContent();
        }
        .width('100%')
        // 顶部只留少量呼吸（评论数 / 刷新已移到底部悬浮输入框），
        // 底部留出悬浮评论输入框高度，最后一条评论不被遮挡
        .padding({ top: this.topInset, bottom: 12 + this.bottomInset });
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    } else {
      this.standardBody();
    }
  }
}
