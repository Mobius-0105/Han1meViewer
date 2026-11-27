import { HanimeInfo } from '../../core/model/Models';
import { Theme, AppColors, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router } from '../../common/Router';
import { MaterialSurface } from './MaterialSurface';
import { GlassCapsule } from './GlassCapsule';

/**
 * 通用小组件集合（PuraPily 风格重做版）。
 *
 * 观感基线：
 *  - 视频卡片：16:9 封面贴满卡片左右/顶部（圆角只保留顶部两角，底部直角）+ 纯色 cardBg +
 *    0.5vp 极淡描边 + 信息区（左右 8、上 6、下 8），标题 13 两行固定 36 高，
 *    元信息行固定 24 高（上传者/分类 + 上传时间，11 号次级色）；160 宽卡高 164；
 *  - 设置/列表卡：圆角 12、行高 52、图标块 30 圆角 10；
 *  - 大面板/弹层：圆角 30；胶囊：高度 24~44、圆角 999；
 *  - 所有文字颜色走 Theme 语义色，禁止写死灰色，保证深浅色可读。
 */

/** 顶栏圆形控件统一尺寸（以搜索页搜索胶囊 44 为基准）：返回/筛选/头像/刷新/设置圆钮共用 */
export const TOP_CONTROL_SIZE: number = 44;
/** 顶栏动作胶囊高度（比圆形控件小一档，避免压过标题；文字 13 垂直居中） */
const TOP_BAR_ACTION_HEIGHT: number = 36;
/** 动作胶囊文字左右内边距（随胶囊高度一起放大，保证 13 号字不贴边） */
const TOP_BAR_ACTION_PADDING: number = 12;
/** 动作文字 13 号字的中文均宽估算（中文同字号下近似正方，用于给固定宽度画布估宽） */
/** 13 号中文字符宽度按 15 估算（覆盖 HarmonyOS Sans 实际字宽 + 抗锯齿，避免按钮被裁切） */
const TOP_BAR_ACTION_CHAR_WIDTH: number = 15;

/**
 * 顶部栏（悬浮覆盖形态）：返回圆钮 + 标题 + 可选右侧文字动作（沉浸玻璃）。
 *
 * 与旧版「Column 内固定条」的区别：
 *  - 本组件不再是页面 Column 的第一个子节点，而是由调用页面放进 **Stack 的最上层**，覆盖在
 *    铺满整页的 Scroll/List/Refresh 之上；页面内容顶部用 `statusBarHeight + topBarHeight` 的
 *    透明 spacer 让出安全区，滚动时内容从顶栏下方经过，MaterialSurface 的 backdropBlur
 *    才有内容可模糊（Bika 的「悬浮顶栏 + 渐变模糊」观感）。
 *  - 组件自身尺寸固定为 `statusBarHeight + topBarHeight`：MaterialSurface(kind:'header') 负责
 *    渐变模糊底板（systemMaterial + 单层 backdropBlur + 中性页面底色染色 + 底边 0.5vp 发丝分割线），
 *    本组件不再自己画 barTint/模糊。
 *  - 返回圆钮 / 动作胶囊的材质统一交给 `GlassCapsule`：它用 Tabs TabBar + systemMaterial 作为
 *    材质画布（与 Index 悬浮底栏同一条渲染路径），材质不可用时由它自己回退
 *    「chipTint + CHIP_BLUR + 1vp 描边」。
 *  - 外层 hitTestBehavior(Transparent)：顶栏自身/子节点照常响应（返回钮、动作胶囊可点），
 *    但不阻塞兄弟节点（空白区域拖拽可以穿透到下层内容滚动）。
 *
 * 兼容性：对外参数（title / showBack / actionText / onAction）与旧版完全一致。
 */
@Component
export struct AppTopBar {
  title: string = '';
  showBack: boolean = true;
  /**
   * 动作文案。用 @Prop：文案可能异步变化（如 HistoryPage 记录加载完才出现「清空」），
   * 变化时组件会重建，动作胶囊宽度随之重算。
   */
  @Prop actionText: string = '';
  onAction: () => void = () => {
  };

  /** 状态栏高度（EntryAbility 写入 AppStorage；全屏窗口下用顶部 padding 把内容让到安全区，玻璃背景覆盖状态栏） */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;

  /**
   * 动作胶囊宽度：GlassCapsule 内部的材质画布是 width 100%，自然宽度必须由外层容器给出。
   * 顶栏动作文案都是「关闭 / 清空 / 去首页看看」这类中文短词，按 13 号字宽 + 左右 14 内边距
   * + 2vp 余量估算，避免文字被胶囊裁切。
   */
  private actionCapsuleWidth(): number {
    if (this.actionText.length === 0) {
      return 0;
    }
    return this.actionText.length * TOP_BAR_ACTION_CHAR_WIDTH + TOP_BAR_ACTION_PADDING * 2 + 10;
  }

  /**
   * 返回圆钮（44，与搜索页返回钮/搜索胶囊同高）：材质由 GlassCapsule 提供（与悬浮底栏同源），
   * 图标在内容层最上层，外层 Stack 承接点击和按压反馈。
   */
  @Builder
  backPlate() {
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
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.94 })
    .onClick(() => {
      Router.pop();
    });
  }

  /** 动作胶囊的文字（内容层，永远在材质之上） */
  @Builder
  actionLabel() {
    Text(this.actionText)
      .fontSize(13)
      .fontColor(Theme.colors().primary)
      .maxLines(1);
  }

  /** 动作胶囊（高 36 / 圆角 999）：材质由 GlassCapsule 提供，外层定宽 Stack 承接点击 */
  @Builder
  actionCapsule() {
    Stack({ alignContent: Alignment.Center }) {
      GlassCapsule({
        capsuleHeight: TOP_BAR_ACTION_HEIGHT,
        capsuleRadius: TOP_BAR_ACTION_HEIGHT / 2,
        kind: 'composer'
      }) {
        Row() {
          this.actionLabel();
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ left: TOP_BAR_ACTION_PADDING, right: TOP_BAR_ACTION_PADDING })
        .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
      }
    }
    .width(this.actionCapsuleWidth())
    .height(TOP_BAR_ACTION_HEIGHT)
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      this.onAction();
    });
  }

  build() {
    Column() {
      // 渐变模糊玻璃底板：systemMaterial 材质层 + 单层 backdropBlur + 中性页面底色染色 +
      // 底边 0.5vp 发丝分割线；所有背景层命中穿透，不挡返回/标题/动作按钮的点击。
      MaterialSurface({ surfaceHeight: this.statusBarHeight + Dimens.topBarHeight, radius: 0, kind: 'header' }) {
        Column() {
          Row() {
            if (this.showBack) {
              this.backPlate();
            }
            Text(this.title)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(Theme.colors().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
              .margin({ left: this.showBack ? 10 : 0 });
            if (this.actionText.length > 0) {
              this.actionCapsule();
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
    .width('100%')
    .height(this.statusBarHeight + Dimens.topBarHeight)
    // 顶栏自身/子节点照常响应（返回钮、动作胶囊可点），但不阻塞兄弟节点：
    // 空白处拖拽时滚动事件可以穿透到下层 Scroll/List（Transparent 语义）
    .hitTestBehavior(HitTestMode.Transparent);
  }
}

/** 加载中（卡片） */
@Component
export struct LoadingView {
  text: string = '加载中…';

  build() {
    Column() {
      Column() {
        LoadingProgress()
          .width(38)
          .height(38)
          .color(Theme.colors().primary);
        Text(this.text)
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .margin({ top: 10 });
      }
      .padding({ left: 32, right: 32, top: 24, bottom: 24 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().glassStrongTint)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}

/** 错误态 + 重试 */
@Component
export struct ErrorView {
  message: string = '加载失败';
  onRetry: () => void = () => {
  };

  build() {
    Column() {
      Column() {
        Text('😵')
          .fontSize(38);
        Text(this.message)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textSecondary)
          .textAlign(TextAlign.Center)
          .lineHeight(21)
          .margin({ top: 10, left: 6, right: 6 });
        Button('重试')
          .fontSize(14)
          .height(36)
          .margin({ top: 16 })
          .backgroundColor(Theme.colors().primary)
          .fontColor(Theme.colors().onPrimary)
          .borderRadius(999)
          .onClick(() => {
            this.onRetry();
          });
      }
      .width('86%')
      .padding({ left: 20, right: 20, top: 24, bottom: 22 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().glassStrongTint)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}

/** 空态 */
@Component
export struct EmptyView {
  text: string = '暂无内容';
  hint: string = '';

  build() {
    Column() {
      Column() {
        Text('🌸')
          .fontSize(34);
        Text(this.text)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textSecondary)
          .margin({ top: 8 });
        if (this.hint.length > 0) {
          Text(this.hint)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .margin({ top: 6 });
        }
      }
      .width('86%')
      .padding({ left: 20, right: 20, top: 24, bottom: 22 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().glassStrongTint)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}

/** 分区标题 + 右侧"更多"（PuraPily 风格：标题 15 bold，更多是小胶囊） */
@Component
export struct SectionHeader {
  title: string = '';
  actionText: string = '';
  onAction: () => void = () => {
  };

  build() {
    Row() {
      Text(this.title)
        .fontSize(Dimens.subtitleSize)
        .fontWeight(FontWeight.Bold)
        .fontColor(Theme.colors().textPrimary)
        .layoutWeight(1);
      if (this.actionText.length > 0) {
        Text(this.actionText)
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(999)
          .backgroundColor(Theme.colors().chipTint)
          .onClick(() => {
            this.onAction();
          });
      }
    }
    .width('100%')
    .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 14, bottom: 8 });
  }
}

/** 可选中标签（圆角胶囊） */
@Component
export struct TagChip {
  text: string = '';
  @Prop selected: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Text(this.text)
      .fontSize(Dimens.captionSize)
      .fontColor(this.selected ? Theme.colors().onPrimary : Theme.colors().textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      .backgroundColor(this.selected ? Theme.colors().primary : Theme.colors().chipTint)
      .border({
        width: this.selected ? 0 : 1,
        color: Theme.colors().glassBorder
      })
      .margin({ right: 8, bottom: 8 })
      .onClick(() => {
        this.onTap();
      });
  }
}

/** 点赞比例条 */
@Component
export struct RatingBar {
  @Prop ratio: number = 0;
  @Prop likes: number = 0;
  @Prop unlikes: number = 0;

  build() {
    Column() {
      Row() {
        Text('👍 ' + (this.likes < 0 ? '-' : this.likes.toString()))
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary);
        Blank();
        Text((this.unlikes < 0 ? '-' : this.unlikes.toString()) + ' 👎')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textSecondary);
      }
      .width('100%')
      .margin({ bottom: 4 });

      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width('100%')
          .height(4)
          .borderRadius(2)
          .backgroundColor(Theme.colors().surfaceVariant);
        Row()
          .width(this.ratio + '%')
          .height(4)
          .borderRadius(2)
          .backgroundColor(Theme.colors().primary);
      }
      .width('100%')
      .height(4);
    }
    .width('100%');
  }
}

/**
 * 大卡片圆角（内容库入口卡 / 设置分组卡 / 「我的」页大卡）：
 * 与「我的」页 PROFILE_CARD_RADIUS 同一基准 24，保证这些大卡圆角一致。
 * 注意：视频卡片（VideoCard）统一使用默认圆角 8，不要再传该大圆角。
 */
export const CARD_RADIUS_LARGE: number = 24;

/** 视频卡片信息区左右内边距（封面贴满卡宽，只有信息区留白） */
const VIDEO_CARD_PADDING: number = 8;
/** 信息区上内边距（标题与封面之间留 6 的呼吸） */
const VIDEO_CARD_INFO_TOP: number = 6;
/** 信息区下内边距（标题块不贴卡片底边） */
const VIDEO_CARD_INFO_BOTTOM: number = 8;
/** 封面宽高比 16:9：封面贴满卡宽后，高度只由卡片宽度决定 */
const VIDEO_COVER_ASPECT_RATIO: number = 16 / 9;
/** 标题块固定高（13 号两行、行高 18） */
const VIDEO_CARD_TITLE_HEIGHT: number = 36;
/** 元信息行固定高（左侧上传者/分类、右侧上传时间） */
const VIDEO_CARD_META_HEIGHT: number = 24;
/**
 * 信息区固定总高 = 上 6 + 标题 36 + 元信息 24 + 下 8 = 74。
 * 视频卡片总高 = 卡片宽度 × 9/16 + 74（160 宽卡 = 90 + 74 = 164，原 165），
 * 横滑轨道常量（如 VideoPage 的 PLAYLIST_RAIL_HEIGHT）按此 + 余量取整。
 */
export const VIDEO_CARD_INFO_HEIGHT: number =
  VIDEO_CARD_INFO_TOP + VIDEO_CARD_TITLE_HEIGHT + VIDEO_CARD_META_HEIGHT + VIDEO_CARD_INFO_BOTTOM;

/**
 * 视频卡片（封面贴满卡宽的双列卡）。
 *
 * 布局口径（所有 2 列网格 / 横滑轨道共用，保证同排卡片严格等高）：
 *  - 外层：纯色 cardBg、圆角 8、极淡 0.5vp glassBorder 描边，**没有整体 padding**；
 *  - 封面：宽 100% 贴齐卡片左右边缘与顶部，16:9；圆角只保留顶部两角（= 卡片外圆角），
 *    底部两角为 0（直角），用 borderRadius({...}) + clip(true) 裁切；底部 36 高黑色渐变，
 *    左下播放图标 11 + 播放量 10 白字，右下时长 10 白字（黑底胶囊）；
 *  - 信息区：封面下方，左右 padding 8、上 6、下 8；标题 13 号、最多两行、行高 18，
 *    固定 36 高；元信息行固定 24 高（左上传者/分类 11 号次级色，右上传时间 11 号次级色）；
 *  - 卡片总高 = 卡宽 × 9/16 + 74（160 宽卡 = 164）。
 *
 * radius 默认 8（双列网格 / 首页横滑 / 内容库最近观看等全部使用默认值）；
 * 如确有更大的外圆角需求仍可传入，封面顶部两角会随外圆角一起变化。
 */
@Component
export struct VideoCard {
  item: HanimeInfo = {
    title: '',
    coverUrl: '',
    videoCode: '',
    duration: '',
    views: '',
    uploadTime: '',
    genre: '',
    reviews: '',
    currentArtist: '',
    itemType: 0,
    playlistItemId: '',
    isPlaying: false
  };
  cardWidth: number = 0;
  /** 卡片外圆角：所有视频卡当前都用默认 8；封面顶部两角跟随该值 */
  radius: number = Dimens.cardRadius;
  onTap: () => void = () => {
  };

  build() {
    Column() {
      // 封面贴满卡片左右边缘与顶部：只保留顶部两角圆角（与卡片外圆角一致），底部两角为直角
      Stack({ alignContent: Alignment.Bottom }) {
        Image(this.item.coverUrl)
          .width('100%')
          .aspectRatio(VIDEO_COVER_ASPECT_RATIO)
          .objectFit(ImageFit.Cover)
          .backgroundColor(Theme.colors().surfaceVariant);
        // 底部 36 高黑色渐变：浅色封面上也能读清播放量/时长
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
      .aspectRatio(VIDEO_COVER_ASPECT_RATIO)
      .borderRadius({ topLeft: this.radius, topRight: this.radius, bottomLeft: 0, bottomRight: 0 })
      .clip(true);

      // 信息区：封面下方单独留白（左右 8、上 6、下 8），合计固定 74 高
      Column() {
        // 固定 36 高（13 号两行、行高 18）：同排卡片高度只由封面宽度决定，严格等高
        Text(this.item.title)
          .fontSize(13)
          .fontColor(Theme.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(18)
          .height(VIDEO_CARD_TITLE_HEIGHT)
          .width('100%');

        // 元信息行固定 24 高：左上传者/分类，右上传时间
        Row() {
          Text(this.item.currentArtist.length > 0 ? this.item.currentArtist : (this.item.genre.length > 0 ? this.item.genre : ' '))
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
        .height(VIDEO_CARD_META_HEIGHT);
      }
      .width('100%')
      .padding({
        left: VIDEO_CARD_PADDING,
        right: VIDEO_CARD_PADDING,
        top: VIDEO_CARD_INFO_TOP,
        bottom: VIDEO_CARD_INFO_BOTTOM
      })
      .alignItems(HorizontalAlign.Start);
    }
    .width(this.cardWidth > 0 ? this.cardWidth : '100%')
    .alignItems(HorizontalAlign.Start)
    .borderRadius(this.radius)
    .backgroundColor(Theme.colors().cardBg)
    // PuraPily 卡片为纯色无描边：这里只留 0.5vp 极淡发丝线帮助卡片与灰底分层
    .border({ width: 0.5, color: Theme.colors().glassBorder })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.96 })
    .onClick(() => {
      if (this.onTap) {
        this.onTap();
      } else if (this.item.videoCode.length > 0) {
        Router.openVideo(this.item.videoCode);
      }
    });
  }
}

/** 列表行式视频条目（收藏 / 历史 / 搜索结果列表） */
@Component
export struct VideoListTile {
  item: HanimeInfo = {
    title: '',
    coverUrl: '',
    videoCode: '',
    duration: '',
    views: '',
    uploadTime: '',
    genre: '',
    reviews: '',
    currentArtist: '',
    itemType: 0,
    playlistItemId: '',
    isPlaying: false
  };
  subtitle: string = '';
  onTap: () => void = () => {
  };

  build() {
    Row() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(this.item.coverUrl)
          .width(116)
          .height(66)
          .objectFit(ImageFit.Cover)
          .borderRadius(Dimens.smallRadius)
          .backgroundColor(Theme.colors().surfaceVariant);
        if (this.item.duration.length > 0) {
          Text(this.item.duration)
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#99000000')
            .padding({ left: 4, right: 4, top: 1, bottom: 1 })
            .borderRadius(4)
            .margin({ right: 4, bottom: 4 });
        }
      }
      .width(116)
      .height(66)
      .clip(true);

      Column() {
        Text(this.item.title)
          .fontSize(14)
          .fontColor(Theme.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .lineHeight(19)
          .width('100%');
        Blank();
        Text(this.subtitle.length > 0 ? this.subtitle : (this.item.views.length > 0 ? this.item.views : this.item.uploadTime))
          .fontSize(11)
          .fontColor(Theme.colors().textHint)
          .maxLines(1)
          .width('100%');
      }
      .layoutWeight(1)
      .height(66)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 10 });
    }
    .width('100%')
    .padding(8)
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: 1, color: Theme.colors().glassBorder })
    .margin({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 5, bottom: 5 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      if (this.item.videoCode.length > 0) {
        Router.openVideo(this.item.videoCode);
      }
    });
  }
}

/** 简易分隔线 */
@Component
export struct DividerLine {
  build() {
    Row()
      .width('100%')
      .height(0.5)
      .backgroundColor(Theme.colors().divider);
  }
}
