/**
 * 视频详情 / 播放器共用的状态视图。
 *
 * 公共的 ErrorView 只有「重试」；Cloudflare 人机验证需要额外的「去验证」入口，
 * 所以在 video/ 目录下补一个带验证引导的错误视图（不改 components/common/**）。
 */

import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { Router } from '../../common/Router';
import { Toast } from '../../common/Toast';

@Component
export struct ErrorStateView {
  message: string = '加载失败';
  /** true 时显示「去验证」入口（Cloudflare challenge） */
  cloudflare: boolean = false;
  baseUrl: string = '';
  onRetry: () => void = () => {
  };
  @StorageLink('themeMode') themeMode: string = 'system';

  build() {
    Column() {
      Column() {
        Text('😵')
          .fontSize(40);
        Text(this.message)
          .fontSize(Dimens.bodySize)
          .fontColor(Theme.colors().textSecondary)
          .textAlign(TextAlign.Center)
          .margin({ top: 12, left: 24, right: 24 });
        if (this.cloudflare) {
          Text('站点要求完成人机验证，完成后回到本页点「重试」。')
            .fontSize(Dimens.captionSize)
            .fontColor(Theme.colors().textHint)
            .textAlign(TextAlign.Center)
            .margin({ top: 8, left: 28, right: 28 });
        }
        Row() {
          Button('重试')
            .fontSize(14)
            .height(38)
            .borderRadius(19)
            .backgroundColor(Theme.colors().primary)
            .fontColor(Theme.colors().onPrimary)
            .onClick(() => {
              this.onRetry();
            });
          if (this.cloudflare) {
            Button('去验证')
              .fontSize(14)
              .height(38)
              .borderRadius(19)
              .margin({ left: 12 })
              .backgroundColor(Theme.colors().chipTint)
              .fontColor(Theme.colors().textPrimary)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .onClick(() => {
                if (this.baseUrl.length === 0) {
                  Toast.show('站点地址为空，请先在设置里配置');
                  return;
                }
                Router.openWeb(this.baseUrl, 'Cloudflare 验证');
              });
          }
        }
        .margin({ top: 18 });
      }
      .width('86%')
      .padding({ left: 20, right: 20, top: 26, bottom: 24 })
      .borderRadius(Dimens.panelRadius)
      .backgroundColor(Theme.colors().glassTint)
      .backgroundBlurStyle(Glass.CARD_BLUR)
      .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
      .shadow(Glass.cardShadow(Theme.colors().glassShadow));
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center);
  }
}

/** 滚动容器内的轻量加载行（LoadingView 是 100% 高，不适合放在 Scroll 里） */
@Component
export struct InlineLoadingRow {
  text: string = '加载中…';
  @StorageLink('themeMode') themeMode: string = 'system';

  build() {
    Row() {
      LoadingProgress()
        .width(18)
        .height(18)
        .color(Theme.colors().primary);
      Text(this.text)
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().textSecondary)
        .margin({ left: 8 });
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 14, bottom: 14 });
  }
}

/** 滚动容器内的轻量空态行 */
@Component
export struct InlineEmptyRow {
  text: string = '暂无内容';
  hint: string = '';
  @StorageLink('themeMode') themeMode: string = 'system';

  build() {
    Column() {
      Text(this.text)
        .fontSize(Dimens.bodySize)
        .fontColor(Theme.colors().textSecondary)
        .textAlign(TextAlign.Center);
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(Dimens.captionSize)
          .fontColor(Theme.colors().textHint)
          .textAlign(TextAlign.Center)
          .margin({ top: 6 });
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 18, bottom: 18 });
  }
}

/** 滚动容器内的错误行 + 重试 */
@Component
export struct InlineErrorRow {
  message: string = '加载失败';
  onRetry: () => void = () => {
  };
  @StorageLink('themeMode') themeMode: string = 'system';

  build() {
    Column() {
      Text(this.message)
        .fontSize(Dimens.bodySize)
        .fontColor(Theme.colors().textSecondary)
        .textAlign(TextAlign.Center);
      Text('点击重试')
        .fontSize(Dimens.captionSize)
        .fontColor(Theme.colors().primary)
        .margin({ top: 8 })
        .onClick(() => {
          this.onRetry();
        });
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
    .padding({ top: 16, bottom: 16 });
  }
}
