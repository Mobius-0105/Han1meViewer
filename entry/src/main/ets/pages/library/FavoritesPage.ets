/**
 * 收藏 / 稍后再看 / 在线历史 / 站点收藏 / 站点稍后再看 页。
 *
 * 进入方式（都通过 RouteParam.title 传模式，Router 没有独立路由）：
 *  - 内容库「收藏」      → FAVORITES_MODE_ONLINE_LIKES（站点在线收藏，需登录）；
 *  - 内容库「稍后再看」  → FAVORITES_MODE_ONLINE_WATCH_LATER（站点在线稍后再看，需登录）；
 *  - 「我的清单 → 在线历史」 → FAVORITES_MODE_ONLINE（站点在线历史，带排序与分页）；
 *  - 旧版 LibraryPage 的本地入口 → 默认“收藏/稍后再看”双 Tab（本机 LocalRepo）；
 *  - 默认选中“稍后再看”Tab → FAVORITES_MODE_WATCH_LATER。
 *
 * 数据来源（对齐 Android 上游 MyListRoutes.kt / MyListType）：
 *  - 在线收藏：`GET user/{userId}/likes?page=`（HanimeApi.getMyList，type='likes'）；
 *  - 在线稍后再看：`GET user/{userId}/saves?page=`（type='saves'）；
 *  - 在线历史：`GET user/{userId}/histories?sort=&page=`；
 *  - 本地收藏/稍后再看：LocalRepo（本机数据，只有本机操作过才有内容）。
 *
 * userId 解析顺序：RouteParam.userId → AppStorage['userId'] → `getHome()` 补齐；
 * 站点在线列表需要登录：未登录时展示登录引导卡（登录成功后由 @StorageLink('loggedIn')
 * 的 @Watch 自动重新加载），登录过期（LoginExpiredError）走 SessionActions.onSessionExpired。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { LoginExpiredError, describeError } from '../../logic/net/Errors';
import { LocalRepo } from '../../logic/db/LocalRepo';
import { AppState } from '../../logic/state/AppState';
import { HanimeInfo, MyListPage, LocalVideoRecord } from '../../core/model/Models';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { RouteParam, Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, EmptyView, ErrorView, LoadingView, VideoListTile } from '../../components/common/Widgets';
import { EmptyRefreshHeader, PullRefreshHeader } from '../../components/common/PullRefreshHeader';
import { SegmentRow } from './LibraryComponents';
import { SessionActions } from '../../viewmodel/library/SessionActions';
import {
  FAVORITES_MODE_ONLINE,
  FAVORITES_MODE_ONLINE_LIKES,
  FAVORITES_MODE_ONLINE_WATCH_LATER,
  FAVORITES_MODE_WATCH_LATER,
  favoriteSubtitle,
  isOnlineListMode,
  notifyLibraryChanged,
  onlineListEmptyHint,
  onlineListEmptyText,
  onlineListLoginHint,
  onlineListLoginTitle,
  onlineListTitle,
  onlineListType
} from '../../viewmodel/library/LibraryViewModel';

/** 本地 Tab 的标题 */
const TAB_TITLE_FAVORITES: string = '收藏';
const TAB_TITLE_WATCH_LATER: string = '稍后再看';
/** 在线历史的排序：站点 OnlineWatchHistorySort 的 3 个取值 */
const ONLINE_SORT_VALUES: string[] = ['latest', 'popular', 'oldest'];
const ONLINE_SORT_LABELS: string[] = ['最新', '最热', '最早'];
/** 本地双 Tab 模式下的页面标题（与站点在线列表区分） */
const LOCAL_PAGE_TITLE: string = '收藏与稍后再看';

@Component
export struct FavoritesPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 登录态：站点收藏/稍后再看需要登录，登录成功后自动加载 */
  @StorageLink('loggedIn') @Watch('onLoggedInChanged') loggedIn: boolean = false;
  /** 站点账号 id（RouteParam 缺失时兜底；登录后由 AppSettings 镜像刷新） */
  @StorageLink('userId') userId: string = '';
  /** 悬浮顶栏覆盖状态栏：列表首个 ListItem spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  /** 在线模式：'' = 本地双 Tab；其余见 LibraryViewModel 的 FAVORITES_MODE_* */
  @State onlineMode: string = '';
  /** 本地模式下的当前 Tab：0 收藏，1 稍后再看 */
  @State activeTab: number = 0;
  /** 在线历史模式下的排序下标（ONLINE_SORT_LABELS） */
  @State onlineSortIndex: number = 0;

  @State favorites: LocalVideoRecord[] = [];
  @State watchLater: LocalVideoRecord[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  /**
   * 下拉手势阶段：两种布局（本地网格 / 站点列表）的两个 Refresh 共用一份，
   * 只给 PullRefreshHeader 换文案用，不参与数据逻辑（KHenTai GalleryListView.ets:197）。
   */
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State hasLoaded: boolean = false;

  @State onlineItems: HanimeInfo[] = [];
  @State onlinePage: number = 1;
  @State onlineMaxPage: number = 1;
  @State loadingMore: boolean = false;
  @State errorMessage: string = '';

  private disposed: boolean = false;
  private lastLoadedAt: number = 0;
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    const mode: string = this.p.title;
    if (isOnlineListMode(mode)) {
      this.onlineMode = mode;
      this.loadOnline(true);
      return;
    }
    if (mode === FAVORITES_MODE_WATCH_LATER) {
      this.activeTab = 1;
    }
    this.loadLocal(false);
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /**
   * 登录态变化（登录成功 / 退出 / 登录过期）：
   *  - 页面处于站点在线模式时，登录成功立即自动加载，退出则清空并回到登录引导卡；
   *  - 本地模式不受影响（本地数据无需登录）。
   */
  onLoggedInChanged(): void {
    if (this.disposed || !isOnlineListMode(this.onlineMode)) {
      return;
    }
    if (!this.loggedIn) {
      this.onlineItems = [];
      this.onlinePage = 1;
      this.onlineMaxPage = 1;
      this.errorMessage = '';
      this.hasLoaded = false;
      this.loading = false;
      this.loadingMore = false;
      this.refreshing = false;
      return;
    }
    this.loadOnline(true);
  }

  // ---------------------------------------------------------------------------
  // 本地收藏 / 稍后再看
  // ---------------------------------------------------------------------------

  async loadLocal(refresh: boolean): Promise<void> {
    if (refresh) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    try {
      const repo: LocalRepo = LocalRepo.getInstance();
      const favorites: LocalVideoRecord[] = await repo.listFavoritesSorted();
      const watchLater: LocalVideoRecord[] = await repo.listWatchLaterSorted();
      if (this.disposed) {
        return;
      }
      this.favorites = favorites;
      this.watchLater = watchLater;
      this.hasLoaded = true;
      this.lastLoadedAt = Date.now();
      this.errorMessage = '';
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.errorMessage = describeError(e as Error);
    } finally {
      if (!this.disposed) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  private currentRecords(): LocalVideoRecord[] {
    return this.activeTab === 0 ? this.favorites : this.watchLater;
  }

  private currentSubtitle(record: LocalVideoRecord): string {
    return favoriteSubtitle(record, Date.now());
  }

  private removeLabel(): string {
    return this.activeTab === 0 ? '取消收藏' : '移除';
  }

  /** 取消收藏 / 移出稍后再看（只删本地库，站点数据不动） */
  async removeRecord(record: LocalVideoRecord): Promise<void> {
    try {
      const repo: LocalRepo = LocalRepo.getInstance();
      if (this.activeTab === 0) {
        await repo.setFavorite(record, false);
      } else {
        await repo.setWatchLater(record, false);
      }
      if (this.disposed) {
        return;
      }
      Toast.show(this.activeTab === 0 ? '已取消收藏' : '已移出稍后再看');
      notifyLibraryChanged();
      await this.loadLocal(false);
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  // ---------------------------------------------------------------------------
  // 站点在线列表（在线收藏 / 在线稍后再看 / 在线历史）
  // ---------------------------------------------------------------------------

  private onlineSortValue(): string {
    if (this.onlineSortIndex <= 0) {
      return ONLINE_SORT_VALUES[0];
    }
    if (this.onlineSortIndex === 1) {
      return ONLINE_SORT_VALUES[1];
    }
    return ONLINE_SORT_VALUES[2];
  }

  private onlineLoadingText(): string {
    if (this.onlineMode === FAVORITES_MODE_ONLINE_LIKES) {
      return '正在加载站点收藏…';
    }
    if (this.onlineMode === FAVORITES_MODE_ONLINE_WATCH_LATER) {
      return '正在加载稍后再看…';
    }
    return '正在加载在线历史…';
  }

  /**
   * 补齐站点 userId：RouteParam.userId → AppStorage['userId'] → getHome()。
   * 失败时把错误写进 errorMessage 供页面展示；登录过期交给 SessionActions 统一处理。
   */
  private async ensureUserId(): Promise<string> {
    if (this.p.userId.length > 0) {
      return this.p.userId;
    }
    if (this.userId.length > 0) {
      return this.userId;
    }
    try {
      const home = await this.api.getHome();
      if (home.userId.length > 0) {
        AppState.setUser(home.userId, home.username, home.avatarUrl);
        return home.userId;
      }
    } catch (e) {
      const error: Error = e as Error;
      if (error instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      if (!this.disposed) {
        this.errorMessage = describeError(error);
      }
    }
    return '';
  }

  /**
   * 加载站点在线列表。
   * @param reset true = 重新从第 1 页加载（首次进入 / 下拉刷新 / 排序切换 / 登录成功）；
   *              false = 触底加载下一页。
   */
  async loadOnline(reset: boolean): Promise<void> {
    if (!this.loggedIn) {
      this.onlineItems = [];
      this.onlinePage = 1;
      this.onlineMaxPage = 1;
      this.errorMessage = '';
      this.hasLoaded = false;
      this.loading = false;
      this.loadingMore = false;
      this.refreshing = false;
      return;
    }
    if (reset) {
      this.errorMessage = '';
      // 已有数据时（下拉刷新/回到本页）保留列表，避免整页闪成 LoadingView
      if (!this.hasLoaded) {
        this.loading = true;
      }
    } else {
      if (this.loadingMore || this.onlinePage >= this.onlineMaxPage) {
        return;
      }
      this.loadingMore = true;
    }

    const userId: string = await this.ensureUserId();
    if (this.disposed) {
      return;
    }
    // getHome 期间可能已退出登录 / 登录过期：交给 @Watch 的登录引导态，不再发清单请求
    if (!this.loggedIn) {
      this.loading = false;
      this.loadingMore = false;
      this.refreshing = false;
      return;
    }
    if (userId.length === 0) {
      this.loading = false;
      this.loadingMore = false;
      this.refreshing = false;
      if (this.errorMessage.length === 0) {
        this.errorMessage = '未能获取账号信息，请重新登录后再试';
      }
      return;
    }

    const page: number = reset ? 1 : this.onlinePage + 1;
    try {
      let result: MyListPage;
      if (this.onlineMode === FAVORITES_MODE_ONLINE) {
        result = await this.api.getOnlineHistory(userId, this.onlineSortValue(), page);
      } else {
        // 站点收藏 = likes，站点稍后再看 = saves（对齐 Android MyListType）
        result = await this.api.getMyList(userId, onlineListType(this.onlineMode), page);
      }
      if (this.disposed) {
        return;
      }
      if (reset) {
        this.onlineItems = result.items;
        this.onlinePage = 1;
      } else {
        const merged: HanimeInfo[] = [];
        for (let i = 0; i < this.onlineItems.length; i++) {
          merged.push(this.onlineItems[i]);
        }
        for (let i = 0; i < result.items.length; i++) {
          merged.push(result.items[i]);
        }
        this.onlineItems = merged;
        this.onlinePage = page;
      }
      this.onlineMaxPage = result.maxPage > 0 ? result.maxPage : 1;
      this.errorMessage = '';
      this.hasLoaded = true;
      this.lastLoadedAt = Date.now();
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
        this.refreshing = false;
        this.loadingMore = false;
      }
    }
  }

  private changeSort(index: number): void {
    if (index === this.onlineSortIndex) {
      return;
    }
    this.onlineSortIndex = index;
    this.loadOnline(true);
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /** 悬浮顶栏让位 spacer（放在滚动内容/列表首项，随内容滚走） */
  @Builder
  topSpacer() {
    Row()
      .width('100%')
      .height(this.statusBarHeight + Dimens.topBarHeight);
  }

  /** 本地双 Tab（收藏 / 稍后再看）：只返回胶囊本身，横向 padding 由调用方按所在容器补 */
  @Builder
  localTabs() {
    SegmentRow({
      options: [TAB_TITLE_FAVORITES, TAB_TITLE_WATCH_LATER],
      selectedIndex: this.activeTab,
      onSelect: (index: number) => {
        if (index !== this.activeTab) {
          this.activeTab = index;
        }
      }
    });
  }

  /** 在线历史排序胶囊：同上，只返回胶囊本身 */
  @Builder
  onlineSortTabs() {
    SegmentRow({
      options: ONLINE_SORT_LABELS,
      selectedIndex: this.onlineSortIndex,
      onSelect: (index: number) => {
        this.changeSort(index);
      }
    });
  }

  /**
   * 本地收藏 / 稍后再看卡片（自绘）：
   *  - 卡片左右 12、内边距 12，不再用「VideoListTile + 卡片外删除按钮」的横排（那样
   *    width 100% + margin 会向右溢出，出现「没有右边距」）；
   *  - 删除胶囊放在元信息行右侧；封面 116×66 + 右侧标题/元信息（间距 10/6）。
   */
  @Builder
  localRow(record: LocalVideoRecord) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(record.coverUrl)
            .width(116)
            .height(66)
            .objectFit(ImageFit.Cover)
            .borderRadius(Dimens.smallRadius)
            .backgroundColor(Theme.colors().surfaceVariant);
        }
        .width(116)
        .height(66)
        .clip(true);

        Column() {
          Text(record.title)
            .fontSize(14)
            .fontColor(Theme.colors().textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(19)
            .width('100%');

          Blank();

          Row() {
            Text(this.currentSubtitle(record))
              .fontSize(11)
              .fontColor(Theme.colors().textHint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            Text(this.removeLabel())
              .fontSize(11)
              .fontColor(Theme.colors().error)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .margin({ left: 8 })
              .borderRadius(999)
              .backgroundColor(Theme.colors().chipTint)
              .backgroundBlurStyle(Glass.CHIP_BLUR)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .onClick(() => {
                this.removeRecord(record);
              });
          }
          .width('100%');
        }
        .layoutWeight(1)
        .height(66)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 });
      }
      .width('100%');
    }
    .width('100%')
    .padding(12)
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      if (record.videoCode.length > 0) {
        Router.openVideo(record.videoCode);
      }
    });
  }

  @Builder
  onlineRow(item: HanimeInfo) {
    VideoListTile({
      item: item,
      subtitle: item.uploadTime.length > 0 ? item.uploadTime : item.views
    });
  }

  /** 未登录引导卡：说明站点收藏/稍后再看需要登录，并提供登录入口 */
  @Builder
  loginGuide() {
    Column() {
      Column() {
        Row() {
          Image($r('app.media.ic_login'))
            .width(26)
            .height(26)
            .fillColor(Theme.colors().primary);
        }
        .width(56)
        .height(56)
        .borderRadius(28)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.colors().primaryContainer)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });

        Text(onlineListLoginTitle(this.onlineMode))
          .fontSize(Dimens.subtitleSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.colors().textPrimary)
          .margin({ top: 14 })
          .textAlign(TextAlign.Center);

        Text(onlineListLoginHint(this.onlineMode))
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .lineHeight(17)
          .margin({ top: 6 })
          .textAlign(TextAlign.Center);

        Button('登录')
          .fontSize(Dimens.bodySize)
          .height(36)
          .margin({ top: 18 })
          .padding({ left: 26, right: 26 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
          .onClick(() => {
            Router.openLogin();
          });
      }
      .width('86%')
      .padding({ left: 24, right: 24, top: 26, bottom: 24 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().glassStrongTint)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .alignItems(HorizontalAlign.Center);
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  /** 在线历史排序条（仅在线历史模式出现；横向 padding 由本 builder 提供，所在容器不再加） */
  @Builder
  onlineSortBar() {
    Row() {
      this.onlineSortTabs();
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 10, bottom: 6 });
  }

  /** 本地双 Tab 条（列表内的版本：List 已有横向 12 边距，这里只补上下间距） */
  @Builder
  localTabBarInList() {
    Row() {
      this.localTabs();
    }
    .width('100%')
    .padding({ top: 10, bottom: 6 });
  }

  /** 本地双 Tab 条（非列表状态：加载/错误/空态，自行补左右 12） */
  @Builder
  localTabBar() {
    Row() {
      this.localTabs();
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 10, bottom: 6 });
  }

  @Builder
  localContent() {
    if (this.loading) {
      Column() {
        this.topSpacer();
        this.localTabBar();
        Column() {
          LoadingView({ text: '正在读取本地数据…' });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%');
    } else if (this.errorMessage.length > 0) {
      Column() {
        this.topSpacer();
        this.localTabBar();
        Column() {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.loadLocal(false);
            }
          });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%');
    } else if (this.currentRecords().length === 0) {
      Column() {
        this.topSpacer();
        this.localTabBar();
        Column() {
          EmptyView({
            text: this.activeTab === 0 ? '还没有本地收藏' : '稍后再看是空的',
            hint: this.activeTab === 0 ? '在视频详情页点击收藏按钮即可加入' : '在视频详情页点击稍后再看即可加入'
          });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%');
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: EmptyRefreshHeader }) {
        // 卡片自身不再带水平 margin，左右 12 边距由 List 横向 padding 提供；
        // 首个 ListItem 是悬浮顶栏让位 spacer（随列表滚走）。
        List({ space: 8 }) {
          ListItem() {
            this.topSpacer();
          }
          ListItem() {
            this.localTabBarInList();
          }
          ForEach(this.currentRecords(), (record: LocalVideoRecord) => {
            ListItem() {
              this.localRow(record);
            }
          }, (record: LocalVideoRecord) => record.videoCode + '@' + record.addedAt)
        }
        .width('100%')
        .height('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          bottom: this.navBarHeight + 16
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
      .width('100%')
      .height('100%')
      // 跟手 1:1 + 触发距离 110（同 KHenTai GalleryListView.ets:886-889）
      .pullDownRatio(1)
      .refreshOffset(110)
      .onRefreshing(() => {
        this.loadLocal(true);
      })
      .onStateChange((state: RefreshStatus) => {
        this.refreshStatus = state;
      });
    }
  }

  @Builder
  onlineContent() {
    if (!this.loggedIn) {
      Column() {
        this.topSpacer();
        if (this.onlineMode === FAVORITES_MODE_ONLINE) {
          this.onlineSortBar();
        }
        this.loginGuide();
      }
      .width('100%')
      .height('100%');
    } else if (this.loading) {
      Column() {
        this.topSpacer();
        if (this.onlineMode === FAVORITES_MODE_ONLINE) {
          this.onlineSortBar();
        }
        Column() {
          LoadingView({ text: this.onlineLoadingText() });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%');
    } else if (this.errorMessage.length > 0 && this.onlineItems.length === 0) {
      Column() {
        this.topSpacer();
        if (this.onlineMode === FAVORITES_MODE_ONLINE) {
          this.onlineSortBar();
        }
        Column() {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.loadOnline(true);
            }
          });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%');
    } else if (this.onlineItems.length === 0) {
      Column() {
        this.topSpacer();
        if (this.onlineMode === FAVORITES_MODE_ONLINE) {
          this.onlineSortBar();
        }
        Column() {
          EmptyView({
            text: onlineListEmptyText(this.onlineMode),
            hint: onlineListEmptyHint(this.onlineMode)
          });
        }
        .width('100%')
        .layoutWeight(1);
      }
      .width('100%')
      .height('100%');
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: EmptyRefreshHeader }) {
        // VideoListTile 自带上下各 5vp 外边距，List space 2 补足 12vp 列表项间距；
        // List 不加横向 padding，由每个 ListItem 的 calc 包装让卡片自带的 12vp 外边距完整可见。
        List({ space: 2 }) {
          ListItem() {
            this.topSpacer();
          }
          if (this.onlineMode === FAVORITES_MODE_ONLINE) {
            ListItem() {
              this.onlineSortBar();
            }
          }
          ForEach(this.onlineItems, (item: HanimeInfo) => {
            ListItem() {
              // VideoListTile 自带左右 12 外边距且 width 100%，直接放进 ListItem 会向右溢出、
              // 右边缘被裁掉（用户反馈的「没有右边距」）。外层 Row 先缩掉两侧 24vp，
              // 卡片自带的 12vp 外边距就完整落在屏幕左右 12vp 处。
              Row() {
                this.onlineRow(item);
              }
              .width('calc(100% - 24vp)');
            }
          }, (item: HanimeInfo) => item.videoCode)

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
          } else if (this.onlinePage >= this.onlineMaxPage) {
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
        .padding({ top: 6, bottom: this.navBarHeight + 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.loadOnline(false);
        });
      }
      .width('100%')
      .height('100%')
      // 与本地布局同一套手感参数（两个 Refresh 必须一致，否则切模式时手会「变」）
      .pullDownRatio(1)
      .refreshOffset(110)
      .onRefreshing(() => {
        this.loadOnline(true);
      })
      .onStateChange((state: RefreshStatus) => {
        this.refreshStatus = state;
      });
    }
  }

  build() {
    // 悬浮顶栏：内容（List/Refresh）铺满整页并在首项用 spacer 让出状态栏 + 顶栏高度，
    // AppTopBar 作为 Stack 覆盖层最后绘制，滚动时内容从渐变模糊顶栏下方经过。
    Stack({ alignContent: Alignment.TopStart }) {
      if (isOnlineListMode(this.onlineMode)) {
        this.onlineContent();
      } else {
        this.localContent();
      }

      // 下拉刷新浮层：本地 / 在线两个 Refresh 共用一颗，钉在悬浮顶栏下沿
      // （列表首项 spacer 就是 statusBarHeight + topBarHeight，见 topSpacer 的注释）。
      PullRefreshHeader({
        status: this.refreshStatus,
        refreshing: this.refreshing,
        topInset: this.statusBarHeight + Dimens.topBarHeight
      });

      AppTopBar({
        title: isOnlineListMode(this.onlineMode) ? onlineListTitle(this.onlineMode) : LOCAL_PAGE_TITLE,
        showBack: true
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      // 从视频详情页返回时刷新（收藏/稍后再看可能在详情页被改动）：
      // 本地模式刷新本地库，在线模式在已加载过的情况下静默刷新第 1 页。
      if (!isVisible || !this.hasLoaded || Date.now() - this.lastLoadedAt <= 800) {
        return;
      }
      if (isOnlineListMode(this.onlineMode)) {
        if (this.loggedIn) {
          this.loadOnline(true);
        }
      } else {
        this.loadLocal(true);
      }
    });
  }
}
