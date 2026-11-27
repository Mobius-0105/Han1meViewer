/**
 * 播放清单详情（清单内的视频列表）。
 *
 * 接口：`HanimeApi.getPlaylistItems(listCode, page)`（`playlist?list=&page=`）。
 * RouteParam：listCode（清单 code）+ title（清单名，用于标题栏）。
 * 分页：List.onReachEnd + maxPage；下拉刷新重新拉第 1 页。
 */

import { HanimeApi } from '../../logic/net/HanimeApi';
import { describeError } from '../../logic/net/Errors';
import { HanimeInfo, MyListPage } from '../../core/model/Models';
import { Theme, Dimens } from '../../common/Theme';
import { RouteParam } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, EmptyView, ErrorView, LoadingView, VideoListTile } from '../../components/common/Widgets';

@Component
export struct PlaylistDetailPage {
  p: RouteParam = new RouteParam();

  @StorageLink('themeMode') themeMode: string = 'system';
  @StorageLink('systemDark') systemDark: boolean = false;
  /** 悬浮顶栏覆盖状态栏：列表首个 ListItem spacer = statusBarHeight + topBarHeight */
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  /** 底部留白：二级页无悬浮底栏，只需让开系统导航条 */
  @StorageProp('navBarHeight') navBarHeight: number = 0;

  @State items: HanimeInfo[] = [];
  @State desc: string = '';
  @State page: number = 1;
  @State maxPage: number = 1;
  @State loading: boolean = true;
  @State loadingMore: boolean = false;
  @State refreshing: boolean = false;
  @State errorMessage: string = '';

  private disposed: boolean = false;
  private api: HanimeApi = HanimeApi.getInstance();

  aboutToAppear(): void {
    this.load(true);
  }

  aboutToDisappear(): void {
    this.disposed = true;
  }

  async load(reset: boolean): Promise<void> {
    if (this.p.listCode.length === 0) {
      this.loading = false;
      this.errorMessage = '缺少播放清单信息';
      return;
    }
    if (reset) {
      this.loading = true;
      this.errorMessage = '';
    } else {
      if (this.loadingMore || this.page >= this.maxPage) {
        return;
      }
      this.loadingMore = true;
    }
    const page: number = reset ? 1 : this.page + 1;
    try {
      const result: MyListPage = await this.api.getPlaylistItems(this.p.listCode, page);
      if (this.disposed) {
        return;
      }
      if (reset) {
        this.items = result.items;
        this.page = 1;
      } else {
        const merged: HanimeInfo[] = [];
        for (let i = 0; i < this.items.length; i++) {
          merged.push(this.items[i]);
        }
        for (let i = 0; i < result.items.length; i++) {
          merged.push(result.items[i]);
        }
        this.items = merged;
        this.page = page;
      }
      this.maxPage = result.maxPage > 0 ? result.maxPage : 1;
      this.desc = result.desc;
      this.errorMessage = '';
    } catch (e) {
      if (this.disposed) {
        return;
      }
      this.errorMessage = describeError(e as Error);
      if (!reset) {
        Toast.show(this.errorMessage);
      }
    } finally {
      if (!this.disposed) {
        this.loading = false;
        this.loadingMore = false;
        this.refreshing = false;
      }
    }
  }

  private subtitleOf(item: HanimeInfo): string {
    if (item.views.length > 0) {
      return item.views;
    }
    return item.uploadTime;
  }

  @Builder
  content() {
    if (this.loading) {
      Column() {
        LoadingView({ text: '正在加载清单内容…' });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.errorMessage.length > 0 && this.items.length === 0) {
      Column() {
        ErrorView({
          message: this.errorMessage,
          onRetry: () => {
            this.load(true);
          }
        });
      }
      .width('100%')
      .layoutWeight(1);
    } else if (this.items.length === 0) {
      Column() {
        EmptyView({ text: '清单里还没有影片', hint: '在视频详情页把影片加入该清单' });
      }
      .width('100%')
      .layoutWeight(1);
    } else {
      Refresh({ refreshing: $$this.refreshing }) {
        // VideoListTile 自带上下各 5vp 外边距，List space 2 补足 12vp 列表项间距
        List({ space: 2 }) {
          // 悬浮顶栏让位 spacer：随列表滚走，内容从顶栏下方经过
          ListItem() {
            Row()
              .width('100%')
              .height(this.statusBarHeight + Dimens.topBarHeight);
          }

          if (this.desc.length > 0) {
            ListItem() {
              Text(this.desc)
                .fontSize(Dimens.captionSize)
                .fontColor(Theme.colors().textSecondary)
                .lineHeight(18)
                .width('100%')
                .padding({ left: Dimens.pagePadding, right: Dimens.pagePadding, top: 6, bottom: 6 });
            }
          }

          ForEach(this.items, (item: HanimeInfo) => {
            ListItem() {
              // VideoListTile 自带左右 12 外边距且 width 100%，直接放进 ListItem 会向右溢出、
              // 右边缘被裁掉（用户反馈的「没有右边距」）。外层 Row 先缩掉两侧 24vp，
              // 卡片自带的 12vp 外边距就完整落在屏幕左右 12vp 处。
              Row() {
                VideoListTile({ item: item, subtitle: this.subtitleOf(item) });
              }
              .width('calc(100% - 24vp)');
            }
          }, (item: HanimeInfo) => item.videoCode)

          if (this.loadingMore) {
            ListItem() {
              Row() {
                LoadingProgress()
                  .width(22)
                  .height(22)
                  .color(Theme.colors().primary);
                Text('加载中…')
                  .fontSize(Dimens.captionSize)
                  .fontColor(Theme.colors().textHint)
                  .margin({ left: 8 });
              }
              .width('100%')
              .height(44)
              .justifyContent(FlexAlign.Center);
            }
          } else if (this.page >= this.maxPage) {
            ListItem() {
              Text('没有更多了')
                .fontSize(Dimens.captionSize)
                .fontColor(Theme.colors().textHint)
                .width('100%')
                .height(44)
                .textAlign(TextAlign.Center);
            }
          }
        }
        .width('100%')
        .height('100%')
        .padding({ bottom: this.navBarHeight + 16 })
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
        .onReachEnd(() => {
          this.load(false);
        });
      }
      .width('100%')
      .layoutWeight(1)
      .onRefreshing(() => {
        this.load(true);
      });
    }
  }

  build() {
    // 悬浮顶栏：List 铺满整页（首个 ListItem 是状态栏+顶栏让位 spacer），AppTopBar 覆盖在最上层。
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.content();
      }
      .width('100%')
      .height('100%');

      AppTopBar({
        title: this.p.title.length > 0 ? this.p.title : '播放清单',
        showBack: true
      });
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent);
  }
}
