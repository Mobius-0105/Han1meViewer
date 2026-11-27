/**
 * 高级搜索页（独立 NavDestination 页面，PuraPily 风格重做）。
 *
 * 提供（业务逻辑未改）：关键词（可选）、类型、排序、时长、发布日期、品牌（多选）、
 * 标签（按 7 个 scope 分组多选）、广泛搜索。数据来源：SearchOptionsStore
 * （rawfile/search_options/*.json，需 init 一次）。
 *
 * 视觉：悬浮顶栏（Stack 覆盖 + 内容 top spacer，滚动时从渐变模糊顶栏下方经过）+ 圆角 12 的分组玻璃面板 + TagChip 同款筛选胶囊 +
 * 圆角 30 的底部玻璃动作条（重置/应用两胶囊）。
 *
 * 提交（未改）：点「应用」把条件写进 AppStorage['searchFilterJson'] 后 Router.pop()；
 * 搜索页通过 @StorageLink + @Watch 接收，自动发起搜索；条件未变化（JSON 相同）时
 * 额外写 AppStorage['searchTrigger'] 触发搜索页再搜一次。
 * 「重置」清空全部选择并把 AppStorage 写成空筛选（搜索页只清状态、不搜索）。
 */

import { common } from '@kit.AbilityKit';
import { SearchOptionItem } from '../../core/model/Models';
import { SearchOptionsStore } from '../../logic/settings/SearchOptionsStore';
import { describeError } from '../../logic/net/Errors';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, LoadingView, TagChip } from '../../components/common/Widgets';
import {
  ALL_OPTION_LABEL,
  SearchFilter,
  containsValue,
  decodeSearchFilter,
  emptySearchFilter,
  encodeSearchFilter,
  isAllOptionKey,
  normalizeOptionKey,
  removeValues
} from '../../viewmodel/search/SearchFilterModel';

/** tags.json 作用域键 → 中文分组名（与 Android strings 一致）。 */
const SCOPE_LABELS: Record<string, string> = {
  'video_attributes': '影片属性',
  'character_relationships': '人物关系',
  'characteristics': '角色设定',
  'appearance_and_figure': '外貌身材',
  'story_plot': '故事剧情',
  'story_location': '情景场所',
  'sex_positions': '性交体位'
};

function scopeLabelOf(scope: string): string {
  const label: string | undefined = SCOPE_LABELS[scope];
  return label !== undefined ? label : scope;
}

/** 一个标签作用域分组（scope + 展示名 + 已过滤空 key 的选项）。 */
class TagScopeGroup {
  scope: string = '';
  label: string = '';
  items: SearchOptionItem[] = [];
}

@Component
export struct AdvancedSearchPage {
  p: RouteParam = new RouteParam();
  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：滚动内容顶部 spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部动作条避让系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  /** 与 SearchPage 约定的筛选条件 JSON */
  @StorageLink('searchFilterJson') searchFilterJson: string = '';

  @State keyword: string = '';
  @State genres: SearchOptionItem[] = [];
  @State sorts: SearchOptionItem[] = [];
  @State durations: SearchOptionItem[] = [];
  @State dates: SearchOptionItem[] = [];
  @State brands: SearchOptionItem[] = [];
  @State tagGroups: TagScopeGroup[] = [];
  @State optionsReady: boolean = false;

  @State selectedGenre: string = '';
  @State selectedSort: string = '';
  @State selectedDate: string = '';
  @State selectedDuration: string = '';
  @State selectedBrands: string[] = [];
  @State selectedTags: string[] = [];
  @State broad: boolean = false;

  private disposed: boolean = false;
  private store: SearchOptionsStore = SearchOptionsStore.getInstance();

  aboutToAppear(): void {
    this.restoreFromStorage();
    this.initOptions();
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** 打开时回填上一次应用的筛选条件 */
  private restoreFromStorage(): void {
    if (this.searchFilterJson.length === 0) {
      return;
    }
    const raw: SearchFilter = decodeSearchFilter(this.searchFilterJson);
    this.keyword = raw.query;
    this.selectedGenre = raw.genre;
    this.selectedSort = raw.sort;
    this.selectedDate = raw.date;
    this.selectedDuration = raw.duration;
    this.broad = raw.broad;
    this.selectedTags = raw.tags.slice();
    this.selectedBrands = raw.brands.slice();
  }

  private async initOptions(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      await this.store.init(ctx, 'zh-rCN');
      if (this.disposed) {
        return;
      }
      this.genres = this.withAllOption(this.store.genres());
      this.sorts = this.withAllOption(this.store.sorts());
      this.durations = this.withAllOption(this.store.durations());
      this.dates = this.withAllOption(this.store.dates());
      // 品牌是多选，不补「全部」（用「清除」语义的 chip 由 multiOptionSection 提供）
      this.brands = this.store.brands();
      this.tagGroups = this.buildTagGroups(this.store.tagScopes());
      this.optionsReady = true;
    } catch (err) {
      if (this.disposed) {
        return;
      }
      // 筛选项加载失败也允许只用关键词搜索，避免卡在加载态
      this.optionsReady = true;
      Toast.show(describeError(err as Error));
    }
  }

  /** 单选列表补一个「全部」项（站点 json 里可能已经有 key='全部'/'' 的项） */
  private withAllOption(items: SearchOptionItem[]): SearchOptionItem[] {
    const result: SearchOptionItem[] = [];
    let hasAll: boolean = false;
    for (let i = 0; i < items.length; i++) {
      if (isAllOptionKey(items[i].key)) {
        hasAll = true;
      }
    }
    if (!hasAll) {
      const all: SearchOptionItem = { label: ALL_OPTION_LABEL, key: '' };
      result.push(all);
    }
    for (let i = 0; i < items.length; i++) {
      result.push(items[i]);
    }
    return result;
  }

  private buildTagGroups(scopes: string[]): TagScopeGroup[] {
    const groups: TagScopeGroup[] = [];
    for (let i = 0; i < scopes.length; i++) {
      const scope: string = scopes[i];
      const items: SearchOptionItem[] = this.store.tagsByScope(scope);
      const group: TagScopeGroup = new TagScopeGroup();
      group.scope = scope;
      group.label = scopeLabelOf(scope);
      const filtered: SearchOptionItem[] = [];
      for (let j = 0; j < items.length; j++) {
        // search_key 为空的项没有提交价值（等同「全部」），不放出来
        if (items[j].key.length > 0) {
          filtered.push(items[j]);
        }
      }
      group.items = filtered;
      if (filtered.length > 0) {
        groups.push(group);
      }
    }
    return groups;
  }

  // ---------------------------------------------------------------------------
  // 选择逻辑
  // ---------------------------------------------------------------------------

  private isSingleSelected(field: string, rawKey: string): boolean {
    const key: string = normalizeOptionKey(rawKey);
    if (field === 'genre') {
      return this.selectedGenre === key;
    }
    if (field === 'sort') {
      return this.selectedSort === key;
    }
    if (field === 'date') {
      return this.selectedDate === key;
    }
    if (field === 'duration') {
      return this.selectedDuration === key;
    }
    return false;
  }

  private onSinglePick(field: string, rawKey: string): void {
    const key: string = normalizeOptionKey(rawKey);
    if (field === 'genre') {
      this.selectedGenre = this.selectedGenre === key ? '' : key;
    } else if (field === 'sort') {
      this.selectedSort = this.selectedSort === key ? '' : key;
    } else if (field === 'date') {
      this.selectedDate = this.selectedDate === key ? '' : key;
    } else if (field === 'duration') {
      this.selectedDuration = this.selectedDuration === key ? '' : key;
    }
  }

  private isBrandSelected(rawKey: string): boolean {
    return containsValue(this.selectedBrands, normalizeOptionKey(rawKey));
  }

  private toggleBrand(rawKey: string): void {
    const key: string = normalizeOptionKey(rawKey);
    if (key.length === 0) {
      this.selectedBrands = [];
      return;
    }
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.selectedBrands.length; i++) {
      if (this.selectedBrands[i] === key) {
        found = true;
      } else {
        next.push(this.selectedBrands[i]);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.selectedBrands = next;
  }

  private isTagSelected(rawKey: string): boolean {
    return containsValue(this.selectedTags, normalizeOptionKey(rawKey));
  }

  private toggleTag(rawKey: string): void {
    const key: string = normalizeOptionKey(rawKey);
    if (key.length === 0) {
      return;
    }
    const next: string[] = [];
    let found: boolean = false;
    for (let i = 0; i < this.selectedTags.length; i++) {
      if (this.selectedTags[i] === key) {
        found = true;
      } else {
        next.push(this.selectedTags[i]);
      }
    }
    if (!found) {
      next.push(key);
    }
    this.selectedTags = next;
  }

  private hasScopeSelection(group: TagScopeGroup): boolean {
    for (let i = 0; i < group.items.length; i++) {
      if (containsValue(this.selectedTags, group.items[i].key)) {
        return true;
      }
    }
    return false;
  }

  private clearScopeTags(group: TagScopeGroup): void {
    const keys: string[] = [];
    for (let i = 0; i < group.items.length; i++) {
      keys.push(group.items[i].key);
    }
    this.selectedTags = removeValues(this.selectedTags, keys);
  }

  // ---------------------------------------------------------------------------
  // 底部动作
  // ---------------------------------------------------------------------------

  private resetAll(): void {
    this.keyword = '';
    this.selectedGenre = '';
    this.selectedSort = '';
    this.selectedDate = '';
    this.selectedDuration = '';
    this.selectedBrands = [];
    this.selectedTags = [];
    this.broad = false;
    // 同步清空共享筛选状态（搜索页会清掉筛选但不搜索）
    this.searchFilterJson = encodeSearchFilter(emptySearchFilter());
  }

  private apply(): void {
    const filter: SearchFilter = new SearchFilter();
    filter.query = this.keyword.trim();
    filter.genre = this.selectedGenre;
    filter.sort = this.selectedSort;
    filter.date = this.selectedDate;
    filter.duration = this.selectedDuration;
    filter.broad = this.broad;
    filter.tags = this.selectedTags.slice();
    filter.brands = this.selectedBrands.slice();
    const nextJson: string = encodeSearchFilter(filter);
    // 条件没变化时 @Watch(onFilterChanged) 不会触发，用独立触发信号让搜索页再搜一次
    const unchanged: boolean = nextJson === this.searchFilterJson;
    this.searchFilterJson = nextJson;
    if (unchanged) {
      AppStorage.setOrCreate('searchTrigger', Date.now());
    }
    Router.pop();
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  /** 分组面板：圆角 12 + 70% 卡片底 + 薄模糊 + 1vp 描边（PuraPily 设置分组观感） */
  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(Dimens.captionSize)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.colors().textSecondary)
      .margin({ bottom: 9 });
  }

  @Builder
  keywordSection() {
    Column() {
      this.sectionTitle('关键词');
      TextInput({ text: $$this.keyword, placeholder: '可留空，仅用筛选条件搜索' })
        .width('100%')
        .height(42)
        .fontSize(14)
        .fontColor(Theme.colors().textPrimary)
        .placeholderColor(Theme.colors().textHint)
        .placeholderFont({ size: 14 })
        .backgroundColor(Theme.colors().chipTint)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .borderRadius(999)
        .padding({ left: 14, right: 14 });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 12 })
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .backgroundBlurStyle(Glass.CARD_BLUR)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .shadow(Glass.cardShadow(Theme.colors().glassShadow))
    .margin({ bottom: 10 });
  }

  @Builder
  singleOptionSection(title: string, field: string, items: SearchOptionItem[]) {
    Column() {
      this.sectionTitle(title);
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(items, (item: SearchOptionItem) => {
          TagChip({
            text: item.label,
            selected: this.isSingleSelected(field, item.key),
            onTap: () => {
              this.onSinglePick(field, item.key);
            }
          });
        }, (item: SearchOptionItem) => title + '_' + item.key + '_' + item.label)
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 6 })
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .backgroundBlurStyle(Glass.CARD_BLUR)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .shadow(Glass.cardShadow(Theme.colors().glassShadow))
    .margin({ bottom: 10 });
  }

  @Builder
  brandSection() {
    Column() {
      Row() {
        Text('品牌')
          .fontSize(Dimens.captionSize)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.colors().textSecondary)
          .layoutWeight(1);
        if (this.selectedBrands.length > 0) {
          Text('清除')
            .fontSize(10)
            .fontColor(Theme.colors().primary)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(999)
            .backgroundColor(Theme.colors().chipTint)
            .onClick(() => {
              this.selectedBrands = [];
            });
        }
      }
      .width('100%')
      .margin({ bottom: 10 });

      Flex({ wrap: FlexWrap.Wrap }) {
        TagChip({
          text: ALL_OPTION_LABEL,
          selected: this.selectedBrands.length === 0,
          onTap: () => {
            this.selectedBrands = [];
          }
        });
        ForEach(this.brands, (item: SearchOptionItem) => {
          TagChip({
            text: item.label,
            selected: this.isBrandSelected(item.key),
            onTap: () => {
              this.toggleBrand(item.key);
            }
          });
        }, (item: SearchOptionItem) => 'brand_' + item.key + '_' + item.label)
      }
      .width('100%');
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ left: 14, right: 14, top: 14, bottom: 6 })
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .backgroundBlurStyle(Glass.CARD_BLUR)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .shadow(Glass.cardShadow(Theme.colors().glassShadow))
    .margin({ bottom: 10 });
  }

  @Builder
  tagSections() {
    Column() {
      this.sectionTitle('标签（可多选，按分组）');
      ForEach(this.tagGroups, (group: TagScopeGroup) => {
        Column() {
          Row() {
            Text(group.label)
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().textHint)
              .layoutWeight(1);
            if (this.hasScopeSelection(group)) {
              Text('清除')
                .fontSize(10)
                .fontColor(Theme.colors().primary)
                .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                .borderRadius(999)
                .backgroundColor(Theme.colors().chipTint)
                .onClick(() => {
                  this.clearScopeTags(group);
                });
            }
          }
          .width('100%')
          .margin({ bottom: 10 });

          Flex({ wrap: FlexWrap.Wrap }) {
            TagChip({
              text: ALL_OPTION_LABEL,
              selected: !this.hasScopeSelection(group),
              onTap: () => {
                this.clearScopeTags(group);
              }
            });
            ForEach(group.items, (item: SearchOptionItem) => {
              TagChip({
                text: item.label,
                selected: this.isTagSelected(item.key),
                onTap: () => {
                  this.toggleTag(item.key);
                }
              });
            }, (item: SearchOptionItem) => group.scope + '_' + item.key + '_' + item.label)
          }
          .width('100%');
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ left: 14, right: 14, top: 14, bottom: 6 })
        .borderRadius(Dimens.listRadius)
        .backgroundColor(Theme.colors().cardBg)
        .backgroundBlurStyle(Glass.CARD_BLUR)
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
        .shadow(Glass.cardShadow(Theme.colors().glassShadow))
        .margin({ bottom: 10 });
      }, (group: TagScopeGroup) => group.scope)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  @Builder
  broadSection() {
    Row() {
      Column() {
        Text('广泛搜索')
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textPrimary);
        Text('开启后结果范围更大、更模糊')
          .fontSize(10)
          .fontColor(Theme.colors().textHint)
          .margin({ top: 2 });
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1);

      Toggle({ type: ToggleType.Switch, isOn: this.broad })
        .selectedColor(Theme.colors().primary)
        .onChange((isOn: boolean) => {
          this.broad = isOn;
        });
    }
    .width('100%')
    .padding(14)
    .alignItems(VerticalAlign.Center)
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .backgroundBlurStyle(Glass.CARD_BLUR)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .shadow(Glass.cardShadow(Theme.colors().glassShadow))
    .margin({ top: 2 });
  }

  /** 底部动作条：圆角 30 的 barTint 玻璃条 + 重置/应用两胶囊 */
  @Builder
  actionBar() {
    Row() {
      Row() {
        Button('重置')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .fontColor(Theme.colors().textPrimary)
          .backgroundColor(Theme.colors().chipTint)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .borderRadius(999)
          .onClick(() => {
            this.resetAll();
          });
        Button('应用')
          .layoutWeight(1)
          .height(44)
          .fontSize(15)
          .margin({ left: 10 })
          .fontColor(Theme.colors().onPrimary)
          .backgroundColor(Theme.colors().primary)
          .borderRadius(999)
          .shadow(Glass.cardShadow(Theme.colors().glassShadow))
          .onClick(() => {
            this.apply();
          });
      }
      .width('100%')
      .height(60)
      .padding({ left: 8, right: 8 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().barTint)
      .backgroundBlurStyle(Glass.BAR_BLUR)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .shadow(Glass.barShadow(Theme.colors().glassShadow));
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 6, bottom: this.navBarHeight + 14 });
  }

  build() {
    // 悬浮顶栏：Scroll 铺满整页并在首部用 spacer 让出状态栏 + 顶栏高度（滚动时内容从顶栏下方经过），
    // 底部动作条固定在 Stack 内容 Column 的底部并避让系统导航条。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        if (!this.optionsReady) {
          Row()
            .width('100%')
            .height(this.statusBarHeight + Dimens.topBarHeight);
          Column() {
            LoadingView({ text: '正在加载筛选项…' });
          }
          .width('100%')
          .layoutWeight(1);
        } else {
          Scroll() {
            Column() {
              // 悬浮顶栏让位 spacer：随内容滚走
              Row()
                .width('100%')
                .height(this.statusBarHeight + Dimens.topBarHeight);

              this.keywordSection();
              this.singleOptionSection('类型', 'genre', this.genres);
              this.singleOptionSection('排序', 'sort', this.sorts);
              this.singleOptionSection('影片时长', 'duration', this.durations);
              this.singleOptionSection('发布日期', 'date', this.dates);
              this.brandSection();
              this.tagSections();
              this.broadSection();
            }
            .width('100%')
            .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, bottom: 8 })
            .alignItems(HorizontalAlign.Start);
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring);

          this.actionBar();
        }
      }
      .width('100%')
      .height('100%');

      AppTopBar({ title: '高级搜索', showBack: true });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
