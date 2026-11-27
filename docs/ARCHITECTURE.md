# 架构说明（HarmonyOS NEXT 移植版）

本文档描述本移植版的整体设计、数据流、关键实现取舍，以及与上游 Android 实现的对应关系。

## 1. 总体分层

```text
┌──────────────────────────────────────────────────────────────┐
│ ArkUI 页面层  pages/（home / search / video / player / ...）    │
│   @State + @StorageLink 驱动，调用 logic 层，不直接处理 HTML    │
├──────────────────────────────────────────────────────────────┤
│ 平台逻辑层    logic/（ArkTS，可用系统 API）                     │
│   net/  HanimeApi · HttpClient · CookieStore · ResponseGuard   │
│   db/   AppDb · LocalRepo（relationalStore）                   │
│   settings/ AppSettings · SearchOptionsStore（preferences/rawfile）│
├──────────────────────────────────────────────────────────────┤
│ 纯逻辑层      core/（纯 TypeScript，无系统 API，Node 可测）      │
│   parser/  HtmlDom（迷你 DOM + CSS 选择器）                     │
│            HanimeParser / CommentParser / SearchOptionParser   │
│   model/   Models（Domain Model）                              │
│   util/    Urls / Format / Constants / CookieHeader / Form      │
└──────────────────────────────────────────────────────────────┘
```

设计原则：

1. **HTML 解析与平台解耦**：Jsoup 在 HarmonyOS 上不可用，因此自研 `HtmlDom`，并用真实/合成 HTML 快照在 Node 里做单测；
2. **网络层只关心 HTTP 与 Cookie**：解析、错误分类、Cookie 逻辑分离，便于替换；
3. **页面不写业务解析**：页面只拿 `HanimeApi` 返回的领域模型；
4. **不引第三方依赖**：全部功能用系统 Kit + 自研实现，避免鸿蒙生态依赖不确定性。

## 2. 数据流

### 2.1 首页 / 搜索

```text
HomePage
  └─ HanimeApi.getHome()
       ├─ HttpClient.get(baseUrl)                       // @kit.NetworkKit
       ├─ ResponseGuard.guardHtml()                     // 错误分类（CF / IP 封禁 / 404…）
       ├─ replaceBackupMediaCdn()                       // 备用媒体 CDN
       └─ parseHomePage(html, baseUrl)                   // core/parser
            └─ HtmlDocument(html) → 各分区 select/extract
  └─ HomePage 渲染 banner + 分区横向列表（VideoCard）
```

搜索：`SearchRequest` → `buildSearchUrl()` → `parseSearchPage()` → `SearchPage { list, maxPage }`，页面按 `maxPage` 判断是否还能翻页。

### 2.2 视频详情

```text
VideoPage
  ├─ HanimeApi.getVideo(code)
  │    ├─ HttpClient.get(baseUrl + 'watch?v=' + code)
  │    └─ parseVideoPage(html, baseUrl, code)
  │         → HanimeVideo{ title, sources[], tags[], myList, playlist, related, artist, csrf, commentCount }
  ├─ 本地收藏/稍后再看：LocalRepo ↔ AppDb(relationalStore)
  ├─ 播放：Router.openPlayer(code, title) → PlayerPage
  └─ 评论：HanimeApi.getComments(code, -1) → parseComments(json) → CommentSection
```

### 2.3 播放器

```text
PlayerPage（设置项 playerKernel：'exo' 默认 / 'mpv'；MPV 失败自动回退 exo）
  ├─ exo：ExoPlayer 位，HarmonyOS 上由系统 AVPlayer 实现 —— XComponent(SURFACE) + media.createAVPlayer()
  │    ├─ media.createAVMediaSourceWithUrl(url, headers)   // Referer / UA / Cookie
  │    ├─ AVPlayer.surfaceId → prepare() → play()
  │    ├─ 事件：stateChange / timeUpdate / durationUpdate / error
  │    ├─ 清晰度：切换 source 后 prepare + seek 回原进度
  │    └─ 进度记录：节流 5s → LocalRepo.recordWatch()
  ├─ mpv：MpvKernel（@mpv-ohos/mpv-arkts → libmpv + FFmpeg，仅 arm64）
  └─ 降级：两个内核都报错 / 无 source → Web(watchUrl)
```

### 2.4 登录与 Cookie

```text
LoginPage（Web 组件打开 /login）
  ├─ 用户完成登录 / Cloudflare 挑战
  ├─ onPageEnd 检测 URL 不再包含 login
  ├─ webview.WebCookieManager.fetchCookieSync(baseUrl) → cookie 字符串
  ├─ CookieStore.setCookieString(cookie)                 // 持久化到 preferences
  ├─ AppSettings.setLoggedIn(true) / setUserId(...)
  └─ Router.pop()
```

`CookieStore` 按 host 保存 cookie；`HttpClient` 每次请求前调
`CookieStore.getCookieHeader(url)` 拼 `Cookie` 头，并从响应 `Set-Cookie` / `cookies` 字段回写。

### 2.5 Cloudflare 挑战

```text
HttpClient → 403 + cf-mitigated: challenge（或 body 含 "Just a moment"）
  └─ ResponseGuard 抛 CloudflareChallengeError
       └─ 页面 catch → 提示"需要网页验证" → Router.openWeb(url, 'Cloudflare 验证')
            └─ WebPage 加载 → 用户完成验证 → fetchCookieSync → CookieStore
                 └─ 返回业务页重试
```

IP 被封禁（`you have been blocked`）与视频不存在（其它 403/500）会给出不同文案，避免用户误以为需要验证。

## 3. 解析层设计（core/parser）

### 3.1 迷你 DOM

`HtmlDom.ts` 实现一个容错 HTML 解析器：

- 逐字符扫描，处理注释、`<script>`/`<style>` 原始文本、`doctype`、void 元素、自闭合标签、属性单/双/无引号；
- 自动闭合：遇到 `</tag>` 向上回溯；常见可选闭合标签（`p`、`li` 等）按浏览器语义处理；
- 实体解码：命名实体 + 数字实体 + 十六进制实体；
- 节点 API 对齐 Jsoup 语义：`text()` / `ownText()` / `select()` / `selectFirst()` / `getElementById()` /
  `getElementsByClass()` / `absUrl()` / `previousElementSibling()` / `children()`；
- CSS 选择器子集：类型、`#id`、`.class`、属性（含 `^= $= *= ~=` 四种匹配）、后代、子代、逗号分组。

> 选择器支持范围以 `Parser.kt` 里实际出现的用法为准，不做完整 CSS 实现。

### 3.2 各页面解析器

| 函数 | 对应上游 | 说明 |
| --- | --- | --- |
| `parseHomePage` | `homePageVer2` | 按 `#home-rows-wrapper > div` 索引取分区，带标题兜底容错 |
| `parseSearchPage` | `hanimeSearch` | 普通/简化两种版式，`#skip-page-input` 取最大页 |
| `parseVideoPage` | `hanimeVideoVer2` | 标题/简介/点赞/源地址/我的清单/系列/相关/作者/评论数 |
| `parseMyListPage` | `myListItems` / `onlineWatchHistoryItems` | 收藏、稍后再看、在线历史 |
| `parsePlaylistsPage` | `playlists` | 我的播放清单 |
| `parseUserAccount` | `userAccountPage` | 账号资料 |
| `parseComments` / `parseCommentsPage` / `parseReplies` | `comments` / `commentsPage` / `commentReply` | JSON 包裹 HTML 片段，2025-11 改版后支持 offset 分批 |
| `parsePostComment` / `parsePostReply` | `postCommentResponse` / `postReplyResponse` | 直接返回新评论 HTML |

站点改版风险集中在选择器；`fixtures/` 中保存了抓取时的真实 HTML 快照，解析器改动后跑 `npm test` 即可回归。

## 4. 本地存储

`relationalStore` 数据库 `hanime.db`（securityLevel S1）：

| 表 | 主键 / 唯一键 | 用途 |
| --- | --- | --- |
| `favorites` | `videoCode` 唯一 | 本地收藏（标题/封面/上传时间/添加时间） |
| `watch_later` | `videoCode` 唯一 | 稍后再看 |
| `history` | `videoCode` 唯一 | 观看历史 + 播放进度（positionMs/durationMs/updatedAt），写入时做"0 值不覆盖旧进度"的合并 |
| `search_history` | `keyword` 唯一 | 搜索历史（去重，最多 50 条，按时间倒序） |

`preferences`（`hanime_settings`）保存：站点域名、UA、备用 CDN、主题、登录态、userId/username/avatar、
默认清晰度、默认倍速、观看历史开关。关键项同步写入 `AppStorage` 供 `@StorageLink` 响应。

`rawfile/search_options/*.json` 是从上游资产复制的搜索筛选项（类型/排序/时长/日期/品牌/标签），
启动时按当前语言解析（`zh-rCN` / `zh-rTW` / `en` / `ja`，缺失回退 `zh-rTW`）。

## 5. 错误处理

`logic/net/Errors.ets` 定义统一错误类型：

| 错误 | 触发条件 | UI 行为 |
| --- | --- | --- |
| `CloudflareChallengeError` | 403 + `cf-mitigated: challenge` 或 body 含 `Just a moment` | 提示"需要网页验证"+ 验证入口 |
| `IpBlockedError` | 403 + body 含 `you have been blocked` | 提示 IP 被封锁，建议切换网络/域名 |
| `NotFoundError` | 其它 403/500 | 提示视频不存在或已下架 |
| `LoginExpiredError` | 404/302 到登录页 | 提示重新登录，跳转登录页 |
| `ParseError` | JSON 解析失败（关键字段缺失时的静默容错是已知限制，见 CODE_REVIEW P2-1） | 提示解析失败，可重试 |
| `NetworkError` | 连接超时 / DNS / TLS 等 | 提示网络错误 |

## 6. 与上游实现的差异（设计层面）

| 主题 | 上游 Android | 本移植版 |
| --- | --- | --- |
| HTML 解析 | Jsoup | 自研 `HtmlDom` + 显式选择器（无第三方依赖） |
| 状态管理 | ViewModel + StateFlow | 页面 `@State` + `logic` 单例 + `AppStorage` 跨页共享 |
| 导航 | Navigation Compose | `Navigation` + `NavPathStack` |
| 后台下载 | WorkManager + Room | 未实现（见 FEATURE_MATRIX） |
| 播放内核 | Media3 / MPV + 自研控制器 | ExoPlayer 位（系统 AVPlayer）+ MPV（libmpv，可选）+ Web 降级。HarmonyOS 无 ExoPlayer/Media3，本项目 `exo` 内核 = 系统 AVPlayer 实现，仅保留上游的接口语义 |
| 崩溃/分析 | Firebase Crashlytics/Analytics | 未接入（不上传任何数据） |
| 公告 | Firebase RTDB | 未实现 |
| 更新检查 | GitHub Releases API | 未实现（设置页提供项目链接） |
| 共享关键 H 帧 | 本地 JSON 资产 + 下载 | 未实现 |

## 7. 已知风险

1. **站点改版**：解析器依赖站点 DOM 结构，改版后需要更新 `core/parser` 与 `fixtures`；
2. **Cloudflare**：数据中心 IP 容易被封，需网页验证；部分网络环境可能无法通过；
3. **媒体 CDN**：视频 CDN 可能有 Referer/Cookie 校验，AVPlayer 无法自定义所有头时依赖 Web 降级；
4. **API 版本**：`AVPlayer`、`WebCookieManager` 等 API 在不同 SDK 版本上签名有差异，本项目按 API 12+ 编写，
   高版本 SDK 编译时若告警/报错需按提示调整；
5. **无法自动化 UI 测试**：本仓库在没有真机/模拟器的情况下只做了静态检查与纯逻辑单测。


## 8. 代码审查

运行期风险与已修复问题的清单见 [docs/CODE_REVIEW.md](CODE_REVIEW.md)；解析层的 fixture 覆盖矩阵见 [docs/parser-notes.md](parser-notes.md)。
