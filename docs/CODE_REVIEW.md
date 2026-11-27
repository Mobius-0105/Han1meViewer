# 代码审查报告

> 审查对象：`Han1meViewer-HarmonyOS`（OpenHarmony API 24 / ArkTS）当前工作区源码（截至 2026-11-21 18:56，含评审期间落盘的 `requestTab`、PlayerPage `createAVPlayer` try/catch 等改动）。
> 审查方式：只读源码 + 与 `android-src` 上游实现逐项对照；未重复编译、未修改任何源码。
> 行号以当前文件为准。

## 结论摘要

> **处理状态**：维护者已按本报告修复全部 3 条 P0 与大部分 P1，修复明细见 [`docs/CODE_REVIEW_FIXES.md`](CODE_REVIEW_FIXES.md)；下方为审查时的原始结论。

- **P0：3 条**（断点续播被详情页清零、登录态误判、冷启动初始化竞态）。
  其中第 1 条是确定性数据/功能损坏，建议发布前必修；第 2 条是登录态正确性问题（游客会话 cookie 被判为已登录）；第 3 条与时序相关，但对"依赖备用域名/Cloudflare 验证"的用户会表现为首屏全部接口失败。
- **P1：9 条**（评论区刷新与登录态失效、库计数不刷新、R18 确认可能重复、跨站 cookie 泄露、DB ready 永久 pending 导致播放器卡死等）。
- **P2：15 条**（解析失败静默空白、缓存/重定向、AVPlayer 释放竞态、续播边界、降级态混播、主题/ForEach 局部不刷新、错误码映射、主线程解析卡顿等）。
- 整体评价：**分层、错误分类、Cookie/表单/分页/评论 offset 等"契约层"与上游 Android 对齐得相当好**（见"已验证正确"），大部分问题出在**页面状态生命周期（普通属性/ForEach key/异步回写）与初始化时序**，而不是解析或网络协议本身。修复集中在 5 个文件（`VideoPage`、`CommentSection`/`CommentInputBar`/`CommentItemView`、`WebPage`/`LoginPage`、`EntryAbility`/`AppDb`）即可覆盖全部 P0/P1。

---

## P0 严重问题

### 1. 打开视频详情页会把续播进度写成 0，断点续播全链路失效（数据丢失）

- **位置**：`entry/src/main/ets/pages/video/VideoPage.ets:150`（`loadLocalState()`；由 `:118` 的 `reload()` 每次进入/刷新/登录变化时调用）；`entry/src/main/ets/logic/db/AppDb.ets:149-160`（`upsertHistory` 用 `ON_CONFLICT_REPLACE`）；`entry/src/main/ets/logic/db/LocalRepo.ets:87-109`。
- **现象/原因**：
  - 详情页加载完成后执行 `repo.recordWatch(code, title, cover, 0, 0)`，`recordWatch` → `upsertHistory` → `insert(..., ON_CONFLICT_REPLACE)`。`history` 表以 `videoCode` 为主键，**整行替换**，因此已保存的 `positionMs/durationMs` 被 0 覆盖。
  - PlayerPage 的续播位置来自 `LocalRepo.getResumePosition()`（`PlayerPage.ets:204-210`），而播放器**只能**从 VideoPage 的"立即播放"进入（`VideoPage.ets:193-198`）。也就是说每次播放前必然先被写 0 → **续播功能永远返回 0**，并且用户"没看完的进度"被清掉（数据丢失）。
  - 对照上游：Android 的 `WatchHistoryDao.insertOrUpdate`（`android-src/.../dao/WatchHistoryDao.kt`）在 `progress == 0L` 时保留旧 `progress`；本移植版没有这层合并。
- **修复建议**（二选一，建议两者都做）：
  1. 删除 `VideoPage.ets:149-153` 的 `recordWatch(..., 0, 0)`（"进入详情即记录历史"不是上游行为，历史/进度应由播放器写）；
  2. 在 `AppDb.upsertHistory` 改成"先读旧行再合并"：`positionMs` 为 0 且旧值 >0 时保留旧进度、`durationMs` 为 0 时保留旧时长、`title/coverUrl` 为空时保留旧值；或新增 `updateProgress`（只 UPDATE position/duration/updatedAt），播放器节流写进度时走 `WatchProgress.saveProgress`（该文件已实现但**当前无任何调用点**，属于死代码）。

### 2. 用 `hanime1_session` cookie 是否存在判定"登录成功"，会把游客/CF 验证判成已登录（登录态持久化错误）

- **位置**：
  - `entry/src/main/ets/pages/web/WebPage.ets:121-144`，关键行 `:141-143`（CF 验证/网页播放页点"完成"时，只要 cookie 串含 `hanime1_session=` 就 `SessionActions.applyLoginCookie(cookie)`）；
  - `entry/src/main/ets/pages/login/LoginPage.ets:101-107`（`hasSessionCookie` 只看 `hanime1_session=` / `remember_web`）、`:170-185`（任何非 `/login` 页面加载完就自动判定登录）、`:188-196`（"我已完成登录"按钮同样判定）；
  - `entry/src/main/ets/viewmodel/library/SessionActions.ets:32-39`（双写 cookie + `setLoggedIn(true)`，会持久化到 preferences）。
- **现象/原因**：
  - 站点是 Laravel 应用，**游客页面也会下发会话 cookie**：`fixtures/home.html`（游客首页快照）里存在 `meta[name=csrf-token]`，`fixtures/watch.html` 游客页里存在 `_token` 输入框——CSRF token 必须绑定 session，说明游客同样拿到 `hanime1_session`。
  - 因此：用户打开 WebPage 做 Cloudflare 验证 → 点"完成" → 命中 `:141` → 应用被标记为"已登录"（但根本没有登录）；之后评论/收藏/我的清单等写操作全部 419/跳登录页，而 UI 一直显示已登录。CF 验证入口在首页/详情/搜索/播放器都有（`ErrorStateView` 的"去验证"、`HomePage.openVerify` 等），触发概率很高。
  - 上游 Android 的登录判定是**再请求一次 `GET /login`，404 才算登录成功**（`android-src/.../logic/NetworkRepo.kt:login()`），从不靠 cookie 名判断。
- **修复建议**：
  1. `WebPage.persistCookies` 里删掉 `:141-143`（CF 验证只应同步 `cf_clearance`，不应改登录态）；
  2. `LoginPage` 的登录判定改为"请求站点 `/login`（或 `user/{id}/edit`）确认 302/200-登录页 → 未登录；404/用户信息 → 已登录"，或退化为"cookie 含 `remember_web`（用户勾选记住登录）**或** pop 前校验 `getHome().userId` 非空"；
  3. 增加"退出登录/失效"路径：写操作收到 `LoginExpiredError` 时清理 `loggedIn` 并引导登录（当前只在个别页面 Toast，见 P2-9）。

### 3. 冷启动初始化是"fire-and-forget"，首屏请求可能仍用默认域名/默认 UA/无 cookie

- **位置**：`entry/src/main/ets/entryability/EntryAbility.ets:18`（`this.initApp()` 未 await）；`:21-43`（`await settings.init` → `initNetwork`（CookieStore）→ `HanimeApi.configure` → `AppDb.init`）；`:50-60`（`onWindowStageCreate` 直接 `windowStage.loadContent('pages/Index')`）。
- **现象/原因**：
  - `onCreate` 里 `initApp()` 在第一次 `await` 处让出后，`onWindowStageCreate` 立刻加载页面；`HomePage.aboutToAppear`（`HomePage.ets:54-56`）会立即发起 `api.getHome()`。页面首请求与 `settings.init`/`CookieStore.init`/`HanimeApi.configure` 之间**没有任何同步**：若首屏先跑，则用 `HanimeApi` 默认的 `https://hanime1.me/`、默认 UA、空 cookie。
  - 对设置了备用域名（`hanime1.com` / `hanimeone.me` / `javchu.com`）的用户，首屏会去请求被墙/不可用的默认域名 → 首页直接报错；对依赖 `cf_clearance` cookie 的用户，首请求会再次被判 Cloudflare challenge。失败后只是显示错误页/Toast，没有"初始化完成后自动重试"。
  - 由于 `initApp` 不 await，`HanimeApi.configure` 晚于 UI 首帧是设计上允许的时序（注释 `:34` 也承认"必须在设置读取完成后应用"），但没有对"首屏请求可能早于它"做防护。
- **修复建议**：把初始化 Promise 化并在 `loadContent` 前等待（`onWindowStageCreate` 改为 `this.initApp().finally(() => windowStage.loadContent(...))`，或至少把 `settings.init` + `CookieStore.init` + `configure` 合成一个 `AppBootstrap.ready` Promise，在 `HttpClient.execute`/`HanimeApi` 入口 `await` 它，并加"初始化完成后 UI 自动重试首屏"的机制）；另有兜底：`HttpClient` 在 `CookieStore` 未 initialized 时拒绝请求、或首屏在 `initReady` 前只显示 Loading。

---

## P1 功能性问题

### 1. 评论点赞 / "展开 N 条回复" 数字不刷新（ForEach key 不含可变字段，可能重复点赞）

- **位置**：`entry/src/main/ets/pages/video/CommentSection.ets:172-177`（`replaceComment` 重新 map 出同 key 数组）、`:236-238`（回复成功 `applyReplyIncrement`）、`:365-380`（`ForEach` key = `commentKey(comment)`，即 `id:<commentId>`）；`entry/src/main/ets/viewmodel/video/VideoUiUtils.ets:108-114`。
- **原因**：`commentKey` 只由评论 id 决定，点赞/回复数变化时 key 不变；ArkUI `ForEach` 对相同 key 的数据项**不会重建/更新**已生成的 `CommentItemView`（其 `@Prop comment` 也不会被重新赋值）。于是服务端点赞成功、Toast 也提示成功，但界面上的点赞数、点赞高亮、"展开 N 条回复"均不变；用户重复点击时又带着**旧的** `likeCommentStatus` 去请求，可能造成重复点赞/状态与服务端不一致。
- **修复建议**：key 里带上可变字段，例如 `commentKey(c) + '|' + c.thumbUp + '|' + (c.post.likeCommentStatus ? 1 : 0) + '|' + c.replyCount`；或把 `VideoComment` 改为 `@Observed` 类并用 `@ObjectLink` 子组件，做到原地更新。

### 2. "回复评论"输入条 UI 不更新：看不到"回复 @谁"、没有"取消回复"

- **位置**：`entry/src/main/ets/pages/video/CommentSection.ets:316-326`（传给 `CommentInputBar` 的 `placeholder`/`replyToName`/`sending`）；`entry/src/main/ets/pages/video/CommentInputBar.ets:10-13`（这三个都是**普通成员变量**，不是 `@Prop`）、`:23-42`（依赖 `replyToName` 才渲染回复提示行）。
- **原因**：ArkUI 中未装饰的成员变量只在子组件创建时初始化一次，父组件因 `@State replyingName` 变化而重渲染时**不会更新**已有子组件的普通属性。`CommentSection.startReply` 设置 `replyingName` 后，`CommentInputBar` 仍是旧值：看不到"回复 @xxx/取消回复"，但 `submit()` 读的是 `CommentSection.replyingId`，**实际会按回复提交**——用户完全没有"我正在回复某人"的感知，也无法取消。
- **修复建议**：把 `CommentInputBar` 的 `placeholder/replyToName/sending` 改成 `@Prop`（`ArkTS` 支持 `@Prop`+普通默认值）；或直接在 `CommentSection` 内联输入条。

### 3. 登录后，已在列表里的评论项仍是"未登录/token 为空"：点赞回复提示请先登录或 419

- **位置**：`entry/src/main/ets/pages/video/CommentItemView.ets:33-35`（`token`、`loggedIn` 为普通属性）、`:99-127`（`toggleLike` 用这两个值判断与提交）；`entry/src/main/ets/pages/video/CommentSection.ets:366-379`（父组件传 `token: this.token(), loggedIn: this.loginFlag()`）。
- **原因**：同 P1-2。登录前后 `comments` 数组仍是同一批 id（key 不变），ForEach 复用旧 `CommentItemView`，其 `loggedIn=false`、`token=''` 不会更新。从详情页内跳登录页登完返回（`VideoPage.onLoginChanged` → `commentReloadToken+1` → `loadFirst`）后，点赞仍弹"请先登录"，或请求因缺 CSRF 失败。
- **修复建议**：`CommentItemView` 的 `token/loggedIn` 改 `@Prop`（并保留 `@Prop @Watch comment`），或在 ForEach key 中带上登录态/ token 版本。

### 4. `CommentSection` 的 `currentUserId/csrfToken/videoCode` 普通属性在父页面刷新后不更新

- **位置**：`entry/src/main/ets/pages/video/CommentSection.ets:36-39`（普通属性）；`entry/src/main/ets/pages/video/VideoPage.ets:591-596`（`CommentSection({ videoCode: this.video.videoCode, currentUserId: this.video.currentUserId, csrfToken: this.video.csrfToken, ... })`）。
- **原因**：`VideoPage.reload()` 后 `this.video` 是全新对象，但 `CommentSection` 已存在、普通属性不更新；`token()/userId()` 的兜底值仍来自旧的 `video`（通常是空串）。当前只有 `loadComment` 响应里带回 `_token`/`comment-user-id` 时才正常（游客快照 `fixtures/comments.json` 里**没有**这两个 input，登录态响应是否带回取决于站点实现）。即"登录后同页刷新"的评论凭据可能仍为空，需退出重进页面才恢复。
- **修复建议**：这四个属性改 `@Prop`（`onCommentCountChange` 回调保持普通函数即可）。

### 5. 收藏 / 稍后再看 / 历史计数不刷新（`libraryVersion` 通知漏发）

- **位置**：写库但未调 `notifyLibraryChanged()`：`VideoPage.ets:222`（收藏）、`:259`（评分联动收藏）、`:275`（稍后再看）、`:150`（写历史）；播放器进度：`PlayerPage.ets:584/595`；读取端：`pages/library/LibraryPage.ets:47`（`@StorageLink('libraryVersion') @Watch`）、`:54-64`（只在首次出现/版本变化时 `loadCounts`）；通知函数：`viewmodel/library/LibraryViewModel.ets:43-47`。
- **原因**：`LibraryPage` 在 Tabs 里常驻，`aboutToAppear` 只跑一次；在详情页收藏/加稍后再看/看完视频返回后，计数仍是旧值（要等收藏页/历史页操作触发 `notifyLibraryChanged` 才刷新）。
- **修复建议**：在 `VideoPage.toggleFavorite/toggleWatchLater/loadLocalState(recordWatch 后)`、`PlayerPage.saveProgress/saveProgressNow`（或 `LocalRepo` 内部统一）调用 `notifyLibraryChanged()`。

### 6. R18 年龄确认可能每次冷启动都重新弹出（`Disclaimer.init` 竞态）

- **位置**：`entry/src/main/ets/entryability/EntryAbility.ets:24-28`（`Disclaimer.init(this.context)` 在 `await settings.init(...)` **之后**才执行）；`entry/src/main/ets/common/Disclaimer.ets:18-33`（`isConfirmed()` 在 `ctx === null` 时返回 false）；`entry/src/main/ets/pages/Index.ets:82-85`（`Index.aboutToAppear` 里 `!Disclaimer.isConfirmed()`）。
- **原因**：`Index.aboutToAppear` 依赖 `windowStage.loadContent`，而 `Disclaimer.init` 依赖 preferences 异步读取完成；两者没有顺序保证。若页面先就绪，`isConfirmed()` 返回 false → 已确认过 18+ 的用户每次启动都会再弹一次（点一次即可继续，不崩溃但属于合规/体验问题）。
- **修复建议**：`Disclaimer` 改用同步 API（`preferences.getPreferencesSync`）并在 `EntryAbility.onCreate` 里**同步初始化上下文**（或把 confirm 状态放进 `AppSettings` 一起加载，并让 Index 在设置加载完成后才判断）。

### 7. 跨站 cookie 泄露：手动/网页登录的会话 cookie 会被注入任意 WebPage 域名

- **位置**：`entry/src/main/ets/logic/net/CookieStore.ets:92-100`（`getCookieHeader` 收集全部 cookie）、`:191-202`（`collectCookies` 把 `loginCookies` 也收集进来）；`entry/src/main/ets/core/util/CookieHeader.ts:167-179`（`domainMatches` 对 `domain === ''` 恒返回 true）；`entry/src/main/ets/pages/web/WebPage.ets:82-104`（打开任何 WebPage 都 `injectStoredCookies`，不校验 host）；打开第三方页面的调用点：`pages/library/LibraryPage.ets:426`（GitHub）、`pages/settings/SettingsPage.ets:562`（GitHub）、`:596`（Apache License）。
- **原因**：`setCookieString` 保存的整串登录 cookie 在 `parseCookieString` 里被解析为 `domain: ''`（"对所有 host 发送"）。于是打开 GitHub/许可证等外部页面时，`injectStoredCookies` 会把 hanime 站点的 `hanime1_session`/`cf_clearance` 等通过 `WebCookieManager.configCookieSync(githubUrl, ...)` **写进 github.com 的 cookie jar**（并随请求发给第三方）。同样问题也可能影响"切换到别的备用域名后仍带旧站点会话"。
- **修复建议**：`injectStoredCookies` 只在 `hostOfUrl(webUrl)` 与 `hostOfUrl(AppSettings.getBaseUrl())` 匹配时执行；`CookieStore` 为手动 cookie 记录一个"仅对站点主域发送"的标记，`getCookieHeader` 对该标记做 host 校验。

### 8. `AppDb.ready` 永久 pending 会把播放器卡在加载态（初始化链路中断时）

- **位置**：`entry/src/main/ets/logic/db/AppDb.ets:55-63`（`ready` 只在 `init` 的 `finally` 里 resolve）、`:76-102`、`:269-276`（`waitStore` 先 `await this.ready`，之后才抛"未初始化"错误）；依赖点：`PlayerPage.ets:191`（`this.pendingSeekMs = await this.resumePosition()`）、`:204-210`（`resumePosition` 里 `await ...getResumePosition`，只 catch 异常，**不处理 pending**）。
- **原因**：`EntryAbility.initApp` 是 fire-and-forget 的 async 函数，若在 `await AppDb.getInstance().init()`（`EntryAbility.ets:36-40`）之前抛异常/永久挂起（如 settings 读盘异常被吞后的后续链路异常、或 `initApp` 内部非预期抛错导致后续语句不执行），`AppDb.init` **永远不会被调用**，`ready` 永不 resolve。此时：
  - 依赖 DB 的页面（收藏/历史/我的计数/搜索历史）一直 loading（例如 `FavoritesPage.loadLocal` 的 `await` 永不返回）；
  - 播放器 `init()` 在第 191 行永久挂起 → `loading` 已置 false 但 `loadSource` 不执行 → **黑屏 + 无限 loading**，用户只能退出页面。
  - 注意：`AppDb.init` 自身失败（catch + finally）是安全的，问题只在"init 根本没被调用/init 内部挂起"。
- **修复建议**：① `EntryAbility.initApp` 用 `try/finally` 保证 `AppDb.init` 一定被调用；② `AppDb` 在 `init` 未调用时提供一个短超时（如 10s）后让 `waitStore` reject（或 `init` 由 `AppStorage/静态` 标记启动中）；③ `PlayerPage.resumePosition` 用 `Promise.race` 超时兜底 0，避免播放器被 DB 卡死。

### 9. 登录过期/CSRF 过期不会清理登录态，且 419 被当成普通网络错误

- **位置**：`entry/src/main/ets/logic/net/ResponseGuard.ets:87-136`（419/429/503 都落到 `:135` 的 `NetworkError('网络请求失败（HTTP n）')`）；写操作失败只 Toast 的调用点：`pages/video/VideoPage.ets:229-233`、`:264-268`、`pages/video/CommentSection.ets:270-274`、`pages/login`/`WebPage` 之外的写接口同构。
- **原因**：会话/CSRF 过期时站点通常回 302→登录页（已被 `assertNotLoginHtml` 兜住）或 419（Laravel CSRF token mismatch）。419 在 UI 上显示为"网络请求失败（HTTP 419），请检查网络…"，用户被误导；`AppSettings.loggedIn`/CookieStore 仍保持"已登录"，后续每次操作都失败，没有自动跳登录/清 cookie 的路径。
- **修复建议**：`ResponseGuard` 增加 419（及 401）→ `LoginExpiredError`；UI 捕获 `LoginExpiredError` 时统一 `SessionActions.logout()` + Toast + `Router.openLogin()`（至少评论/收藏/评分/我的清单写操作）。

---

## P2 健壮性/体验问题

1. **HTML 解析失败静默成空白页**：`HanimeApi.getHome/getVideo/search`（`HanimeApi.ets:100-135`）只做 HTTP 状态判定，`parseVideoPage` 解析不到关键字段时返回全空对象（`HanimeParser.ts:956-1047`），没有按 `docs/parser-notes.md` 所说"由网络层判定是否抛 `ParseError`"。站点维护页/改版/被重定向到 200 登录页时：详情页全空白（无错误提示）、首页显示"暂时没有内容"，用户无法判断是网络问题还是解析问题。建议网络层校验 `title`/`sources`/`list` 关键字段，缺失抛 `ParseError`。
2. **`usingCache: true` + 自动跟随 302**（`logic/net/HttpClient.ets:129`、文件头注释 `:11-16`）：POST 按 HTTP 语义不会被缓存（登录/评论不会被"缓存命中"），主要风险在无 `Cache-Control` 的 GET 页面可能返回旧响应（尤其登录/登出后的 `user/**`、首页）；302 被自动跟随后拿不到中间 `Set-Cookie`/状态码，登录重定向只能靠"响应体是登录页"特征兜底（当前 `assertNotLoginHtml`/`loginRequiredHtml` 已覆盖主要路径）。建议对登录态相关 GET 关闭缓存（或全局 `usingCache:false`），并考虑 README 里说明的 CF 页面不缓存。
3. **AVPlayer 释放后的回调竞态**（`PlayerPage.ets:266-281` 注册、`:534-573` release、`:382-390`）：回调全部是箭头函数（`this` 绑定正确，不会出现 `this` 丢失），`release()` 后 JS 侧 AVPlayer 对象仍存在，误用会抛 `BusinessError` 而非崩溃；但 `timeUpdate` 回调未判 `disposed`，页面销毁后仍可能再写一次 DB；`error` 回调与 `stateChange('error')` 会重复触发 `fallbackToWeb` → 重复 Toast/重复 release。建议 release 前 `player.off('timeUpdate')/off('error')`，或在所有回调入口判 `this.disposed || this.avPlayer !== player`。
4. **`setMediaSource` 后的状态误判会导致"能播却降级网页"**（`PlayerPage.ets:307-323`）：`await setMediaSource()` 成功后若 `player.state` 尚未刷新为 `initialized`，会走 `player.url = source.url`；在 `initialized` 状态设置 `url` 会抛错，被外层 catch 捕获后直接 `fallbackToWeb`。建议删掉该分支（`setMediaSource` 失败已在内层 catch 处理），或改为轮询/超时等待 `initialized` 再决定。需真机验证各 SDK 版本下该分支是否触发。
5. **续播缺少"接近结尾则从头播"保护**（`PlayerPage.ets:352-367`、`:373-376`；`WatchProgress.ets:52-58`）：播放到结尾时 `completed` 把 `positionMs = durationMs` 写库；下次进入 seek 到结尾 → 立即 completed，表现为"打开就是最后一帧/黑屏"。建议 `target > duration*0.95` 时归 0（`duration` 在 prepared 后即可判断）。
6. **网页降级态下点清晰度会另起原生播放器（声音叠加）**（`PlayerPage.ets:509-518` 未把 `useWeb` 复位；清晰度 chips 在 `useWeb=true` 时仍显示，`:783-802`）：网页播放中点击清晰度会 `loadSource` 创建 AVPlayer 播放音频，而 Web 播放器仍在放，出现双声/失控。建议 `changeQuality` 里先 `this.useWeb = false` 并在确认 surface 后再起播，或 useWeb 时禁用清晰度/倍速控件。
7. **播放器在打开"网页"页或切后台时继续播放**（`PlayerPage.ets:601-606` 直接 `Router.openWeb` 压栈，`aboutToDisappear` 不会触发；EntryAbility 未处理后台）：点"网页"后音频继续、锁屏/切后台也继续；对内容类应用通常需要 `onPageHide`/窗口 stage 回调里 `pause()`。
8. **同 P1-1 的 ForEach key 问题在其它列表也存在**：`pages/library/HistoryPage.ets:208-213`（key=videoCode，返回后进度/相对时间/进度条不更新）、`pages/library/FavoritesPage.ets:307-311`（"收藏于 X"不更新）；`components/common/Widgets.ets:190-193` 的 `RatingBar`（`ratio/likes/unlikes` 是普通属性）+ `VideoPage.ets:454-458`：详情页点赞/点踩后按钮文案会变，但上方的点赞数/比例条不刷新。建议 key 带上可变字段，或 `RatingBar`/`VideoListTile` 相关字段改 `@Prop`。
9. **深色模式切换后部分子组件颜色可能不刷新**：各页面用 `@StorageLink('themeMode')` 触发自身重绘，但 `AppTopBar`/`VideoCard`/`VideoListTile`/`NavRow`/`SegmentRow`/`DividerLine`/`EmptyView`/`LoadingView` 等子组件既没有订阅 `themeMode`，也没接收颜色参数（如 `Widgets.ets:12-53`、`:229-321`、`LibraryComponents.ets`），切换主题时可能保留旧色。需真机确认 ArkUI 是否会在父组件重渲染时重跑这些子组件 `build`；若不会，应把颜色作为 `@Prop` 传入或在这些组件里加 `@StorageLink('themeMode')`。
10. **冷启动首响应 cookie 可能被丢弃**：`CookieStore.init` 前请求返回的 `Set-Cookie` 只写内存（`CookieStore.ets:284-290` 中 `prefs===null` 直接 return），随后 `init` 的 `loadHostCookies` 会 `clear()`（`:239-263`）覆盖为持久化内容 → 首请求拿到的 `cf_clearance` 丢失。建议 init 前不发请求（见 P0-3），或 init 时 merge 而不是 clear。
11. **WebPage 在 ArkWeb 内核未初始化前注入 cookie 会失败且被静默吞掉**（`WebPage.ets:54` 在 `aboutToAppear` 里调 `injectStoredCookies`，此时 Web 组件尚未创建；`:98-103` try/catch 忽略）；手动 cookie 用户第一次打开网页播放/验证页时可能没有登录态。建议移到 `Web.onControllerAttached` 之后，或至少失败时提示。
12. **主线程解析大 HTML 造成首屏/切页卡顿**：`HanimeApi.getHome/getVideo/search` 在 JS 线程（=UI 线程）同步解析（`fixtures/watch.html` 638KB、`home.html` 214KB），ArkTS 无 Worker 参与，低端机可能出现几百 ms 卡顿；建议把解析结果做页级缓存（同 code 不重复解析）或后续迁移到 TaskPool。
13. **设置页/存储统计阻塞 UI**：`SettingsPage.ets:86-89` 在 `aboutToAppear` 同步递归统计 `cacheDir`（`CacheManager.ets:25-68` 全同步 fileIo），大缓存时会卡主线程；`CacheManager.clear`（`:35-41`、`:70-94`）同步删除 `cacheDir`，其中可能包含 ArkWeb 的磁盘缓存目录，运行中删除是否影响 Web 组件需真机确认。
14. **搜索筛选的语言与关键词组合**：`AdvancedSearchPage.ets:113` 固定 `init(ctx, 'zh-rCN')`，设备语言/站点语言为繁中/英文时筛选项标签始终简体（与 `SearchOptionsStore` 设计不符）；`SearchPage.applyFilter`（`SearchPage.ets:87-97`）在 `filter.query` 为空时**不清空**输入框旧关键词，`runSearch`（`:169-171`）又用 `this.keyword` 覆盖请求 query → "只选类型不填关键词"的搜索会悄悄带上旧关键词。建议按 locale 传语言、并在应用筛选时同步清空/覆盖关键词。
15. **文档与实现不一致（维护风险）**：`docs/ARCHITECTURE.md:138-141` 写的表名是 `local_favorite/local_watch_later/local_history`，实际是 `Schema.ets:16-19` 的 `favorites/watch_later/history`；文档又说"关键字段缺失由网络层判定抛 ParseError"，实际 `HanimeApi` 没有该判定（见 P2-1）。建议同步文档，避免后续按文档改代码踩坑。

---

## 已验证正确的关键链路（避免误报）

1. **评论分页 offset 语义**：`HanimeApi.getComments`（`:145-159`）把 `offset<=0` 归一为 -1 且 `buildCommentsUrl`（`core/util/Urls.ts:139-146`）对负 offset **不加** `offset` 参数（与上游 Retrofit `@Query offset: Int? = null` 首屏不带参数一致）；`parseComments`/`parseCommentsPage` 把 `has_more=false` 的 `next_offset` 归一为 -1；`CommentSection.loadMore`（`:133-142`）还有 `nextOffset<=0` 的二次防护。**即使站点返回 `next_offset=0` 也不会重复拉首屏**（Lead 疑问 1：已确认，低风险）。
2. **评论/写操作的请求契约**：`postComment/postReply/likeComment/favVideo/rateVideo/addToMyList` 的表单字段、字段顺序语义、`X-CSRF-TOKEN` 头与 `_token` 字段均与 `android-src/.../HanimeCommentService.kt`、`HanimeMyListService.kt` 对齐（含 `like-status='1'/''`、`is_positive`、`comment-likes-sum` 等）。
3. **错误分类**：`ResponseGuard` 的 403（CF `cf-mitigated: challenge` / `Just a moment` → Cloudflare；`you have been blocked` → IP 封禁；其它 → NotFound）、404（未登录→LoginExpired / 已登录→NotFound）、500→NotFound、302（permit302 语义、登录页判定）与上游 `throwRequestException()` 对齐；`HanimeApi` 对需要登录的 HTML 页额外做 `assertNotLoginHtml`，对 JSON 接口做"登录页伪装 JSON"兜底。
4. **Cookie 读写**：`CookieHeader.ts` 的 Set-Cookie 解析（含 Expires 逗号、Max-Age 优先）、host/path 匹配、同名覆盖、`HttpResponse.cookies`（curl/Netscape 行格式 + 多行 Set-Cookie + `a=1; b=2` 三种回退）均有实现且有单测（`tests/net/cookie.test.ts`）；`HttpClient` 每次请求前拼 Cookie 头、响应后回写 cookie。
5. **DB 表/列与 `Schema.ets` 一致**：`favorites/watch_later/history/search_history` 四表、主键/索引、`SQL_TRIM_*` 裁剪、`AppDb` 各读写方法的列名与 `Models.ts` 一一对应（未发现 SQL 拼写/列名错位；建议把 `docs/ARCHITECTURE.md` 表名同步过来）。
6. **搜索筛选跨页契约**：`SearchFilterModel.encodeSearchFilter/decodeSearchFilter` 为两端（AdvancedSearchPage 写、SearchPage 读）共用同一份实现，字段与 `SearchRequest` 对齐，非法 JSON 回退默认值；首页分区标题→`genre/sort/tags` 的映射（`HomeViewModel.SECTION_SPECS`）与 `rawfile/search_options/*.json` 的 `search_key` 一致（抽查 `裏番`、`泡麵番`、`最新上傳`、`2D動畫`、`新番預告` 均正确）。
7. **路由参数**：`PageMap` 的 `name` 分支覆盖 `Router.kt` 全部常量；`Router.pop` 有 `size>0` 保护；`openPlayer/openWeb/openSearchResult` 等传递的 `RouteParam` 字段与各页面 `p.xxx` 使用一致（未发现空/类型错用）。
8. **资源与权限**：所有 `$r('app.media.*')` 引用的 17 个资源均存在；`module.json5` 已声明 `ohos.permission.INTERNET`/`GET_NETWORK_INFO`；`main_pages.json` 只注册 `pages/Index`，符合 Navigation 单入口结构。
9. **无敏感信息落日志/无数据上传**：hilog 输出不含 cookie/token（`HttpClient` 只打 URL 与错误信息，`AppSettings` 只打 key/错误码）；全项目无 Analytics/上传逻辑，符合 README/FEATURE_MATRIX 的"不收集数据"声明。
10. **`configure` 的设置生效路径**：设置页修改域名/UA/备用 CDN 后调用 `NetworkConfigurator.apply()` → `HanimeApi.configure` 同步设置 `baseUrl/userAgent/backupCdn` 与 `HttpClient.userAgent`（`SettingsViewModel.ets:28-38`、`SettingsPage.ets:122-155`）；`WebLogin/WebPage` 也把 WebView UA 设为同一 UA（保证 `cf_clearance` 与 UA 绑定）。仅在"冷启动首帧"存在时序问题（P0-3），交互中改设置是即时生效的。
11. **`Index.ets` 的 `requestTab` 信号不会造成循环**（Lead 疑问 4）：`onRequestTab` 在 `>=0` 时切 Tab 并复位为 -1，复位触发的第二次 watch 不满足条件直接返回；`Tabs.onChange` 只是把 `currentTab` 赋为同一值（幂等，不触发二次渲染）。`tabsController.changeIndex` 与 `index: this.currentTab` 双通道切到同一页签，无死循环。需注意的唯一小隐患：`AdvancedSearchPage.apply()` 先 `Router.pop()` 再写 `requestTab`，页面弹出动画期间切底层 Tab，顺序上建议改为先写信号再 pop（或延迟到 pop 完成回调）更稳。
12. **单元测试与静态检查**：`node scripts/arkts-lint.mjs` 通过（58 文件 0 问题）；解析/fixture 测试覆盖首页/搜索/详情/评论/搜索项，为解析层回归提供了基线。

---

## 需真机验证项

1. **AVPlayer 全链路**：`XComponent` surface 时序（`onSurfaceCreated` vs `onLoad`）、`setMediaSource` 后 `state` 是否立即为 `initialized`（P2-4 分支）、HLS（`t33.cdn2020.com` 等）带 Referer/Cookie 能否起播、切清晰度 reset→prepare→seek 是否黑屏、`setSpeed` 各档位是否被流支持、全屏切换（`isFullScreen` 改布局会重建 XComponent/surface）是否黑屏/花屏。
2. **冷启动时序**（P0-3）：清数据安装后冷启动，抓包确认首次 `getHome` 请求是否已带 `cf_clearance`、是否指向用户配置的备用域名；可在 `HanimeApi.configure`/`CookieStore.init` 里加 hilog 时间戳对照首请求时间。
3. **游客是否下发 `hanime1_session`**（P0-2）：用抓包确认游客访问 `hanime1.me` 的 `Set-Cookie`；若游客确实不带该 cookie，则 P0-2 降级为理论风险。同时验证"CF 验证完成后是否被误标登录"。
4. **ArkUI 状态语义**：普通（未装饰）子组件属性在父组件重渲染时是否更新、`ForEach` 相同 key 是否真的复用旧 item——这决定 P1-2/3/4、P2-8/9 的严重度；建议在真机用"登录后评论点赞""回复评论""切深色模式"三个场景各点一遍即可确认。
5. **`WebCookieManager.configCookieSync` 在 ArkWeb 内核初始化前调用**（P2-11）：首次安装、未打开过任何 Web 页面时，从播放器降级/CF 验证入口打开 WebPage，确认网页是否带上登录 cookie。
6. **`CacheManager.clear(cacheDir)` 对 ArkWeb 的影响**（P2-13）：清除缓存后 Web 页面是否仍能正常加载/登录态是否丢失。
7. **播放器后台/压栈行为**（P2-7）：播放中打开"网页"页、按 Home 键、锁屏，确认音频是否继续（是否符合预期）。
8. **首页/详情大 HTML 解析耗时**（P2-12）：在低端机/大页面（watch.html 638KB）上观察首屏与详情页切换是否有明显掉帧。
9. **系统返回键**：播放器全屏态按系统返回是退出页面还是退出全屏（当前未拦截 `onBackPress`，预期会整页退出）。
10. **DB 初始化失败场景**（P1-8）：可临时让 `relationalStore.getRdbStore` 抛错，验证 FavoritesPage/HistoryPage/PlayerPage 的表现（当前预期：错误页/Toast 可恢复；但"init 根本没被调用"时永久 loading）。

---

## 未审查项

以下模块仅做了静态通读或未逐行审查，结论可能不完整：`core/parser/HtmlDom.ts` 的选择器实现细节（仅抽查，依赖单测覆盖）、`core/parser/SearchOptionParser.ts`、`pages/settings/SettingsPage.ets` 后半段 UI 细节、`viewmodel/settings/CacheManager` 以外的零散工具函数、`tests/**` 与 `scripts/**`（不在运行时路径内）。
