/**
 * “我的” Tab（Tabs 第三个 Tab 的内容页，无参数）。
 *
 * 结构：
 *  - 顶部自定义头部（不用 AppTopBar，因为 Tab 页没有“返回”）：高 topBarHeight + statusBarHeight，
 *    barTint + BAR_BLUR 背景覆盖状态栏，标题行 52 高并在状态栏下方；右侧设置齿轮；
 *  - 账号卡片：未登录 → 点击登录；已登录 → 头像 / 用户名 / 用户 ID / 退出登录；
 *  - 本地内容：收藏 / 稍后再看 / 观看历史（数量从 LocalRepo 读取）；
 *  - 在线内容（仅登录后）：我的清单 / 在线历史 / 账号资料；
 *  - 其它：设置 / 关于（版本 / GitHub / 许可证 / 免责声明）。
 *
 * 全屏窗口：根容器透明（壁纸透出），头部自行吃掉状态栏高度，内容底部
 * 预留 Dimens.bottomInset（悬浮底栏）+ navBarHeight（导航条）。
 *
 * 计数刷新：本页在 Tabs 里常驻，从收藏/历史页返回不会重新 aboutToAppear，
 * 因此监听 AppStorage['libraryVersion']（收藏/历史/设置/登录页改动后自增）。
 */

import { AppState } from '../../logic/state/AppState';
import { LocalRepo } from '../../logic/db/LocalRepo';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { describeError } from '../../logic/net/Errors';
import { HistoryRecord, LocalVideoRecord } from '../../core/model/Models';
import { APP_NAME, GITHUB_REPO_URL } from '../../core/util/Constants';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, ROUTE_FAVORITES, RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { GroupTitle, NavRow, ProfileCard, PROFILE_CARD_RADIUS, RowDivider } from './LibraryComponents';
import {
  FAVORITES_MODE_ONLINE,
  FAVORITES_MODE_WATCH_LATER,
  LibraryCounts,
  countValueText,
  notifyLibraryChanged
} from '../../viewmodel/library/LibraryViewModel';
import { SessionActions } from '../../viewmodel/library/SessionActions';

/** 与 AppScope/app.json5 的 versionName 保持一致 */
const APP_VERSION: string = '1.0.0';

@Component
export struct LibraryPage {
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 主题强调色：切主题色后返回本页也能即时换色 */
  @StorageLink('themeColor') themeColor: string = '#007DFF';
  /** 全屏窗口下的系统栏高度（EntryAbility 写入）：头部覆盖状态栏、列表底部避开导航条 */
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('navBarHeight') navBarHeight: number = 0;
  /** 登录态三件套由 AppSettings 镜像到 AppStorage，登录/退出后自动更新 */
  @StorageLink('loggedIn') loggedIn: boolean = false;
  @StorageLink('username') username: string = '';
  @StorageLink('avatarUrl') avatarUrl: string = '';
  @StorageLink('userId') userId: string = '';
  /** 本地库版本号：收藏/历史/设置页改动后 +1，这里刷新计数 */
  @StorageLink('libraryVersion') @Watch('onLibraryChanged') libraryVersion: number = 0;

  @State counts: LibraryCounts = new LibraryCounts();
  /** 内容进入动画：根内容 opacity 0→1 + 垂直 10→0（animateTo 240ms Curve.Friction） */
  @State contentOpacity: number = 0;
  @State contentOffsetY: number = 10;

  private disposed: boolean = false;
  private lastCountsLoadedAt: number = 0;
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    this.loadCounts();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  onLibraryChanged(): void {
    this.loadCounts();
  }

  /** 页面内容进入：淡入 + 轻微上移，只在首次出现时播放，避免列表滚动时重复触发 */
  private playEnterAnimation(): void {
    animateTo({ duration: 240, curve: Curve.Friction }, () => {
      this.contentOpacity = 1;
      this.contentOffsetY = 0;
    });
  }

  /** 读取本地收藏 / 稍后再看 / 历史数量；失败时静默（不打断页面） */
  async loadCounts(): Promise<void> {
    try {
      const repo: LocalRepo = LocalRepo.getInstance();
      const favorites: LocalVideoRecord[] = await repo.listFavoritesSorted();
      const watchLater: LocalVideoRecord[] = await repo.listWatchLaterSorted();
      const history: HistoryRecord[] = await repo.listHistorySorted();
      if (this.disposed) {
        return;
      }
      const next: LibraryCounts = new LibraryCounts();
      next.favorites = favorites.length;
      next.watchLater = watchLater.length;
      next.history = history.length;
      this.counts = next;
      this.lastCountsLoadedAt = Date.now();
    } catch (e) {
      // 本地库未就绪（首次启动）时保持 0，不弹错误
    }
  }

  private confirmLogout(): void {
    AlertDialog.show({
      title: '退出登录',
      message: '退出后本地收藏与观看历史仍会保留；在线清单、在线历史需要重新登录后查看。',
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
        }
      }
    });
  }

  /** 登录后userId理论上非空；若为空（例如只导入了 cookie）先用首页接口补齐账号信息 */
  private async ensureUserId(): Promise<string> {
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
      Toast.show(describeError(e as Error));
    }
    return '';
  }

  private async openPlaylists(): Promise<void> {
    const uid: string = await this.ensureUserId();
    if (uid.length === 0) {
      Toast.show('未能获取账号信息，请重新登录后再试');
      return;
    }
    Router.openPlaylists(uid);
  }

  private async openOnlineHistory(): Promise<void> {
    const uid: string = await this.ensureUserId();
    if (uid.length === 0) {
      Toast.show('未能获取账号信息，请重新登录后再试');
      return;
    }
    // Router 没有独立的在线历史路由：复用 FavoritesPage，用 RouteParam.title 传模式
    const p: RouteParam = new RouteParam();
    p.title = FAVORITES_MODE_ONLINE;
    p.userId = uid;
    Router.push(ROUTE_FAVORITES, p);
  }

  private async openAccount(): Promise<void> {
    if (!this.loggedIn) {
      Router.openLogin();
      return;
    }
    const uid: string = await this.ensureUserId();
    if (uid.length === 0) {
      Toast.show('未能获取账号信息，请重新登录后再试');
      return;
    }
    Router.openUserAccount(uid);
  }

  private openWatchLater(): void {
    const p: RouteParam = new RouteParam();
    p.title = FAVORITES_MODE_WATCH_LATER;
    Router.push(ROUTE_FAVORITES, p);
  }

  private showAbout(): void {
    const message: string = '版本 ' + APP_VERSION + '\n\n' +
      APP_NAME + ' 是 hanime1.me 的第三方客户端，仅用于技术研究与学习交流，' +
      '与站点无任何隶属或合作关系。\n\n' +
      '开源许可证：Apache License 2.0\n\n' +
      '免责声明：应用内可能包含仅限成年人浏览的内容（R18）。请确认您已年满 18 周岁，' +
      '并遵守所在地区法律法规，自行承担使用本应用产生的一切后果。';
    AlertDialog.show({
      title: '关于 ' + APP_NAME,
      message: message,
      confirm: {
        value: '关闭',
        action: () => {
        }
      }
    });
  }

  /**
   * 顶部玻璃浮条：整体高度 = topBarHeight + statusBarHeight，barTint + BAR_BLUR 背景覆盖状态栏；
   * 内部标题行高 52 并位于状态栏下方，标题 17 粗体，右侧设置齿轮（34 圆 chipTint）。
   */
  @Builder
  pageHeader() {
    Column() {
      Row() {
        Text('我的')
          .fontSize(Dimens.titleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .layoutWeight(1);

        Row() {
          Image($r('app.media.ic_settings'))
            .width(20)
            .height(20)
            .fillColor(Theme.colors().textPrimary);
        }
        .width(34)
        .height(34)
        .justifyContent(FlexAlign.Center)
        .borderRadius(17)
        .backgroundColor(Theme.colors().chipTint)
        .backgroundBlurStyle(Glass.CHIP_BLUR)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .onClick(() => {
          Router.openSettings();
        });
      }
      .width('100%')
      .height(Dimens.topBarHeight)
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });
    }
    .width('100%')
    .height(Dimens.topBarHeight + this.statusBarHeight)
    .padding({ top: this.statusBarHeight })
    .backgroundColor(Theme.colors().barTint)
    .backgroundBlurStyle(Glass.BAR_BLUR)
    .border({ width: { bottom: 0.5 }, color: Theme.colors().divider });
  }

  /** 账号卡：纯色大面板（圆角 24 + 1vp 描边，无阴影；cardBg 已是纯色不再叠模糊） */
  @Builder
  userCard() {
    if (this.loggedIn) {
      Row() {
        if (this.avatarUrl.length > 0) {
          Image(this.avatarUrl)
            .width(56)
            .height(56)
            .borderRadius(28)
            .objectFit(ImageFit.Cover)
            .backgroundColor(Theme.colors().surface)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        } else {
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
        }

        Column() {
          Text(this.username.length > 0 ? this.username : '已登录用户')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%');
          Text(this.userId.length > 0 ? '用户 ID：' + this.userId : '登录信息同步中…')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 4 })
            .width('100%');
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14, right: 8 });

        Text('退出登录')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().error)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .backgroundBlurStyle(Glass.CHIP_BLUR)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .onClick(() => {
            this.confirmLogout();
          });
      }
      .width('100%')
      .padding(18)
      .borderRadius(PROFILE_CARD_RADIUS)
      .backgroundColor(Theme.colors().cardBg)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(() => {
        this.openAccount();
      });
    } else {
      Row() {
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
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .margin({ right: 14 });

        Column() {
          Text('点击登录')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary);
          Text('登录后可查看我的清单、在线历史与账号资料')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .lineHeight(16)
            .margin({ top: 4 });
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ right: 8 });

        Text('登录')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().onPrimary)
          .padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().primary);
      }
      .width('100%')
      .padding(18)
      .borderRadius(PROFILE_CARD_RADIUS)
      .backgroundColor(Theme.colors().cardBg)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(() => {
        Router.openLogin();
      });
    }
  }

  /** 本地内容分组（ProfileCard 大卡，行间 0.5 发丝线） */
  @Builder
  localGroup() {
    ProfileCard() {
      NavRow({
        icon: $r('app.media.ic_heart'),
        title: '收藏',
        subtitle: '保存在本机的收藏',
        valueText: countValueText(this.counts.favorites),
        onTap: () => {
          Router.openFavorites();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_star'),
        title: '稍后再看',
        subtitle: '想稍后观看的影片',
        valueText: countValueText(this.counts.watchLater),
        onTap: () => {
          this.openWatchLater();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_clock'),
        title: '观看历史',
        subtitle: '本机的播放记录与进度',
        valueText: countValueText(this.counts.history),
        onTap: () => {
          Router.openHistory();
        }
      });
    }
  }

  /** 在线内容分组（仅登录后显示） */
  @Builder
  onlineGroup() {
    ProfileCard() {
      NavRow({
        icon: $r('app.media.ic_library'),
        title: '我的清单',
        subtitle: '站点的播放清单',
        onTap: () => {
          this.openPlaylists();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_clock'),
        title: '在线历史',
        subtitle: '站点同步的观看历史',
        onTap: () => {
          this.openOnlineHistory();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_login'),
        title: '账号资料',
        subtitle: '头像 / 邮箱 / 统计信息',
        onTap: () => {
          this.openAccount();
        }
      });
    }
  }

  /** 其它分组：设置 / 关于 / 上游项目 */
  @Builder
  otherGroup() {
    ProfileCard() {
      NavRow({
        icon: $r('app.media.ic_settings'),
        title: '设置',
        subtitle: '外观 / 网络 / 播放 / 隐私 / 存储',
        onTap: () => {
          Router.openSettings();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_star'),
        title: '关于 ' + APP_NAME,
        subtitle: '版本 ' + APP_VERSION + ' · Apache-2.0',
        onTap: () => {
          this.showAbout();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_share'),
        title: '上游项目（GitHub）',
        subtitle: '查看上游 Android 源码',
        onTap: () => {
          Router.openWeb(GITHUB_REPO_URL, 'Han1meViewer 上游项目');
        }
      });
    }
  }

  build() {
    Column() {
      this.pageHeader();

      List() {
        ListItem() {
          this.userCard();
        }

        ListItem() {
          GroupTitle({ text: '本地内容' });
        }

        ListItem() {
          this.localGroup();
        }

        if (this.loggedIn) {
          ListItem() {
            GroupTitle({ text: '在线内容' });
          }

          ListItem() {
            this.onlineGroup();
          }
        }

        ListItem() {
          GroupTitle({ text: '其它' });
        }

        ListItem() {
          this.otherGroup();
        }
      }
      .width('100%')
      .layoutWeight(1)
      .padding({
        left: Dimens.pagePadding,
        right: Dimens.pagePadding,
        top: 4,
        bottom: Dimens.bottomInset + this.navBarHeight
      })
      .opacity(this.contentOpacity)
      .translate({ y: this.contentOffsetY })
      .onAppear(() => {
        this.playEnterAnimation();
      })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      // 从其它页面（视频详情收藏/播放器记录历史）返回时刷新计数：
      // 其它 owner 的页面不会调用 notifyLibraryChanged，这里兜底。
      if (isVisible && Date.now() - this.lastCountsLoadedAt > 800) {
        this.loadCounts();
      }
    });
  }
}
