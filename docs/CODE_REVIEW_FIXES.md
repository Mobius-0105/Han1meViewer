# 代码审查 · 修复记录

> 本文件记录 [`docs/CODE_REVIEW.md`](CODE_REVIEW.md) 中 P0/P1 问题的处理结果（审查报告正文保留不改，便于追溯）。
> 处理时间：2026-11-21；处理后已重新全量编译（ArkTS 0 error）并跑通 91 个单测。

## 已修复

| 审查项 | 问题 | 修复 |
| --- | --- | --- |
| P0-1 | 打开详情页把续播进度写成 0（`ON_CONFLICT_REPLACE`），断点续播失效且丢数据 | `AppDb.upsertHistory` 改为合并语义：`positionMs/durationMs` 为 0 时保留旧值，`title/coverUrl` 为空时保留旧值，进度 ≥95% 视为看完归零 |
| P0-2 | 用 `hanime1_session` cookie 判断登录 → 游客/CF 验证被误标已登录 | 新增 `HanimeApi.checkLoginState()`（`GET /login` 返回 404 = 已登录）；`LoginPage` 校验通过才持久化登录态（失败回退 `remember_web`）；`WebPage` 只同步 cookie，不再自动当登录态 |
| P0-3 | `initApp()` fire-and-forget，首屏可能用默认域名/UA/空 cookie | `EntryAbility` 持有 `initPromise`，`onWindowStageCreate` 等初始化完成后再 `loadContent`；`Disclaimer.init` 提前到 `onCreate` 同步执行（顺带修复 P1-6 R18 重复弹窗） |
| P1-1 | 评论点赞数/回复数不刷新（ForEach key 只含 id） | `commentKey` 带上 `thumbUp/likeCommentStatus/unlikeCommentStatus/replyCount` |
| P1-2 | 回复输入条不显示「回复 @xx / 取消」 | `CommentInputBar.placeholder/replyToName/sending` 改 `@Prop` |
| P1-3 | 登录后已有评论项仍是未登录/token 为空 | `CommentItemView.token/loggedIn` 改 `@Prop` |
| P1-4 | 父页面刷新后评论区凭据不更新 | `CommentSection.videoCode/currentUserId/csrfToken` 改 `@Prop` |
| P1-5 | 收藏/稍后再看/历史计数不刷新 | 详情页与播放器写库后调用 `notifyLibraryChanged()` |
| P1-7 | 会话 cookie 被注入 GitHub/Apache 等第三方 WebPage | `WebPage.injectStoredCookies` 只在站点自身域执行 |
| P1-8 | `AppDb.ready` 永久 pending 导致播放器无限 loading | `waitStore` 加 8s 超时；`EntryAbility` 保证 `AppDb.init` 一定执行 |
| P1-9（部分） | 419/401 被当作普通网络错误 | `ResponseGuard` 将 401/419 归类为 `LoginExpiredError`（UI 统一自动登出仍未全页面接入） |
| P2-5 | 看完后下次打开停在最后一帧 | 写库时进度 ≥95% 归零 |
| P2-8 | 历史/收藏列表进度、时间不刷新；`RatingBar` 比例不刷新 | 列表 key 带 `positionMs/updatedAt/addedAt`；`RatingBar` 改 `@Prop` |
| P2-14 | 高级搜索先 pop 再切 Tab，时序不稳 | 先写 `requestTab` 信号再 `Router.pop()` |
| 其它 | — | `usingCache` 仅 GET；`HttpResponse.cookies` 缺省防御；清理未使用媒体资源 |

## 仍未修复 / 已知限制（需真机或后续迭代）

1. UI 侧「捕获 `LoginExpiredError` → 自动 logout + 跳登录」未统一接入（目前错误分类已正确，但需各页面自行处理）。
2. `PlayerPage`：`setMediaSource` 后状态误判（P2-4）、网页降级态下清晰度控件的双声风险（P2-6）、切后台/压栈继续播放（P2-7）——需要真机确认后再改。
3. 主题切换时未订阅 `themeMode` 的公共子组件是否重绘（P2-9）需真机验证。
4. `WebPage` 在 ArkWeb 内核初始化前注入 cookie 可能失败（P2-11）；大 HTML 在主线程解析（P2-12，实测首页 214KB 解析约 15–25ms，暂可接受）；设置页缓存统计同步遍历可能阻塞（P2-13）。
5. 解析失败时可能静默为空白页（P2-1）：网络层未强制校验关键字段并抛 `ParseError`。
6. 各模块均未在真机/模拟器运行验证（本环境无 HarmonyOS 设备）——见 CODE_REVIEW「需真机验证项」。
