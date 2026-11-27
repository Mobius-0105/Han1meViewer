# 构建说明

> **本版本要求 HarmonyOS 7.0（API 26）+ ArkTS**：为了使用系统「沉浸材质」（`uiMaterial.ImmersiveMaterial` +
> `.systemMaterial()`）实现真正的原生玻璃效果，工程编译目标已提升到 **API 26**。
> 需要兼容 HarmonyOS 6.x 的设备请使用 v1.1.0 的 HAP（手写毛玻璃版本，API 24 编译）。

本仓库提供两个 build product，编译同一份源码（都要求 API 26 SDK）：

| product | runtimeOS | 用途 |
| --- | --- | --- |
| `default` | HarmonyOS | 真机 / 上架，DevEco Studio 7.x（含 HarmonyOS SDK 26）常规构建 |
| `api26` | OpenHarmony | 无 HarmonyOS SDK 时的本地命令行验证构建（OpenHarmony 7.0 / API 26） |

---

## 1. DevEco Studio（推荐）

1. 安装 **DevEco Studio 7.x**（含 **HarmonyOS SDK 26.0.0 / API 26**，需登录华为账号下载）；
2. 打开本目录，等待 Sync；
3. Project Structure → Signing Configs → 勾选 *Automatically generate signature*；
4. 选择 `entry` 运行，或 Build → Build Hap(s)。

> SDK 版本以 `build-profile.json5` 中的 `"26.0.0(26)"` 为准；如果你的 DevEco 提供的是其它 26.x 版本字符串，
> 按本机 SDK 实际版本调整（`compatibleSdkVersion / compileSdkVersion / targetSdkVersion` 三个都要改）。

## 2. 命令行工具（本仓库实际验证过的路径）

本仓库验证环境（2026-11）：

| 组件 | 版本 |
| --- | --- |
| Command Line Tools | 6.1.1.268（`toolchain/clt`，Windows） |
| hvigor / ohpm | 6.24.1 / 6.1.2.268 |
| **SDK** | **OpenHarmony 7.0 / API 26**（`toolchain/sdk26/sdk`，由 GitHub `ErBWs/ohos-sdk` 的 HarmonyOS CLI 26.0.0.821 包中提取 `ets/api|kits|component` 等声明，与 Windows 构建工具混合而成） |
| Node / JDK | v26.13.1 / Temurin 17.0.21+9 |

> 这套 API 26 SDK 是「本地验证用」的拼装 SDK，只存在于开发机的 `toolchain/` 目录，不随仓库分发。
> 正式开发/上架请使用 DevEco Studio 自带的官方 HarmonyOS SDK 26。

```powershell
# 本机（仓库开发者）：
pwsh -File D:\path\to\workspace\toolchain\sdk26\build26.ps1 `
     -ProjectDir D:\path\to\Han1meViewer-HarmonyOS -Product api26
```

产物：

```text
entry\build\api26\outputs\default\entry-default-unsigned.hap
```

未配置签名时为 unsigned HAP（`No signingConfig found` 警告），仅用于验证编译/打包；
安装到真机需要签名（HoKit 自动签名，或 DevEco Studio 自动签名）。

> 如果拿到的是官方 Command Line Tools 26 Windows 包：解压后设 `DEVECO_SDK_HOME=<clt>\sdk`、
> `OHOS_BASE_SDK_HOME=<clt>\sdk\default\openharmony`，然后在项目目录执行
> `hvigorw --mode module -p product=api26 -p module=entry@default assembleHap --no-daemon` 即可。

### 2.1 安装包名与升级（必读）

- 本工程 `bundleName` 为 **`com.hanime1.harmony`**（`AppScope/app.json5`），与 Android 上游包名
  `com.yenaly.han1meviewer` 不同；
- 换包名后的 HAP 是**全新应用**：不会覆盖旧版（旧版 HAP 的 bundleName 仍是 `com.yenaly.han1meviewer`），
  升级前先卸载旧包 `hdc uninstall com.yenaly.han1meviewer`，再安装新 HAP；
- 旧包数据（登录 Cookie / 收藏 / 历史 / 设置）不会迁移，新版首次启动为全新状态；
- 查看 / 卸载新包：`hdc shell bm dump -n com.hanime1.harmony`、`hdc uninstall com.hanime1.harmony`；
  安装：`hdc install -r <hap 路径>`。

## 3. 纯逻辑测试（不需要 SDK）

```powershell
npm install
npm test                          # Node + tsx：解析层 / 网络纯逻辑 / 搜索选项 / 工具函数
npm run typecheck                 # tsc 类型检查 core/ 与 tests/
node scripts/arkts-lint.mjs       # ArkTS 受限语法 + import + 资源引用的静态检查
```

## 4. 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `Cannot find name 'uiMaterial'` / `systemMaterial` 不存在 | 用了 API 24 或更低版本 SDK；本工程需要 **API 26** SDK |
| `00303168 SDK component missing` | 选了 `runtimeOS: "HarmonyOS"` 但没有安装 HarmonyOS SDK；改用 `-p product=api26`（OpenHarmony SDK） |
| `spawn java ENOENT` | 打包 HAP 需要 JDK：设置 `JAVA_HOME` 并加入 `PATH` |
| `Unable to find the following components: toolchains:26 ...` | `OHOS_BASE_SDK_HOME` 必须指向 SDK 根（组件在 `<root>\26\...`），不能指到 `...\26` |
| `SyscapTransform` 失败 / 找不到 phone device-define | OpenHarmony 的 `device-define` 只有 `default.json`；本地验证时把 `default.json` 复制为 `phone.json`（`toolchain/sdk26/env26.ps1` 已自动做） |
| `The '@StorageProp' property ... cannot be assigned` | `@StorageProp` 只读，改用 `@StorageLink` 或 `@State` |
| `Type annotation in catch clause is not supported` | 写 `catch (rawError) { const e: Error = rawError as Error; }` |
| 安装报 `9568276 install already exist` | 同 bundleName 已存在：先卸载旧版（`hdc uninstall com.hanime1.harmony`）或用 HoKit 覆盖安装；从旧包名 `com.yenaly.han1meviewer` 升级时需先手动卸载旧包（换包名后是全新应用，不会覆盖，数据不迁移） |
| 设备 API < 26 安装/运行异常 | 本版本要求 HarmonyOS 7.0+；更老的设备请安装 v1.1.0（API 24 编出的包） |

## 5. 已验证的状态（v1.11.0）

在 2026-11-21 的实际构建中（CLT 6.1.1.268 + **API 26 SDK** + hvigor 6.24.1 + JDK 17.0.21）：

| 项目 | 结果 |
| --- | --- |
| `hvigorw --mode module -p product=api26 -p module=entry@default assembleHap` | **BUILD SUCCESSFUL** |
| ArkTS 编译（`CompileArkTS`） | 通过，0 error（`uiMaterial` + `Tabs.barFloatingStyle.systemMaterial` 编译通过） |
| HAP 打包（`PackageHap`） | 通过，约 3.29 MB（HAP 内含 `ohos.arkui.UIMaterial.state=enable` metadata） |
| 纯 TypeScript 单测（`npx tsx --test tests`） | 91 个用例全部通过 |
| 类型检查 / ArkTS 静态检查 | 通过 / 无问题 |
| 真机运行 | **未验证**（本环境没有 HarmonyOS 设备），运行时表现（尤其真材质光感）以真机为准 |

编译警告：`promptAction.showToast`、`AlertDialog.show`、`getContext` 等为了兼容旧 API 保留的写法在 API 26
上会给出 deprecation 警告，不影响构建；如需消除可替换为 `UIContext` 对应新接口。

## 6. 第三方依赖与播放内核

**本工程没有第三方播放内核，也没有任何 native 库。** 播放只用系统 `AVPlayer`
（`@kit.MediaKit`）+ `XComponent`，失败降级为系统 `Web` 组件；`entry/oh-package.json5`
的 `dependencies` 为空对象，HAP 里不含 `.so`、不含额外体积。

历史说明：曾以本地 HAR 形式集成 `@mpv-ohos/mpv-arkts`（libmpv + FFmpeg，`entry/libs/mpv-arkts-1.0.0.har`），
并配套 `logic/player/MpvKernel.ets` 与设置页的「播放内核」切换项。libmpv 在真机上无法起播
（黑屏 / 无 error 事件），为避免「可切换内核」的误导，该内核、HAR、`buildOption.nativeLib`
ABI 过滤与相关设置项已全部移除。HarmonyOS 也没有 ExoPlayer / Media3，因此不需要再考虑
「换一个更兼容的内核」这条路。

### 6.1 安装依赖

DevEco Studio 打开工程时会自动 Sync；命令行构建前建议手动执行一次：

```powershell
. D:\path\to\workspace\toolchain\env.ps1
cd D:\path\to\Han1meViewer-HarmonyOS
ohpm install --all
```

`entry/oh-package-lock.json5` 由 `ohpm` 自动生成 / 更新，随仓库提交。
