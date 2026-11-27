# UI 层开发契约（多个 agent 并行开发时必须遵守）

目标 SDK：`5.0.0(12)`（HarmonyOS NEXT API 12）。先读 `docs/ARKTS_GUIDE.md` 的语言限制。

## 0. 文件归属（不要越界写）

| Owner | 路径 |
| --- | --- |
| 根 agent | `pages/Index.ets`、`components/common/**`、`common/**`、`entryability/**`、资源、docs |
| home/search agent | `pages/home/**`、`pages/search/**`、`viewmodel/home/**`、`viewmodel/search/**` |
| video agent | `pages/video/**`、`pages/player/**`、`viewmodel/video/**` |
| library agent | `pages/library/**`、`pages/settings/**`、`pages/login/**`、`pages/web/**`、`viewmodel/library/**`、`viewmodel/settings/**` |

每个页面可以在自己的目录下新建子组件 / 子 viewmodel 文件。**不要**修改其它 owner 的文件；发现契约缺口在最终报告里说明。

## 1. 路由与页面组件签名（Index.ets 已按此装配）

`pages/Index.ets` 用 `Navigation` + `NavPathStack`，`navDestination` 里根据路由名实例化下列组件。**签名必须完全一致**：

```ts
// pages/home/HomePage.ets
@Component export struct HomePage {}

// pages/search/SearchPage.ets
@Component export struct SearchPage {}

// pages/library/LibraryPage.ets
@Component export struct LibraryPage {}

// 其余页面都接收 RouteParam（common/Router.ets）
@Component export struct VideoPage { p: RouteParam }
@Component export struct PlayerPage { p: RouteParam }
@Component export struct SettingsPage { p: RouteParam }
@Component export struct LoginPage { p: RouteParam }
@Component export struct WebPage { p: RouteParam }
@Component export struct FavoritesPage { p: RouteParam }
@Component export struct HistoryPage { p: RouteParam }
@Component export struct AdvancedSearchPage { p: RouteParam }
@Component export struct SearchResultPage { p: RouteParam }
@Component export struct PlaylistsPage { p: RouteParam }
@Component export struct PlaylistDetailPage { p: RouteParam }
@Component export struct UserAccountPage { p: RouteParam }
```

⚠️ struct 成员：`p: RouteParam = new RouteParam();`（必须给默认值，Index 传值覆盖）。

各页面**不要**自己套 `NavDestination`，Index 的 PageMap 已经包好。

路由名常量在 `common/Router.ets`，跳转统一用 `Router.openVideo(code)` 等静态方法，不要自己操作 NavPathStack。

## 2. 可直接使用的公共模块

```ts
import { Theme, AppColors, Dimens } from '../../common/Theme';   // 相对路径按页面深度调整
import { Router, RouteParam, ROUTE_VIDEO } from '../../common/Router';
import { Toast } from '../../common/Toast';
import { AppTopBar, LoadingView, ErrorView, EmptyView, SectionHeader, TagChip, RatingBar, VideoCard, VideoListTile, DividerLine } from '../../components/common/Widgets';
```

- `Theme.colors(): AppColors` —— `primary / onPrimary / primaryContainer / background / surface / surfaceVariant / cardBg / textPrimary / textSecondary / textHint / divider / error / overlay / playerBg`。**页面里不要写死颜色**（除播放器黑底/遮罩），否则深色模式错乱。
- 响应主题切换：页面加 `@StorageLink('themeMode') themeMode: string = 'system';`，build 里用 `Theme.colors()`。
- 深色判断：`Theme.isDark()`。
- `Dimens`：pagePadding=12、gap=10、cardRadius=10、titleSize=18、subtitleSize=15、bodySize=14、captionSize=12、topBarHeight=52。
- `AppTopBar` 参数：`title: string`、`showBack: boolean`、`actionText: string`、`onAction: () => void`。
- `VideoCard` 参数：`item: HanimeInfo`、`cardWidth: number`（0=100%）、`onTap`（默认跳视频详情）。
- `VideoListTile` 参数：`item`、`subtitle: string`、`onTap`。
- `LoadingView { text }`、`ErrorView { message, onRetry }`、`EmptyView { text, hint }`。

## 3. 数据层 API（已由其它 agent 实现，签名固定）

### 3.1 `logic/net/HanimeApi.ets`

```ts
import { HanimeApi } from '../../logic/net/HanimeApi';
const api: HanimeApi = HanimeApi.getInstance();

api.configure(baseUrl, userAgent, backupCdn);   // 设置页改域名/UA/备用 CDN 后必须调；登录态变化不需要
api.getHome(): Promise<HomePage>;
api.search(req: SearchRequest): Promise<SearchPage>;
api.getVideo(videoCode: string): Promise<HanimeVideo>;
api.getComments(videoCode: string, offset: number): Promise<VideoComments>;   // offset=-1 表示首屏
api.getReplies(commentId: string): Promise<VideoComments>;
api.postComment(text: string, currentUserId: string, targetId: string, token: string): Promise<PostCommentResult>;
api.postReply(commentId: string, text: string, token: string): Promise<PostCommentResult>;
api.likeComment(token: string, type: string, foreignId: string, isPositive: boolean, likesCount: number, likesSum: number, likeStatus: boolean, unlikeStatus: boolean): Promise<void>;
api.favVideo(videoCode: string, cancel: boolean, userId: string, token: string): Promise<void>;
api.rateVideo(videoCode: string, positive: boolean, likeStatus: boolean, unlikeStatus: boolean, likesCount: number, unlikesCount: number, userId: string, token: string): Promise<void>;
api.getMyList(userId: string, type: string, page: number): Promise<MyListPage>;   // type: 'likes' | 'saves'
api.getPlaylists(userId: string, page: number): Promise<PlaylistsPage>;
api.getPlaylistItems(listCode: string, page: number): Promise<MyListPage>;
api.getOnlineHistory(userId: string, sort: string, page: number): Promise<MyListPage>;
api.getUserAccount(userId: string): Promise<UserAccount>;
```

`SearchRequest` 字段：`page, query, genre, sort, broad, date, duration, tags: string[], brands: string[]`（空字符串/空数组表示不过滤）。
错误类型见 `logic/net/Errors.ets`：`CloudflareChallengeError / IpBlockedError / NotFoundError / LoginExpiredError / ParseError / NetworkError`。统一 catch 后 `Toast.show(describeError(e as Error))`；`CloudflareChallengeError` 要引导用户点"去验证"→ `Router.openWeb(api当前站点地址, '验证')`，验证完成后重试。

### 3.2 `logic/db/AppDb.ets` / `logic/db/LocalRepo.ets`

```ts
AppDb.getInstance(): 收藏/稍后再看/历史/搜索历史的 CRUD（见 ARKTS_GUIDE 任务描述）
LocalRepo.getInstance():
  setFavorite(item: LocalVideoRecord, fav: boolean): Promise<void>
  isFavorited(code: string): Promise<boolean>
  listFavoritesSorted(): Promise<LocalVideoRecord[]>
  setWatchLater(item: LocalVideoRecord, on: boolean): Promise<void>
  isWatchLater(code: string): Promise<boolean>
  listWatchLater(): Promise<LocalVideoRecord[]>
  recordWatch(item: LocalVideoRecord, positionMs: number, durationMs: number): Promise<void>
  listHistorySorted(): Promise<HistoryRecord[]>
  deleteHistory(code: string): Promise<void>
  clearHistory(): Promise<void>
```
（若 LocalRepo 名称/签名有差异，以 `logic/db/LocalRepo.ets` 实际代码为准，并在报告里说明。）

### 3.3 `logic/settings/AppSettings.ets`

```ts
AppSettings.getInstance()：getBaseUrl/getUserAgent/getBackupCdn/getThemeMode/setThemeMode/getUserId/getUsername/getAvatarUrl/isLoggedIn/setLoggedIn/getPlayerQualityIndex/getPlayerSpeed/getWatchHistoryEnabled ...
```

### 3.4 `logic/settings/SearchOptionsStore.ets`

```ts
SearchOptionsStore.getInstance(): genres(): SearchOptionItem[]; sorts(); durations(); dates(); brands(); tagScopes(): string[]; tagsByScope(scope: string): SearchOptionItem[];
```

## 4. ArkUI 编码约定（减少编译风险，必须遵守）

- **状态**：`@State` / `@Prop` / `@Link` / `@StorageLink` / `@StorageProp`；数组/对象更新要**整体重新赋值**（`this.list = newArray`），`ForEach` 的 keyGenerator 必须稳定：`(item: HanimeInfo) => item.videoCode + item.title`。
- **异步**：`aboutToAppear() { this.load(); }`，`load` 用 `async`；页面销毁后在 `aboutToDisappear` 置 `this.disposed = true`，异步回来先判空/判 disposed 再 setState。
- **下拉刷新**：`Refresh({ refreshing: $$this.refreshing }) { List() {...} }.onRefreshing(() => this.refresh())`（`$$` 双向绑定是标准写法）。
- **上拉加载**：`List().onReachEnd(() => this.loadMore())`，用 `loadingMore` / `hasMore` 防重入。
- **列表**：优先 `List` + `ListItem`（`ListItem` 内不能再套可滚动容器）；网格用 `Grid` + `GridItem` + `columnsTemplate('1fr 1fr 1fr')`；横向滚动用 `List({ space })` + `listDirection: Axis.Horizontal`。
- **图片**：`Image(url)` 会解码真实 URL；封面统一 `.aspectRatio(0.72).objectFit(ImageFit.Cover)`，加载失败用 `.alt($r('app.media.ic_play'))` 不必要可省略。
- **弹窗**：`promptAction.showDialog`/`showToast`、`@CustomDialog`（简单场景用 `AlertDialog.show({...})`）。确认框用 `AlertDialog.show`。
- **输入**：`TextInput({ text: $$this.keyword }).onSubmit(() => ...)`。
- **Tab 内页面**：`HomePage/SearchPage/LibraryPage` 是 Tabs 的三个 TabContent 内容，**不要**自己加全屏背景/`position` 固定；顶部安全区由外层处理。
- **键盘避让**：`TextInput` 所在 Column 用 `.expandSafeArea()` 不需要；保持默认。
- **禁止**：`router.pushUrl`（本项目用 Navigation）、`@ohos.router`、`LocalStorage`、`window.getLastWindow` 改窗口（除播放器页面）、`@Builder` 全局函数导出、`Grid` 内嵌 `List`、`Scroll` 内嵌 `List`（除 `List` 自身滚动）。
- **播放器页面例外**：`pages/player/PlayerPage.ets` 可以用 XComponent + `@kit.MediaKit`，退出时恢复竖屏（如果设置了横屏）。

## 5. 视觉与交互要求

- 顶部标题栏统一 `AppTopBar`；各页面顶部留白由 AppTopBar 提供，不要在标题栏上方再加 padding。
- 所有异步页面必须有三种状态：加载中（`LoadingView`）、失败（`ErrorView` + 重试）、空（`EmptyView`）。
- 深色模式必须可用（颜色全部来自 `Theme.colors()`）。
- 中文文案；数字/时长格式化用 `core/util/Format.ts` 的函数。
- 首页：banner（有则显示）+ 各分区横向卡片行；点击更多跳到对应搜索结果页（`Router.openSearchResult(分区名)` 需要 D 自己扩展，路由已有 ROUTE_SEARCH_RESULT）。
- 视频详情页：封面/标题/信息/标签/点赞比例/收藏与稍后再看按钮/系列播放列表/相关推荐/评论（首屏 + 分页加载 + 回复 + 点赞 + 发送评论，需登录时提示登录）。
- 播放器：优先原生 AVPlayer（HLS/m3u8），失败自动降级到 Web 播放（`Router.openWeb(watchUrl)` 或页内 Web 组件），要有播放/暂停、进度条、倍速、清晰度切换、全屏。
