/**
 * 搜索页（独立 NavDestination 页面，PuraPily 风格；已从底部 Tab 移除，通过 Router.openSearch 打开）。
 *
 * 骨架（Stack 覆盖式）：内容铺满整页并从悬浮顶栏下方滚过，顶栏最后绘制：
 *  - 悬浮搜索顶栏：玻璃材质返回圆钮 + 玻璃材质胶囊搜索框
 *    （44 高 / 圆角 999：左侧放大镜 + 输入 + 右侧内嵌「搜索」小胶囊）+ 玻璃材质圆形筛选按钮；
 *  - 内容统一放进一个 Grid：首行透明 spacer（高 = 顶栏高度 - rowsGap）→ 搜索历史 TagChip 行
 *    → 筛选摘要胶囊行 → 结果网格（VideoCard，gap 12；横屏固定 4 列、
 *    竖屏按窗口宽度断点 2~4 列）；滚动时历史/结果都会从顶栏下方穿过。
 * 顶栏底板用 MaterialSurface 的渐变模糊玻璃（覆盖状态栏），根容器透明。
 *
 * 跨页契约（未改动）：
 *  - AdvancedSearchPage 把筛选条件写入 AppStorage['searchFilterJson']（JSON 见
 *    viewmodel/search/SearchFilterModel.ets 的注释），本页用
 *    `@StorageLink('searchFilterJson') @Watch('onFilterChanged')` 接收并自动开搜；
 *  - 条件未变化时 AdvancedSearchPage 额外写 AppStorage['searchTrigger']（递增时间戳），
 *    本页 `@StorageLink('searchTrigger') @Watch('onSearchTrigger')` 再次开搜；
 *  - 搜索历史来自 AppDb（addSearchHistory / listSearchHistory / deleteSearchHistory /
 *    clearSearchHistory），点击回填并立即搜索，长按删除单条。
 *
 * 分页：api.search 返回 maxPage，`page < maxPage` 时 Grid 触底加载下一页。
 */

import { AppDb } from '../../logic/db/AppDb';
import { HanimeApi } from '../../logic/net/HanimeApi';
import { CloudflareChallengeError, describeError } from '../../logic/net/Errors';
import { AppSettings } from '../../logic/settings/AppSettings';
import { HanimeInfo, SearchRequest } from '../../core/model/Models';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { ErrorView, EmptyView, LoadingView, TagChip, VideoCard, TOP_CONTROL_SIZE } from '../../components/common/Widgets';
import { MaterialSurface } from '../../components/common/MaterialSurface';
import { GlassCapsule } from '../../components/common/GlassCapsule';
import {
  SearchFilter,
  buildFilterSummary,
  decodeSearchFilter,
  emptySearchFilter,
  hasAdvancedFilter,
  hasSearchCondition,
  toSearchRequest
} from '../../viewmodel/search/SearchFilterModel';

/**
 * 结果网格列数断点（vp）：横屏（窗口宽 > 高）固定 4 列；
 * 竖屏按窗口宽度自适应 —— 宽 > 1000 用 4 列、> 720 用 3 列，其余（手机竖屏）保持 2 列；间距恒为 Dimens.gap(12)。
 */
const GRID_4_COLUMN_MIN_WIDTH: number = 1000;
const GRID_3_COLUMN_MIN_WIDTH: number = 720;
/** 顶部搜索栏高度：搜索胶囊 / 返回 / 筛选同高 44，上下各留 6vp（MaterialSurface 底板按这个高度铺） */
const SEARCH_HEADER_HEIGHT: number = 56;
/** 胶囊内右侧「搜索」按钮的尺寸（高 32、圆角 999，与评论输入框发送按钮同档） */
const INLINE_SEARCH_BTN_HEIGHT: number = 32;
/** 右侧高级筛选圆钮直径：与搜索胶囊/返回钮同高（全局顶栏控件统一 44） */
const FILTER_BTN_SIZE: number = TOP_CONTROL_SIZE;
/** 筛选生效时叠在材质圆钮内部的 primary 实心内盘直径（比外圈小 8vp，外圈仍透出材质） */
const FILTER_APPLIED_DISC: number = FILTER_BTN_SIZE - 8;
/** 加载 / 错误 / 空态在结果网格里占的高度（内容统一放进网格滚动，状态块给定高度） */
const SEARCH_STATE_HEIGHT: number = 380;

@Component
export struct SearchPage {
  p: RouteParam = new RouteParam();
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 高级筛选页写入的 JSON；变化时自动开搜 */
  @StorageLink('searchFilterJson') @Watch('onFilterChanged') searchFilterJson: string = '';
  /** 高级筛选页「应用」的强制开搜信号（条件未变化时也能重新搜索） */
  @StorageLink('searchTrigger') @Watch('onSearchTrigger') searchTrigger: number = 0;

  @State keyword: string = '';
  @State results: HanimeInfo[] = [];
  @State histories: string[] = [];
  @State loading: boolean = false;
  @State loadingMore: boolean = false;
  @State hasSearched: boolean = false;
  @State errorMessage: string = '';
  @State needVerify: boolean = false;
  @State filterApplied: boolean = false;
  @State filterSummary: string = '';
  /** 页面宽度（onAreaChange 更新）：驱动横屏 / 宽屏下的结果网格列数断点 */
  @State viewportWidth: number = 0;
  /** 页面高度（onAreaChange 更新）：与宽度比较判定横屏（宽 > 高时网格固定 4 列），0 表示尚未测量 */
  @State viewportHeight: number = 0;

  private disposed: boolean = false;
  private page: number = 1;
  private maxPage: number = 1;
  /** 请求序号：丢弃过期响应（连续搜索/筛选竞态） */
  private seq: number = 0;
  private filter: SearchFilter = emptySearchFilter();
  private api: HanimeApi = HanimeApi.getInstance();
  private db: AppDb = AppDb.getInstance();

  aboutToAppear(): void {
    this.loadHistories();
    // 回填上次应用的筛选条件：只恢复筛选状态，不自动搜索（避免每次打开搜索页都发请求）
    if (this.searchFilterJson.length > 0) {
      const restored: SearchFilter = decodeSearchFilter(this.searchFilterJson);
      this.filter = restored;
      this.filterApplied = hasAdvancedFilter(restored);
      this.filterSummary = buildFilterSummary(restored);
    }
    // 从首页搜索胶囊带关键词进入时直接开搜；空关键词则展示搜索历史/空态
    const preset: string = this.p.query.trim();
    if (preset.length > 0) {
      this.keyword = preset;
      this.startSearch();
    }
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** @StorageLink 变化回调（参数为变量名，ArkUI 约定签名） */
  onFilterChanged(propName: string): void {
    if (this.searchFilterJson.length === 0) {
      // 「重置」会把 key 清空：同步清掉本页筛选状态，但不发起搜索
      this.filter = emptySearchFilter();
      this.filterApplied = false;
      this.filterSummary = '';
      return;
    }
    this.applyFilter(decodeSearchFilter(this.searchFilterJson), true);
  }

  /**
   * 高级筛选页「应用」的强制开搜信号：条件 JSON 没变化时 @Watch(onFilterChanged)
   * 不会触发，用独立时间戳把「再搜一次」的意图传进来。
   */
  onSearchTrigger(propName: string): void {
    if (this.searchTrigger <= 0 || this.disposed) {
      return;
    }
    // 高级筛选里的关键词回填到搜索框（本页重开时只恢复了筛选、没恢复关键词）
    if (this.keyword.trim().length === 0 && this.filter.query.trim().length > 0) {
      this.keyword = this.filter.query;
    }
    if (this.keyword.trim().length === 0 && !hasAdvancedFilter(this.filter)) {
      return;
    }
    this.startSearch();
  }

  /** 应用筛选条件；autoSearch 为 true 且条件非空时立即搜索 */
  private applyFilter(filter: SearchFilter, autoSearch: boolean): void {
    this.filter = filter;
    this.filterApplied = hasAdvancedFilter(filter);
    this.filterSummary = buildFilterSummary(filter);
    if (filter.query.trim().length > 0) {
      this.keyword = filter.query;
    }
    if (autoSearch && hasSearchCondition(filter)) {
      this.startSearch();
    }
  }

  /** 记录关键词历史（失败不影响搜索本身） */
  private saveHistory(keyword: string): void {
    const trimmed: string = keyword.trim();
    if (trimmed.length === 0) {
      return;
    }
    this.db.addSearchHistory(trimmed).then(() => {
      this.loadHistories();
    }).catch((err: Error) => {
      // 搜索历史只是附属功能，写失败静默忽略
    });
  }

  async loadHistories(): Promise<void> {
    try {
      const list: string[] = await this.db.listSearchHistory();
      if (this.disposed) {
        return;
      }
      this.histories = list;
    } catch (err) {
      // 数据库未就绪时不影响搜索
    }
  }

  private deleteHistory(keyword: string): void {
    this.db.deleteSearchHistory(keyword).then(() => {
      this.loadHistories();
    }).catch((err: Error) => {
      Toast.show(describeError(err as Error));
    });
  }

  private clearHistories(): void {
    this.db.clearSearchHistory().then(() => {
      if (!this.disposed) {
        this.histories = [];
      }
    }).catch((err: Error) => {
      Toast.show(describeError(err as Error));
    });
  }

  /** 点击历史/搜索按钮入口：重置分页后执行搜索 */
  private startSearch(): void {
    const trimmed: string = this.keyword.trim();
    if (trimmed.length === 0 && !hasAdvancedFilter(this.filter)) {
      Toast.show('请输入搜索关键词');
      return;
    }
    this.hasSearched = true;
    this.page = 1;
    this.maxPage = 1;
    this.results = [];
    this.runSearch(false);
    this.saveHistory(trimmed);
  }

  /** 执行搜索；append=true 表示加载下一页 */
  private async runSearch(append: boolean): Promise<void> {
    const seq: number = this.seq + 1;
    this.seq = seq;
    const targetPage: number = append ? this.page + 1 : 1;
    if (append) {
      this.loadingMore = true;
    } else {
      this.loading = true;
      this.errorMessage = '';
      this.needVerify = false;
    }
    const request: SearchRequest = toSearchRequest(this.filter, targetPage);
    // 关键词以输入框为准（筛选 JSON 里的 query 仅用于回填）
    request.query = this.keyword.trim();
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
    if (this.loading || this.loadingMore || !this.hasSearched) {
      return;
    }
    if (this.page >= this.maxPage) {
      return;
    }
    this.runSearch(true);
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

  private clearFilter(): void {
    this.filter = emptySearchFilter();
    this.filterApplied = false;
    this.filterSummary = '';
    this.searchFilterJson = '';
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 系统导航条高度：独立页面没有悬浮底栏，底部只需避开导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  /** 悬浮搜索顶栏总高（状态栏 + 56 搜索行）：整体盖在内容之上，不再占用布局高度 */
  private headerHeight(): number {
    return this.statusBarHeight + SEARCH_HEADER_HEIGHT;
  }

  /**
   * 内容首部透明 spacer：让首屏（搜索历史/筛选摘要）仍从顶栏下沿开始；
   * Grid 有 12 的 rowsGap，spacer 行与下一行之间还会多出 12vp，所以减掉一个 gap。
   */
  private topSpacerHeight(): number {
    const height: number = this.headerHeight() - Dimens.gap;
    return height > 0 ? height : 0;
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

  @Builder
  searchBar() {
    // 悬浮搜索顶栏：MaterialSurface 的「渐变模糊玻璃」底板（含状态栏区域）——
    // 系统沉浸材质 Row（CommonModifier 挂 systemMaterial）+ 单层 backdropBlur
    // + 中性页面底色染色 + 底边 0.5vp 发丝分割线；材质不可用时回退 barTint + 厚模糊。
    // 作为页面 Stack 的最后绘制层盖在内容之上，所有背景层命中穿透，不挡输入框、返回/筛选按钮。
    // 外层命中设为 Transparent：顶栏控件照常响应点击，空白处拖拽可穿透到下层结果网格滚动。
    Column() {
      MaterialSurface({ surfaceHeight: this.headerHeight(), radius: 0, kind: 'header' }) {
      Column() {
        Row() {
          // 返回圆钮（独立页面，44 = 与搜索胶囊同高）：材质由 GlassCapsule 提供（与悬浮底栏同源），
          // 图标在内容层最上层；整行 alignItems(VerticalAlign.Center) 保证与搜索胶囊垂直居中对齐。
          Stack({ alignContent: Alignment.Center }) {
            GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: TOP_CONTROL_SIZE / 2, kind: 'composer' }) {
              Row() {
                Image($r('app.media.ic_back'))
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
          .margin({ right: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Router.pop();
          });

          // 玻璃胶囊搜索框（44 高 / 圆角 999）：左侧放大镜 + 输入，右侧内嵌「搜索」按钮
          //（不再有外置的大圆形搜索按钮，搜索动作收进胶囊内部，和评论输入框的发送按钮同一套观感）
          // 材质含在 GlassCapsule 内，输入区/按钮都在内容层，胶囊可点、可聚焦。
          Stack({ alignContent: Alignment.Center }) {
            GlassCapsule({ capsuleHeight: 44, capsuleRadius: 999, kind: 'composer' }) {
              // 内容层（最上层）：输入区可交互，背景材质层命中穿透
              Row() {
                Image($r('app.media.ic_search'))
                .width(18)
                .height(18)
                .fillColor(Theme.colors().textHint)
                .margin({ right: 8 });
              TextInput({ text: $$this.keyword, placeholder: '搜索视频、标签…' })
                .layoutWeight(1)
                .height(40)
                .padding({ left: 0, right: 0 })
                .backgroundColor(Color.Transparent)
                .fontSize(14)
                .fontColor(Theme.colors().textPrimary)
                .placeholderColor(Theme.colors().textHint)
                .placeholderFont({ size: 14 })
                .caretColor(Theme.colors().primary)
                .onSubmit(() => {
                  this.startSearch();
                });
              if (this.keyword.length > 0) {
                Image($r('app.media.ic_close'))
                  .width(15)
                  .height(15)
                  .fillColor(Theme.colors().textHint)
                  .margin({ right: 6 })
                  .onClick(() => {
                    this.keyword = '';
                  });
              }
              // 胶囊内右侧「搜索」小按钮：primary 填充 + 白字，高 32 / 圆角 999
              Row() {
                Text('搜索')
                  .fontSize(12)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.colors().onPrimary);
              }
              .height(INLINE_SEARCH_BTN_HEIGHT)
              .padding({ left: 12, right: 12 })
              .borderRadius(999)
              .justifyContent(FlexAlign.Center)
              .backgroundColor(Theme.colors().primary)
              .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
              .onClick(() => {
                this.startSearch();
              });
            }
              .width('100%')
              .height('100%')
              .padding({ left: 14, right: 5 })
              .borderRadius(999)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
            }
          }
          .layoutWeight(1)
          .height(44);

          // 高级筛选入口（44，与搜索胶囊/返回钮同高）：材质圆钮由 GlassCapsule 提供；
          // 筛选生效时在材质层上叠一枚 primary 实心内盘（44 → 36），外圈仍透出材质，
          // 状态一眼可辨且不整块盖掉材质。
          Stack({ alignContent: Alignment.Center }) {
            GlassCapsule({ capsuleHeight: FILTER_BTN_SIZE, capsuleRadius: FILTER_BTN_SIZE / 2, kind: 'composer' }) {
              Row() {
                if (this.filterApplied) {
                  Row() {
                    Image($r('app.media.ic_filter'))
                      .width(18)
                      .height(18)
                      .fillColor(Theme.colors().onPrimary);
                  }
                  .width(FILTER_APPLIED_DISC)
                  .height(FILTER_APPLIED_DISC)
                  .borderRadius(FILTER_APPLIED_DISC / 2)
                  .justifyContent(FlexAlign.Center)
                  .backgroundColor(Theme.colors().primary);
                } else {
                  Image($r('app.media.ic_filter'))
                    .width(18)
                    .height(18)
                    .fillColor(Theme.colors().textSecondary);
                }
              }
              .width('100%')
              .height('100%')
              .justifyContent(FlexAlign.Center)
              .borderRadius(FILTER_BTN_SIZE / 2)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
            }
          }
          .width(FILTER_BTN_SIZE)
          .height(FILTER_BTN_SIZE)
          .margin({ left: 8 })
          .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
          .onClick(() => {
            Router.openAdvancedSearch();
          });
        }
        .width('100%')
        .height(SEARCH_HEADER_HEIGHT)
        .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding })
        .alignItems(VerticalAlign.Center);
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

  @Builder
  historySection() {
    Column() {
      Row() {
        Text('搜索历史')
          .fontSize(Dimens.subtitleSize)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.colors().textPrimary)
          .layoutWeight(1);
        Text('清空')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .onClick(() => {
            this.clearHistories();
          });
      }
      .width('100%')
      .padding({ bottom: 6 });

      Scroll() {
        Row() {
          ForEach(this.histories, (item: string) => {
            // 公共 TagChip 没有手势参数，这里用外层容器承接长按删除
            Column() {
              TagChip({
                text: item,
                selected: false,
                onTap: () => {
                  this.keyword = item;
                  this.startSearch();
                }
              });
            }
            .gesture(LongPressGesture().onAction(() => {
              this.deleteHistory(item);
            }));
          }, (item: string) => 'history_' + item)
        }
      }
      .width('100%')
      .height(38)
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off);
    }
    .width('100%')
    .padding({ top: 12, bottom: 2 });
  }

  @Builder
  filterSummaryRow() {
    Row() {
      Row() {
        Image($r('app.media.ic_filter'))
          .width(14)
          .height(14)
          .fillColor(Theme.colors().primary)
          .margin({ right: 8 });
        Text(this.filterSummary)
          .fontSize(11)
          .fontColor(Theme.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1);
        Text('清除筛选')
          .fontSize(11)
          .fontColor(Theme.colors().primary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .onClick(() => {
            this.clearFilter();
          });
      }
      .width('100%')
      .padding({ left: 14, right: 8 })
      .height(38)
      .borderRadius(19)
      .backgroundColor(Theme.colors().chipTint)
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .padding({ top: 10, bottom: 2 });
  }

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
              this.startSearch();
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

  /**
   * 页面内容：透明 spacer + 搜索历史/筛选摘要 + 结果网格/五态，全部放在同一个 Grid 里滚动。
   * 这样滚动时历史与结果都会从悬浮搜索顶栏下方穿过，顶栏的渐变模糊/沉浸材质才有内容可采样；
   * 「加载更多」胶囊单独叠在网格下方，不随滚动。
   */
  @Builder
  searchContent() {
    Stack({ alignContent: Alignment.Bottom }) {
      Grid() {
        // 内容内 spacer（跨全部列）：透明占位，随内容一起滚动
        GridItem() {
          Row()
            .width('100%')
            .height(this.topSpacerHeight());
        }
        .columnStart(0)
        .columnEnd(this.gridLastColumn());

        if (this.histories.length > 0) {
          GridItem() {
            this.historySection();
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        }

        if (this.filterApplied) {
          GridItem() {
            this.filterSummaryRow();
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        }

        // ---- 结果区：加载 / 错误 / 未搜索 / 空 / 网格 五态 ----
        if (this.loading) {
          GridItem() {
            Column() {
              LoadingView({ text: '搜索中…' });
            }
            .width('100%')
            .height(SEARCH_STATE_HEIGHT);
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        } else if (this.errorMessage.length > 0) {
          GridItem() {
            Column() {
              if (this.needVerify) {
                this.verifyErrorCard();
              } else {
                ErrorView({
                  message: this.errorMessage,
                  onRetry: () => {
                    this.startSearch();
                  }
                });
              }
            }
            .width('100%')
            .height(SEARCH_STATE_HEIGHT);
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        } else if (!this.hasSearched) {
          GridItem() {
            Column() {
              EmptyView({ text: '输入关键词开始搜索', hint: '也可以点右侧筛选按钮使用高级搜索' });
            }
            .width('100%')
            .height(SEARCH_STATE_HEIGHT);
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        } else if (this.results.length === 0) {
          GridItem() {
            Column() {
              EmptyView({ text: '没有找到相关内容', hint: '换个关键词或减少筛选条件试试' });
            }
            .width('100%')
            .height(SEARCH_STATE_HEIGHT);
          }
          .columnStart(0)
          .columnEnd(this.gridLastColumn());
        } else {
          ForEach(this.results, (item: HanimeInfo) => {
            GridItem() {
              VideoCard({
                item: item,
                cardWidth: 0,
                onTap: () => {
                  Router.openVideo(item.videoCode);
                }
              });
            }
          }, (item: HanimeInfo) => 'result_' + item.videoCode + item.title);
        }

        // 底部留白：避开系统导航条
        GridItem() {
          Row()
            .width('100%')
            .height(this.navBarHeight + 24);
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

      // 悬浮的「加载更多」玻璃胶囊（浮在底栏上方，不遮挡内容）
      if (this.loadingMore) {
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
        .height(36)
        .padding({ left: 14, right: 18 })
        .borderRadius(18)
        .backgroundColor(Theme.colors().barTint)
        .backgroundBlurStyle(Glass.BAR_BLUR)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .shadow(Glass.barShadow(Theme.colors().glassShadow))
        .margin({ bottom: this.navBarHeight + 10 });
      }
    }
    .width('100%')
    .height('100%');
  }

  build() {
    // 覆盖式骨架：内容（历史 / 筛选摘要 / 结果）铺满整页，滚动时从悬浮搜索顶栏下方穿过；
    // 顶栏作为最后绘制层盖在内容之上，MaterialSurface 的渐变模糊/沉浸材质有内容可采样。
    Stack({ alignContent: Alignment.TopStart }) {
      this.searchContent();

      // 悬浮搜索顶栏层：返回圆钮 / 搜索胶囊 / 筛选圆钮都盖在内容之上
      this.searchBar();
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
