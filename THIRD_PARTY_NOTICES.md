# 第三方开源软件声明（Third-Party Notices）

本仓库自身的代码以 Apache License 2.0 授权（见 `LICENSE`）。本文件列出随仓库分发、
或以二进制/源码依赖形式被本工程使用的第三方开源软件及其许可证。

---

## 说明

本工程**不包含任何第三方播放内核或原生库**：播放只用 HarmonyOS 系统 `AVPlayer`
（`@kit.MediaKit`）与系统 `Web` 组件，全部来自系统 Kit，没有 vendored 的 `.har` / `.so`。
历史上曾以本地 HAR 形式集成 `@mpv-ohos/mpv-arkts`（libmpv + FFmpeg），因 libmpv 在真机上
无法起播，已整体移除（含 HAR 文件、依赖声明与 `logic/player/MpvKernel.ets`）。
