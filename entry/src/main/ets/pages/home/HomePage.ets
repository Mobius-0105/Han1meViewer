/**
 * 首页（Tabs 第一个 Tab 的内容页，PuraPily 风格 + Bika 式悬浮顶栏）。
 *
 * 骨架（Stack 覆盖式）：内容（Refresh + Grid）铺满整页，顶栏作为最后绘制的悬浮层盖在内容之上：
 *  - 悬浮顶栏（高 statusBarHeight + 52，含状态栏区域）：左侧小 logo「Han1me」+ 中间玻璃材质搜索胶囊
 *    （点击 push 独立搜索页）+ 右侧玻璃材质头像圆钮 / 登录胶囊；底板是 MaterialSurface 的渐变模糊玻璃；
 *  - 内容 Grid 首行是透明 spacer（高 = 顶栏高度 - rowsGap），滚动出后内容从顶栏下方穿过，
 *    顶栏的渐变模糊/沉浸材质因此有内容可采样；
 *  - 单列滚动 Grid（横屏固定 4 列；竖屏按窗口宽度断点 2~4 列，间距恒 12）承载整页：
 *    - 轮播（高 338、圆角 30、自动播放 4s）跨全部列；
 *    - 频道胶囊行（推荐 + 各分区标题）跨全部列；
 *    - 视频网格（选中频道的视频，最多 12 条；列数跟随页面网格 2~4 列）；
 *    - 「查看更多」胶囊（跳分区搜索结果）；
 *    - 2~3 个横向分区行（信息量补充，不做满）；
 *    - 底部留白（给悬浮底栏让位）。
 *
 * 数据来源：`HanimeApi.getHome()` → `viewmodel/home/HomeViewModel` 的
 * `buildHomeSections / buildBanner`。频道 = 「推荐」(= latestHanime，即「最新上传」分区) +
 * 站点返回的非空分区；轮播 = banner（若有）+ 各分区前几张封面去重，最多 5 张。
 *
 * 交互保留：
 *  - 搜索胶囊通过 Router.openSearch('') push 独立的搜索页（搜索已从底部 Tab 移除）；
 *  - 下拉刷新、Cloudflare 网页验证自动重试、「去验证 / 网页确认 / 换个域名重试」、账号同步；
 *  - 分区「更多」与「查看更多」都调用 Router.openSearchResult(分区标题)，
 *    由 SearchResultPage 把标题还原成站点搜索参数。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { CloudflareChallengeError, IpBlockedError, describeError } from '../../logic/net/Errors';
import { AppSettings } from '../../logic/settings/AppSettings';
import { HanimeInfo } from '../../core/model/Models';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router, CF_VERIFY_TICK_KEY } from '../../common/Router';
import { SiteSwitcher } from '../../common/SiteSwitcher';
import { Toast } from '../../common/Toast';
import { EmptyView, ErrorView, LoadingView, SectionHeader, VideoCard, TOP_CONTROL_SIZE } from '../../components/common/Widgets';
import { MaterialSurface } from '../../components/common/MaterialSurface';
import { GlassCapsule } from '../../components/common/GlassCapsule';
import { EmptyRefreshHeader, PullRefreshHeader } from '../../components/common/PullRefreshHeader';
import { BannerState, HomeSection, buildBanner, buildHomeSections } from '../../viewmodel/home/HomeViewModel';

/** 轮播高度与圆角（PuraPily：高度固定 338、大面板圆角 30）。 */
const CAROUSEL_HEIGHT: number = 338;
const CAROUSEL_RADIUS: number = 30;
/** 轮播最多张数 / 每个分区最多取几张。 */
const HERO_LIMIT: number = 5;
const HERO_PER_SECTION: number = 2;
/** 选中频道的网格最多展示条数。 */
const GRID_LIMIT: number = 12;
/** 网格下方横向分区行的卡片宽度与行高。 */
const RAIL_CARD_WIDTH: number = 160;
const RAIL_HEIGHT: number = 176;
/** 每行最多展示的卡片数（控制首屏图片解码量，横向列表本身可滑）。 */
const RAIL_ITEM_LIMIT: number = 8;
/** 横向分区行最多保留几个（不要堆满整页）。 */
const RAIL_LIMIT: number = 3;
/**
 * 内容网格列数断点（vp）：横屏（窗口宽 > 高）固定 4 列；
 * 竖屏按窗口宽度自适应 —— 宽 > 1000 用 4 列、> 720 用 3 列，其余（手机竖屏）保持 2 列；间距恒为 Dimens.gap(12)。
 */
const GRID_4_COLUMN_MIN_WIDTH: number = 1000;
const GRID_3_COLUMN_MIN_WIDTH: number = 720;
/** 推荐频道对应的站点分区（"推荐"= 最新上传）。 */
const RECOMMEND_SECTION_TITLE: string = '最新上传';
const RECOMMEND_CHANNEL_TITLE: string = '推荐';

/** 轮播的一屏（站点 banner 或某个分区的封面）。 */
class HeroSlide {
  title: string = '';
  coverUrl: string = '';
  videoCode: string = '';
}

/** 首页频道：首项「推荐」，其余由首页分区标题生成。 */
class HomeChannel {
  /** 频道胶囊上显示的标题 */
  title: string = '';
  /** 「查看更多」传给 SearchResultPage 的标题（推荐 → 最新上传） */
  searchTitle: string = '';
  items: HanimeInfo[] = [];
}

/** 去掉空条目并按需截断（ArkTS 状态数组整体重赋值，这里统一生成新数组）。 */
function trimItems(items: HanimeInfo[], limit: number): HanimeInfo[] {
  const result: HanimeInfo[] = [];
  const seen: Set<string> = new Set<string>();
  for (let i = 0; i < items.length && result.length < limit; i++) {
    const item: HanimeInfo = items[i];
    const key: string = item.videoCode.length > 0 ? item.videoCode : item.title;
    if (key.length === 0 || seen.has(key)) {
      continue;
    }
    seen.add(key);
    result.push(item);
  }
  return result;
}

/**
 * 轮播数据：banner（若有）在前，再按分区顺序补前几张封面，按 videoCode/封面去重，最多 5 张。
 * banner 缺失时 buildBanner 已用分区首条视频兜底，所以这里只负责组合与去重。
 */
function buildHeroSlides(banner: BannerState, sections: HomeSection[]): HeroSlide[] {
  const slides: HeroSlide[] = [];
  const seen: Set<string> = new Set<string>();
  if (banner.hasValue && banner.picUrl.length > 0) {
    const first: HeroSlide = new HeroSlide();
    first.title = banner.title.length > 0 ? banner.title : '精选推荐';
    first.coverUrl = banner.picUrl;
    first.videoCode = banner.videoCode;
    slides.push(first);
    seen.add(banner.picUrl);
    if (banner.videoCode.length > 0) {
      seen.add(banner.videoCode);
    }
  }
  for (let s = 0; s < sections.length && slides.length < HERO_LIMIT; s++) {
    const items: HanimeInfo[] = sections[s].items;
    let taken: number = 0;
    for (let i = 0; i < items.length && taken < HERO_PER_SECTION && slides.length < HERO_LIMIT; i++) {
      const item: HanimeInfo = items[i];
      if (item.coverUrl.length === 0) {
        continue;
      }
      const key: string = item.videoCode.length > 0 ? item.videoCode : item.coverUrl;
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      const slide: HeroSlide = new HeroSlide();
      slide.title = item.title;
      slide.coverUrl = item.coverUrl;
      slide.videoCode = item.videoCode;
      slides.push(slide);
      taken++;
    }
  }
  return slides;
}

/** 频道数据：首项「推荐」= 最新上传分区；其余按首页分区顺序（空分区已由 ViewModel 过滤）。 */
function buildChannels(sections: HomeSection[]): HomeChannel[] {
  const channels: HomeChannel[] = [];
  let recommendItems: HanimeInfo[] = [];
  let recommendSearchTitle: string = RECOMMEND_SECTION_TITLE;
  for (let i = 0; i < sections.length; i++) {
    if (sections[i].title === RECOMMEND_SECTION_TITLE) {
      recommendItems = sections[i].items;
      break;
    }
  }
  // 站点改版导致「最新上传」分区缺失时，用第一个分区的数据兜底，避免推荐频道为空
  if (recommendItems.length === 0 && sections.length > 0) {
    recommendItems = sections[0].items;
    recommendSearchTitle = sections[0].title;
  }
  if (recommendItems.length > 0) {
    const recommend: HomeChannel = new HomeChannel();
    recommend.title = RECOMMEND_CHANNEL_TITLE;
    recommend.searchTitle = recommendSearchTitle;
    recommend.items = recommendItems;
    channels.push(recommend);
  }
  for (let i = 0; i < sections.length; i++) {
    const channel: HomeChannel = new HomeChannel();
    channel.title = sections[i].title;
    channel.searchTitle = sections[i].title;
    channel.items = sections[i].items;
    channels.push(channel);
  }
  return channels;
}

@Component
export struct HomePage {
  @StorageLink('themeMode') themeMode: string = 'system';
  /** 系统深浅色也需要订阅，否则跟随系统模式下切换深色不会重绘 */
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 登录态三件套直接用 AppSettings 镜像到 AppStorage 的值，登录/退出后头部自动更新 */
  @StorageLink('username') username: string = '';
  @StorageLink('avatarUrl') avatarUrl: string = '';
  @StorageLink('userId') userId: string = '';

  @State sections: HomeSection[] = [];
  @State channels: HomeChannel[] = [];
  @State heroSlides: HeroSlide[] = [];
  @State gridItems: HanimeInfo[] = [];
  @State activeChannel: number = 0;
  @State heroIndex: number = 0;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  /**
   * 下拉手势阶段：只给 PullRefreshHeader 换文案/箭头用，不参与任何数据逻辑
   * （请求仍由 onRefreshing 触发）。与 KHenTai GalleryListView.ets:197 同一个做法。
   */
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State errorMessage: string = '';
  /** 错误是否为 Cloudflare 验证（是则额外给「去验证」按钮） */
  @State needVerify: boolean = false;
  /** 错误是否为 Cloudflare 硬拦截（IP 被封，验证也过不去，给「网页确认 / 换域名」） */
  @State ipBlocked: boolean = false;
  @State hasData: boolean = false;
  /** 页面宽度（onAreaChange 更新）：驱动横屏 / 宽屏下的网格列数断点 */
  @State viewportWidth: number = 0;
  /** 页面高度（onAreaChange 更新）：与宽度比较判定横屏（宽 > 高时网格固定 4 列），0 表示尚未测量 */
  @State viewportHeight: number = 0;
  /** Cloudflare 网页验证完成信号（WebPage 写入），收到后自动重试 */
  @StorageLink(CF_VERIFY_TICK_KEY) @Watch('onCfVerified') cfVerifyTick: number = 0;

  private disposed: boolean = false;
  /** 请求序号：刷新/重试竞态时丢弃旧响应 */
  private loadSeq: number = 0;
  private api: HanimeApi = HanimeApi.getInstance();
  private swiperController: SwiperController = new SwiperController();

  aboutToAppear(): void {
    this.loadHome(false);
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  /** Cloudflare 网页验证完成（WebPage 写入 cfVerifyTick）后自动重试首页，对齐上游拦截器的自动重试行为 */
  onCfVerified(): void {
    if (this.cfVerifyTick > 0 && this.errorMessage.length > 0 && !this.disposed) {
      this.loadHome(false);
    }
  }

  /**
   * 拉取首页。
   * @param refresh true = 下拉刷新（保留旧内容，失败只 Toast）；false = 首次加载/重试（展示全屏加载态）
   */
  async loadHome(refresh: boolean): Promise<void> {
    const seq: number = this.loadSeq + 1;
    this.loadSeq = seq;
    if (refresh) {
      this.refreshing = true;
    } else {
      this.loading = true;
      this.errorMessage = '';
      this.needVerify = false;
    }
    try {
      const home = await this.api.getHome();
      if (this.disposed || seq !== this.loadSeq) {
        return;
      }
      const nextSections: HomeSection[] = buildHomeSections(home, Date.now());
      const nextBanner: BannerState = buildBanner(home);
      const nextChannels: HomeChannel[] = buildChannels(nextSections);
      this.sections = nextSections;
      this.channels = nextChannels;
      this.heroSlides = buildHeroSlides(nextBanner, nextSections);
      this.heroIndex = 0;
      this.activeChannel = 0;
      this.gridItems = nextChannels.length > 0 ? trimItems(nextChannels[0].items, GRID_LIMIT) : [];
      this.hasData = true;
      this.errorMessage = '';
      this.needVerify = false;
      this.ipBlocked = false;
      this.syncAccount(home.username, home.avatarUrl, home.userId);
    } catch (e) {
      if (this.disposed || seq !== this.loadSeq) {
        return;
      }
      const error: Error = e as Error;
      const message: string = describeError(error);
      if (this.hasData) {
        // 刷新失败：保留旧内容，只轻提示
        Toast.show(message);
      } else {
        this.errorMessage = message;
        this.needVerify = error instanceof CloudflareChallengeError;
        this.ipBlocked = error instanceof IpBlockedError;
        if (this.ipBlocked) {
          // IP 硬拦截时同步更新提示文案（describeError 已给出步骤，这里保留用于判断按钮）
          this.needVerify = false;
        }
      }
    } finally {
      if (!this.disposed && seq === this.loadSeq) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  /** 解析出的账号信息回写设置（登录后没有主动刷新资料时用），同时更新头部头像 */
  syncAccount(name: string, avatar: string, uid: string): void {
    if (name.length === 0) {
      return;
    }
    const settings: AppSettings = AppSettings.getInstance();
    if (settings.getUsername() !== name) {
      settings.setUsername(name);
    }
    if (avatar.length > 0 && settings.getAvatarUrl() !== avatar) {
      settings.setAvatarUrl(avatar);
    }
    if (uid.length > 0 && settings.getUserId() !== uid) {
      settings.setUserId(uid);
    }
  }

  /** 依据当前站点地址打开 Cloudflare 验证页，验证完回来重试即可 */
  private openVerify(): void {
    Router.openWeb(AppSettings.getInstance().getBaseUrl(), 'Cloudflare 验证');
  }

  private openAccount(): void {
    if (this.userId.length > 0) {
      Router.openUserAccount(this.userId);
    } else {
      Router.openLogin();
    }
  }

  /** 切频道：只替换网格数据，不重新请求（数据已在 getHome 一次性拿到） */
  private selectChannel(index: number): void {
    if (index < 0 || index >= this.channels.length || index === this.activeChannel) {
      return;
    }
    this.activeChannel = index;
    this.gridItems = trimItems(this.channels[index].items, GRID_LIMIT);
  }

  /** 当前频道的展示标题（无频道时为空串） */
  private currentChannelTitle(): string {
    if (this.activeChannel < 0 || this.activeChannel >= this.channels.length) {
      return '';
    }
    return this.channels[this.activeChannel].title;
  }

  /** 当前频道「查看更多」跳转用的分区标题 */
  private currentSearchTitle(): string {
    if (this.activeChannel < 0 || this.activeChannel >= this.channels.length) {
      return '';
    }
    return this.channels[this.activeChannel].searchTitle;
  }

  /**
   * 网格下方补充的横向分区行：最多 3 个，跳过当前频道；
   * 当前频道是「推荐」时跳过它对应的分区（内容与网格重复）。
   */
  private extraSections(): HomeSection[] {
    const result: HomeSection[] = [];
    const activeTitle: string = this.currentChannelTitle();
    const recommendActive: boolean = activeTitle === RECOMMEND_CHANNEL_TITLE;
    const recommendSection: string = this.currentSearchTitle();
    for (let i = 0; i < this.sections.length; i++) {
      if (result.length >= RAIL_LIMIT) {
        break;
      }
      const title: string = this.sections[i].title;
      if (title === activeTitle) {
        continue;
      }
      if (recommendActive && title === recommendSection) {
        continue;
      }
      result.push(this.sections[i]);
    }
    return result;
  }

  private openSlide(slide: HeroSlide): void {
    // banner 与普通封面一致：只有拿到 videoCode 才跳详情（保持原 banner 点击逻辑）
    if (slide.videoCode.length > 0) {
      Router.openVideo(slide.videoCode);
    }
  }

  // ---------------------------------------------------------------------------
  // 头部：小 logo + 搜索胶囊 + 头像/登录
  // ---------------------------------------------------------------------------

  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 系统导航条高度：底部留白要同时避开悬浮底栏与导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  /** 悬浮顶栏总高（状态栏 + 52 标题行）：顶栏整体盖在内容之上，不再占用布局高度 */
  private headerHeight(): number {
    return this.statusBarHeight + Dimens.topBarHeight;
  }

  /**
   * 内容首部透明 spacer 的高度：让首屏第一屏内容仍从顶栏下沿开始；
   * Grid 有 rowsGap，spacer 行与下一行之间还会多出 12vp，所以这里减掉一个 gap。
   */
  private topSpacerHeight(): number {
    const height: number = this.headerHeight() - Dimens.gap;
    return height > 0 ? height : 0;
  }

  // ---------------------------------------------------------------------------
  // 响应式网格列数（横屏固定 4 列；竖屏按宽度断点 2~4 列；间距恒 12）
  // ---------------------------------------------------------------------------

  /** 内容网格列数：横屏（宽 > 高）固定四列；其余按窗口宽度断点（>1000 四列、>720 三列，其余两列） */
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
    for (let i = 1; i < columns; i++) {
      template = template + ' 1fr';
    }
    return template;
  }

  /** 整行跨列 GridItem 的结束列下标（列数 - 1） */
  private gridLastColumn(): number {
    return this.gridColumns() - 1;
  }

  /** 视频卡左右页边距：首列左边距 12、末列右边距 12，中间列不加（与列间距 12 对齐） */
  private gridCardLeft(index: number): number {
    return index % this.gridColumns() === 0 ? Dimens.pagePadding : 0;
  }

  private gridCardRight(index: number): number {
    return index % this.gridColumns() === this.gridColumns() - 1 ? Dimens.pagePadding : 0;
  }

  @Builder
  homeHeader() {
    // 悬浮顶栏（含状态栏区域）：外层 Stack 的最后绘制层，盖在铺满整页的内容之上。
    // 底板仍走 MaterialSurface 的「渐变模糊玻璃」：系统沉浸材质 Row + 单层 backdropBlur
    // + 中性页面底色染色 + 底边 0.5vp 发丝分割线；材质不可用时回退 barTint + 厚模糊。
    // 顶栏控件统一 44 高（搜索胶囊 / 头像圆钮 / 登录圆钮 / 登录胶囊都按 TOP_CONTROL_SIZE），
    // 与搜索页同高；行内垂直居中，悬浮顶栏标题行仍为 Dimens.topBarHeight（52）。
    // 内容首部有透明 spacer，滚动后内容会从顶栏下方穿过，渐变模糊/材质因此有内容可采样。
    // 外层命中设为 Transparent：顶栏控件照常响应点击，空白处拖拽可穿透到下层内容滚动。
    Column() {
      MaterialSurface({ surfaceHeight: this.headerHeight(), radius: 0, kind: 'header' }) {
      Column() {
        Row() {
      Text('Han1me')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().primary)
        .margin({ right: 12 });

      // 搜索胶囊（44，与搜索页搜索胶囊同高）：push 独立的搜索页。材质由 GlassCapsule 提供（与悬浮底栏同源的
      // Tabs TabBar 系统材质渲染路径），材质层命中穿透，放大镜+占位文字在内容层最上层；
      // 外层 Stack 只负责点击与横排布局（不再叠任何背景色，否则会盖住材质）。
      Stack({ alignContent: Alignment.Center }) {
        GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: 999, kind: 'composer' }) {
          Row() {
            Image($r('app.media.ic_search'))
              .width(17)
              .height(17)
              .fillColor(Theme.colors().textHint)
              .margin({ right: 7 });
            Text('搜索影片 / 作者 / 标签')
              .fontSize(13)
              .fontColor(Theme.colors().textHint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
          }
          .width('100%')
          .height('100%')
          .padding({ left: 14, right: 14 })
          .borderRadius(999)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
        }
      }
      .layoutWeight(1)
      .height(TOP_CONTROL_SIZE)
      .margin({ right: 10 })
      .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
      .onClick(() => {
        Router.openSearch('');
      });

      if (this.avatarUrl.length > 0) {
        // 已登录且拿到头像：40 圆头像嵌在 44 的 GlassCapsule 材质圆钮里（外圈露出 2vp 材质环）
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
      } else if (this.username.length > 0) {
        // 已登录但站点未返回头像：登录图标同样嵌进 44 的材质圆钮（与头像圆钮同一观感）
        Stack({ alignContent: Alignment.Center }) {
          GlassCapsule({ capsuleHeight: TOP_CONTROL_SIZE, capsuleRadius: TOP_CONTROL_SIZE / 2, kind: 'composer' }) {
            Row() {
              Image($r('app.media.ic_login'))
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
      } else {
        // 未登录：primary 登录胶囊保持实心（唯一的主 CTA，需要最强的可发现性；
        // 如果也铺玻璃材质会和主色抢注意力，且文字自适应宽度不适合固定宽度画布的胶囊宿主）。
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
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
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
    // 顶栏控件照常响应点击，空白处拖拽可穿透到下层内容滚动
    .hitTestBehavior(HitTestMode.Transparent);
  }

  // ---------------------------------------------------------------------------
  // 轮播
  // ---------------------------------------------------------------------------

  @Builder
  carouselDots() {
    Row() {
      ForEach(this.heroSlides, (slide: HeroSlide, index: number) => {
        Row()
          .width(index === this.heroIndex ? 14 : 6)
          .height(6)
          .borderRadius(3)
          .backgroundColor('#FFFFFF')
          .opacity(index === this.heroIndex ? 1.0 : 0.55)
          .shadow({ radius: 3, color: '#66000000', offsetX: 0, offsetY: 1 })
          .margin({ left: index === 0 ? 0 : 5 });
      }, (slide: HeroSlide, index: number) => 'hero_dot_' + index)
    }
    .height(10)
    .hitTestBehavior(HitTestMode.None);
  }

  @Builder
  carouselView() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Swiper(this.swiperController) {
        ForEach(this.heroSlides, (slide: HeroSlide) => {
          Stack({ alignContent: Alignment.BottomStart }) {
            Image(slide.coverUrl)
              .width('100%')
              .height('100%')
              .objectFit(ImageFit.Cover)
              .backgroundColor(Theme.colors().surfaceVariant);
            // 上下渐变 scrim：保证顶部/底部叠字与圆点在任意封面上都清晰
            Column()
              .width('100%')
              .height('100%')
              .linearGradient({
                angle: 180,
                colors: [
                  [Theme.colors().heroScrim, 0.0],
                  ['#00000000', 0.34],
                  ['#00000000', 0.58],
                  [Theme.colors().heroScrim, 1.0]
                ]
              });
            // 左下标题胶囊（高 36、圆角 18、barTint + 背景模糊，最多一行省略）
            Row() {
              Text(slide.title)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.isDark() ? '#FFFFFF' : Theme.colors().primary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis });
            }
            .constraintSize({ maxWidth: '76%' })
            .height(36)
            .padding({ left: 16, right: 16 })
            .borderRadius(18)
            .backgroundColor(Theme.colors().barTint)
            .backgroundBlurStyle(Glass.CHIP_BLUR)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
            .margin({ left: 14, bottom: 16 });
          }
          .width('100%')
          .height('100%')
          .onClick(() => {
            this.openSlide(slide);
          });
        }, (slide: HeroSlide) => 'hero_' + slide.videoCode + slide.coverUrl);
      }
      .width('100%')
      .height(CAROUSEL_HEIGHT)
      .autoPlay(true)
      .interval(4000)
      .loop(true)
      .indicator(false)
      .index(this.heroIndex)
      .onChange((index: number) => {
        this.heroIndex = index;
      });

      // 右下圆点指示器：白点 6，选中拉宽为 14 胶囊
      Row() {
        this.carouselDots();
      }
      .margin({ right: 16, bottom: 22 })
      .hitTestBehavior(HitTestMode.None);
    }
    .width('100%')
    .height(CAROUSEL_HEIGHT)
    .borderRadius(CAROUSEL_RADIUS)
    .clip(true)
    .shadow(Glass.cardShadow(Theme.colors().glassShadow));
  }

  // ---------------------------------------------------------------------------
  // 频道胶囊行
  // ---------------------------------------------------------------------------

  @Builder
  channelChips() {
    Scroll() {
      Row() {
        ForEach(this.channels, (channel: HomeChannel, index: number) => {
          Text(channel.title)
            .fontSize(13)
            .fontWeight(this.activeChannel === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.activeChannel === index ? Theme.colors().onPrimary : Theme.colors().textSecondary)
            .padding({ left: 14, right: 14, top: 7, bottom: 7 })
            .borderRadius(999)
            .backgroundColor(this.activeChannel === index ? Theme.colors().primary : Theme.colors().chipTint)
            .border({
              width: this.activeChannel === index ? 0 : Glass.borderWidth(),
              color: Theme.colors().glassBorder
            })
            .margin({ right: 8 })
            .onClick(() => {
              this.selectChannel(index);
            });
        }, (channel: HomeChannel, index: number) => 'channel_' + channel.title + '_' + index)
      }
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });
    }
    .width('100%')
    .height(40)
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.Spring);
  }

  // ---------------------------------------------------------------------------
  // 网格：视频卡 / 查看更多 / 横向分区行
  // ---------------------------------------------------------------------------

  @Builder
  moreButton() {
    Row() {
      Row() {
        Text('查看更多 · ' + this.currentSearchTitle())
          .fontSize(13)
          .fontColor(Theme.colors().primary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis });
        Image($r('app.media.ic_more'))
          .width(14)
          .height(14)
          .fillColor(Theme.colors().primary)
          .margin({ left: 4 });
      }
      .height(38)
      .padding({ left: 18, right: 18 })
      .borderRadius(19)
      .backgroundColor(Theme.colors().chipTint)
      .backgroundBlurStyle(Glass.CHIP_BLUR)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .onClick(() => {
        Router.openSearchResult(this.currentSearchTitle());
      });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding });
  }

  /** 横向分区行实际展示的卡片（截断到 RAIL_ITEM_LIMIT，避免首屏一次解码过多封面） */
  private railItems(section: HomeSection): HanimeInfo[] {
    if (section.items.length > RAIL_ITEM_LIMIT) {
      return section.items.slice(0, RAIL_ITEM_LIMIT);
    }
    return section.items;
  }

  @Builder
  railSection(section: HomeSection) {
    Column() {
      SectionHeader({
        title: section.title,
        actionText: '更多',
        onAction: () => {
          Router.openSearchResult(section.title);
        }
      });
      List({ space: 10 }) {
        ForEach(this.railItems(section), (item: HanimeInfo) => {
          ListItem() {
            VideoCard({
              item: item,
              cardWidth: RAIL_CARD_WIDTH,
              onTap: () => {
                Router.openVideo(item.videoCode);
              }
            });
          }
        }, (item: HanimeInfo) => 'rail_' + section.title + '_' + item.videoCode + item.title)
      }
      .listDirection(Axis.Horizontal)
      .width('100%')
      .height(RAIL_HEIGHT)
      .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding })
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring);
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start);
  }

  // ---------------------------------------------------------------------------
  // 状态视图
  // ---------------------------------------------------------------------------

  @Builder
  errorCard() {
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
              this.loadHome(false);
            });
          if (this.needVerify) {
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
          } else if (this.ipBlocked) {
            // IP 硬拦截：验证页通常也过不去，先让用户用网页确认是 IP 还是客户端被识别
            Button('网页确认')
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
        }
        .margin({ top: 16 })
        .justifyContent(FlexAlign.Center);

        // 备用域名轮换：Cloudflare 对不同站点风控不同，换域名往往直接可用（对齐上游「切换站点」）
        Button('换个域名重试')
          .fontSize(13)
          .height(36)
          .margin({ top: 10 })
          .backgroundColor(Theme.colors().chipTint)
          .fontColor(Theme.colors().textSecondary)
          .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
          .borderRadius(999)
          .onClick(() => {
            SiteSwitcher.switchToNext();
            this.loadHome(false);
          });
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

  // ---------------------------------------------------------------------------
  // 页面骨架
  // ---------------------------------------------------------------------------

  build() {
    // 覆盖式骨架：内容（Refresh + Grid）铺满整页，顶栏改为最后绘制的悬浮层。
    // 内容首部放透明 spacer，滚动时 spacer 先滚出、内容从顶栏下方穿过，
    // 顶栏 MaterialSurface 的渐变模糊/系统沉浸材质才有内容可采样，而不是被实色顶栏挡住。
    Stack({ alignContent: Alignment.TopStart }) {
      if (this.loading && !this.hasData) {
        Column() {
          LoadingView({ text: '正在加载首页…' });
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.headerHeight() });
      } else if (this.errorMessage.length > 0 && !this.hasData) {
        Column() {
          // 需要额外动作（去验证 / 网页确认 / 换域名）时用自定义卡片，否则复用公共 ErrorView
          if (this.needVerify || this.ipBlocked) {
            this.errorCard();
          } else {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.loadHome(false);
              }
            });
          }
        }
        .width('100%')
        .height('100%')
        .padding({ top: this.headerHeight() });
      } else {
        Refresh({ refreshing: $$this.refreshing, builder: EmptyRefreshHeader }) {
          Grid() {
            // 内容内 spacer（跨全部列）：透明占位，随内容一起滚动
            GridItem() {
              Row()
                .width('100%')
                .height(this.topSpacerHeight());
            }
            .columnStart(0)
            .columnEnd(this.gridLastColumn());

            if (this.heroSlides.length > 0) {
              GridItem() {
                Column() {
                  this.carouselView();
                }
                .width('100%')
                .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 8 });
              }
              .columnStart(0)
              .columnEnd(this.gridLastColumn());
            }

            if (this.channels.length > 0) {
              GridItem() {
                this.channelChips();
              }
              .columnStart(0)
              .columnEnd(this.gridLastColumn());
            }

            ForEach(this.gridItems, (item: HanimeInfo, index: number) => {
              GridItem() {
                Column() {
                  VideoCard({
                    item: item,
                    cardWidth: 0,
                    onTap: () => {
                      Router.openVideo(item.videoCode);
                    }
                  });
                }
                .width('100%')
                .padding({
                  left: this.gridCardLeft(index),
                  right: this.gridCardRight(index)
                });
              }
            }, (item: HanimeInfo) => 'grid_' + item.videoCode + item.title)

            if (this.gridItems.length > 0) {
              GridItem() {
                this.moreButton();
              }
              .columnStart(0)
              .columnEnd(this.gridLastColumn());
            }

            ForEach(this.extraSections(), (section: HomeSection) => {
              GridItem() {
                this.railSection(section);
              }
              .columnStart(0)
              .columnEnd(this.gridLastColumn());
            }, (section: HomeSection) => 'extra_' + section.title + '_' + section.version)

            if (this.heroSlides.length === 0 && this.channels.length === 0) {
              GridItem() {
                Column() {
                  EmptyView({ text: '首页暂时没有内容', hint: '下拉刷新试试' });
                }
                .width('100%')
                .height(420);
              }
              .columnStart(0)
              .columnEnd(this.gridLastColumn());
            }

            // 底部留白：给悬浮毛玻璃底栏让位，并避开系统导航条
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
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring);
        }
        .width('100%')
        .height('100%')
        // 跟手比例 1：手指下拉多少、内容就下移多少。系统默认 0.5 时下拉 40 只位移 20，
        // 手感发「黏」、指示器还被吃掉一半（KHenTai GalleryListView.ets:887-889）。
        .pullDownRatio(1)
        // 触发距离 64 → 110：指示器可见性已交给浮层（下拉阶段就出现），
        // 这里只影响「要拉多深才触发刷新」，往大调是为了减少滚到顶时的手势误触（KHenTai :881-886）。
        .refreshOffset(110)
        .onRefreshing(() => {
          this.loadHome(true);
        })
        // 只记录阶段供浮层分支，不产生任何副作用
        .onStateChange((state: RefreshStatus) => {
          this.refreshStatus = state;
        });
      }

      // 刷新状态浮层：钉在悬浮顶栏下沿（topInset = 顶栏总高），与 7 个页面共用同一个组件。
      PullRefreshHeader({
        status: this.refreshStatus,
        refreshing: this.refreshing,
        topInset: this.headerHeight()
      });

      // 悬浮顶栏层（最后绘制，盖在内容之上）：背景层 hitTest None，不挡内容滚动
      this.homeHeader();
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onAreaChange((_old: Area, area: Area) => {
      // 窗口尺寸驱动网格列数断点：横屏（宽 > 高）固定 4 列，竖屏按宽度断点切 2~4 列
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
