# Han1meViewer · HarmonyOS NEXT 移植版

> 🔞 **R18 警告：未满 18 岁禁止下载和使用。**

这是 [misaka10032w/Han1meViewer](https://github.com/misaka10032w/Han1meViewer)（Android / Kotlin + Jetpack Compose）的
**HarmonyOS NEXT（ArkTS / ArkUI）移植版**，以 [Apache License 2.0](./LICENSE) 发布。

本项目与 `hanime1.me` 及其关联方没有任何隶属、合作或授权关系；仅通过常规网络请求获取站点公开页面并做本地解析展示，
不存储、不修改、不主张任何版权内容的所有权。详见 [免责声明](#免责声明)。

> **v1.2.0 起要求 HarmonyOS 7.0（API 26），v1.19.0 播放页 tab 切换不闪、相关推荐预加载+入场动画+3:4 竖版卡、返回长按回首页、最近观看底部边距优化**：为了使用系统「沉浸材质」（`uiMaterial` + `systemMaterial`）
> 实现真正的原生玻璃底栏，编译目标提升到 API 26。需要兼容 HarmonyOS 5.x/6.x 的设备请使用 `dist/` 下
> v1.1.0 的 HAP（手写毛玻璃版本，API 24 编译）。

---

## ✨ 功能概览

| 模块 | HarmonyOS 实现 |
| --- | --- |
| 首页 | banner、最新上市 / 最新上传 / 里番 / 泡面番 / Motion / 3DCG / 2.5D / 2D / AI / MMD / Cosplay / 他们在看 / 新番预告 分区横向卡片 |
| 搜索 | 关键词搜索、结果网格、分页、搜索历史、高级搜索（类型 / 排序 / 时长 / 日期 / 品牌 / 7 组标签多选）；从首页搜索胶囊进入（独立页） |
| **视频（v1.4.0）** | **播放器 +「简介 / 评论」双标签**：简介 tab = 可展开简介/标签/系列/单列推荐卡片；评论 tab = 评论列表 + 悬浮输入条（沉浸材质，分页/回复/点赞/发评论） |
| 播放 | 系统 `AVPlayer`（单一内核，无内核切换）；HLS/MP4、清晰度、倍速、续播、进度记忆、**视频比例自适应、页内横屏全屏、控制层 3 秒自动隐藏**，失败自动降级网页播放；带「复制播放地址 / 浏览器打开」排查入口 |
| 评论 | 首屏 + offset 分页、展开子回复、发评论/回复、点赞 |
| 我的订阅 | 登录后查看订阅的作者与更新视频（`GET /subscriptions`），分页加载、点击作者跳搜索、点击视频进详情 |
| 账号 | **网页登录 / 账号密码 / 手动 Cookie 三种方式**；登录态三级校验（`/login` 404 → 首页用户信息 → `/subscriptions`，网页登录失败按 Cookie 信任）；账号资料、在线清单/历史、登录过期自动清理、登出 |
| 设置 | 通用（深色模式、**主题色 5 选一**）、外观（沉浸材质底栏）、站点域名/UA/备用 CDN、默认清晰度/倍速、隐私、清缓存、关于（PuraPily 分组卡片样式） |
| 网络 | Cookie 持久化、Cloudflare 挑战识别 + 网页验证 + 自动重试、IP 拦截/登录过期等错误分类、换域名重试 |
| 安全 | 首次启动 18+ 年龄确认 |

未移植功能见 [`docs/FEATURE_MATRIX.md`](docs/FEATURE_MATRIX.md)。

## 🎨 界面

沉浸式玻璃设计：渐变壁纸 + 彩色光斑背景，半透明毛玻璃卡片，胶囊控件，**悬浮底栏使用 HarmonyOS 7.0 系统沉浸材质**
（`Tabs.barFloatingStyle({ systemMaterial: uiMaterial.ImmersiveMaterial })`，真材质，带系统光感交互）；
不支持材质的设备自动退回 `backgroundBlurStyle` 手写玻璃。

- 设计系统与令牌：[`docs/UI_STYLE.md`](docs/UI_STYLE.md)
- 视觉方向参考 [PuraPily](https://github.com/aryue/PuraPily)（GPL-3.0，仅参考设计思路，代码独立实现、未复制）

## 🧱 技术栈

| 类别 | 选型 |
| --- | --- |
| 语言 / UI | ArkTS · ArkUI（Stage 模型，**API 26 / HarmonyOS 7.0**） |
| 导航 | `Navigation` + `NavPathStack`（单 Ability 单页面） |
| 网络 | `@kit.NetworkKit` 的 `http` + 自研 Cookie 管理 |
| HTML 解析 | 自研迷你 DOM + CSS 选择器（`core/parser/HtmlDom.ts`），对齐上游 Jsoup 用法 |
| 存储 | `relationalStore`（收藏/历史/搜索历史）+ `preferences`（设置） |
| 播放 | `@kit.MediaKit` 的 `AVPlayer` + `XComponent`（单一内核，无三方播放库），降级 `Web` |
| 网页能力 | `@kit.ArkWeb`（登录、Cloudflare 验证、网页播放） |
| 玻璃材质 | API 26 `uiMaterial` + `systemMaterial`；降级 `backgroundBlurStyle` |
| 测试 | Node + `tsx` 纯 TS 单测；`scripts/arkts-lint.mjs` 静态检查 |

## 📁 目录结构

```text
Han1meViewer-HarmonyOS/
├── AppScope/                         应用级配置（bundleName、图标、版本）
├── entry/src/main/
│   ├── ets/
│   │   ├── entryability/             UIAbility 入口（初始化设置/数据库/网络/主题）
│   │   ├── core/                     纯 TypeScript（可 Node 测试）：model / parser / util
│   │   ├── logic/                    平台层：net / db / settings / state
│   │   ├── pages/                    Index + home / search / video / player / library / settings / login / web
│   │   ├── components/common/        通用玻璃组件（卡片、顶栏、状态视图、标签…）
│   │   └── common/                   主题、玻璃配方、材质封装、路由、Toast
│   ├── resources/                    字符串、SVG 图标、rawfile（搜索选项 JSON）
│   └── module.json5
├── docs/                             架构 / 构建 / UI 设计 / 功能矩阵 / 解析说明 / 代码审查
├── fixtures/                         解析层单测的真实/合成 HTML 快照
├── dist/                             构建好的 unsigned HAP（v1.0.1 / v1.1.0 / v1.2.1 / v1.3.0 / v1.4.0）
├── scripts/                          arkts-lint.mjs 等
├── tests/                            Node 单测
├── build-profile.json5               product：default（HarmonyOS 26）/ api26（OpenHarmony 26）
└── oh-package.json5
```

## 🚀 构建

> ✅ 已用真实工具链验证：ArkTS 编译 0 error，`entry-default-unsigned.hap` 打包成功。
> 完整步骤/版本组合/踩坑见 [`docs/BUILD.md`](docs/BUILD.md)。

### DevEco Studio（推荐）

1. 安装 **DevEco Studio 7.x**（含 HarmonyOS SDK **26.0.0 / API 26**，需登录华为账号）；
2. 打开本目录 → Sync → 配置自动签名 → Run / Build Hap(s)。

### 命令行（本仓库验证路径）

```powershell
pwsh -File D:\path\to\workspace\toolchain\sdk26\build26.ps1 `
     -ProjectDir D:\path\to\Han1meViewer-HarmonyOS -Product api26
# 产物：entry\build\api26\outputs\default\entry-default-unsigned.hap
```

> API 26 SDK 来源：官方 [OpenHarmony 7.0 Release SDK（Windows）](https://repo.huaweicloud.com/harmonyos/os/7.0-Release/)
> （`@ohos.arkui.uiMaterial` 在 OpenHarmony 7.0 中公开）；本机已验证 `uiMaterial` + `systemMaterial` 编译打包通过。
> SDK 体积大，不随仓库分发，细节见 `toolchain/sdk26/REPORT.md`。

### 安装包名与升级

- 本工程 `bundleName` 为 **`com.hanime1.harmony`**（`AppScope/app.json5`），与 Android 上游包名
  `com.yenaly.han1meviewer` 不同；
- 换包名后是**全新应用**：新 HAP 不会覆盖旧版（旧版 HAP 的包名仍是 `com.yenaly.han1meviewer`），
  升级前请先卸载旧版 `hdc uninstall com.yenaly.han1meviewer`，再安装新 HAP；
- 旧版数据（登录 Cookie / 收藏 / 历史 / 设置）不会自动迁移到新包，新版首次启动为全新状态；
- 安装 / 卸载：`hdc install -r <hap 路径>`、`hdc uninstall com.hanime1.harmony`。

### 纯逻辑测试（不需要 SDK）

```powershell
npm install
npm test            # 91 个用例：解析层 / 网络纯逻辑 / Cookie / 搜索项 / URL 格式
npm run typecheck
node scripts/arkts-lint.mjs
```

## ✅ 验证情况

| 项目 | 结果 |
| --- | --- |
| ArkTS 全量编译（API 26 / hvigor 6.24.1） | **0 error**（`uiMaterial` / `systemMaterial` 编译通过） |
| HAP 打包 | 成功，`dist/Han1meViewer-HarmonyOS-1.13.0-api26-unsigned.hap`（约 3.41 MB） |
| 纯逻辑单测 | 91 用例全部通过 |
| 类型检查 / ArkTS 静态检查 | 通过 / 无问题 |
| 真机 | **未验证**（本环境无 HarmonyOS 设备）；运行期风险见 [`docs/CODE_REVIEW.md`](docs/CODE_REVIEW.md) |

## 📚 文档

| 文档 | 内容 |
| --- | --- |
| [`docs/BUILD.md`](docs/BUILD.md) | 构建环境、DevEco/命令行步骤、已验证版本、常见报错 |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | 分层架构、数据流、解析层与存储设计、错误处理、已知风险 |
| [`docs/UI_STYLE.md`](docs/UI_STYLE.md) | 沉浸玻璃设计系统：颜色令牌、玻璃配方、系统沉浸材质用法 |
| [`docs/FEATURE_MATRIX.md`](docs/FEATURE_MATRIX.md) | 与 Android 上游的功能对照 |
| [`docs/parser-notes.md`](docs/parser-notes.md) | 解析层各函数的 fixture 来源与验证矩阵 |
| [`docs/ARKTS_GUIDE.md`](docs/ARKTS_GUIDE.md) | ArkTS 编码规范（受限语法、模块契约） |
| [`docs/UI_CONTRACT.md`](docs/UI_CONTRACT.md) | UI 层接口契约、路由与页面签名、公共组件 |
| [`docs/CODE_REVIEW.md`](docs/CODE_REVIEW.md) | 代码审查报告 |
| [`docs/CODE_REVIEW_FIXES.md`](docs/CODE_REVIEW_FIXES.md) | 审查问题修复明细 |

## 🔧 与上游实现的对应关系

- `logic/Parser.kt`（Jsoup 解析）→ `core/parser/HtmlDom.ts` + `HanimeParser.ts` + `CommentParser.ts`
- `logic/NetworkRepo.kt` + `logic/network/service/*.kt` → `logic/net/HanimeApi.ets` + `HttpClient.ets`
- `logic/network/HCookieJar.kt` + `Preferences.kt`（cookie）→ `logic/net/CookieStore.ets`
- `logic/dao/*.kt`（Room）→ `logic/db/AppDb.ets`（relationalStore）
- `ui/screen/**`（Compose）→ `pages/**`（ArkUI，视频详情与播放合并为单页）
- 播放内核（Media3 / MPV）→ 系统 `AVPlayer`（单一内核，HLS/MP4）+ 内嵌播放器 + 全屏播放页 + Web 降级
  （HarmonyOS 无 ExoPlayer/Media3；libmpv 真机无法起播，已移除，不再提供内核切换）

## 📄 许可证与修改说明

- 本项目继承上游 [Apache License 2.0](./LICENSE)；
- 上游版权归 [YenalyLiew/Han1meViewer](https://github.com/YenalyLiew/Han1meViewer) 与
  [misaka10032w/Han1meViewer](https://github.com/misaka10032w/Han1meViewer) 作者所有；
- 本移植版为**重写实现**（Kotlin/Compose → ArkTS/ArkUI），修改内容见 [`NOTICE`](./NOTICE)；
- UI 视觉参考 PuraPily（GPL-3.0）设计思路，代码独立实现，未复制。

## 免责声明

- 本应用与 `hanime1.me` 无任何隶属、合作或授权关系；
- 仅通过常规网络请求和页面解析获取站点公开信息，不访问其后端数据库，不绕过授权；
- 仅用于技术研究、学习交流与移动端体验优化，不提供商业化服务；
- 原始内容版权归原网站 / 原始制作发行方所有，本应用不存储、不修改、不主张版权；
- 使用本应用产生的一切后果由使用者自行承担，请遵守所在地区法律法规与目标站点规则。

> ℹ️ 建议通过官方渠道支持原站内容。
