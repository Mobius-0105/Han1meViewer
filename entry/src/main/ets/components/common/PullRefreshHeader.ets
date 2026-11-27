import { GlassCapsule } from './GlassCapsule';
import { Theme } from '../../common/Theme';

/**
 * 下拉刷新浮层（胶囊），与 KHenTai 的 `GalleryListView.refreshPill()` 逐项对齐。
 *
 * 参考实现：`JHenTai-HarmonyOS/entry/src/main/ets/ui/GalleryListView.ets`
 *  - :33-36  REFRESH_PILL_WIDTH / HEIGHT / GAP 三个几何常量
 *  - :653-657 refreshPillVisible()（refreshing || Drag || OverDrag）
 *  - :670-713 refreshPill() 本体（箭头 + 文案三态、透明度/位移动画、position 定位）
 *  - :886-896 refreshOffset(110) / pullDownRatio(1) / onStateChange 记录阶段
 *
 * ## 为什么不用 Refresh 自带的顶部分区
 * Refresh 把下拉指示器画在**组件顶部**，而本工程所有列表都在首项放了一个
 * `statusBarHeight + topBarHeight` 的让位 spacer（内容从半透明顶栏下方开始）——
 * 那块区域整片被顶栏盖住，手指要走完一整个顶栏高度才第一次看见任何文字，
 * 体感就是「要拉半屏」（KHenTai 把同样的现象记在 :659-668）。浮层挂在顶栏下沿，
 * 拉一点点就出现。
 *
 * ## 尺寸对照（数值全部取自 KHenTai，不要自己发明）
 *  | 项            | KHenTai                          | 本组件                        |
 *  | 宽            | 120（:33，写死，材质层 width 100% 需要外框夹住） | PILL_WIDTH 120     |
 *  | 高            | 32（:34）                        | PILL_HEIGHT 32                |
 *  | 距顶栏下沿    | 8（:36 REFRESH_PILL_GAP）        | PILL_GAP 8                    |
 *  | 圆角          | 999（:676 MaterialPlane radius） | PILL_HEIGHT / 2（= 16，胶囊） |
 *  | 文案字号      | 11（Tokens.FONT_TAG）            | PILL_FONT 11                  |
 *  | 图标尺寸      | 16（:679-683）                   | PILL_ICON 16                  |
 *  | 图标与文案间距| 6（:677 Row space）              | PILL_CONTENT_GAP 6            |
 *  | 描边          | 0.7 / #33FFFFFF（:702 + btnEdge）| PILL_EDGE 0.7 / '#33FFFFFF'   |
 *  | 阴影          | radius 64 / #1A000000 / dy 12    | PILL_SHADOW 同值              |
 *  | 出现动画      | 160ms Smooth，隐藏时上移 6（:710-711） | 同值                     |
 *
 * 字号为什么固定 11 而不取 Dimens.captionSize(12)：120 的宽度是按 11 号字
 * 「16 + 6 + 正在刷新…≈66 + 左右留白 32」算出来的（KHenTai :26-32 的注释）；
 * 换成 12 号会把文案挤到边缘，胶囊宽度就必须跟着改，7 个页面又会各漂一档。
 *
 * ## 用法（7 个页面共用同一套参数）
 * 放在页面根 Stack（或包住 Refresh 的 Stack）里、**最后一个**子节点之前提：
 *   Stack({ alignContent: Alignment.TopStart }) {
 *     ...内容 / Refresh...
 *     PullRefreshHeader({ status: this.refreshStatus, refreshing: this.refreshing,
 *                         topInset: this.statusBarHeight + Dimens.topBarHeight })
 *   }
 * topInset = 视觉顶部的让位量（悬浮顶栏总高）；列表顶部没有悬浮顶栏时传 0。
 * 组件自己负责 position 定位，所以父容器必须是 Stack，且不要给本组件再套 padding。
 */
const PILL_WIDTH: number = 120;
const PILL_HEIGHT: number = 32;
/** 与顶栏下沿的间距：8 与底栏离底 4 同一档呼吸，贴着顶栏但不粘住（KHenTai :35-36） */
const PILL_GAP: number = 8;
const PILL_FONT: number = 11;
const PILL_ICON: number = 16;
const PILL_CONTENT_GAP: number = 6;
/** 0.7 而不是 1：浅色玻璃上 1vp 黑边会读成卡片边框，0.7 才是「玻璃边缘」 */
const PILL_EDGE: number = 0.7;
/** 浮起控件共用的接触阴影：大半径 + 极低透明度（KHenTai Theme.floatShadow） */
const PILL_SHADOW: ShadowOptions = { radius: 64, color: '#1A000000', offsetX: 0, offsetY: 12 };
/** 隐藏时上移的位移量：给「出现/收起」一点方向感，纯淡入淡出会显得生硬（KHenTai :710） */
const PILL_HIDE_LIFT: number = -6;
const PILL_ANIM_MS: number = 160;

@Component
export struct PullRefreshHeader {
  /**
   * 下拉手势阶段（Inactive / Drag / OverDrag / Refresh / Done）。
   *
   * 必须由页面在 `Refresh.onStateChange` 里写进 @State：refreshing 只有「刷 / 不刷」
   * 两态，下拉过程中（还没松手）它一直是 false，那段时间的反馈只能靠这个阶段区分。
   */
  @Prop status: RefreshStatus = RefreshStatus.Inactive;
  /** 是否正在刷新：与 status 一起决定可见性与「刷新中…」文案 */
  @Prop refreshing: boolean = false;
  /**
   * 视觉顶部的让位量（vp）：悬浮顶栏总高 = statusBarHeight + topBarHeight。
   * 与 KHenTai 的 topInset 同义（:712 position.y = topInset + GAP）。
   */
  @Prop topInset: number = 0;

  /**
   * 何时可见：刷新中，以及下拉/过线阶段。
   * 与 KHenTai :653-657 完全一致 —— 让反馈在第一次下拉位移就出现，而不是等触发刷新。
   * 用普通方法而不是 @State：它只由上面三个 @Prop 推导，本身不需要触发重绘。
   */
  private visible(): boolean {
    return this.refreshing || this.status === RefreshStatus.Drag || this.status === RefreshStatus.OverDrag;
  }

  /** 三态文案：Drag 下拉 / OverDrag 松手 / Refresh（或 refreshing）刷新中 */
  private label(): string {
    if (this.refreshing || this.status === RefreshStatus.Refresh) {
      return '正在刷新…';
    }
    return this.status === RefreshStatus.OverDrag ? '松手刷新' : '下拉刷新';
  }

  /** 箭头方向：只有过线（松手就会刷）才翻成 ↑ */
  private arrow(): string {
    return this.status === RefreshStatus.OverDrag ? '↑' : '↓';
  }

  private spinning(): boolean {
    return this.refreshing || this.status === RefreshStatus.Refresh;
  }

  build() {
    // 整行铺满宽度只是为了「水平居中」：真正的胶囊只有 120 宽。
    // hitTest None 必须加：这层浮在手势区上方，抢事件会让列表下拉直接失效。
    Row() {
      // 外层 Stack 给材质一个**有界**的宽（GlassCapsule 内层材质是 width('100%')，
      // 宽度由内容自撑会解析到整屏，横铺成通栏色带），并承载描边与阴影。
      // 与 KHenTai :672-704 的 Stack 同一职责。
      Stack({ alignContent: Alignment.Center }) {
        // 与 KHenTai 的 MaterialPlane 同位：一块有界的系统沉浸材质玻璃。
        GlassCapsule({ capsuleHeight: PILL_HEIGHT, capsuleRadius: PILL_HEIGHT / 2, kind: 'composer' }) {
          Row({ space: PILL_CONTENT_GAP }) {
            if (this.spinning()) {
              LoadingProgress()
                .width(PILL_ICON)
                .height(PILL_ICON)
                .color(Theme.accent());
            } else {
              Text(this.arrow())
                .fontSize(PILL_FONT)
                .fontColor(Theme.colors().textSecondary)
                .height(PILL_ICON)
                .textAlign(TextAlign.Center);
            }
            Text(this.label())
              .fontSize(PILL_FONT)
              .fontColor(Theme.colors().textPrimary)
              .maxLines(1);
          }
          .width('100%')
          .justifyContent(FlexAlign.Center);
        }
      }
      .width(PILL_WIDTH)
      .height(PILL_HEIGHT)
      // 描边与阴影挂在不裁剪的这一层（KHenTai :701-703）：材质自己按 radius 裁圆，
      // 边画在裁剪层里会被削掉一半。降级路径（系统材质不可用）GlassCapsule 自带一圈
      // 1vp chip 描边，两者同族，读起来仍是一颗胶囊，不会出现双色边。
      .border({ width: PILL_EDGE, color: '#33FFFFFF' })
      .borderRadius(PILL_HEIGHT / 2)
      .shadow(PILL_SHADOW);
    }
    .width('100%')
    .height(PILL_HEIGHT)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.None)
    .opacity(this.visible() ? 1 : 0)
    .translate({ y: this.visible() ? 0 : PILL_HIDE_LIFT })
    .animation({ duration: PILL_ANIM_MS, curve: Curve.Smooth })
    // 绝对定位：不参与父 Stack 的布局，也就不挤占列表高度、不改内容起点（KHenTai :712）。
    .position({ x: 0, y: this.topInset + PILL_GAP });
  }
}

/**
 * 空的自定义刷新区。
 *
 * 为什么要它：`Refresh` 自带一套「箭头 + 下拉刷新 / 松手刷新 / 转圈」的下拉头（旧版视觉），
 * 与我们的跟手胶囊重复，一起出现时像两个刷新提示。`RefreshOptions.builder` 一旦提供，
 * 就替换掉系统默认下拉头的**内容**（见 refresh.d.ts：builder / refreshingContent），
 * 这里给一个 0 高的空容器，手机上就只剩胶囊一个提示。
 *
 * 用法：`Refresh({ refreshing: $$this.refreshing, builder: EmptyRefreshHeader })`
 */
@Builder
export function EmptyRefreshHeader() {
  Column()
    .width('100%')
    .height(0);
}
