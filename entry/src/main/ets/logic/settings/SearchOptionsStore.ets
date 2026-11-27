/**
 * 搜索筛选项数据源（rawfile/search_options/*.json）。
 *
 * 上游 Android 把筛选数据放在 assets 里（`SearchViewModel` 的 genres/tags/brands/
 * sortOptions/durations/timeList），这里改为 rawfile + 一次性解析进内存，UI 同步取用。
 *
 * 生命周期：`await SearchOptionsStore.getInstance().init(ctx, lang)` 一次（建议在
 * 搜索页 aboutToAppear 或 EntryAbility 中调用；切换语言后可再次 init 刷新）。
 * init 之前所有 getter 返回空数组，不会崩。
 *
 * 历史说明：上游在 AV 镜像站下会改用 AV 分类（genre_av.json）。本工程已把该站从可选站点中
 * 移除（见 Constants.BASE_URL_OPTIONS），没有入口能切过去，因此这段分支被删掉；
 * 对应的 rawfile/search_options/genre_av.json 保留，仅作上游数据留档，当前无加载入口。
 */

import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SearchOptionItem } from '../../core/model/Models';
import { parseOptionList, parseOptionMap, scopeKeys } from '../../core/util/SearchOptions';

const DOMAIN: number = 0x0001;
const TAG: string = 'SearchOptionsStore';

/** rawfile 下筛选数据的目录前缀。 */
const OPTION_DIR: string = 'search_options/';

/** 列表型数据文件名。 */
const FILE_GENRE: string = 'genre.json';
const FILE_SORT: string = 'sort_option.json';
const FILE_DURATION: string = 'duration.json';
const FILE_RELEASE_DATE: string = 'release_date.json';
const FILE_BRANDS: string = 'brands.json';
const FILE_TAGS: string = 'tags.json';

export class SearchOptionsStore {
  private static instance: SearchOptionsStore | null = null;

  private genreItems: SearchOptionItem[] = [];
  private sortItems: SearchOptionItem[] = [];
  private durationItems: SearchOptionItem[] = [];
  private dateItems: SearchOptionItem[] = [];
  private brandItems: SearchOptionItem[] = [];
  private tagMap: Record<string, SearchOptionItem[]> = {};

  private constructor() {
  }

  static getInstance(): SearchOptionsStore {
    if (SearchOptionsStore.instance === null) {
      SearchOptionsStore.instance = new SearchOptionsStore();
    }
    return SearchOptionsStore.instance;
  }

  /**
   * 读取并解析全部筛选数据。读取失败的文件降级为空列表（只影响对应筛选栏）。
   * @param lang 站点语言键：'zh-rCN' | 'zh-rTW' | 'en' | 'ja'
   */
  async init(ctx: common.UIAbilityContext, lang: string): Promise<void> {
    const language: string = lang.length > 0 ? lang : 'zh-rTW';

    this.genreItems = await this.loadList(ctx, FILE_GENRE, language);
    this.sortItems = await this.loadList(ctx, FILE_SORT, language);
    this.durationItems = await this.loadList(ctx, FILE_DURATION, language);
    this.dateItems = await this.loadList(ctx, FILE_RELEASE_DATE, language);
    this.brandItems = await this.loadList(ctx, FILE_BRANDS, language);
    this.tagMap = await this.loadMap(ctx, FILE_TAGS, language);
    hilog.info(DOMAIN, TAG, `搜索筛选项加载完成: genre=${this.genreItems.length}, tags=${scopeKeys(this.tagMap).length} scopes`);
  }

  genres(): SearchOptionItem[] {
    return this.genreItems;
  }

  sorts(): SearchOptionItem[] {
    return this.sortItems;
  }

  durations(): SearchOptionItem[] {
    return this.durationItems;
  }

  dates(): SearchOptionItem[] {
    return this.dateItems;
  }

  brands(): SearchOptionItem[] {
    return this.brandItems;
  }

  /** tags.json 的作用域键（保持 JSON 内顺序）。 */
  tagScopes(): string[] {
    return scopeKeys(this.tagMap);
  }

  /** 某作用域下的标签；未知 scope 返回空数组。 */
  tagsByScope(scope: string): SearchOptionItem[] {
    const items: SearchOptionItem[] | undefined = this.tagMap[scope];
    if (items === undefined) {
      return [];
    }
    return items;
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  private async loadList(
    ctx: common.UIAbilityContext,
    fileName: string,
    lang: string
  ): Promise<SearchOptionItem[]> {
    try {
      const json: string = await this.readRawText(ctx, fileName);
      return parseOptionList(json, lang);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `读取 ${fileName} 失败: code=${error.code}, message=${error.message}`);
      return [];
    }
  }

  private async loadMap(
    ctx: common.UIAbilityContext,
    fileName: string,
    lang: string
  ): Promise<Record<string, SearchOptionItem[]>> {
    try {
      const json: string = await this.readRawText(ctx, fileName);
      return parseOptionMap(json, lang);
    } catch (err) {
      const error: BusinessError = err as BusinessError;
      hilog.error(DOMAIN, TAG, `读取 ${fileName} 失败: code=${error.code}, message=${error.message}`);
      return {};
    }
  }

  /** rawfile 是 UTF-8 字节流，用 util.TextDecoder（API 12 的 decodeToString）转字符串。 */
  private async readRawText(ctx: common.UIAbilityContext, fileName: string): Promise<string> {
    const bytes: Uint8Array = await ctx.resourceManager.getRawFileContent(OPTION_DIR + fileName);
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(bytes);
  }
}
