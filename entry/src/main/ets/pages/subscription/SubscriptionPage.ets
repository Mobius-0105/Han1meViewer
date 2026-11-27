/**
 * 「我的订阅」Tab 页（底部 4 Tab 之一，由 Index.ets 挂载；本页不做 Tab 切换）。
 *
 * 对应 Android 上游 `ui/screen/home/SubscriptionScreen.kt` + `subscription/SubscriptionContent.kt`
 * + `MySubscriptionsViewModel.kt` 的功能：
 *  - 骨架用 Stack 覆盖：Refresh + Grid 内容铺满整页，顶栏作为最后绘制的悬浮层（MaterialSurface 渐变模糊玻璃）：
 *    标题「我的订阅」+ 玻璃材质刷新圆钮（44），未登录时右侧「登录」胶囊；
 *  - 网格首行是透明 spacer（高 = 顶栏高度 - rowsGap），滚动出后内容从顶栏下方穿过；
 *  - 未登录：居中卡片说明「登录后可查看订阅的作者与更新」+ 登录按钮；
 *  - 已登录：断点列数网格里依次放「订阅的作者」横向列表、「订阅视频更新」视频卡片（VideoCard）、
 *    底部「加载更多」胶囊；支持下拉刷新、错误重试、空态。
 *
 * 数据：`SubscriptionApi.getMySubscriptions(page)`（独立文件，避免并发修改 HanimeApi）。
 * 登录态：`AppStorage['loggedIn']`，登录/退出后 @Watch 自动重新加载或清空。
 *
 * 全屏窗口：根容器透明（Index 灰底透出），顶栏玻璃吃掉状态栏高度，内容底部预留
 * Dimens.bottomInset（悬浮底栏）+ navBarHeight（导航条）。
 */

import { MySubscriptions, SubscriptionArtist, SubscriptionVideo } from '../../core/model/Subscription';
import { HanimeInfo, ITEM_TYPE_NORMAL } from '../../core/model/Models';
import { SubscriptionApi } from '../../logic/net/SubscriptionApi';
import { LoginExpiredError, describeError } from '../../logic/net/Errors';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { EmptyView, ErrorView, LoadingView, VideoCard, TOP_CONTROL_SIZE } from '../../components/common/Widgets';
import { MaterialSurface } from '../../components/common/MaterialSurface';
import { GlassCapsule } from '../../components/common/GlassCapsule';
import { SessionActions } from '../../viewmodel/library/SessionActions';

/** 首屏 / 每页最多展示的视频条数（上游每页 60 条，这里按 2 列网格密度收窄） */
const PAGE_ITEM_LIMIT: number = 12;
/** 作者头像直径（Android `ArtistIconSize`） */
const ARTIST_AVATAR_SIZE: number = 56;
/** 作者横向列表单项宽度 */
const ARTIST_ITEM_WIDTH: number = 64;
/**
 * 网格列数断点（vp），与首页 HomePage 完全一致：
 * 横屏（窗口宽 > 高）固定 4 列；竖屏按窗口宽自适应 —— > 1000 用 4 列、> 720 用 3 列，
 * 其余（手机竖屏）保持 2 列；间距恒为 Dimens.gap(12)。宽屏下不把 2 列卡片拉成超宽大卡。
 */
const GRID_4_COLUMN_MIN_WIDTH: number = 1000;
const GRID_3_COLUMN_MIN_WIDTH: number = 720;

@Component
export struct SubscriptionPage {
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 主题强调色：设置页切色后返回本 Tab 立即生效 */
  @StorageLink('themeColor') themeColor: string = '#007DFF';
  /** 全屏窗口下的系统栏高度（EntryAbility 写入） */
  @StorageLink('statusBarHeight') statusBarHeight: number = 0;
  @StorageLink('navBarHeight') navBarHeight: number = 0;
  /** 登录态（AppSettings 镜像到 AppStorage）：登录/退出后自动重新加载 */
  @StorageLink('loggedIn') @Watch('onLoginChanged') loggedIn: boolean = false;

  @State artists: SubscriptionArtist[] = [];
  @State cards: HanimeInfo[] = [];
  @State maxPage: number = 1;
  @State currentPage: number = 0;
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State refreshing: boolean = false;
  @State errorMessage: string = '';
  @State hasData: boolean = false;
  /** 页面宽度（onAreaChange 更新）：驱动横屏 / 宽屏下的网格列数断点（与首页一致） */
  @State viewportWidth: number = 0;
  /** 页面高度（onAreaChange 更新）：与宽度比较判定横屏（宽 > 高时网格固定 4 列），0 表示尚未测量 */
  @State viewportHeight: number = 0;

  private disposed: boolean = false;
  /** 请求序号：刷新 / 加载更多 / 退出登录竞态时丢弃旧响应 */
  private seq: number = 0;

  /** 悬浮顶栏总高（状态栏 + 52 标题行）：顶栏整体盖在内容之上，不再占用布局高度 */
  private headerHeight(): number {
    return this.statusBarHeight + Dimens.topBarHeight;
  }

  /**
   * 内容首部透明 spacer：让首屏内容仍从顶栏下沿开始；
   * Grid 有 12 的 rowsGap，spacer 行与下一行之间还会多出 12vp，所以减掉一个 gap。
   */
  private topSpacerHeight(): number {
    const height: number = this.headerHeight() - Dimens.gap;
    return height > 0 ? height : 0;
  }

  // ---------------------------------------------------------------------------
  // 响应式网格列数（与首页一致：横屏固定 4 列；竖屏按宽度断点 2~4 列；间距恒 12）
  // ---------------------------------------------------------------------------

  /** 内容网格列数：横屏（宽 > 高）固定四列；其余窗口宽 > 1000 四列、> 720 三列，否则两列 */
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

  /** Grid 的 columnsTemplate 字符串（列数均分；ArkTS 里不能用动态属性访问，显式拼串） */
  private gridTemplate(): string {
    const columns: number = this.gridColumns();
    let template: string = '1fr';
    for (let i: number = 1; i < columns; i++) {
      template = template + ' 1fr';
    }
    return template;
  }

  /** 整行跨列 GridItem 的结束列下标（列数 - 1）：spacer / 作者区 / 标题 / 空态 / 底部留白等 */
  private gridLastColumn(): number {
    return this.gridColumns() - 1;
  }

  aboutToAppear(): void {
    if (this.loggedIn) {
      this.loadFirst(false);
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** 登录态变化：登录后自动加载第一页，退出后清空并停止加载 */
  onLoginChanged(): void {
    if (this.disposed) {
      return;
    }
    if (this.loggedIn) {
      this.currentPage = 0;
      this.hasData = false;
      this.loadFirst(false);
      return;
    }
    this.seq++;
    this.artists = [];
    this.cards = [];
    this.maxPage = 1;
    this.currentPage = 0;
    this.hasData = false;
    this.loading = false;
    this.loadingMore = false;
    this.refreshing = false;
    this.errorMessage = '';
  }

  // ---------------------------------------------------------------------------
  // 数据加载
  // ---------------------------------------------------------------------------

  /** 加载第一页；refreshMode=true 为下拉刷新（保留旧内容，失败只 Toast） */
  private async loadFirst(refreshMode: boolean): Promise<void> {
    if (!this.loggedIn) {
      return;
    }
    const seq: number = this.seq + 1;
    this.seq = seq;
    if (refreshMode) {
      this.refreshing = true;
    } else {
      this.loading = true;
      this.errorMessage = '';
    }
    try {
      const result: MySubscriptions = await SubscriptionApi.getMySubscriptions(1);
      if (this.disposed || seq !== this.seq) {
        return;
      }
      this.artists = result.artists;
      this.cards = this.toCards(result.videos);
      this.maxPage = result.maxPage > 0 ? result.maxPage : 1;
      this.currentPage = 1;
      this.hasData = true;
      this.errorMessage = '';
    } catch (rawError) {
      if (this.disposed || seq !== this.seq) {
        return;
      }
      const error: Error = rawError as Error;
      if (error instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      const message: string = describeError(error);
      if (this.hasData || refreshMode) {
        // 已有内容时刷新失败：保留旧内容，只轻提示
        Toast.show(message);
      } else {
        this.errorMessage = message;
      }
    } finally {
      if (!this.disposed && seq === this.seq) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  /** 加载下一页并追加；page >= maxPage 或正在加载时直接忽略 */
  private async loadMore(): Promise<void> {
    if (!this.loggedIn || this.loading || this.loadingMore ||
      this.currentPage <= 0 || this.currentPage >= this.maxPage) {
      return;
    }
    const targetPage: number = this.currentPage + 1;
    const seq: number = this.seq + 1;
    this.seq = seq;
    this.loadingMore = true;
    try {
      const result: MySubscriptions = await SubscriptionApi.getMySubscriptions(targetPage);
      if (this.disposed || seq !== this.seq) {
        return;
      }
      // 作者列表只在第 1 页取（站点翻页时会重复返回）
      if (this.artists.length === 0) {
        this.artists = result.artists;
      }
      const incoming: HanimeInfo[] = this.toCards(result.videos);
      this.cards = this.mergeCards(this.cards, incoming);
      this.currentPage = targetPage;
      this.maxPage = result.maxPage > 0 ? result.maxPage : this.maxPage;
      if (incoming.length === 0) {
        // 边界页返回空：停止继续加载
        this.maxPage = targetPage;
      }
    } catch (rawError) {
      if (this.disposed || seq !== this.seq) {
        return;
      }
      const error: Error = rawError as Error;
      if (error instanceof LoginExpiredError) {
        SessionActions.onSessionExpired();
      }
      Toast.show(describeError(error));
    } finally {
      if (!this.disposed && seq === this.seq) {
        this.loadingMore = false;
      }
    }
  }

  /** 顶部刷新圆钮：已登录则重新拉第一页，未登录不请求 */
  private refresh(): void {
    if (!this.loggedIn) {
      return;
    }
    if (this.loading || this.refreshing) {
      return;
    }
    this.loadFirst(this.hasData);
  }

  /** SubscriptionVideo → HanimeInfo（复用公共 VideoCard 组件） */
  private toCard(video: SubscriptionVideo): HanimeInfo {
    const info: HanimeInfo = {
      title: video.title,
      coverUrl: video.coverUrl,
      videoCode: video.videoCode,
      duration: video.duration,
      views: video.views,
      uploadTime: video.uploadTime,
      genre: '',
      reviews: video.reviews,
      currentArtist: video.currentArtist,
      itemType: ITEM_TYPE_NORMAL,
      playlistItemId: '',
      isPlaying: false
    };
    return info;
  }

  /** 取本页视频（最多 PAGE_ITEM_LIMIT 条）并转成 VideoCard 需要的 HanimeInfo */
  private toCards(videos: SubscriptionVideo[]): HanimeInfo[] {
    const result: HanimeInfo[] = [];
    const limit: number = videos.length > PAGE_ITEM_LIMIT ? PAGE_ITEM_LIMIT : videos.length;
    for (let i: number = 0; i < limit; i++) {
      result.push(this.toCard(videos[i]));
    }
    return result;
  }

  /** 合并分页结果：按 videoCode（缺失时用标题）去重，避免边界页重复条目 */
  private mergeCards(existing: HanimeInfo[], incoming: HanimeInfo[]): HanimeInfo[] {
    const merged: HanimeInfo[] = [];
    const seen: Set<string> = new Set<string>();
    for (let i: number = 0; i < existing.length; i++) {
      const item: HanimeInfo = existing[i];
      const key: string = item.videoCode.length > 0 ? item.videoCode : item.title;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(item);
    }
    for (let i: number = 0; i < incoming.length; i++) {
      const item: HanimeInfo = incoming[i];
      const key: string = item.videoCode.length > 0 ? item.videoCode : item.title;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      merged.push(item);
    }
    return merged;
  }

  /** 点击作者：去掉名字里的空格后按关键词搜索（对齐上游「点击作者 → 搜索」） */
  private artistQuery(artistName: string): string {
    return artistName.replace(/\s+/g, '');
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /**
   * 悬浮顶栏：MaterialSurface 的「渐变模糊玻璃」底板（系统沉浸材质 + 单层 backdropBlur
   * + 中性页面底色染色 + 底边 0.5vp 发丝分割线），材质不可用时回退 barTint + 厚模糊；
   * 整体高度 = topBarHeight + statusBarHeight（状态栏区域也覆盖），盖在铺满整页的滚动内容之上，
   * 标题行 52 高并位于状态栏下方，右侧刷新圆钮（44，沉浸材质）+ 未登录时的「登录」胶囊（同高 44）。
   */
  @Builder
  pageHeader() {
    // 外层命中设为 Transparent：顶栏控件照常响应点击，空白处拖拽可穿透到下层网格滚动。
    Column() {
      MaterialSurface({ surfaceHeight: this.headerHeight(), radius: 0, kind: 'header' }) {
      Column() {
        Row() {
          Text('我的订阅')
            .fontSize(Dimens.titleSize)
            .fontWeight(FontWeight.Bold)
            .fontColor(Theme.colors().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);

          // 刷新圆钮（44，与搜索页控件同高）：材质由 GlassCapsule 提供（与悬浮底栏同源），
          // 内容层放加载指示或刷新箭头，外层 Stack 承接点击。
          Stack({ alignContent: Alignment.Center }) {
            GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: TOP_CONTROL_SIZE / 2, kind: 'composer' }) {
              // 内容层（最上层，可点击）：加载中显示进度，否则显示刷新箭头
              Row() {
                if (this.loading || this.refreshing) {
                  LoadingProgress()
                    .width(20)
                    .height(20)
                    .color(Theme.colors().primary);
                } else {
                  // 无专用刷新图标资源：用文本箭头，44 材质圆钮与其它悬浮圆钮一致
                  Text('↻')
                    .fontSize(20)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.colors().textPrimary);
                }
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
            this.refresh();
          });

          if (!this.loggedIn) {
            // 未登录「登录」胶囊：主 CTA 保持 primary 实心（全页唯一的登录入口，
            // 需要最强的可发现性；且文字自适应宽度不适合固定宽度画布的玻璃胶囊宿主）。
            // 高度与其它顶栏控件统一为 44，Row 承载保证文字垂直居中。
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
            .margin({ left: 10 })
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

  /** 未登录：居中说明卡 + 登录按钮 */
  @Builder
  loginHint() {
    Column() {
      Column() {
        Text('🔒')
          .fontSize(34);
        Text('登录后可查看订阅的作者与更新')
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textSecondary)
          .textAlign(TextAlign.Center)
          .lineHeight(21)
          .margin({ top: 10, left: 6, right: 6 });
        Text('这里会展示你订阅的作者，以及他们最新投稿的影片。')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .textAlign(TextAlign.Center)
          .lineHeight(17)
          .margin({ top: 6, left: 6, right: 6 });
        Button('登录')
          .fontSize(14)
          .height(38)
          .padding({ left: 24, right: 24 })
          .margin({ top: 18 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .onClick(() => {
            Router.openLogin();
          });
      }
      .width('86%')
      .padding({ left: 20, right: 20, top: 24, bottom: 24 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().cardBg)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .height('100%')
    .padding({ top: this.headerHeight() })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  /** 「订阅的作者」区域（标题 + 横向列表） */
  @Builder
  artistsSection() {
    Column() {
      Row() {
        Text('订阅的作者')
          .fontSize(Dimens.subtitleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .layoutWeight(1);
        Text(this.artists.length + ' 位')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint);
      }
      .width('100%')
      .padding({ left: 4, right: 4, bottom: 8 });

      if (this.artists.length === 0) {
        Row() {
          Text('还没有订阅作者')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint);
        }
        .width('100%')
        .height(64)
        .justifyContent(FlexAlign.Center)
        .borderRadius(Dimens.listRadius)
        .backgroundColor(Theme.colors().chipTint)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
      } else {
        List({ space: 14 }) {
          ForEach(this.artists, (artist: SubscriptionArtist) => {
            ListItem() {
              Column() {
                if (artist.avatar.length > 0) {
                  Image(artist.avatar)
                    .width(ARTIST_AVATAR_SIZE)
                    .height(ARTIST_AVATAR_SIZE)
                    .borderRadius(ARTIST_AVATAR_SIZE / 2)
                    .objectFit(ImageFit.Cover)
                    .backgroundColor(Theme.colors().surfaceVariant)
                    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
                } else {
                  Row() {
                    Text(artist.artistName.length > 0 ? artist.artistName.substring(0, 1) : '?')
                      .fontSize(18)
                      .fontColor(Theme.colors().primary);
                  }
                  .width(ARTIST_AVATAR_SIZE)
                  .height(ARTIST_AVATAR_SIZE)
                  .justifyContent(FlexAlign.Center)
                  .borderRadius(ARTIST_AVATAR_SIZE / 2)
                  .backgroundColor(Theme.colors().primaryContainer)
                  .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
                }

                Text(artist.artistName)
                  .fontSize(Dimens.captionSize)
                  .fontColor(Theme.colors().textSecondary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                  .width(ARTIST_ITEM_WIDTH)
                  .margin({ top: 6 });
              }
              .width(ARTIST_ITEM_WIDTH)
              .alignItems(HorizontalAlign.Center)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                Router.openSearchResult(this.artistQuery(artist.artistName));
              });
            }
          }, (artist: SubscriptionArtist) => 'artist_' + artist.artistName + '_' + artist.avatar);
        }
        .listDirection(Axis.Horizontal)
        .width('100%')
        .height(88)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ top: 8 });
  }

  /** 「订阅视频更新」区域标题 */
  @Builder
  videosTitle() {
    Row() {
      Text('订阅视频更新')
        .fontSize(Dimens.subtitleSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().textPrimary)
        .layoutWeight(1);
    }
    .width('100%')
    .padding({ left: 4, right: 4, top: 6, bottom: 2 });
  }

  /** 底部「加载更多」胶囊；加载中禁用并换成加载指示 */
  @Builder
  loadMoreFooter() {
    Row() {
      if (this.loadingMore) {
        LoadingProgress()
          .width(18)
          .height(18)
          .color(Theme.colors().textHint);
        Text('加载中…')
          .fontSize(13)
          .fontColor(Theme.colors().textHint)
          .margin({ left: 6 });
      } else {
        Button('加载更多')
          .fontSize(13)
          .height(40)
          .padding({ left: 26, right: 26 })
          .backgroundColor(Theme.colors().chipTint)
          .fontColor(Theme.colors().primary)
          .borderRadius(999)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .enabled(!this.loading)
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
          .onClick(() => {
            this.loadMore();
          });
      }
    }
    .width('100%')
    .height(56)
    .justifyContent(FlexAlign.Center);
  }

  /** 已登录内容：下拉刷新 + 断点列数网格（作者区 / 标题 / 视频卡片 / 分页） */
  @Builder
  subscriptionContent() {
    Refresh({ refreshing: $$this.refreshing }) {
      Grid() {
        // 内容内 spacer（跨全部列）：透明占位，随内容一起滚动，滚出后内容从悬浮顶栏下方穿过
        GridItem() {
          Row()
            .width('100%')
            .height(this.topSpacerHeight());
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());

        GridItem() {
          this.artistsSection();
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());

        GridItem() {
          this.videosTitle();
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());

        ForEach(this.cards, (item: HanimeInfo) => {
          GridItem() {
            VideoCard({
              item: item,
              cardWidth: 0,
              onTap: () => {
                Router.openVideo(item.videoCode);
              }
            });
          }
        }, (item: HanimeInfo) => 'sub_video_' + item.videoCode + item.title);

        if (this.hasData && this.artists.length === 0 && this.cards.length === 0) {
          GridItem() {
            Column() {
              EmptyView({ text: '订阅列表还是空的', hint: '去作者主页订阅喜欢的作者吧' });
            }
            .width('100%')
            .height(380);
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        }

        if (this.cards.length > 0 && this.currentPage < this.maxPage) {
          GridItem() {
            this.loadMoreFooter();
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        }

        // 底部留白：给悬浮毛玻璃底栏 + 导航条让位（跨全部列）
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
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 8 })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .height('100%')
    .onRefreshing(() => {
      this.loadFirst(true);
    });
  }

  build() {
    // 覆盖式骨架：登录提示 / 加载 / 错误 / 网格内容都铺满整页，顶栏最后绘制成悬浮层。
    // 网格首行是透明 spacer，滚动时内容从顶栏下方穿过，顶栏渐变模糊/沉浸材质有内容可采样。
    Stack({ alignContent: Alignment.TopStart }) {
      if (!this.loggedIn) {
        this.loginHint();
      } else if (this.loading && !this.hasData) {
        Column() {
          LoadingView({ text: '正在加载订阅…' });
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.headerHeight() });
      } else if (this.errorMessage.length > 0 && !this.hasData) {
        Column() {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.loadFirst(false);
            }
          });
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.headerHeight() });
      } else {
        this.subscriptionContent();
      }

      // 悬浮顶栏层（最后绘制，盖在内容之上）：背景层 hitTest None，不挡内容滚动
      this.pageHeader();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onAreaChange((_old: Area, area: Area) => {
      // 窗口尺寸驱动网格列数断点（与首页一致）：横屏（宽 > 高）固定 4 列，竖屏按宽度断点切 2~4 列
      const width: number = Number(area.width);
      if (!isNaN(width) && width > 0 && Math.abs(width - this.viewportWidth) >= 0.5) {
        this.viewportWidth = width;
      }
      const height: number = Number(area.height);
      if (!isNaN(height) && height > 0 && Math.abs(height - this.viewportHeight) >= 0.5) {
        this.viewportHeight = height;
      }
    });
  }
}
