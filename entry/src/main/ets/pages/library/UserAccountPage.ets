/**
 * 账号资料页。
 *
 * 接口：`HanimeApi.getUserAccount(userId)`（`user/{userId}/edit`），展示头像 / 用户名 / 邮箱 /
 * 加入时间 / 订阅数 / 视频数。
 *
 * 已实现：资料展示 + 退出登录（AlertDialog 确认）。
 * 未实现：修改昵称 / 邮箱 / 密码 / 头像裁剪（上游有对应接口，但 GUIDE 未提供写接口签名，
 * 且涉及头像上传与裁剪 UI，见最终报告“未实现”说明）。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { LoginExpiredError, describeError } from '../../logic/net/Errors';
import { UserAccount, emptyUserAccount } from '../../core/model/Models';
import { AppSettings } from '../../logic/settings/AppSettings';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { RouteParam, Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, ErrorView, LoadingView } from '../../components/common/Widgets';
import { GroupCard, GroupTitle, NavRow, PROFILE_CARD_RADIUS, RowDivider } from './LibraryComponents';
import { accountStatText } from '../../viewmodel/library/LibraryViewModel';
import { SessionActions } from '../../viewmodel/library/SessionActions';

@Component
export struct UserAccountPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：内容顶部 spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：本页是二级页（无悬浮底栏），只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State account: UserAccount = emptyUserAccount();
  @State loading: boolean = true;
  @State errorMessage: string = '';

  private disposed: boolean = false;
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  async load(): Promise<void> {
    if (this.p.userId.length === 0) {
      this.loading = false;
      this.errorMessage = '缺少用户信息，请重新登录后再试';
      return;
    }
    this.loading = true;
    this.errorMessage = '';
    try {
      const account: UserAccount = await this.api.getUserAccount(this.p.userId);
      if (this.disposed) {
        return;
      }
      this.account = account;
      // 顺手把最新资料写回设置（“我的”Tab 头像/昵称会同步刷新）
      const settings: AppSettings = AppSettings.getInstance();
      if (account.username.length > 0) {
        settings.setUsername(account.username);
      }
      if (account.avatarUrl.length > 0) {
        settings.setAvatarUrl(account.avatarUrl);
      }
      if (account.userId.length > 0) {
        settings.setUserId(account.userId);
      }
    } catch (e) {
      if (this.disposed) {
        return;
      }
      const error: Error = e as Error;
      if (error instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      this.errorMessage = describeError(error);
    } finally {
      if (!this.disposed) {
        this.loading = false;
      }
    }
  }

  private confirmLogout(): void {
    AlertDialog.show({
      title: '退出登录',
      message: '退出后本地收藏与观看历史仍会保留；在线内容需要重新登录后查看。',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '退出登录',
        fontColor: Theme.colors().error,
        action: () => {
          SessionActions.logout();
          Toast.show('已退出登录');
          Router.pop();
        }
      }
    });
  }

  /** 资料头卡：纯色大面板（头像 / 昵称 / ID / 统计，圆角 20 + 1vp 描边，无阴影） */
  @Builder
  profileCard() {
    Column() {
      Row() {
        if (this.account.avatarUrl.length > 0) {
          Image(this.account.avatarUrl)
            .width(72)
            .height(72)
            .borderRadius(36)
            .objectFit(ImageFit.Cover)
            .backgroundColor(Theme.colors().surface)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        } else {
          Row() {
            Image($r('app.media.ic_login'))
              .width(32)
              .height(32)
              .fillColor(Theme.colors().primary);
          }
          .width(72)
          .height(72)
          .borderRadius(36)
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.colors().primaryContainer)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        }

        Column() {
          Text(this.account.username.length > 0 ? this.account.username : '未命名用户')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Text('用户 ID：' + (this.account.userId.length > 0 ? this.account.userId : this.p.userId))
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          if (this.account.joinedLabel.length > 0) {
            Text('加入时间：' + this.account.joinedLabel)
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().textHint)
              .margin({ top: 2 })
              .width('100%');
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14 });
      }
      .width('100%');

      Row() {
        Text(accountStatText('订阅', this.account.subscriberCount))
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary);
        Blank();
        Text(accountStatText('视频', this.account.videoCount))
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary);
      }
      .width('100%')
      .margin({ top: 14 })
      .padding({ top: 10 })
      .border({ width: { top: 0.5 }, color: Theme.colors().divider });
    }
    .width('100%')
    .padding(20)
    .borderRadius(PROFILE_CARD_RADIUS)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
  }

  @Builder
  content() {
    if (this.loading) {
      Column() {
        LoadingView({ text: '正在加载账号资料…' });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.errorMessage.length > 0) {
      Column() {
        ErrorView({
          message: this.errorMessage,
          onRetry: () => {
            this.load();
          }
        });
      }
      .width('100%')
      .layoutWeight(1);
    } else {
      Scroll() {
        Column() {
          // 悬浮顶栏让位 spacer：随内容滚走，内容从顶栏下方经过
          Row()
            .width('100%')
            .height(this.statusBarHeight + Dimens.topBarHeight);

          this.profileCard();

          GroupTitle({ text: '资料' });
          GroupCard() {
            NavRow({
              showIcon: false,
              showArrow: false,
              title: '邮箱',
              subtitle: this.account.emailEditable ? '站点资料页支持修改' : '站点不允许在 App 内修改',
              valueText: this.account.email.length > 0 ? this.account.email : '未绑定'
            });
            RowDivider();
            NavRow({
              showIcon: false,
              showArrow: false,
              title: '资料修改',
              subtitle: '修改昵称 / 密码 / 头像请在网页版账号资料页操作'
            });
          }

          Column() {
            Button('打开网页版资料页')
              .fontSize(Dimens.bodySize)
              .height(44)
              .width('100%')
              .backgroundColor(Theme.colors().primary)
              .fontColor(Theme.colors().onPrimary)
              .borderRadius(999)
              .onClick(() => {
                Router.openWeb(AppSettings.getInstance().getBaseUrl() + 'user/' + this.p.userId + '/edit',
                  '账号资料');
              });

            Button('退出登录')
              .fontSize(Dimens.bodySize)
              .height(44)
              .width('100%')
              .margin({ top: 10 })
              .backgroundColor(Theme.colors().chipTint)
              .fontColor(Theme.colors().error)
              .borderRadius(999)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .onClick(() => {
                this.confirmLogout();
              });
          }
          .width('100%')
          .margin({ top: 16 });
        }
        .width('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          top: 10,
          bottom: this.navBarHeight + 16
        });
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
  }

  build() {
    // 悬浮顶栏：内容铺满整页（顶部 spacer 让出状态栏+顶栏），AppTopBar 作为 Stack 覆盖层。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.content();
      }
      .width('100%')
      .height('100%');

      AppTopBar({ title: '账号资料', showBack: true });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
