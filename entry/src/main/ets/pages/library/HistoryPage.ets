/**
 * 本地观看历史页（按最后观看时间倒序）。
 *
 * - 数据来自 LocalRepo.listHistorySorted()（relationalStore 的 local_history 表）；
 * - 每条显示进度（position/duration + 百分比）与相对时间；
 * - 支持单条删除（直接删，Toast 提示）与清空（AlertDialog.show 二次确认）；
 * - 从视频详情/播放器返回时通过 onVisibleAreaChange 自动刷新。
 */

import { LocalRepo } from '../../logic/db/LocalRepo';
import { describeError } from '../../logic/net/Errors';
import { HistoryRecord } from '../../core/model/Models';
import { formatMs } from '../../core/util/Format';
import { Theme, Dimens } from '../../common/Theme';
import { Glass } from '../../common/Glass';
import { RouteParam, Router } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, EmptyView, ErrorView, LoadingView } from '../../components/common/Widgets';
import { EmptyRefreshHeader, PullRefreshHeader } from '../../components/common/PullRefreshHeader';
import {
  historyProgressPercent,
  historySubtitle,
  notifyLibraryChanged
} from '../../viewmodel/library/LibraryViewModel';

@Component
export struct HistoryPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：列表首个 ListItem spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State records: HistoryRecord[] = [];
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  /** 下拉手势阶段：只给 PullRefreshHeader 换文案用（KHenTai GalleryListView.ets:197） */
  @State refreshStatus: RefreshStatus = RefreshStatus.Inactive;
  @State hasLoaded: boolean = false;
  @State errorMessage: string = '';

  private disposed: boolean = false;
  private lastLoadedAt: number = 0;

  aboutToAppear(): void {
    this.load(false);
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  async load(refresh: boolean): Promise<void> {
    if (refresh) {
      this.refreshing = true;
    } else {
      this.loading = true;
    }
    try {
      const list: HistoryRecord[] = await LocalRepo.getInstance().listHistorySorted();
      if (this.disposed) {
        return;
      }
      this.records = list;
      this.errorMessage = '';
      this.hasLoaded = true;
      this.lastLoadedAt = Date.now();
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.errorMessage = describeError(e as Error);
    } finally {
      if (!this.disposed) {
        this.loading = false;
        this.refreshing = false;
      }
    }
  }

  async deleteOne(record: HistoryRecord): Promise<void> {
    try {
      await LocalRepo.getInstance().deleteHistory(record.videoCode);
      if (this.disposed) {
        return;
      }
      Toast.show('已删除该记录');
      notifyLibraryChanged();
      await this.load(false);
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  private confirmClear(): void {
    AlertDialog.show({
      title: '清空观看历史',
      message: '将删除本机所有观看记录与播放进度，无法恢复。是否继续？',
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.colors().error,
        action: () => {
          this.clearAll();
        }
      }
    });
  }

  async clearAll(): Promise<void> {
    try {
      await LocalRepo.getInstance().clearHistory();
      if (this.disposed) {
        return;
      }
      Toast.show('观看历史已清空');
      notifyLibraryChanged();
      await this.load(false);
    } catch (e) {
      Toast.show(describeError(e as Error));
    }
  }

  private subtitleOf(record: HistoryRecord): string {
    return historySubtitle(record, Date.now());
  }

  /**
   * 观看历史卡片（自绘，不再直接复用 VideoListTile）：
   *  - 卡片左右 12、内边距 12，卡片自身不再加水平 margin（避免 width 100% + margin 向右溢出、
   *    右边缘被裁剪的「没有右边距」问题）；
   *  - 封面 116×66 + 右侧标题/元信息（间距 10/6/8）；删除胶囊在元信息行右侧；
   *  - 观看进度条画在卡片 padding 之内、主内容行下方，宽度 = 卡片内容宽（不溢出卡片）。
   */
  @Builder
  historyRow(record: HistoryRecord) {
    Column() {
      Row() {
        Stack({ alignContent: Alignment.BottomEnd }) {
          Image(record.coverUrl)
            .width(116)
            .height(66)
            .objectFit(ImageFit.Cover)
            .borderRadius(Dimens.smallRadius)
            .backgroundColor(Theme.colors().surfaceVariant);
          if (record.durationMs > 0) {
            Text(formatMs(record.durationMs))
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
          Text(record.title)
            .fontSize(14)
            .fontColor(Theme.colors().textPrimary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .lineHeight(19)
            .width('100%');

          Blank();

          Row() {
            Text(this.subtitleOf(record))
              .fontSize(11)
              .fontColor(Theme.colors().textHint)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1);
            Text('删除')
              .fontSize(11)
              .fontColor(Theme.colors().error)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .margin({ left: 8 })
              .borderRadius(999)
              .backgroundColor(Theme.colors().chipTint)
              .backgroundBlurStyle(Glass.CHIP_BLUR)
              .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
              .onClick(() => {
                this.deleteOne(record);
              });
          }
          .width('100%');
        }
        .layoutWeight(1)
        .height(66)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 });
      }
      .width('100%');

      // 观看进度条：卡片内容宽、卡片 padding 之内（时长未知时不显示）
      if (record.durationMs > 0) {
        Stack({ alignContent: Alignment.Start }) {
          Row()
            .width('100%')
            .height(3)
            .borderRadius(1.5)
            .backgroundColor(Theme.colors().surfaceVariant);
          Row()
            .width(historyProgressPercent(record) + '%')
            .height(3)
            .borderRadius(1.5)
            .backgroundColor(Theme.colors().primary);
        }
        .width('100%')
        .height(3)
        .margin({ top: 8 });
      }
    }
    .width('100%')
    .padding(12)
    .borderRadius(Dimens.listRadius)
    .backgroundColor(Theme.colors().cardBg)
    .border({ width: Glass.borderWidth(), color: Theme.colors().glassBorder })
    .clickEffect({ level: ClickEffectLevel.LIGHT, scale: 0.97 })
    .onClick(() => {
      if (record.videoCode.length > 0) {
        Router.openVideo(record.videoCode);
      }
    });
  }

  @Builder
  content() {
    if (this.loading) {
      Column() {
        LoadingView({ text: '正在读取观看历史…' });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.errorMessage.length > 0) {
      Column() {
        ErrorView({
          message: this.errorMessage,
          onRetry: () => {
            this.load(false);
          }
        });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.records.length === 0) {
      Column() {
        EmptyView({ text: '还没有观看记录', hint: '播放过的影片会按时间倒序出现在这里' });
      }
      .width('100%')
      .layoutWeight(1);
    } else {
      Refresh({ refreshing: $$this.refreshing, builder: EmptyRefreshHeader }) {
        // 卡片自身不再带水平 margin，左右 12 边距由 List 横向 padding 提供；
        // 首个 ListItem 是悬浮顶栏让位 spacer（随列表滚走）。
        List({ space: 8 }) {
          ListItem() {
            Row()
              .width('100%')
              .height(this.statusBarHeight + Dimens.topBarHeight);
          }

          ForEach(this.records, (record: HistoryRecord) => {
            ListItem() {
              this.historyRow(record);
            }
          }, (record: HistoryRecord) => record.videoCode + '@' + record.positionMs + '@' + record.updatedAt)
        }
        .width('100%')
        .height('100%')
        .padding({
          left: Dimens.pagePadding,
          right: Dimens.pagePadding,
          bottom: this.navBarHeight + 16
        })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring);
      }
      .width('100%')
      .layoutWeight(1)
      // 跟手 1:1 + 触发距离 110，与其它列表页同一套手感（KHenTai GalleryListView.ets:886-889）
      .pullDownRatio(1)
      .refreshOffset(110)
      .onRefreshing(() => {
        this.load(true);
      })
      .onStateChange((state: RefreshStatus) => {
        this.refreshStatus = state;
      });
    }
  }

  build() {
    // 悬浮顶栏：列表铺满整页（首个 ListItem 是状态栏+顶栏让位 spacer），AppTopBar 覆盖在最上层。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.content();
      }
      .width('100%')
      .height('100%');

      // 下拉刷新浮层：钉在悬浮顶栏下沿（列表首项 spacer 即顶栏总高）
      PullRefreshHeader({
        status: this.refreshStatus,
        refreshing: this.refreshing,
        topInset: this.statusBarHeight + Dimens.topBarHeight
      });

      AppTopBar({
        title: '观看历史',
        showBack: true,
        actionText: this.records.length > 0 ? '清空' : '',
        onAction: () => {
          this.confirmClear();
        }
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      if (isVisible && this.hasLoaded && Date.now() - this.lastLoadedAt > 800) {
        this.load(true);
      }
    });
  }
}
