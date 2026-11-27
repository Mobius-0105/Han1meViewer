/**
 * 内容库一级页（底部 Tab 第三个 Tab，对齐 Android 上游 ContentLibraryScreen / ContentLibraryEntry）。
 *
 * 结构（Stack 覆盖式：整页内容就是一个网格 Grid，列数随窗口宽度自适应 2~4 列，顶栏最后绘制成悬浮层）：
 *  - 悬浮顶栏（MaterialSurface 渐变模糊玻璃覆盖状态栏）：标题「内容库」+ 右侧登录态
 *    （已登录显示 40 圆头像嵌 44 玻璃材质圆环，点击进账号资料页；未登录显示「登录」胶囊，同高 44）；
 *  - Grid 首行是透明 spacer（高 = 顶栏高度），滚动出后卡片从顶栏下方穿过被模糊采样；
 *  - 入口卡片：Grid（columnsGap/rowsGap 12 + 页面左右 padding 12；横屏固定 4 列，
 *    竖屏按窗口宽度断点 2~4 列），每张卡圆角 24（与「我的」页大卡 CARD_RADIUS_LARGE 一致）、
 *    cardBg 纯色 + 1vp 描边、无阴影；图标块 40×40 圆角 12（primaryContainer 底 + primary 图标）、
 *    标题 14、描述 12；
 *    - 收藏 / 稍后再看：站点在线数据（`user/{id}/likes|saves`），需要登录；未登录也可进入，
 *      页面内展示登录引导，登录成功后自动加载（与 Android 上游 FavVideo/WatchLater 一致）；
 *    - 我的清单：需要登录（站点在线播放清单），未登录点击直接跳登录页；
 *    - 观看历史：本地数据，无需登录；
 *    - 下载：功能占位，点击 Toast 提示。
 *    需要登录的入口在未登录时右上角显示 12 号「需登录」hint 角标。
 *  - 最近观看：本地观看历史横向卡片列表（有数据才显示，列表首尾留白 12、卡片间距 12；行高 176 与首页
 *    横滑分区一致，160 宽卡片实际高 164，留 12 余量，卡片信息区不被裁切），横滑卡与首页/搜索等双列卡同款
 *    VideoCard（默认圆角 8、封面贴满卡宽），不再用大圆角；本地历史没有站点播放量/上传者/上传时间，
 *    卡片按 LibraryViewModel.historyToHanime 的降级映射展示（封面时长 + 观看进度 + 最近观看时间），
 *    播放量缺失时不渲染该浮层，保证不出现一行空白。
 *
 * 数据：本地历史走 LocalRepo（relationalStore）；清单跳转需要 userId（登录后缺失时用首页接口补齐）。
 * 底部预留 Dimens.bottomInset（悬浮底栏）+ navBarHeight（系统导航条）。
 */

import { AppState } from '../../logic/state/AppState';
import { LocalRepo } from '../../logic/db/LocalRepo';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { describeError } from '../../logic/net/Errors';
import { HanimeInfo, HistoryRecord } from '../../core/model/Models';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, ROUTE_FAVORITES, RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { MaterialSurface } from '../../components/common/MaterialSurface';
import { GlassCapsule } from '../../components/common/GlassCapsule';
import { CARD_RADIUS_LARGE, VideoCard, TOP_CONTROL_SIZE } from '../../components/common/Widgets';
import {
  FAVORITES_MODE_ONLINE_LIKES,
  FAVORITES_MODE_ONLINE_WATCH_LATER,
  historyToHanime
} from '../../viewmodel/library/LibraryViewModel';

/**
 * 最近观看横向卡片的宽度与行高（与首页横滑分区 HomePage 的 RAIL_CARD_WIDTH / RAIL_HEIGHT 一致）：
 * VideoCard 160 宽卡实际高 = 160 × 9/16（封面 90）+ 74（标题 36 + 元信息行 24 + 上下内边距 14）= 164，
 * 行高 176 留 12 余量，时长浮层 / 标题两行 / 元信息行完整展示，不被列表裁切。
 */
const RECENT_CARD_WIDTH: number = 160;
const RECENT_RAIL_HEIGHT: number = 176;
/** 最近观看最多展示条数 */
const RECENT_LIMIT: number = 8;
/** 入口卡片固定高度（2 列网格等高） */
const ENTRY_CARD_HEIGHT: number = 112;
/**
 * 内容网格列数断点（vp）：横屏（窗口宽 > 高）固定 4 列；
 * 竖屏按窗口宽度自适应 —— 宽 > 1000 用 4 列、> 720 用 3 列，其余（手机竖屏）保持 2 列；间距恒为 Dimens.gap(12)。
 */
const GRID_4_COLUMN_MIN_WIDTH: number = 1000;
const GRID_3_COLUMN_MIN_WIDTH: number = 720;

/** 内容库入口定义（对应上游 ContentLibraryEntry：顺序 / 登录要求集中在这里） */
class LibraryEntry {
  /** 稳定标识，用于点击分发与 ForEach key */
  key: string = '';
  title: string = '';
  desc: string = '';
  requiresLogin: boolean = false;
}

/** 入口列表（顺序与上游一致：收藏 / 稍后再看 / 我的清单 / 观看历史 / 下载） */
function buildEntries(): LibraryEntry[] {
  const entries: LibraryEntry[] = [];

  const favorites: LibraryEntry = new LibraryEntry();
  favorites.key = 'favorites';
  favorites.title = '收藏';
  favorites.desc = '站点账号的收藏';
  favorites.requiresLogin = true;
  entries.push(favorites);

  const watchLater: LibraryEntry = new LibraryEntry();
  watchLater.key = 'watchLater';
  watchLater.title = '稍后再看';
  watchLater.desc = '站点账号的稍后再看';
  watchLater.requiresLogin = true;
  entries.push(watchLater);

  const playlists: LibraryEntry = new LibraryEntry();
  playlists.key = 'playlists';
  playlists.title = '我的清单';
  playlists.desc = '站点同步的播放清单';
  playlists.requiresLogin = true;
  entries.push(playlists);

  const history: LibraryEntry = new LibraryEntry();
  history.key = 'history';
  history.title = '观看历史';
  history.desc = '本机的播放记录与进度';
  history.requiresLogin = false;
  entries.push(history);

  const download: LibraryEntry = new LibraryEntry();
  download.key = 'download';
  download.title = '下载';
  download.desc = '离线缓存即将支持';
  download.requiresLogin = false;
  entries.push(download);

  return entries;
}

@Component
export struct ContentLibraryPage {
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  @StorageLink('themeColor') themeColor: string = '#007DFF';
  /** 登录态：站点在线入口（收藏/稍后再看/我的清单）需要登录，决定「需登录」角标与跳转 */
  @StorageLink('loggedIn') loggedIn: boolean = false;
  @StorageLink('userId') userId: string = '';
  /** 头像地址（AppSettings 镜像到 AppStorage，与首页头部同一套登录态） */
  @StorageLink('avatarUrl') avatarUrl: string = '';
  /** 本地库版本号：收藏/历史页改动后刷新最近观看 */
  @StorageLink('libraryVersion') @Watch('onLibraryChanged') libraryVersion: number = 0;

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State entries: LibraryEntry[] = [];
  @State recent: HanimeInfo[] = [];
  /** 页面宽度（onAreaChange 更新）：驱动横屏 / 宽屏下的入口网格列数断点 */
  @State viewportWidth: number = 0;
  /** 页面高度（onAreaChange 更新）：与宽度比较判定横屏（宽 > 高时网格固定 4 列），0 表示尚未测量 */
  @State viewportHeight: number = 0;

  private disposed: boolean = false;
  private lastLoadedAt: number = 0;
  private api: HanimeApi = HanimeApi.getInstance();

  /** 悬浮顶栏总高（状态栏 + 52 标题行）：顶栏整体盖在内容之上，不再占用布局高度 */
  private headerHeight(): number {
    return this.statusBarHeight + Dimens.topBarHeight;
  }

  // ---------------------------------------------------------------------------
  // 响应式网格列数（横屏固定 4 列；竖屏按宽度断点 2~4 列；间距恒 12）
  // ---------------------------------------------------------------------------

  /** 入口网格列数：横屏（宽 > 高）固定四列；其余按窗口宽度断点（>1000 四列、>720 三列，其余两列） */
  private gridColumns(): number {
    if (this.viewportHeight > 0 && this.viewportWidth > this.viewportHeight) {
      return 4;
    }
    if (this.viewportWidth > GRID_4_COLUMN_MIN_WIDTH) {
      return 4;
    }
    if (this.viewportWidth > GRID_3_COLUMN_MIN_WIDTH) {
      return 3;
    }
    return 2;
  }

  /** Grid 的 columnsTemplate 字符串（列数均分；ArkTS 里不用动态属性访问，显式拼串） */
  private gridTemplate(): string {
    const columns: number = this.gridColumns();
    let template: string = '1fr';
    for (let i = 1; i < columns; i++) {
      template = template + ' 1fr';
    }
    return template;
  }

  /** 整行跨列 GridItem 的结束列下标（列数 - 1） */
  private gridLastColumn(): number {
    return this.gridColumns() - 1;
  }

  aboutToAppear(): void {
    this.entries = buildEntries();
    this.loadRecent();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  onLibraryChanged(): void {
    this.loadRecent();
  }

  /** 读取本地观看历史并转成横向卡片数据；失败静默（首次启动库未就绪） */
  async loadRecent(): Promise<void> {
    try {
      const repo: LocalRepo = LocalRepo.getInstance();
      const history: HistoryRecord[] = await repo.listHistorySorted();
      if (this.disposed) {
        return;
      }
      // 同一批卡片统一用同一个“当前时间”基准，保证右槽相对时间文案一致
      const now: number = Date.now();
      const items: HanimeInfo[] = [];
      for (let i = 0; i < history.length && items.length < RECENT_LIMIT; i++) {
        items.push(historyToHanime(history[i], now));
      }
      this.recent = items;
      this.lastLoadedAt = now;
    } catch (e) {
      // 本地库未就绪时保持空列表，不打断页面
    }
  }

  /** 入口图标（按 key 选资源，避免在数据类里存 Resource） */
  private iconOf(key: string): Resource {
    if (key === 'favorites') {
      return $r('app.media.ic_heart');
    }
    if (key === 'watchLater') {
      return $r('app.media.ic_star');
    }
    if (key === 'playlists') {
      return $r('app.media.ic_library');
    }
    if (key === 'history') {
      return $r('app.media.ic_clock');
    }
    return $r('app.media.ic_download');
  }

  /** 登录后 userId 理论上非空；为空（例如只导入了 cookie）时先用首页接口补齐账号信息 */
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

  /** 已登录账号入口（与首页头部一致）：有 userId 进账号资料页，缺失时去登录页补齐账号信息 */
  private openAccount(): void {
    if (this.userId.length > 0) {
      Router.openUserAccount(this.userId);
    } else {
      Router.openLogin();
    }
  }

  private async openPlaylists(): Promise<void> {
    const uid: string = await this.ensureUserId();
    if (uid.length === 0) {
      Toast.show('未能获取账号信息，请重新登录后再试');
      return;
    }
    Router.openPlaylists(uid);
  }

  /** 打开「收藏」：复用 FavoritesPage 的站点在线收藏模式（user/{id}/likes） */
  private openOnlineLikes(): void {
    this.openOnlineList(FAVORITES_MODE_ONLINE_LIKES);
  }

  /** 打开「稍后再看」：复用 FavoritesPage 的站点在线稍后再看模式（user/{id}/saves） */
  private openOnlineWatchLater(): void {
    this.openOnlineList(FAVORITES_MODE_ONLINE_WATCH_LATER);
  }

  /** 站点在线列表统一入口（RouteParam.title 传模式，页面自己解析 userId / 登录态） */
  private openOnlineList(mode: string): void {
    const p: RouteParam = new RouteParam();
    p.title = mode;
    Router.push(ROUTE_FAVORITES, p);
  }

  private onEntryTap(entry: LibraryEntry): void {
    // 收藏 / 稍后再看是站点在线列表：未登录也进入页面（页面内展示登录引导卡，
    // 登录成功后通过 @StorageLink('loggedIn') 自动加载），避免“点进去是空的本地库”。
    if (entry.key === 'favorites') {
      this.openOnlineLikes();
      return;
    }
    if (entry.key === 'watchLater') {
      this.openOnlineWatchLater();
      return;
    }
    if (entry.requiresLogin && !this.loggedIn) {
      Router.openLogin();
      return;
    }
    if (entry.key === 'playlists') {
      this.openPlaylists();
      return;
    }
    if (entry.key === 'history') {
      Router.openHistory();
      return;
    }
    Toast.show('下载功能暂未支持');
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /**
   * 悬浮顶栏：MaterialSurface 的「渐变模糊玻璃」底板（系统沉浸材质 + 单层 backdropBlur
   * + 中性页面底色染色 + 底边 0.5vp 发丝分割线，材质不可用时回退 barTint + 厚模糊）；
   * 覆盖状态栏并盖在铺满整页的滚动内容之上，标题 17 粗体（Tab 页没有返回按钮）；
   * 右侧登录态与首页一致——已登录显示 40 圆头像（嵌 44 沉浸材质圆环，无头像用 ic_person 材质圆钮），
   * 点击进账号资料页；未登录显示 primary「登录」胶囊（高度与圆钮统一 44）。
   */
  @Builder
  pageHeader() {
    // 外层命中设为 Transparent：顶栏控件照常响应点击，空白处拖拽可穿透到下层 Grid 滚动。
    Column() {
      MaterialSurface({ surfaceHeight: this.headerHeight(), radius: 0, kind: 'header' }) {
      Column() {
        Row() {
          Text('内容库')
            .fontSize(Dimens.titleSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary)
            .layoutWeight(1);

          if (this.loggedIn) {
            if (this.avatarUrl.length > 0) {
              // 已登录且拿到头像：40 圆头像嵌在 44 的 GlassCapsule 材质圆钮里
              //（与首页头部同一套控件材质：外圈 2vp 材质环，材质层命中穿透，内容层可点）
              Stack({ alignContent: Alignment.Center }) {
                GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: TOP_CONTROL_SIZE / 2, kind: 'composer' }) {
                  Row() {
                    Image(this.avatarUrl)
                      .width(40)
                      .height(40)
                      .borderRadius(20)
                      .objectFit(ImageFit.Cover)
                      .backgroundColor(Theme.colors().surfaceVariant)
                      .border({ width: 1, color: Theme.colors().glassBorder });
                  }
                  .width('100%')
                  .height('100%')
                  .justifyContent(FlexAlign.Center)
                  .borderRadius(TOP_CONTROL_SIZE / 2);
                }
              }
              .width(TOP_CONTROL_SIZE)
              .height(TOP_CONTROL_SIZE)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.openAccount();
              });
            } else {
              // 已登录但站点未返回头像：人形图标同样嵌进 44 的材质圆钮（保持同一入口）
              Stack({ alignContent: Alignment.Center }) {
                GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: TOP_CONTROL_SIZE / 2, kind: 'composer' }) {
                  Row() {
                    Image($r('app.media.ic_person'))
                      .width(18)
                      .height(18)
                      .fillColor(Theme.colors().textPrimary);
                  }
                  .width('100%')
                  .height('100%')
                  .justifyContent(FlexAlign.Center)
                  .borderRadius(TOP_CONTROL_SIZE / 2);
                }
              }
              .width(TOP_CONTROL_SIZE)
              .height(TOP_CONTROL_SIZE)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.openAccount();
              });
            }
          } else {
            // 未登录：primary 登录胶囊保持实心（主 CTA 需要最强可发现性，且文字自适应宽度
            // 不适合固定宽度画布的玻璃胶囊宿主）；高度与其它顶栏控件统一为 44，
            // Row 承载保证文字垂直居中。
            Row() {
              Text('登录')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.colors().onPrimary);
            }
            .height(TOP_CONTROL_SIZE)
            .padding({ left: 16, right: 16 })
            .borderRadius(999)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.colors().primary)
            .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
            .onClick(() => {
              Router.openLogin();
            });
          }
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

  /** 单个入口卡片：图标块 40×40 圆角 12 + 标题 14 + 描述 12，圆角 24 纯色卡 + 1vp 描边（与「我的」页一致） */
  @Builder
  entryCard(entry: LibraryEntry) {
    Column() {
      Row() {
        Row() {
          Image(this.iconOf(entry.key))
            .width(20)
            .height(20)
            .fillColor(Theme.colors().primary);
        }
        .width(40)
        .height(40)
        .borderRadius(12)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.colors().primaryContainer);

        Blank();

        // 未登录时给需要登录的入口加“需登录”角标（12 号 hint）
        if (entry.requiresLogin && !this.loggedIn) {
          Text('需登录')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(999)
            .backgroundColor(Theme.colors().chipTint)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        }
      }
      .width('100%');

      Blank();

      Text(entry.title)
        .fontSize(Dimens.bodySize)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.colors().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%');
      Text(entry.desc)
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textHint)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
        .width('100%');
    }
    .width('100%')
    .height(ENTRY_CARD_HEIGHT)
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .borderRadius(CARD_RADIUS_LARGE)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      this.onEntryTap(entry);
    });
  }

  @Builder
  recentHeader() {
    Row() {
      Text('最近观看')
        .fontSize(Dimens.subtitleSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().textPrimary)
        .layoutWeight(1);
      Text('全部')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textSecondary)
        .padding({ left: 10, right: 10, top: 4, bottom: 4 })
        .borderRadius(999)
        .backgroundColor(Theme.colors().chipTint)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .onClick(() => {
          Router.openHistory();
        });
    }
    .width('100%')
    // 只留标题与上一区块的间距；与下方横向列表的间距交给 Grid 的 rowsGap
    .padding({ top: 12 });
  }

  @Builder
  recentRail() {
    List({ space: 12 }) {
      ForEach(this.recent, (item: HanimeInfo) => {
        ListItem() {
          VideoCard({
            item: item,
            cardWidth: RECENT_CARD_WIDTH,
            onTap: () => {
              Router.openVideo(item.videoCode);
            }
          });
        }
      }, (item: HanimeInfo) => 'recent_' + item.videoCode + item.title)
    }
    .listDirection(Axis.Horizontal)
    .width('100%')
    .height(RECENT_RAIL_HEIGHT)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring);
  }

  build() {
    // 覆盖式骨架：整页就是一个网格 Grid（入口卡 + 最近观看），顶栏最后绘制成悬浮层。
    // Grid 首行是透明 spacer，滚动出后卡片/最近观看从顶栏下方穿过，顶栏的渐变模糊/沉浸材质才有内容可采样。
    // 页面左右 padding 12 + columnsGap 12：首列卡左留 12、末列卡右留 12，右边缘不再贴屏。
    Stack({ alignContent: Alignment.TopStart }) {
      Grid() {
        // 内容内 spacer（跨全部列）：透明占位，高度 = 状态栏 + 52 标题行
        GridItem() {
          Row()
            .width('100%')
            .height(this.headerHeight());
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());

        // 入口卡 2 列网格：收藏 / 稍后再看 / 我的清单 / 观看历史 / 下载
        ForEach(this.entries, (entry: LibraryEntry) => {
          GridItem() {
            this.entryCard(entry);
          }
        }, (entry: LibraryEntry) => 'library_entry_' + entry.key)

        if (this.recent.length > 0) {
          GridItem() {
            this.recentHeader();
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());

          GridItem() {
            this.recentRail();
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        }

        // 底部留白：悬浮底栏 + 系统导航条
        GridItem() {
          Row()
            .width('100%')
            .height(Dimens.bottomInset + this.navBarHeight);
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());
      }
      .columnsTemplate(this.gridTemplate())
      .columnsGap(Dimens.gap)
      .rowsGap(Dimens.gap)
      .width('100%')
      .height('100%')
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);

      // 悬浮顶栏层（最后绘制，盖在内容之上）：背景层 hitTest None，不挡内容滚动
      this.pageHeader();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onAreaChange((_old: Area, area: Area) => {
      // 窗口尺寸驱动入口网格列数断点：横屏（宽 > 高）固定 4 列，竖屏按宽度断点切 2~4 列
      const width: number = Number(area.width);
      if (!isNaN(width) && width > 0 && Math.abs(width - this.viewportWidth) >= 0.5) {
        this.viewportWidth = width;
      }
      const height: number = Number(area.height);
      if (!isNaN(height) && height > 0 && Math.abs(height - this.viewportHeight) >= 0.5) {
        this.viewportHeight = height;
      }
    })
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      // 从视频详情返回时刷新最近观看（其它页面不会主动通知）
      if (isVisible && Date.now() - this.lastLoadedAt > 800) {
        this.loadRecent();
      }
    });
  }
}
