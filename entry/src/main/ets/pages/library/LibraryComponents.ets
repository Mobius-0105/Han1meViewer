/**
 * “我的”/收藏/历史/清单/设置/登录 页共用的小组件（PuraPily 设置页视觉规范）。
 *
 * 视觉基线（与 docs/UI_STYLE.md 一致，参考 PuraPily 的分组卡片观感，独立实现）：
 *  - 分组标题 GroupTitle：纯文字，13 号 textHint，上 12 / 下 6，不再用渐变竖条；
 *  - 「我的」页大卡片 ProfileCard：圆角 24（PuraPily PageSurface 观感，比旧版 20 更圆润），
 *    cardBg 纯色（浅色纯白 / 深色 #17181A）+ 1vp glassBorder，无阴影、无模糊；
 *  - 设置页分组卡片 GroupCard：圆角 24（与「我的」页大卡统一，复用 Widgets.CARD_RADIUS_LARGE）、
 *    cardBg 纯色 + 1vp glassBorder，无阴影、无模糊；行间用 RowDivider（0.5 发丝线，左右内缩 12）；
 *  - 行 NavRow / SwitchRow：行高 52，左图标块 30×30 圆角 10（primaryContainer 底 +
 *    primary 图标；危险操作用 chipTint 底 + error 图标），标题 14 textPrimary、
 *    副标题 12 textHint，右侧 value 12 textSecondary + ›；按下缩放 0.97（LIGHT）；
 *  - 分段 SegmentRow：chipTint 胶囊容器（1vp 描边，圆角 999），选中段 primary 填充，
 *    每段按下缩放 0.97。
 *
 * 兼容性：所有既有参数名 / 回调名保持不变，新增参数一律带默认值。
 */

import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { CARD_RADIUS_LARGE } from '../../components/common/Widgets';

/** 「我的」页大卡片圆角（与内容库入口卡/最近观看卡/设置分组卡共用 24 基准） */
export const PROFILE_CARD_RADIUS: number = CARD_RADIUS_LARGE;

/** 设置/分组卡片圆角（ProfilePage / SettingsPage / UserAccountPage 等所有 GroupCard 使用方自动一致） */
export const GROUP_CARD_RADIUS: number = CARD_RADIUS_LARGE;

/** 分组标题：纯文字 13 号 hint 色（PuraPily 风格分组标题） */
@Component
export struct GroupTitle {
  @Prop text: string = '';

  build() {
    Text(this.text)
      .fontSize(13)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.colors().textHint)
      .maxLines(1)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 6 });
  }
}

/**
 * 「我的」页的大卡片（账号卡 / 内容分组卡）：PuraPily PageSurface 观感 ——
 * 圆角 24 + cardBg 纯色 + 1vp glassBorder，无阴影、无模糊；内部行直接贴在卡里，
 * 行间用 RowDivider 发丝线区分。
 */
@Component
export struct ProfileCard {
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content();
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
    .borderRadius(PROFILE_CARD_RADIUS)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .transition(TransitionEffect.OPACITY.animation({ duration: 220 }));
  }
}

/**
 * 设置页分组卡片：把同一分组的若干行包成一张纯色长卡（圆角默认 24 + 1vp 描边，无阴影）。
 * 行内容由调用方用尾随闭包传入（NavRow / SwitchRow / SegmentRow / 输入框均可）。
 * 默认圆角与「我的」页 PROFILE_CARD_RADIUS(24) 一致，设置页/账号页分组卡自动统一。
 * 注意：Theme 的 cardBg 已是纯色（浅色纯白 / 深色 #17181A），不再叠加背景模糊，
 * 避免无效的模糊层开销。
 */
@Component
export struct GroupCard {
  /** 卡片圆角：默认 GROUP_CARD_RADIUS(24)；调用方可显式传自定义值 */
  radius: number = GROUP_CARD_RADIUS;
  @BuilderParam content: () => void;

  build() {
    Column() {
      this.content();
    }
    .width('100%')
    .padding({ top: 2, bottom: 2 })
    .borderRadius(this.radius)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .transition(TransitionEffect.OPACITY.animation({ duration: 220 }));
  }
}

/** 分组卡片内行与行之间的 0.5 发丝线（左右内缩 12，与行内容左边缘对齐） */
@Component
export struct RowDivider {
  build() {
    Row() {
      Row()
        .width('100%')
        .height(0.5)
        .backgroundColor(Theme.colors().divider);
    }
    .width('100%')
    .padding({ left: 12, right: 12 });
  }
}

/** 可点击的导航行：图标 + 标题 + 副标题 + 右侧值/箭头（透明行，放在 GroupCard 内） */
@Component
export struct NavRow {
  icon: Resource = $r('app.media.ic_more');
  showIcon: boolean = true;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop valueText: string = '';
  showArrow: boolean = true;
  /** 危险操作（清空数据等）用 error 色文字；默认 false，旧调用行为不变 */
  danger: boolean = false;
  onTap: () => void = () => {
  };

  build() {
    Row() {
      if (this.showIcon) {
        Row() {
          Image(this.icon)
            .width(18)
            .height(18)
            .fillColor(this.danger ? Theme.colors().error : Theme.colors().primary);
        }
        .width(30)
        .height(30)
        .borderRadius(10)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.danger ? Theme.colors().surfaceVariant : Theme.colors().primaryContainer)
        .margin({ right: 12 });
      }
      Column() {
        Text(this.title)
          .fontSize(Dimens.bodySize)
          .fontColor(this.danger ? Theme.colors().error : Theme.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .lineHeight(16)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%');
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start);

      if (this.valueText.length > 0) {
        Text(this.valueText)
          .fontSize(Dimens.captionSize)
          .fontColor(this.danger ? Theme.colors().error : Theme.colors().textSecondary)
          .maxLines(1)
          .margin({ left: 8, right: 2 });
      }
      if (this.showArrow) {
        Text('›')
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .margin({ left: 4 });
      }
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      this.onTap();
    });
  }
}

/** 带开关的行（设置页的布尔项，透明行，放在 GroupCard 内） */
@Component
export struct SwitchRow {
  icon: Resource = $r('app.media.ic_settings');
  showIcon: boolean = true;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop isOn: boolean = false;
  onToggle: (value: boolean) => void = (value: boolean) => {
  };

  build() {
    Row() {
      if (this.showIcon) {
        Row() {
          Image(this.icon)
            .width(18)
            .height(18)
            .fillColor(Theme.colors().primary);
        }
        .width(30)
        .height(30)
        .borderRadius(10)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.colors().primaryContainer)
        .margin({ right: 12 });
      }
      Column() {
        Text(this.title)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%');
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .lineHeight(16)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 2 })
            .width('100%');
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ right: 8 });

      Toggle({ type: ToggleType.Switch, isOn: this.isOn })
        .selectedColor(Theme.colors().primary)
        .onChange((value: boolean) => {
          this.onToggle(value);
        });
    }
    .width('100%')
    .constraintSize({ minHeight: 52 })
    .padding({ left: 12, right: 12, top: 8, bottom: 8 })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 });
  }
}

/** 横向分段选择器（主题 / Tab 切换 / 排序）：胶囊容器 + 选中段 primary 填充 */
@Component
export struct SegmentRow {
  options: string[] = [];
  @Prop selectedIndex: number = 0;
  onSelect: (index: number) => void = (index: number) => {
  };

  build() {
    Row() {
      ForEach(this.options, (label: string, index: number) => {
        Row() {
          Text(label)
            .fontSize(Dimens.captionSize)
            .fontWeight(this.selectedIndex === index ? FontWeight.Medium : FontWeight.Normal)
            .fontColor(this.selectedIndex === index ? Theme.colors().onPrimary : Theme.colors().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis });
        }
        .layoutWeight(1)
        .height(34)
        .borderRadius(999)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.selectedIndex === index ? Theme.colors().primary : Color.Transparent)
        .margin(2)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
        .onClick(() => {
          this.onSelect(index);
        });
      }, (label: string, index: number) => label + index)
    }
    .width('100%')
    .padding(3)
    .borderRadius(999)
    .backgroundColor(Theme.colors().chipTint)
    .backgroundBlurStyle(Glass.CHIP_BLUR)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder });
  }
}
