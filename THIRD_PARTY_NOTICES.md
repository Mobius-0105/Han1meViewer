# 第三方开源软件声明（Third-Party Notices）

本仓库自身的代码以 Apache License 2.0 授权（见 `LICENSE`）。本文件列出随仓库分发、
或以二进制/源码依赖形式被本工程使用的第三方开源软件及其许可证。

---

## @mpv-ohos/mpv-arkts 1.0.0（MPV 播放内核 HAR）

| 项目 | 内容 |
| --- | --- |
| 组件 | `@mpv-ohos/mpv-arkts` 1.0.0 |
| 来源 | mpv-ohos 工程（HAR 包），源码：<https://github.com/mpv-ohos/mpv-arkts> |
| 许可证 | **MIT**（ArkTS 封装层） |
| 分发形式 | 仓库内 vendored 的预编译 HAR：`entry/libs/mpv-arkts-1.0.0.har`（约 16MB，未做任何修改） |
| 使用方式 | 应用通过 `@mpv-ohos/mpv-arkts` 的 ArkTS API（封装于 `logic/player/MpvKernel.ets`）调用，运行时加载 HAR 中预编译的 `libmpv.so`、`libmpv_wrapper.so`、`libaki_jsbind.so`（arm64-v8a）；本仓库未修改这些库的源码，也未在应用内静态链接 LGPL 组件 |
| 许可证文件 | HAR 内自带 `LICENSE`（MIT），安装后位于 `entry/oh_modules/@mpv-ohos/mpv-arkts/`，随 HAP 一并保留、不得删除 |

### HAR 内随附的第三方组件（LGPL）

`libmpv.so` 内部以动态库形式打包了 libmpv 及其依赖的 FFmpeg 等组件，依据 libmpv / FFmpeg 上游声明：

| 组件 | 许可证 | 说明 |
| --- | --- | --- |
| libmpv | LGPLv2.1 or later | 播放器核心库 `libmpv.so`，以动态链接方式使用 |
| FFmpeg（libavcodec / libavformat / libavutil / libswscale / libswresample 等） | LGPLv3 | 由 libmpv 动态链接使用，未启用 GPL-only 组件 |
| libmpv_wrapper.so / libaki_jsbind.so | MIT（随 `@mpv-ohos/mpv-arkts`） | ArkTS ↔ libmpv 的 NAPI 封装层 |

### LGPL 合规说明

- **libmpv 以 LGPLv2.1+ 动态链接使用**：`libmpv.so` 作为独立动态库随 HAP 分发，应用代码只通过公开的
  ArkTS API 调用，不构成对 LGPL 组件的静态链接或衍生作品；
- **FFmpeg 为 LGPLv3**，同样以动态库形式由 libmpv 在运行时加载；
- 由于是动态链接，**用户可用同 ABI（arm64-v8a）的 `.so` 替换** HAP 内的对应库以使用修改后的版本
  （需重新签名安装）；
- 组件源码可从上方上游链接获取；若后续修改了 HAR 内 LGPL 组件的源码，必须按 LGPL 公开修改后的源码。

---

## 动态库体积提示

`@mpv-ohos/mpv-arkts` HAR 内含 arm64-v8a 一套预编译库（HAR 约 16MB，`libmpv.so` 占大头）。
本工程在 `entry/build-profile.json5` 中通过 `buildOption.nativeLib.filter.excludes`
排除 x86_64，只把 **arm64-v8a** 打进 HAP（MPV 内核本身也仅支持 arm64）。
