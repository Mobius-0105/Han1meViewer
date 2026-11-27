# 解析层实现说明（core/parser）

本文档记录 `entry/src/main/ets/core/parser/` 的实现范围、fixture 来源、每条解析路径的验证强度与已知风险。
最后更新：2026-11-21（对应站点 2026-11 结构）。

## 1. 文件与职责

| 文件 | 内容 | 对应上游 Android |
| --- | --- | --- |
| `HtmlDom.ts` | 容错 HTML 解析器 + 迷你 DOM + CSS 选择器子集 | 替代 Jsoup（无直接对应） |
| `HanimeParser.ts` | 首页 / 搜索 / 视频页 / 我的清单 / 播放清单 / 账号 | `Parser.kt` 的 `homePageVer2`、`hanimeSearch`、`hanimeVideoVer2`、`myListItems`、`myPlayListItems`、`onlineWatchHistoryItems`、`playlists`、`userAccountPage`、`extractTokenFromLoginPage` |
| `CommentParser.ts` | 评论首屏 / 分批 / 子评论 / 发表评论 / 发表回复 | `comments`、`commentsPage`、`commentReply`、`postCommentResponse`、`postReplyResponse`、`parseCommentBlock`、`parseReplyPair` |
| `SearchOptionParser.ts` | 搜索筛选项 JSON（列表形态 + tags 映射形态） | `SearchOption.kt` + `assets/search_options/*.json` |

约定：

- 全部纯 TS、零依赖，Node（tsx）可直接跑；`core/**` 不 import 任何系统 Kit；
- 遵守 ArkTS 限制（无 `any` / `enum` / 对象展开 / `for...in` / 动态属性访问，属性用平行数组保存）；
- 解析失败不抛异常：返回尽量完整的对象 + 空串/空数组，由网络层判定是否抛 `ParseError`；
- `absUrl` 统一转绝对地址（封面、播放源、原作漫画等），避免 ArkUI `Image` 拿到相对地址。

## 2. 运行方式与结果

```bash
cd Han1meViewer-HarmonyOS
npm install                       # 已安装
npx tsx --test tests/parser       # 56 个用例，全部通过（~0.4s）
npx tsc -p tsconfig.test.json --noEmit   # 0 error
```

性能：214KB 真实首页（`fixtures/home.html`）解析 + 12 个分区选择约 **15–25ms**（测试断言 < 1s）。

## 3. fixture 来源

### 3.1 真实快照（REAL）

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `fixtures/home.html` | 2026 年 Wayback 快照（`web.archive.org/web/2026id_/https://hanime1.me/`），由 main 工作区 `fixtures/home.html` 拷入 | 214,627 bytes；未登录状态：csrf 只在 `meta[name=csrf-token]`，无 `input[_token]`；首页 `#home-rows-wrapper` 有 14 个直接子 div（索引 4、9 是广告位） |
| `fixtures/watch.html` | `https://javchu.com/watch?v=404507`（2026-11-21 抓取） | 真实 AV 站视频页；未登录。hanime1.me / hanime1.com / hanimeone.me 直连均被 Cloudflare 403 拦截，javchu.com 可直连 |
| `fixtures/search.html` | `https://javchu.com/search?sort=最新上傳` | 61 个 `horizontal-card`（含 2 个 EROLABS 广告卡，无 watch 链接，解析时过滤）→ 59 条 |
| `fixtures/login.html` | `https://javchu.com/login` | 真实 `input[name=_token]`，用于 `extractCsrfFromLoginPage` |
| `fixtures/comments.json` | `https://javchu.com/loadComment?type=video&id=404507` | 首屏 11 条评论 + `#comment-scroll-sentinel`（`data-has-more=0`、`data-next-offset=11`） |
| `fixtures/comments_page.json` | `https://javchu.com/loadComment?type=video&id=404507&offset=11` | 真实分批响应：`{items_html:"", has_more:false, next_offset:11}`（该视频不足一批，所以 items 为空） |
| `fixtures/replies.json` | `https://javchu.com/loadReplies?id=493824` | 真实子评论响应（2 条，成对节点） |
| `fixtures/playlists.html` | `https://javchu.com/user/575858/playlists` | 真实"我的播放清单"列表页（60 个清单，`ul.pagination` 最大页 17） |
| `fixtures/playlist_items.html` | `https://javchu.com/playlist?list=703938` | 真实播放清单详情页（`.playlist-video-list` + `div[class^=user-tab-item-wrapper]`） |
| `fixtures/search_options/*.json` | `android-src/app/src/main/assets/search_options/` 原样拷贝 | genre / genre_av / sort_option / duration / release_date / brands / tags |

### 3.2 手工合成（SYNTHETIC，文件头有 `SYNTHETIC FIXTURE` 注释）

| 文件 | 覆盖的解析路径 | 为什么必须合成 |
| --- | --- | --- |
| `watch_synthetic_hanime.html` | 主站版式：`video#player > source[size]` 清晰度列表、`fixAvCdnHost`、点赞/点踩已登录字段、我的清单 checkbox、中文标题/简介、原作漫画、旧版系列播放列表（`card-mobile-panel`）、作者订阅表单 | 主站被 CF 拦截；javchu 是 AV 站，未登录页面没有 `<source>`、标签、点赞 input |
| `search_simplified.html` | 简化版式搜索结果（`.home-rows-videos-wrapper` 子元素） | 2026 快照的普通搜索页只有普通卡片；简化版式只在"新番预告"搜索出现 |
| `user_lists.html` | 我的清单（`#playlist-show-description` + `.horizontal-row` + `user-tab-item-wrapper` + `#skip-page-input`） | `/user/<id>/likes`、`/saves` 需登录，匿名访问为空列表 |
| `user_account.html` | 账号资料页（`img#playlist-avatar`、`#email[disabled]`、`profile-sub-stats-*` 等） | `/user/<id>/edit` 需登录，匿名 302 到 `/login` |
| `comments_page_items.json` | 分批评论的非空 `items_html` + `has_more:true`/`next_offset:111` | 真实响应该视频不足一批，`items_html` 为空；评论块本身取自 `comments.json` 的真实 HTML |
| `post_comment.json` | 发表评论响应 `{single_video_comment, comment_count}` | POST 需登录态 |
| `post_reply.json` | 发表回复响应 `{comment_id, single_video_comment}`（成对节点 + 点赞表单） | 同上 |
| `comments_legacy.json` | 旧版评论结构（`#comment-start` 下每 4 个兄弟节点一条） | 站点已改版，拿不到旧版真实响应 |

## 4. 各解析函数验证矩阵

| 函数 | 真实 fixture 验证 | 合成 fixture 验证 | 未验证/站点敏感点 |
| --- | --- | --- | --- |
| `parseHomePage` | 分区数量/卡片字段/banner/csrf(meta 兜底)/userId(未登录为空) | — | 登录态用户信息（`#user-modal-dp-wrapper`）、首页评论/新番预告分区 |
| `parseSearchPage` | 普通卡片 59 条、`#skip-page-input` maxPage=1654、广告卡过滤 | 简化版式 2 条 | 简化版式真实 DOM 细节 |
| `parseVideoPage` | 标题/中文标题(上一兄弟)/日期/观看数/script 兜底源/新版系列(41)/相关(59)/作者/评论数/未登录字段(-1,空清单) | 主站 `<source>` 列表、CDN 修正、点赞字段、我的清单、旧版系列、作者订阅、原作漫画 | 主站真实视频页整体（被 CF 拦截）；登录态点赞/我的清单真实 DOM |
| `parseMyListPage` | `playlist_items.html`（`.playlist-video-list` 路径，含 playlistItemId） | 我的清单页（`.horizontal-row` 路径、desc、maxPage） | 收藏/稍后再看/在线历史真实页面（需登录） |
| `parsePlaylistsPage` | 60 个清单、maxPage、listCode/title/total/cover | — | — |
| `parseUserAccount` | — | 全部字段（含 email disabled） | 真实 `/edit` 页面（需登录）；表单错误不在此处识别（网络层统一处理） |
| `extractCsrfFromLoginPage` | 真实登录页 token | — | — |
| `parseComments` | 11 条、id/用户名/日期/内容/点赞/回复数/举报 id、sentinel | 旧版 4 节点结构 | 登录态：`comment-user-id`/`_token`/`foreign_id` 等点赞表单 |
| `parseCommentsPage` | 真实空 items 响应 | 非空 items + has_more/next_offset | 真实"下一批"响应（该视频只有 11 条评论） |
| `parseReplies` | 2 条真实子评论 | `post_reply`（点赞表单） | 登录态点赞字段 |
| `parsePostComment` / `parsePostReply` | — | 新评论/新回复 + 计数 + 父 id | 真实创建/回复响应 |
| `parseOptionList` / `parseOptionMap` | 7 个真实 JSON（多语言/回退/空 key） | — | — |

## 5. 站点结构敏感点与容错设计

### 5.1 首页分区索引（重要）

Android 原版按 `div[id=home-rows-wrapper] > div` 的索引取分区：
`0 最新上市 / 1 最新上傳 / 2 裏番 / 3 泡麵番 / 4 广告 / 5 Motion / 6 3DCG / 7 2.5D / 8 2D / 9 广告 / 10 AI / 11 MMD / 12 Cosplay / 13 他們在看`。
2026-11 真实快照与此完全一致（14 个直接子 div，索引 4、9 是广告位）。

实现采用 **"标题优先 + Android 索引兜底"**（`pickHomeSection`）：

1. 从分区 div 的前一个兄弟 `<a class=horizontal-row-title><h3>` 用 `ownText()` 取标题；
2. 标题命中关键词（最新上市/最新上傳/裏番/泡麵番/Motion/3DCG/2.5D/2D/AI生成/MMD/Cosplay/他們在看/新番預告）就认领该分区；
3. 标题都认不出（例如站点换语言）时按 Android 索引兜底；
4. 每个分区只被认领一次（`used[]`），避免错位时同一分区被重复使用。

新番预告（AV 站索引 13 / 主站索引 12）先按标题"新番預告"识别；识别不到时按 Android 索引兜底，但**如果该索引分区已被
Cosplay/他們在看 占用则返回空列表**——这是对上游的一处修正：上游这样会把 Cosplay 的卡片重复塞进新番预告；
2026 快照主站没有新番预告分区，因此 `newAnimeTrailer = []` 是预期结果。

### 5.2 视频页

- `video#player` 有 `<source size=1080 src=... type=...>` 时按 `size` 生成 `"1080P"` 等标签，按分辨率从高到低排序、同分辨率去重；
  没有 `<source>` 时回退到 `div[id=player-div-wrapper]` 里第一段 `const source = '...'` 脚本（AV 站版式），此时分辨率标签为 `"auto"`
  （Android 用 `"Unknown"`，见 Models 注释允许 `"auto"`，播放器只把它当展示标签）。
- `size` 缺省 → `"auto"`；`size="1080p"` → `"1080P"`；任意数字尺寸（如 2160）也会保留为 `"2160P"`（Android 只认 1080/720/480/240，会丢弃其它）。
- `fixAvCdnHost`：仅当 baseUrl 含 `javchu.com` 时把 `//t\d+.cdn2020.com` 改成 `t33`（正则忽略大小写，保留 `//` 或 `https://` 前缀）。
- 登录态字段缺失时：`favTimes`/`unlikesCount = -1`，`isFav`/`isUnlike = false`，`myList` 仍是对象（`{isWatchLater:false, myListInfo:[]}`，与 Android 一致）。
- 解析失败（403 挑战页、结构大改）不抛异常：`title=''`、`sources=[]` 等，由网络层 `ResponseGuard`/`HanimeApi` 判断是否抛 `ParseError`。

### 5.3 评论

- 2025-11 改版：每条评论是 `div.comment-item-block[data-comment-id]`；旧版"每 4 个兄弟节点一条评论"逻辑保留为兜底（`comments_legacy.json` 验证）。
- 子评论是"基本信息 + 点赞表单"成对节点，按 2 个一组解析（`parseReplyPair`）。
- `#comment-scroll-sentinel`：`hasMoreComments = data-has-more === '1'`；`nextCommentOffset` 在 `has_more=0` 时归一为 **-1**。
  站点在 `has_more=0` 时仍会返回一个无意义的 `data-next-offset`（真实快照里是 11），UI 约定 -1 表示"没有下一页"，
  因此这里不照抄原始值。`parseCommentsPage` 的 `next_offset` 同理（`has_more=false` → -1）。
- 未登录时评论的点赞表单（`#foreign_id` / `is_positive` / `comment-likes-*`）不存在，`post` 里数字字段为 0、布尔为 false；`thumbUp` 用 -1 表示未解析。

### 5.4 域名

`isAvSite(baseUrl)` 只根据 baseUrl 是否包含 `javchu.com` 判断（对应 Android `HANIME_URL[3]`）。
hanime1.me / hanime1.com / hanimeone.me / javchu.com 四个域名中，只有 javchu 需要 AV CDN 修正；页面选择器其余部分共用。

### 5.5 我的清单 / 播放清单

契约只有 `parseMyListPage` 一个函数，但它同时承担 Android 的三个函数
（`myListItems` / `myPlayListItems` / `onlineWatchHistoryItems`）以及 `HanimeApi.getPlaylistItems` 的页面：

1. 先试 `.horizontal-row` 下的 `div[class^=user-tab-item-wrapper]`（我的清单/历史）；
2. 为空再试 `.playlist-video-list`（播放清单详情页）；
3. 描述取 `#playlist-show-description` 的 ownText，回退 `p.playlist-description` 的 text；
4. 总页数：优先 `#skip-page-input`（列表页表单），回退 `ul.pagination`。

## 6. 与上游 Android 的已知差异（有意为之）

| 项 | Android | 本移植版 | 原因 |
| --- | --- | --- | --- |
| 解析失败 | `throwIfParseNull` 抛 `ParseException` | 返回空字段对象 | 网络层统一判定并抛 `ParseError`；避免评论区/首页局部字段缺失导致整页失败 |
| 首页 csrf | 只读 `input[name=_token]` | 再回退 `meta[name=csrf-token]` | 2026 快照未登录首页只有 meta 里有 token |
| `parseHomePage` 分区 | 纯索引 | 标题优先 + 索引兜底 | 站点改版/插入广告位时索引会错位 |
| 新番预告索引 | AV 13 / 主站 12，可能与 Cosplay 重复 | 标题优先；索引分区已被占用则空 | 避免同一批卡片重复出现在两个分区 |
| `favTimes`/`unlikesCount` | `Int?`（null） | `-1` 表示未解析 | Models 契约要求 number；UI 据此隐藏点赞数 |
| 分辨率标签 | 固定 1080/720/480/240/Unknown | 保留任意 `size` + `auto` | 站点可能新增分辨率；`"auto"` 是 Models 注释里允许的展示值 |
| `nextCommentOffset` | null | `has_more=0` 时 -1 | UI 约定 -1 表示没有下一页 |
| `parsePostReply` 响应只有 1 个节点 | 解析失败 | 用同一节点兜底解析（点赞字段留空） | 容错，避免结构小变动导致整条回复丢失 |
| 播放清单总页数 | `ul.pagination` | 先 `#skip-page-input` 再 `ul.pagination` | 新版列表页改用"跳到指定页"表单 |

## 7. 已知风险 / 后续注意

1. **主站真实视频页未被验证**：hanime1.me / hanime1.com / hanimeone.me 在本机直连均 403 Cloudflare；
   真实 `watch.html` 取自 javchu.com（AV 站）。主站特有路径（`<source>` 列表、标签、中文标题、我的清单、原作漫画、旧版系列播放列表）
   目前只有合成 HTML 验证；如果主站 DOM 与合成结构不一致，需要补抓真实快照（可尝试 Wayback，但 watch 页收录很少）。
2. **登录态未验证**：点赞状态、`comment-user-id`/`_token`、评论点赞表单、账号资料页都需要登录 Cookie，目前只有未登录真实响应 + 合成页面。
3. **评论分批的真实"下一页"响应未验证**：抓取到的视频只有 11 条评论，真实 `items_html` 非空的分批响应未拿到（合成覆盖）。
4. **新番预告分区真实结构未验证**：2026 快照首页没有该分区；`search_simplified.html` 为合成。
5. **站点改版**：所有选择器都集中在 `HanimeParser.ts` / `CommentParser.ts` 顶部函数里，
   改版后先跑 `npx tsx --test tests/parser` 定位，再按上面的 fixture 来源补抓快照。
6. **`SearchOptionParser.ts` 与 `core/util/SearchOptions.ts` 存在功能重叠**：后者由 db/settings 一侧实现并被
   `logic/settings/SearchOptionsStore.ets` 使用；本文件是按 `docs/ARKTS_GUIDE.md` 契约独立实现的解析层版本（语义一致，
   额外支持 `zh-rTW` 回退等）。两者目前都没有被重复调用，建议后续二选一（推荐 `core/parser/SearchOptionParser.ts` 作为契约入口，
   `core/util/SearchOptions.ts` 改为 re-export），本次未修改越界文件。
7. **`HtmlDom.absUrl` 空 baseUrl 行为**：文档没有 baseUrl 时相对地址返回 `''`（Jsoup 在 baseUri 非法时返回原值）。
   真实解析调用都传了 baseUrl，不影响业务；单独用 `parseHtml(html, '')` 时需注意。
8. **`HtmlDom.select` 包含上下文根自身**：与 Jsoup `Element.select` 文档一致（"Matched elements may include this element"），
   `doc.select` 从 `<html>` 开始遍历，行为不受影响。
