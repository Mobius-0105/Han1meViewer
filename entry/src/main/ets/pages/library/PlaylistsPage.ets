/**
 * 我的清单（站点的播放清单列表）。
 *
 * 接口：`HanimeApi.getPlaylists(userId, page)`（`user/{userId}/playlists?page=`）。
 * 点击一条 → Router.openPlaylistDetail(listCode, title)。
 *
 * 说明：RouteParam.userId 由 LibraryPage 传入；若为空（例如只导入了 cookie 还没同步过账号），
 * 这里用首页接口补一次 userId。进入时若无网络/登录失效，显示错误态 + 重试。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { LoginExpiredError, describeError } from '../../logic/net/Errors';
import { PlaylistSummary } from '../../core/model/Models';
import { AppState } from '../../logic/state/AppState';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { RouteParam, Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, EmptyView, ErrorView, LoadingView } from '../../components/common/Widgets';
import { playlistCountText } from '../../viewmodel/library/LibraryViewModel';
import { SessionActions } from '../../viewmodel/library/SessionActions';

@Component
export struct PlaylistsPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：列表首个 ListItem spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State playlists: PlaylistSummary[] = [];
  @State page: number = 1;
  @State maxPage: number = 1;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State refreshing: boolean = false;
  @State errorMessage: string = '';

  private userId: string = '';
  private disposed: boolean = false;
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    this.userId = this.p.userId;
    this.load(true);
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** 补齐 userId（首页接口会返回登录用户的 id / 昵称 / 头像） */
  private async ensureUserId(): Promise<boolean> {
    if (this.userId.length > 0) {
      return true;
    }
    try {
      const home = await this.api.getHome();
      if (home.userId.length > 0) {
        this.userId = home.userId;
        AppState.setUser(home.userId, home.username, home.avatarUrl);
        return true;
      }
    } catch (e) {
      const error: Error = e as Error;
      if (error instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      const message: string = describeError(error);
      if (!this.disposed) {
        this.errorMessage = message;
      }
    }
    return false;
  }

  async load(reset: boolean): Promise<void> {
    if (reset) {
      this.loading = true;
      this.errorMessage = '';
    } else {
      if (this.loadingMore || this.page >= this.maxPage) {
        return;
      }
      this.loadingMore = true;
    }
    const ok: boolean = await this.ensureUserId();
    if (!ok) {
      if (!this.disposed) {
        this.loading = false;
        this.loadingMore = false;
        this.refreshing = false;
        if (this.errorMessage.length === 0) {
          this.errorMessage = '未能获取账号信息，请重新登录后再试';
        }
      }
      return;
    }
    const page: number = reset ? 1 : this.page + 1;
    try {
      const result = await this.api.getPlaylists(this.userId, page);
      if (this.disposed) {
        return;
      }
      if (reset) {
        this.playlists = result.playlists;
        this.page = 1;
      } else {
        const merged: PlaylistSummary[] = [];
        for (let i = 0; i < this.playlists.length; i++) {
          merged.push(this.playlists[i]);
        }
        for (let i = 0; i < result.playlists.length; i++) {
          merged.push(result.playlists[i]);
        }
        this.playlists = merged;
        this.page = page;
      }
      this.maxPage = result.maxPage > 0 ? result.maxPage : 1;
      this.errorMessage = '';
    } catch (e) {
      if (this.disposed) {
        return;
      }
      const error: Error = e as Error;
      if (error instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      this.errorMessage = describeError(error);
      if (!reset) {
        Toast.show(this.errorMessage);
      }
    } finally {
      if (!this.disposed) {
        this.loading = false;
        this.loadingMore = false;
        this.refreshing = false;
      }
    }
  }

  @Builder
  playlistRow(item: PlaylistSummary) {
    Row() {
      Image(item.coverUrl)
        .width(104)
        .height(66)
        .objectFit(ImageFit.Cover)
        .borderRadius(Dimens.smallRadius)
        .backgroundColor(Theme.colors().surfaceVariant);

      Column() {
        Text(item.title)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        Text(playlistCountText(item.total))
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .margin({ top: 4 });
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 });

      Text('›')
        .fontSize(Dimens.titleSize)
        .fontColor(Theme.colors().textHint)
        .margin({ left: 2 });
    }
    .width('100%')
    .padding(10)
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    // 左右 12 边距由 List 的横向 padding 提供（卡片自身不再加水平 margin，
    // 否则 width 100% + margin 会向右溢出、右边缘被裁剪 = 用户反馈的「没有右边距」）
    .margin({ top: 6, bottom: 6 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      Router.openPlaylistDetail(item.listCode, item.title);
    });
  }

  @Builder
  content() {
    if (this.loading) {
      Column() {
        LoadingView({ text: '正在加载我的清单…' });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.errorMessage.length > 0 && this.playlists.length === 0) {
      Column() {
        ErrorView({
          message: this.errorMessage,
          onRetry: () => {
            this.load(true);
          }
        });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.playlists.length === 0) {
      Column() {
        EmptyView({ text: '还没有播放清单', hint: '在站点上创建播放清单后会显示在这里' });
      }
      .width('100%')
      .layoutWeight(1);
    } else {
      Refresh({ refreshing: $$this.refreshing }) {
        List() {
          // 悬浮顶栏让位 spacer：随列表滚走，卡片从顶栏下方经过
          ListItem() {
            Row()
              .width('100%')
              .height(this.statusBarHeight + Dimens.topBarHeight);
          }

          ForEach(this.playlists, (item: PlaylistSummary) => {
            ListItem() {
              this.playlistRow(item);
            }
          }, (item: PlaylistSummary) => item.listCode)

          if (this.loadingMore) {
            ListItem() {
              Row() {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color(Theme.colors().primary);
                Text('加载中…')
                  .fontSize(Dimens.captionSize)
                  .fontColor(Theme.colors().textHint)
                  .margin({ left: 8 });
              }
              .width('100%')
              .height(44)
              .justifyContent(FlexAlign.Center);
            }
          } else if (this.page >= this.maxPage) {
            ListItem() {
              Text('没有更多了')
                .fontSize(Dimens.captionSize)
                .fontColor(Theme.colors().textHint)
                .width('100%')
                .height(44)
                .textAlign(TextAlign.Center);
            }
          }
        }
        .width('100%')
        .height('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          bottom: this.navBarHeight + 16
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.load(false);
        });
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing(() => {
        this.load(true);
      });
    }
  }

  build() {
    // 悬浮顶栏：List 铺满整页（首个 ListItem 是状态栏+顶栏让位 spacer），AppTopBar 覆盖在最上层。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.content();
      }
      .width('100%')
      .height('100%');

      AppTopBar({ title: '我的清单', showBack: true });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
