/**
 * 相关推荐 tab 的竖版视频卡片。
 *
 * 为什么在本页自绘而不是改公共 `VideoCard`：
 *  首页 / 搜索 / 内容库等所有双列卡片共用 `components/common/Widgets.ets` 的 VideoCard，
 *  它的封面比例固定 16:9、信息区高度固定 74；相关推荐需要竖版封面 + 更紧凑的名称区，
 *  直接改默认比例会影响其它页面。因此这里复制一份「仅本 tab 使用」的卡片实现，
 *  公共 VideoCard 与其默认比例保持不动。
 *
 * 与 VideoCard 的差异（只针对相关推荐 tab）：
 *  - 封面高度：**按封面图片真实比例**（高 = 卡片宽度 / 宽高比，里番多为 3:2 / 16:9），
 *    不再按相关推荐区可用高度自适应压扁 —— 上一版为了「首屏 2 行」压扁封面被用户否决，
 *    本版恢复固定比例，列表可正常上下滚动即可；
 *  - 横屏：卡片宽度改由父页面按「右侧面板实际可用宽度」传入（不再是竖屏全宽），
 *    封面高度按同一卡宽 × 4/3 跟随，拖分隔条改变面板宽度时卡宽 / 封面高度同步更新、比例不变形；
 *  - 信息区更紧凑：上 4 + 标题固定 36（13 号两行、行高 18）+ 元信息行间距仅 2 +
 *    元信息固定 18 + 下 4 = 64（公共 VideoCard 是 74，且元信息行本身 24 偏高）；
 *    标题与元信息之间没有额外 padding / margin，元信息行直接贴标题下方 2vp；
 *  - 其余（圆角 8、cardBg 纯色 + 0.5vp 发丝描边、封面底部渐变 + 播放量/时长、点击反馈）沿用公共卡片口径。
 */

import { Theme, Dimens } from '../../common/Theme';
import { HanimeInfo, emptyHanimeInfo } from '../../core/model/Models';

/**
 * 封面**默认**宽高比 3:4：只在封面图片尺寸还没拿到时占位用。
 * 真实比例由 coverAspectValue() 读图片原始像素决定（见那里的说明）。
 */
export const RELATED_COVER_ASPECT_RATIO: number = 3 / 4;
/** 封面比例夹取范围：太窄/太宽的图会被夹住，避免卡片高度失控 */
const COVER_ASPECT_MIN: number = 0.6;
const COVER_ASPECT_MAX: number = 1.9;

/** 信息区上内边距（标题与封面之间的呼吸） */
const INFO_TOP: number = 4;
/** 标题块固定高（13 号两行、行高 18），同排卡片严格等高 */
const TITLE_HEIGHT: number = 36;
/** 标题与元信息行的间距：只留 2vp，去掉公共卡片里额外的 24 高元信息行留白 */
const META_GAP: number = 2;
/** 元信息行固定高（11 号单行） */
const META_HEIGHT: number = 18;
/** 信息区下内边距（较公共卡片的 8 收紧到 4，卡片更紧凑） */
const INFO_BOTTOM: number = 4;
/** 信息区左右内边距 */
const INFO_PADDING: number = 8;

@Component
export struct RelatedVideoCard {
  item: HanimeInfo = emptyHanimeInfo();
  /**
   * 卡片宽度基准（vp）：由父页面按「内容区实际可用宽度 - 左右页边距 - 列间距」/ 2 算出。
   * 竖屏 = 窗口全宽口径；横屏 = 右侧面板宽（窗口宽 - 左播放器分栏 - 分隔条）口径。
   * 它只是**首次布局 / 测量前的宽度基准**：卡片真正占满 GridItem 的列宽（width 100%），
   * 横屏拖分隔条、旋转屏幕后由 measuredWidth（onAreaChange，@State）接管——
   * ForEach 复用已有卡片时不会重新执行 itemGenerator，单靠父组件传值不一定能刷新，
   * 因此这里用「实测宽度优先、传入宽度兜底」保证卡宽与 3:4 封面高度始终跟随实际列宽。
   */
  @Prop cardWidth: number = 0;
  /** 卡片实测宽度（onAreaChange 写入）：跟随 Grid 列宽变化，驱动封面高度 = 卡宽 × 4/3 */
  @State private measuredWidth: number = 0;
  /**
   * 封面实际的 width / height（来自 Image.onComplete 的原始像素尺寸，0 = 还没加载完）。
   * 用它来区分「竖版封面（里番 3:4）」与「横版封面（三次元 16:9）」—— 只有比例接近端值才采信，
   * 中间比例（比如 1:1 截图）不强行归类，按默认里番 3:4 处理，避免卡片高度乱跳。
   */
  @State private naturalW: number = 0;
  @State private naturalH: number = 0;
  onTap: () => void = () => {
  };

  /** 当前用于计算封面高度的卡片宽度：实测值优先，尚未测量时用父页面传入的基准值 */
  private layoutCardWidth(): number {
    if (this.measuredWidth > 0) {
      return this.measuredWidth;
    }
    return this.cardWidth > 0 ? this.cardWidth : 0;
  }

  /**
   * 封面宽高比（width / height）：**按封面图片自身比例显示**，不再统一 3:4。
   *
   * 为什么放弃「按里番/三次元硬定比例」：
   *  - 实测 hanime1 的封面：里番 1024×576（16:9）、相关推荐缩略图 640×430（≈3:2），
   *    三次元(DVD)封面才是竖版 3:4 —— 「里番固定 3:4」与实际图片正好相反，
   *    硬按 3:4 等于把横图两侧各裁掉一大块；
   *  - 相关推荐卡片解析出来没有分类字段（genre 为空），关键词 / AV 番号识别基本打不中，
   *    所以上一版判定永远落到默认分支 —— 表现就是「全是 3:4」。
   *
   * 现在读图片真实像素（Image.onComplete）：里番横图自动变宽卡、三次元竖图自动变竖卡；
   * 加载完成前用 3:4 占位（此时无图可裁），拿到尺寸后按真实比例落定，再夹到 [0.6, 1.9]。
   */
  coverAspectValue(): number {
    const w: number = this.naturalW;
    const h: number = this.naturalH;
    if (w > 0 && h > 0) {
      const ratio: number = w / h;
      if (ratio < COVER_ASPECT_MIN) {
        return COVER_ASPECT_MIN;
      }
      if (ratio > COVER_ASPECT_MAX) {
        return COVER_ASPECT_MAX;
      }
      return ratio;
    }
    return RELATED_COVER_ASPECT_RATIO;
  }

  /**
   * 封面高度（vp）= 卡片宽度 / 封面真实比例（里番横图矮、三次元竖图高）。
   * 只依赖卡片宽度与图片比例，不读取相关推荐区高度 / 播放器高度，窗口滚动不会改卡片高度；
   * 封面宽高只由这一处 height 驱动（不叠 aspectRatio），避免「宽度 100% + aspectRatio + 显式高度」
   * 双重约束在横屏窄面板下把封面拉伸。
   */
  coverHeightValue(): number {
    const width: number = this.layoutCardWidth();
    if (!(width > 0)) {
      return 0;
    }
    return width / this.coverAspectValue();
  }

  /** 元信息左侧文案：优先上传者，其次分类；都没有时用空格占位保持行高 */
  metaText(): string {
    if (this.item.currentArtist.length > 0) {
      return this.item.currentArtist;
    }
    if (this.item.genre.length > 0) {
      return this.item.genre;
    }
    return ' ';
  }

  build() {
    Column() {
      // 封面按图片真实比例：宽 100% 贴齐卡片，只有顶部两角圆角（与卡片外圆角一致），底部直角
      Stack({ alignContent: Alignment.Bottom }) {
        Image(this.item.coverUrl)
          .width('100%')
          .height(this.coverHeightValue())
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.colors().surfaceVariant)
          // onComplete 带回图片原始像素宽高：用它判定横版 / 竖版封面（只在比例明显时采信）
          .onComplete((event) => {
            if (event !== undefined && event.width > 0 && event.height > 0) {
              if (this.naturalW !== event.width || this.naturalH !== event.height) {
                this.naturalW = event.width;
                this.naturalH = event.height;
              }
            }
          });
        // 底部 36 高黑色渐变：浅色封面上也能读清播放量 / 时长
        Row()
          .width('100%')
          .height(36)
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], ['#99000000', 1.0]]
          });
        Row() {
          if (this.item.views.length > 0) {
            Row() {
              Image($r('app.media.ic_play'))
                .width(11)
                .height(11)
                .fillColor('#FFFFFF');
              Text(this.item.views)
                .fontSize(10)
                .fontColor('#FFFFFF')
                .margin({ left: 3 })
                .maxLines(1);
            }
          }
          Blank();
          if (this.item.duration.length > 0) {
            Text(this.item.duration)
              .fontSize(10)
              .fontColor('#FFFFFF')
              .maxLines(1)
              .padding({ left: 4, right: 4, top: 1, bottom: 1 })
              .borderRadius(4)
              .backgroundColor('#99000000');
          }
        }
        .width('100%')
        .padding({ left: 6, right: 6, bottom: 6 });
      }
      .width('100%')
      .height(this.coverHeightValue())
      .borderRadius({
        topLeft: Dimens.cardRadius,
        topRight: Dimens.cardRadius,
        bottomLeft: 0,
        bottomRight: 0
      })
      .clip(true);

      // 紧凑信息区：标题固定 36 高，元信息行紧跟标题下方 2vp，无额外上下留白
      Column() {
        Text(this.item.title)
          .fontSize(13)
          .fontColor(Theme.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .height(TITLE_HEIGHT)
          .width('100%');

        Row() {
          Text(this.metaText())
            .fontSize(11)
            .fontColor(Theme.colors().textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1);
          if (this.item.uploadTime.length > 0) {
            Text(this.item.uploadTime)
              .fontSize(11)
              .fontColor(Theme.colors().textHint)
              .maxLines(1)
              .margin({ left: 6 });
          }
        }
        .width('100%')
        .height(META_HEIGHT)
        .margin({ top: META_GAP });
      }
      .width('100%')
      .padding({
        left: INFO_PADDING,
        right: INFO_PADDING,
        top: INFO_TOP,
        bottom: INFO_BOTTOM
      })
      .alignItems(HorizontalAlign.Start);
    }
    // 宽度永远占满 GridItem 的列宽：横屏右侧面板变宽 / 变窄（拖分隔条、旋转屏幕）时
    // 卡片宽度跟随实际列宽，封面高度再由 measuredWidth × 4/3 得到，比例不会失真。
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .borderRadius(Dimens.cardRadius)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: 0.5, color: Theme.colors().glassBorder })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
    .onAreaChange((_old: Area, area: Area) => {
      // 实测列宽：横屏拖分隔条 / 旋转 / 分屏时列宽变化，这里同步后封面高度立即重算（3:4 不变形）
      const width: number = Number(area.width);
      if (!isNaN(width) && width > 0 && Math.abs(width - this.measuredWidth) >= 0.5) {
        this.measuredWidth = width;
      }
    })
    .onClick(() => {
      this.onTap();
    });
  }
}

