/**
 * 评论输入条：一条评论与「回复某条评论」共用同一个输入框，
 * 由父组件 CommentSection 控制 mode（replyToName 非空时是回复模式）。
 *
 * 视觉：
 *  - 标准模式（material=false）：底部毛玻璃条（barTint + BAR_BLUR + 顶部发丝线），
 *    输入框是 chipTint 玻璃胶囊，发送按钮圆形 primary；
 *  - 材质模式（material=true）：输入条不再自绘背景，由父页面的 GlassCapsule
 *    （capsuleHeight 48 / capsuleRadius 24 / kind 'composer'，与悬浮底栏同源的 Tabs 材质画布）
 *    承载系统沉浸材质，用于悬浮评论输入框；
 *    高度固定 48，回复状态用占位文案 + 左侧取消小圆点表达；
 *    输入胶囊内左侧可渲染评论数小标签（12 号次级色，见 commentCount / countLabel）。
 */

import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';

/** 材质模式悬浮输入条高度（PuraPily 风格收紧：56 → 48，圆角取高度一半） */
const MATERIAL_BAR_HEIGHT: number = 48;

@Component
export struct CommentInputBar {
  @Prop placeholder: string = '说点什么…';
  /** 非空时为回复模式，显示「回复 @xxx」并允许取消 */
  @Prop replyToName: string = '';
  @Prop sending: boolean = false;
  /**
   * 材质模式：输入条本身不再画背景 / 发丝线，转而由父页面的 GlassCapsule
   * （capsuleHeight 48 / capsuleRadius 24 / kind 'composer'）承载系统沉浸材质。
   * 高度固定 48，用于「悬浮评论输入框」。
   */
  @Prop material: boolean = false;
  /**
   * 评论数（material 模式）：父页面把评论总数传进来，用于输入胶囊内左侧的计数小标签。
   * 与 countLabel 同时提供时 countLabel 优先；二者都为 0 / 空时标签不渲染。
   * 非 material 模式（站内标准输入条）忽略该参数，行为与旧版完全一致。
   */
  @Prop commentCount: number = 0;
  /** 评论数文案（material 模式，可选）：例如「评论 12」；空串时按 commentCount 兜底生成 */
  @Prop countLabel: string = '';
  onSend: (text: string) => void = () => {
  };
  onCancelReply: () => void = () => {
  };
  /**
   * 输入框焦点变化回调：页面据此切换「手动键盘避让 / 系统避让」。
   * 只在悬浮评论输入条（material 模式）用到，普通输入条保持默认空实现。
   */
  onFocusChange: (focused: boolean) => void = () => {
  };
  @StorageLink('themeMode') themeMode: string = 'system';
  @State text: string = '';

  /** 输入胶囊内左侧评论数文案：countLabel 优先，否则 commentCount > 0 时生成「评论 N」，都没有返回空串（不渲染） */
  countText(): string {
    if (this.countLabel.length > 0) {
      return this.countLabel;
    }
    if (this.commentCount > 0) {
      return '评论 ' + this.commentCount;
    }
    return '';
  }

  /** 材质模式：高度固定 48 的悬浮胶囊（回复状态用占位文案 + 取消小圆点表达） */
  @Builder
  materialBody() {
    Row() {
      // 评论数小标签：12 号次级色，与输入框 / 发送按钮同一行；限宽 + 单行省略，不抢输入空间
      if (this.countText().length > 0) {
        Text(this.countText())
          .fontSize(12)
          .fontColor(Theme.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .constraintSize({ maxWidth: 80 })
          .margin({ right: 8 });
      }
      if (this.replyToName.length > 0) {
        Row() {
          Image($r('app.media.ic_close'))
            .width(11)
            .height(11)
            .fillColor(Theme.colors().textHint);
        }
        .width(26)
        .height(26)
        .borderRadius(13)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.colors().chipTint)
        .margin({ right: 6 })
        .onClick(() => {
          this.text = '';
          this.onCancelReply();
        });
      }
      TextArea({ placeholder: this.placeholder, text: this.text })
        .placeholderColor(Theme.colors().textHint)
        .fontColor(Theme.colors().textPrimary)
        .fontSize(Dimens.bodySize)
        .height(34)
        .maxLength(2000)
        .borderRadius(17)
        .backgroundColor(Color.Transparent)
        .padding({ left: 8, right: 8, top: 6, bottom: 6 })
        .layoutWeight(1)
        .onFocus(() => {
          this.onFocusChange(true);
        })
        .onBlur(() => {
          this.onFocusChange(false);
        })
        .onChange((value: string) => {
          this.text = value;
        });
      Button(this.sending ? '…' : '发送')
        .fontSize(12)
        .width(34)
        .height(34)
        .borderRadius(17)
        .padding(0)
        .margin({ left: 6 })
        .backgroundColor(Theme.colors().primary)
        .fontColor(Theme.colors().onPrimary)
        .enabled(!this.sending && this.text.trim().length > 0)
        .opacity(this.text.trim().length > 0 && !this.sending ? 1 : 0.55)
        .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.92 })
        .onClick(() => {
          const content: string = this.text.trim();
          if (content.length === 0 || this.sending) {
            return;
          }
          // 先清空输入框（失败时用户需要重新输入，故清空由调用方决定失败回填）
          this.text = '';
          this.onSend(content);
        });
    }
    .width('100%')
    .height(MATERIAL_BAR_HEIGHT)
    .padding({ left: 12, right: 6 })
    .alignItems(VerticalAlign.Center);
  }

  build() {
    // 根容器固定为 Column：ArkTS 要求 build() 只有一个根节点，if 必须放在容器内部
    Column() {
      if (this.material) {
        this.materialBody();
      } else {
        if (this.replyToName.length > 0) {
          Row() {
            Text('回复 @' + this.replyToName)
              .fontSize(Dimens.captionSize)
              .fontColor(Theme.colors().primary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            Text('取消回复')
              .fontSize(11)
              .fontColor(Theme.colors().textHint)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .borderRadius(10)
              .backgroundColor(Theme.colors().chipTint)
              .margin({ left: 8 })
              .onClick(() => {
                this.text = '';
                this.onCancelReply();
              });
          }
          .width('100%')
          .padding({ left: 2, right: 2, bottom: 8 })
          .alignItems(VerticalAlign.Center);
        }

        Row() {
          TextArea({ placeholder: this.placeholder, text: this.text })
            .placeholderColor(Theme.colors().textHint)
            .fontColor(Theme.colors().textPrimary)
            .fontSize(Dimens.bodySize)
            .height(40)
            .maxLength(2000)
            .borderRadius(20)
            .backgroundColor(Theme.colors().chipTint)
            .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .layoutWeight(1)
            .onChange((value: string) => {
              this.text = value;
            });
          Button(this.sending ? '…' : '发送')
            .fontSize(12)
            .width(40)
            .height(40)
            .borderRadius(20)
            .padding(0)
            .margin({ left: 8 })
            .backgroundColor(Theme.colors().primary)
            .fontColor(Theme.colors().onPrimary)
            .enabled(!this.sending && this.text.trim().length > 0)
            .opacity(this.text.trim().length > 0 && !this.sending ? 1 : 0.5)
            .shadow(Glass.cardShadow(Theme.colors().glassShadow))
            .onClick(() => {
              const content: string = this.text.trim();
              if (content.length === 0 || this.sending) {
                return;
              }
              // 先清空输入框（失败时用户需要重新输入，故清空由调用方决定失败回填）
              this.text = '';
              this.onSend(content);
            });
        }
        .width('100%')
        .alignItems(VerticalAlign.Center);
      }
    }
    .width('100%')
    .padding(this.material ? { left: 0, right: 0, top: 0, bottom: 0 } : {
      left: Dimens.pagePadding,
      right: Dimens.pagePadding,
      top: 8,
      bottom: 8
    })
    .backgroundColor(this.material ? Color.Transparent : Theme.colors().barTint)
    .backgroundBlurStyle(this.material ? BlurStyle.NONE : Glass.BAR_BLUR)
    .border({ width: { top: this.material ? 0 : 0.5 }, color: Theme.colors().divider });
  }
}
