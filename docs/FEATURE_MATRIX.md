# 功能矩阵：Android 上游 vs HarmonyOS 移植版

图例：✅ 已实现（有对应 ArkTS 代码）　🟡 部分实现 / 行为不同　❌ 未移植

> 统计时间：移植版 v1.0.0。上游仓库：<https://github.com/misaka10032w/Han1meViewer>。
>
> 构建状态：ArkTS 全量编译 0 error、unsigned HAP 打包成功（OpenHarmony API 24 / hvigor 6.24.1）；
> 解析层与纯逻辑 91 个单测全部通过。未在真机运行验证，运行期风险见 `docs/CODE_REVIEW.md`。
>
> **包名**：本移植版 `bundleName` 为 `com.hanime1.harmony`（`AppScope/app.json5`），与上游 Android 的
> `com.yenaly.han1meviewer` 不同；两者是独立应用，旧包需手动卸载（`hdc uninstall com.yenaly.han1meviewer`），
> 数据不迁移。

## 浏览与发现

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 首页推荐 / 最新上市 / 最新上传 | ✅ | `parseHomePage` 分区索引 + 标题兜底 |
| 首页分类行（里番/泡面番/Motion/3DCG/2.5D/2D/AI/MMD/Cosplay） | ✅ | 空分区自动跳过 |
| 首页 banner | ✅ | 点击打开视频 |
| "他们在看" / "新番预告" | ✅ | 新番预告仅列表，不含 Getchu 预览详情 |
| 预览页（Getchu 联动） | ❌ | 依赖 getchu.com 的另一套解析，未移植 |
| 公告（Firebase RTDB） | ❌ | 需要 Firebase 与后端约定，未移植 |

## 搜索

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 关键词搜索 | ✅ | |
| 高级搜索（类型/排序/时长/发布日期/品牌/标签） | ✅ | 数据来自复制的 `search_options` 资产；年份/月份细分筛选未做 |
| 搜索结果分页 | ✅ | `maxPage` / `onReachEnd` |
| 搜索历史 | ✅ | relationalStore 持久化，去重、限长 |
| 搜索筛选条件展示 | 🟡 | 筛选页内展示，结果页不重复显示 chips |

## 视频与播放

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 视频详情（简介/作者/标签/系列/相关） | ✅ | |
| 在线播放 | ✅ | ExoPlayer（系统 AVPlayer，默认）或 MPV（libmpv，FFmpeg）播放 HLS/MP4 |
| 清晰度切换 | ✅ | 依据 `<source size>` |
| 倍速播放 | ✅ | PlaybackSpeed 枚举档位 |
| 画中画 | ❌ | 鸿蒙 PiP 能力未接入 |
| 全屏 | 🟡 | 播放器页内布局全屏（不改窗口方向） |
| 播放内核切换（Media3/MPV） | ✅ | 设置页「播放」分组可在 ExoPlayer（系统 AVPlayer）+ MPV（`@mpv-ohos/mpv-arkts` 1.0.0）间切换；MPV 播放失败自动回退 ExoPlayer。HarmonyOS 无 ExoPlayer/Media3，本项目 `exo` 内核 = 系统 AVPlayer 实现，仅保留上游的接口语义 |
| 本地下载文件播放 | ❌ | 无下载功能 |
| 播放进度记忆 | ✅ | 本地历史记录 positionMs |

## 评论

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 评论列表（首屏 + 分批加载） | ✅ | 2025-11 改版的 offset 分批 |
| 子回复展开 | ✅ | `/loadReplies` |
| 发表评论 / 回复 | ✅ | |
| 评论点赞/点踩 | ✅ | |
| 评论排序 | 🟡 | 站点默认排序，未实现切换 |
| 子评论点赞 | ❌ | 父评论点赞已实现 |
| 举报评论 | ❌ | UI 明确提示"暂未实现"，不静默 |
| 复制分享文本 | ❌ | |

## 用户内容

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 本地收藏 | ✅ | relationalStore |
| 稍后再看 | ✅ | 本地 |
| 在线收藏 / 稍后再看（站点 likes / saves 列表） | ❌ | 写操作（收藏、稍后再看）已接；站点收藏列表未做 UI，本地库覆盖 |
| 在线观看历史 | ✅ | `user/{id}/histories`，FavoritesPage 内按 latest/popular/oldest 排序 + 分页 |
| 自定义播放清单（列表 / 详情） | ✅ | 我的清单列表 + 详情 |
| 订阅作者 / 作者主页 | 🟡 | 详情页作者信息 + 新增「我的订阅」列表（订阅作者与更新视频，点击作者跳搜索）；独立作者主页未做 |
| 创作中心（上传/上传中） | ❌ | |
| 在线删除历史 / 清单条目 | ❌ | 本地可删，在线删除未接 UI |

## 账号

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 网页登录 + Cookie 同步 | ✅ | Web 组件登录后 `WebCookieManager` 同步；登录态三级校验（/login 404 → 首页用户信息 → /subscriptions），失败时按 Cookie 信任兜底 |
| 账号密码登录 | ✅ | GET /login 取 CSRF token → POST /login → 校验 + 汇总 Set-Cookie（对齐原版） |
| 手动录入 Cookie | ✅ | 登录页内（网页 / 账号密码 / 手动 Cookie 三种方式切换） |
| 账号资料展示 / 退出登录 | ✅ | |
| 修改昵称 / 密码 / 头像裁剪 | ❌ | 接口未接 UI |
| 登录状态检测 | ✅ | 三级校验 + `LoginExpiredError` → `SessionActions.onSessionExpired()` |

## 设置与网络

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 主题（浅色/深色/跟随系统） | ✅ | 自研 `Theme`，未做动态取色 |
| 首页布局 / 卡片列数设置 | ❌ | |
| 备用域名切换 | ✅ | 4 个域名 |
| 自定义 UA | ✅ | |
| 备用媒体 CDN | ✅ | `vdownload.hembed.com` ↔ `cdn77` |
| Cloudflare 处理 | ✅ | 识别 + 网页验证 + Cookie 同步 |
| 代理设置 | ❌ | |
| 网络检测 / CDN 检测 | ❌ | |
| 更新检查（GitHub Releases） | ❌ | 设置页提供项目链接 |
| 清空缓存 / 数据 | ✅ | 清空本地历史、搜索历史，并统计/清理 cacheDir；WebView 自身缓存未单独清理 |

## 隐私与其它

| 上游功能 | 状态 | 说明 |
| --- | --- | --- |
| 首次启动 18+ 确认 | ✅ | 鸿蒙侧新增 |
| 应用锁（生物识别） | ❌ | 未接入 `@kit.UserAuthenticationKit` |
| 启动器图标伪装 | ❌ | |
| 后台下载 + 下载分组 | ❌ | 工作量最大的一块，未移植 |
| 桌面小组件 / 健康打卡 | ❌ | |
| 共享关键 H 帧 | ❌ | |
| Firebase Analytics / Crashlytics | ❌ | 移植版不收集任何数据 |

## 有意为之的差异

1. **除可选的 MPV 播放内核（`@mpv-ohos/mpv-arkts`，封装层 MIT，内含 libmpv/FFmpeg LGPL 动态库，HAR 本地依赖）外不引入任何第三方库**
   （含 Firebase / Room / Retrofit），其余全部使用系统 Kit；不启用 MPV 时仅系统 AVPlayer；
2. **不收集任何用户数据**，无埋点、无崩溃上报；
3. 播放器默认 ExoPlayer（HarmonyOS 上即系统 AVPlayer）；设置里可切换 MPV（libmpv，FFmpeg），
   MPV 初始化或播放失败自动回退 ExoPlayer，仍失败再降级为网页播放，保证"能看"优先；
4. 评论区、收藏等写操作在未登录时统一引导到登录页，不静默失败。
