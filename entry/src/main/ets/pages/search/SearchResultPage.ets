/**
 * 搜索结果页（独立 NavDestination 页面，PuraPily 风格重做）。
 *
 * 两种入口（逻辑未改）：
 *  1. 首页分区「更多 / 查看更多」→ `Router.openSearchResult(分区标题)`：
 *     标题会在 viewmodel/home/HomeViewModel.findHomeSectionByTitle 里还原成该分区的
 *     genre/sort/tags 参数，按分区结果展示；
 *  2. 其他调用方传 `p.genre` → 直接按类型筛选；否则把 `p.query` 当关键词搜索。
 *
 * 视觉：悬浮顶栏（Stack 覆盖 + 网格首行 top spacer，滚动时卡片从渐变模糊顶栏下方经过）+ 结果网格
 * （「里番」分区用竖版 3:4 封面卡 RelatedVideoCard，其余分区/搜索仍用 16:9 VideoCard；gap 12；
 * 横屏固定 4 列，竖屏按窗口宽度断点 2~4 列；底部预留 navBarHeight + 16（二级页无悬浮底栏）。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { CloudflareChallengeError, describeError } from '../../logic/net/Errors';
import { AppSettings } from '../../logic/settings/AppSettings';
import { HanimeInfo, SearchRequest } from '../../core/model/Models';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, EmptyView, ErrorView, LoadingView, VideoCard } from '../../components/common/Widgets';
import { RelatedVideoCard } from '../video/RelatedVideoCard';
import { HomeSection, findHomeSectionByTitle } from '../../viewmodel/home/HomeViewModel';
import {
  SearchFilter,
  emptySearchFilter,
  hasSearchCondition,
  toSearchRequest
} from '../../viewmodel/search/SearchFilterModel';

/**
 * 结果网格列数断点（vp）：横屏（窗口宽 > 高）固定 4 列；
 * 竖屏按窗口宽度自适应 —— 宽 > 1000 用 4 列、> 720 用 3 列，其余（手机竖屏）保持 2 列；间距恒为 Dimens.gap(12)。
 */
const GRID_4_COLUMN_MIN_WIDTH: number = 1000;
const GRID_3_COLUMN_MIN_WIDTH: number = 720;
/** 首页「里番」分区的标题（只有这个分区「查看更多」的列表用 3:4 竖版封面卡） */
const SECTION_TITLE_R18: string = '里番';

@Component
export struct SearchResultPage {
  p: RouteParam = new RouteParam();
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：网格首行 spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State results: HanimeInfo[] = [];
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State errorMessage: string = '';
  @State needVerify: boolean = false;
  @State title: string = '搜索结果';
  /**
   * 是否使用竖版 3:4 封面卡：**只对「里番」分区「查看更多」列表开启**。
   * 其它分区（最新上传 / 泡面番 / Motion Anime / 3DCG / 2.5D / 2D 等）以及普通搜索、
   * 标签/作者搜索结果仍用公共 16:9 的 VideoCard。
   */
  @State portraitCards: boolean = false;
  @State hasCondition: boolean = true;
  /** 页面宽度（onAreaChange 更新）：驱动横屏 / 宽屏下的结果网格列数断点 */
  @State viewportWidth: number = 0;
  /** 页面高度（onAreaChange 更新）：与宽度比较判定横屏（宽 > 高时网格固定 4 列），0 表示尚未测量 */
  @State viewportHeight: number = 0;

  private disposed: boolean = false;
  private page: number = 1;
  private maxPage: number = 1;
  private seq: number = 0;
  private filter: SearchFilter = emptySearchFilter();
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    this.prepare();
    if (this.hasCondition) {
      this.runSearch(1, false);
    } else {
      this.loading = false;
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** 把路由参数还原成搜索条件 */
  private prepare(): void {
    const filter: SearchFilter = emptySearchFilter();
    const keyword: string = this.p.query.trim();
    const genreParam: string = this.p.genre.trim();
    let title: string = keyword;

    if (genreParam.length > 0) {
      filter.genre = genreParam;
      filter.query = keyword;
      if (title.length === 0) {
        title = genreParam;
      }
    } else if (keyword.length > 0) {
      const section: HomeSection | null = findHomeSectionByTitle(keyword);
      if (section !== null) {
        filter.genre = section.genre;
        filter.sort = section.sort;
        filter.tags = section.tags;
        // 分区可能只靠 sort 区分（如「最新上市」），query 留空
        filter.query = '';
      } else {
        filter.query = keyword;
      }
    }

    this.filter = filter;
    this.hasCondition = hasSearchCondition(filter);
    this.title = title.length > 0 ? title : '搜索结果';
    // 只有「里番」分区「查看更多」的列表用竖版 3:4 封面卡；其它分区 / 搜索 / 标签结果保持 16:9
    this.portraitCards = keyword === SECTION_TITLE_R18;
  }

  private async runSearch(targetPage: number, append: boolean): Promise<void> {
    const seq: number = this.seq + 1;
    this.seq = seq;
    if (append) {
      this.loadingMore = true;
    } else {
      this.loading = true;
      this.errorMessage = '';
      this.needVerify = false;
    }
    const request: SearchRequest = toSearchRequest(this.filter, targetPage);
    try {
      const result = await this.api.search(request);
      if (this.disposed || seq !== this.seq) {
        return;
      }
      const incoming: HanimeInfo[] = result.list;
      this.results = append ? this.mergeResults(this.results, incoming) : this.dedupeResults(incoming);
      this.page = targetPage;
      this.maxPage = result.maxPage > 0 ? result.maxPage : 1;
      this.errorMessage = '';
      this.needVerify = false;
    } catch (e) {
      if (this.disposed || seq !== this.seq) {
        return;
      }
      const error: Error = e as Error;
      const message: string = describeError(error);
      if (append) {
        Toast.show(message);
      } else {
        this.errorMessage = message;
        this.needVerify = error instanceof CloudflareChallengeError;
      }
    } finally {
      if (!this.disposed && seq === this.seq) {
        this.loading = false;
        this.loadingMore = false;
      }
    }
  }

  private loadMore(): void {
    if (this.loading || this.loadingMore || !this.hasCondition) {
      return;
    }
    if (this.page >= this.maxPage) {
      return;
    }
    this.runSearch(this.page + 1, true);
  }

  private dedupeResults(items: HanimeInfo[]): HanimeInfo[] {
    const seen: Set<string> = new Set<string>();
    const list: HanimeInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      const item: HanimeInfo = items[i];
      const key: string = item.videoCode.length > 0 ? item.videoCode : item.title;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      list.push(item);
    }
    return list;
  }

  private mergeResults(existing: HanimeInfo[], incoming: HanimeInfo[]): HanimeInfo[] {
    const merged: HanimeInfo[] = [];
    for (let i = 0; i < existing.length; i++) {
      merged.push(existing[i]);
    }
    for (let i = 0; i < incoming.length; i++) {
      merged.push(incoming[i]);
    }
    return this.dedupeResults(merged);
  }

  private openVerify(): void {
    Router.openWeb(AppSettings.getInstance().getBaseUrl(), 'Cloudflare 验证');
  }

  // ---------------------------------------------------------------------------
  // 响应式结果网格列数（横屏固定 4 列；竖屏按宽度断点 2~4 列；间距恒 12）
  // ---------------------------------------------------------------------------

  /** 结果网格列数：横屏（宽 > 高）固定四列；其余按窗口宽度断点（>1000 四列、>720 三列，其余两列） */
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

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @Builder
  verifyErrorCard() {
    Column() {
      Column() {
        Text('😵')
          .fontSize(38);
        Text(this.errorMessage)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textSecondary)
          .textAlign(TextAlign.Center)
          .lineHeight(21)
          .margin({ top: 10, left: 6, right: 6 });
        Row() {
          Button('重试')
            .fontSize(14)
            .height(36)
            .fontColor(Theme.colors().textPrimary)
            .backgroundColor(Theme.colors().chipTint)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
            .borderRadius(999)
            .onClick(() => {
              this.runSearch(1, false);
            });
          Button('去验证')
            .fontSize(14)
            .height(36)
            .margin({ left: 10 })
            .fontColor(Theme.colors().onPrimary)
            .backgroundColor(Theme.colors().primary)
            .borderRadius(999)
            .onClick(() => {
              this.openVerify();
            });
        }
        .margin({ top: 16 })
        .justifyContent(FlexAlign.Center);
      }
      .width('86%')
      .padding({ left: 20, right: 20, top: 24, bottom: 22 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().glassStrongTint)
      .backgroundBlurStyle(Glass.CARD_BLUR)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .shadow(Glass.cardShadow(Theme.colors().glassShadow));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }

  @Builder
  resultGrid() {
    Grid() {
      // 悬浮顶栏让位 spacer：跨全部列的首行，随网格滚走（滚动时卡片从顶栏下方经过）
      GridItem() {
        Row()
          .width('100%')
          .height(this.statusBarHeight + Dimens.topBarHeight);
      }
      .columnStart(0)
      .columnEnd(this.gridLastColumn());

      ForEach(this.results, (item: HanimeInfo) => {
        GridItem() {
          if (this.portraitCards) {
            // 仅「里番」分区「查看更多」列表：竖版 3:4 封面（与视频页「相关推荐」同一张卡）
            RelatedVideoCard({
              item: item,
              cardWidth: 0,
              onTap: () => {
                Router.openVideo(item.videoCode);
              }
            });
          } else {
            VideoCard({
              item: item,
              cardWidth: 0,
              onTap: () => {
                Router.openVideo(item.videoCode);
              }
            });
          }
        }
      }, (item: HanimeInfo) => 'result_' + item.videoCode + item.title)

      if (this.loadingMore) {
        GridItem() {
          Row() {
            LoadingProgress()
              .width(20)
              .height(20)
              .color(Theme.colors().primary);
            Text('加载更多…')
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().textSecondary)
              .margin({ left: 8 });
          }
          .width('100%')
          .height(44)
          .justifyContent(FlexAlign.Center)
          .borderRadius(Dimens.listRadius)
          .backgroundColor(Theme.colors().cardBg)
          .backgroundBlurStyle(Glass.CARD_BLUR)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());
      }

      // 底部留白：让开系统导航条
      GridItem() {
        Row()
          .width('100%')
          .height(this.navBarHeight + 16);
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
    .edgeEffect(EdgeEffect.Spring)
    .onReachEnd(() => {
      this.loadMore();
    });
  }

  build() {
    // 悬浮顶栏：网格铺满整页（首行 GridItem 是状态栏+顶栏让位 spacer），AppTopBar 覆盖在最上层。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (this.loading) {
          Column() {
            LoadingView({ text: '搜索中…' });
          }
          .width('100%')
          .layoutWeight(1);
        } else if (this.errorMessage.length > 0) {
          Column() {
            if (this.needVerify) {
              this.verifyErrorCard();
            } else {
              ErrorView({
                message: this.errorMessage,
                onRetry: () => {
                  this.runSearch(1, false);
                }
              });
            }
          }
          .width('100%')
          .layoutWeight(1);
        } else if (!this.hasCondition) {
          Column() {
            EmptyView({ text: '没有可搜索的内容', hint: '请从搜索结果或分区入口重新进入' });
          }
          .width('100%')
          .layoutWeight(1);
        } else if (this.results.length === 0) {
          Column() {
            EmptyView({ text: '没有找到相关内容', hint: '换个关键词试试' });
          }
          .width('100%')
          .layoutWeight(1);
        } else {
          this.resultGrid();
        }
      }
      .width('100%')
      .height('100%');

      AppTopBar({ title: this.title, showBack: true });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onAreaChange((_old: Area, area: Area) => {
      // 窗口尺寸驱动结果网格列数断点：横屏（宽 > 高）固定 4 列，竖屏按宽度断点切 2~4 列
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
