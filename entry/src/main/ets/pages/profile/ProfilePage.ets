/**
 * “我的”一级页（底部 Tab 第四个 Tab，对齐 Android 上游 ProfileScreen）。
 *
 * 结构（Stack 覆盖式：List 内容铺满整页，顶栏最后绘制成悬浮层）：
 *  - 悬浮顶栏（MaterialSurface 渐变模糊玻璃，覆盖状态栏）：标题「我的」+ 右侧玻璃材质设置齿轮圆钮；
 *  - List 首项是透明 spacer（高 = 顶栏高度，statusBarHeight + 52），滚动出后卡片从顶栏下方穿过被模糊采样；
 *    List 不再额外加 top padding，顶栏与首个内容卡的视觉间距固定 12（与内容库 Grid 的 rowsGap / 本页卡片间距一致）；
 *  - 账号卡：圆角 24、cardBg 纯色 + 1vp 描边、无阴影；
 *    未登录 → 头像占位 + “点击登录” + 登录胶囊；已登录 → 头像 / 用户名 / 用户 ID / 本地计数；
 *  - 账号与在线分组（圆角 24 分组卡、行高 52、图标块 30）：账号资料 / 在线清单 / 在线历史；
 *    未登录点击这些入口统一跳登录页；
 *  - 其它分组：设置 / 关于与开源许可；
 *  - 底部「退出登录」文字胶囊（error 色，AlertDialog 确认后调用 SessionActions.logout()）。
 *
 * 逻辑沿用原 LibraryPage：本地计数（收藏 / 稍后再看 / 观看历史）从 LocalRepo 读取，
 * 用 AppStorage['libraryVersion'] 与可见性变化兜底刷新；清单跳转在 userId 缺失时用首页接口补齐。
 * 底部预留 Dimens.bottomInset（悬浮底栏）+ navBarHeight（系统导航条）。
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
import { MaterialSurface } from '../../components/common/MaterialSurface';
import { GlassCapsule } from '../../components/common/GlassCapsule';
import { TOP_CONTROL_SIZE } from '../../components/common/Widgets';
import {
  GroupCard,
  GroupTitle,
  NavRow,
  PROFILE_CARD_RADIUS,
  RowDivider
} from '../library/LibraryComponents';
import {
  FAVORITES_MODE_ONLINE,
  LibraryCounts
} from '../../viewmodel/library/LibraryViewModel';
import { SessionActions } from '../../viewmodel/library/SessionActions';

/** 与 AppScope/app.json5 的 versionName 保持一致 */
const APP_VERSION: string = '1.0.0';

@Component
export struct ProfilePage {
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 主题强调色：切主题色后返回本页也能即时换色 */
  @StorageLink('themeColor') themeColor: string = '#007DFF';
  /** 登录态三件套由 AppSettings 镜像到 AppStorage，登录/退出后自动更新 */
  @StorageLink('loggedIn') loggedIn: boolean = false;
  @StorageLink('username') username: string = '';
  @StorageLink('avatarUrl') avatarUrl: string = '';
  @StorageLink('userId') userId: string = '';
  /** 本地库版本号：收藏/历史/设置页改动后 +1，这里刷新计数 */
  @StorageLink('libraryVersion') @Watch('onLibraryChanged') libraryVersion: number = 0;

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State counts: LibraryCounts = new LibraryCounts();
  /** 内容进入动画：opacity 0→1 + 垂直 10→0 */
  @State contentOpacity: number = 0;
  @State contentOffsetY: number = 10;

  private disposed: boolean = false;
  private lastCountsLoadedAt: number = 0;
  private api: HanimeApi = HanimeApi.getInstance();

  /** 悬浮顶栏总高（状态栏 + 52 标题行）：顶栏整体盖在内容之上，不再占用布局高度 */
  private headerHeight(): number {
    return this.statusBarHeight + Dimens.topBarHeight;
  }

  aboutToAppear(): void {
    this.loadCounts();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  onLibraryChanged(): void {
    this.loadCounts();
  }

  /** 页面内容进入：淡入 + 轻微上移，只在首次出现时播放 */
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

  /** 账号卡上的本地计数行（保留原“我的”页的计数展示） */
  private countsLine(): string {
    return '收藏 ' + this.counts.favorites + ' · 稍后再看 ' + this.counts.watchLater +
      ' · 观看历史 ' + this.counts.history;
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

  /** 登录后 userId 理论上非空；若为空（例如只导入了 cookie）先用首页接口补齐账号信息 */
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
    if (!this.loggedIn) {
      Router.openLogin();
      return;
    }
    const uid: string = await this.ensureUserId();
    if (uid.length === 0) {
      Toast.show('未能获取账号信息，请重新登录后再试');
      return;
    }
    Router.openPlaylists(uid);
  }

  private async openOnlineHistory(): Promise<void> {
    if (!this.loggedIn) {
      Router.openLogin();
      return;
    }
    const uid: string = await this.ensureUserId();
    if (uid.length === 0) {
      Toast.show('未能获取账号信息，请重新登录后再试');
      return;
    }
    // 路由没有独立的在线历史：复用 FavoritesPage，用 RouteParam.title 传模式
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

  private showAbout(): void {
    const message: string = '版本 ' + APP_VERSION + '\n\n' +
      APP_NAME + ' 是 hanime1.me 的第三方客户端，仅用于技术研究与学习交流，' +
      '与站点无任何隶属或合作关系。\n\n' +
      '开源许可证：Apache License 2.0\n' +
      '上游项目：' + GITHUB_REPO_URL + '\n\n' +
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

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /**
   * 悬浮顶栏：覆盖状态栏并盖在铺满整页的列表内容之上，标题 17 粗体 + 右侧设置齿轮
   * （44 沉浸材质圆钮，与搜索页控件同高）；底板走 MaterialSurface 的「渐变模糊玻璃」
   * （系统沉浸材质 + 单层 backdropBlur + 中性页面底色染色 + 底边 0.5vp 发丝分割线，
   * 材质不可用时回退 barTint + 厚模糊）。
   */
  @Builder
  pageHeader() {
    // 外层命中设为 Transparent：顶栏控件照常响应点击，空白处拖拽可穿透到下层列表滚动。
    Column() {
      MaterialSurface({ surfaceHeight: this.headerHeight(), radius: 0, kind: 'header' }) {
      Column() {
        Row() {
          Text('我的')
            .fontSize(Dimens.titleSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary)
            .layoutWeight(1);

          // 设置齿轮圆钮（44，与搜索页控件同高）：材质由 GlassCapsule 提供（与悬浮底栏同源），
          // 图标在内容层最上层，外层 Stack 承接点击。
          Stack({ alignContent: Alignment.Center }) {
            GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: TOP_CONTROL_SIZE / 2, kind: 'composer' }) {
              // 内容层（最上层，可点击）
              Row() {
                Image($r('app.media.ic_settings'))
                  .width(20)
                  .height(20)
                  .fillColor(Theme.colors().textPrimary);
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .borderRadius(TOP_CONTROL_SIZE / 2)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
            }
          }
          .width(TOP_CONTROL_SIZE)
          .height(TOP_CONTROL_SIZE)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Router.openSettings();
          });
        }
        .width('100%')
        .height(Dimens.topBarHeight)
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });
      }
      .width('100%')
      .height('100%')
      .padding({ top: this.statusBarHeight });
    }
    }
    // 以上两个 } 分别结束 MaterialSurface 底板与其外层透明容器
    .width('100%')
    .height(this.headerHeight())
    .hitTestBehavior(HitTestMode.Transparent);
  }

  /** 账号卡：圆角 24（PROFILE_CARD_RADIUS）+ 纯色卡 + 1vp 描边，无阴影；内部行高仍为 52 */
  @Builder
  accountCard() {
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
            Image($r('app.media.ic_person'))
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
            .margin({ top: 3 })
            .width('100%');
          Text(this.countsLine())
            .fontSize(11)
            .fontColor(Theme.colors().textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%');
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 14, right: 10 });

        Text('资料')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .padding({ left: 12, right: 12, top: 7, bottom: 7 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
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
          Image($r('app.media.ic_person'))
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
            .margin({ top: 3 });
          Text(this.countsLine())
            .fontSize(11)
            .fontColor(Theme.colors().textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%');
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

  /** 账号与在线分组：账号资料 / 在线清单 / 在线历史（圆角与账号大卡一致 = 24） */
  @Builder
  accountGroup() {
    GroupCard({ radius: PROFILE_CARD_RADIUS }) {
      NavRow({
        icon: $r('app.media.ic_login'),
        title: '账号资料',
        subtitle: '头像 / 邮箱 / 统计信息',
        onTap: () => {
          this.openAccount();
        }
      });
      RowDivider();
      NavRow({
        icon: $r('app.media.ic_library'),
        title: '在线清单',
        subtitle: '站点同步的播放清单',
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
    }
  }

  /** 其它分组：设置 / 关于与开源许可（圆角与账号大卡一致 = 24） */
  @Builder
  otherGroup() {
    GroupCard({ radius: PROFILE_CARD_RADIUS }) {
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
        title: '关于与开源许可',
        subtitle: '版本 ' + APP_VERSION + ' · Apache-2.0',
        onTap: () => {
          this.showAbout();
        }
      });
    }
  }

  /** 底部退出登录文字胶囊（error 色，二次确认） */
  @Builder
  logoutPill() {
    Row() {
      Text('退出登录')
        .fontSize(Dimens.bodySize)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.colors().error);
    }
    .width('100%')
    .height(48)
    .justifyContent(FlexAlign.Center)
    .borderRadius(999)
    .backgroundColor(Theme.colors().chipTint)
    .backgroundBlurStyle(Glass.CHIP_BLUR)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      this.confirmLogout();
    });
  }

  build() {
    // 覆盖式骨架：List 内容铺满整页，顶栏最后绘制成悬浮层；
    // 列表首项是透明 spacer（高度 = 状态栏 + 52 标题行），滚动后卡片会从顶栏下方穿过，
    // 顶栏 MaterialSurface 的渐变模糊/沉浸材质因此有内容可采样。
    Stack({ alignContent: Alignment.TopStart }) {
      List() {
        // 内容内 spacer：随列表一起滚动，只在首屏占位
        ListItem() {
          Row()
            .width('100%')
            .height(this.headerHeight());
        }

        // 首个内容卡与顶栏的视觉间距 = 该页其它卡片间距 12（与内容库 Grid 的 rowsGap 一致）；
        // spacer 仍严格等于「状态栏 + 52 标题行」，滚动时卡片从顶栏下方穿过。
        ListItem() {
          Column() {
            this.accountCard();
          }
          .width('100%')
          .padding({ top: Dimens.gap });
        }

        ListItem() {
          GroupTitle({ text: '账号与在线' });
        }

        ListItem() {
          this.accountGroup();
        }

        ListItem() {
          GroupTitle({ text: '其它' });
        }

        ListItem() {
          this.otherGroup();
        }

        if (this.loggedIn) {
          ListItem() {
            Column() {
              this.logoutPill();
            }
            .width('100%')
            .padding({ top: 18 });
          }
        }

        // 底部 spacer：与首页 / 我的订阅 / 内容库一致，把「悬浮底栏 + 系统导航条」的高度
        // 作为内容内的最后一项留白。这样列表视口始终铺到屏幕底部，内容会从悬浮底栏下方
        // 穿过（底栏下面是内容/卡片而不是一条页面底色），同时最后一项也能滚到胶囊上方。
        ListItem() {
          Row()
            .width('100%')
            .height(Dimens.bottomInset + this.navBarHeight);
        }
      }
      .width('100%')
      .height('100%')
      // 显式透明：列表自身不是一块纯色 / 白色容器，滚动到底部时底部留白与页面灰底连续，
      // 不会在悬浮底栏周围形成一条遮挡内容的整条底色（材质底栏 / 导航条区域可透出内容）。
      .backgroundColor(Color.Transparent)
      // 不再额外 top padding：顶栏下方间距只由「spacer 高度 + 首个内容卡的 12」决定，
      // 与内容库（spacer + rowsGap 12）/首页口径一致，避免顶栏下方多出一段间距。
      .padding({
        left: Dimens.pagePadding,
        right: Dimens.pagePadding
      })
      .opacity(this.contentOpacity)
      .translate({ y: this.contentOffsetY })
      .onAppear(() => {
        this.playEnterAnimation();
      })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);

      // 悬浮顶栏层（最后绘制，盖在内容之上）：背景层 hitTest None，不挡列表滚动
      this.pageHeader();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      // 从其它页面（视频详情收藏/播放器记录历史）返回时兜底刷新计数
      if (isVisible && Date.now() - this.lastCountsLoadedAt > 800) {
        this.loadCounts();
      }
    });
  }
}
