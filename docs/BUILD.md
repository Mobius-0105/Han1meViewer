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

## 6. MPV 播放内核（可选）

`@mpv-ohos/mpv-arkts`（libmpv + FFmpeg 的 ArkTS 封装）作为**可选**播放内核集成，HAR 已随仓库
放在 `entry/libs/`，无需联网下载；默认内核仍是系统 AVPlayer（设置页里叫 `ExoPlayer`）。

| 项 | 值 |
| --- | --- |
| HAR 文件 | `entry/libs/mpv-arkts-1.0.0.har`（约 16MB，含 arm64-v8a 的 `libmpv.so` 等） |
| 依赖声明 | `entry/oh-package.json5` → `"@mpv-ohos/mpv-arkts": "file:./libs/mpv-arkts-1.0.0.har"` |
| 许可证 | 封装层 **MIT**；内含 libmpv（LGPLv2.1+）/ FFmpeg（LGPLv3）动态库，说明见根目录 `THIRD_PARTY_NOTICES.md` |
| 上游源码 | <https://github.com/mpv-ohos/mpv-arkts> |
| ABI | 仅 **arm64-v8a**（x86_64 模拟器上无法播放 MPV） |

### 6.1 安装依赖

DevEco Studio 打开工程时会自动 Sync；命令行构建前需手动安装一次：

```powershell
. D:\path\to\workspace\toolchain\env.ps1
cd D:\path\to\Han1meViewer-HarmonyOS
ohpm install --all
```

成功后出现 `entry/oh_modules/@mpv-ohos/mpv-arkts/`（指向 `oh_modules/.ohpm/` 下解包目录的链接），
并生成 `entry/oh-package-lock.json5`。

> 仓库的 `.gitignore` 默认忽略 `*.har`；提交仓库时需确保 `entry/libs/mpv-arkts-1.0.0.har`
> 被跟踪（已有 `!entry/libs/*.har` 例外），否则新克隆的环境执行 `ohpm install` 会因找不到本地 HAR 而失败。

### 6.2 native 库如何打进 HAP

- hvigor 的 `ProcessLibs` 任务会自动收集依赖 HAR 的 `libs/<abi>/*.so`，经
  `intermediates/libs` → `stripped_native_libs` → 打包工具的 `--lib-path` 写入 HAP 的
  `libs/<abi>/*.so`；模块不需要额外声明 native 依赖（本地无 CMake/NAPI 源码）；
- 设备是 arm64，MPV HAR 也只提供 arm64-v8a；HAP 默认 `compressNativeLibs=false`
  （`.so` 不压缩），`libmpv.so` 会让 HAP 明显增大。`entry/build-profile.json5` 里保留：

  ```json5
  "buildOption": {
    "nativeLib": {
      "filter": {
        "excludes": ["**/x86_64/**"]
      }
    }
  }
  ```

  确保只打包 **arm64-v8a**。若换用带多 ABI 的 HAR，同样靠这段 `excludes` 控制体积；
- 体积影响：HAP 里的 `libmpv.so` 约 35MB（HAR 内未 strip，HAP 的 `.so` 不压缩），
  HAP 从约 3.7MB 增至约 41MB（实测 41,545,232 字节）；
- MPV 内核不可用时上层会自动回退到 `ExoPlayer`（系统 AVPlayer），因此不装 MPV 也能正常播放。

### 6.3 兼容性与已知风险

- HAR 的 `compatibleSdkVersion` 为 20（`compatibleSdkType: HarmonyOS`），本工程目标 API 26 满足要求；
  `api26`（OpenHarmony）product 下同样可引用；
- 该 HAR 是 **byteCode HAR**（`metadata.byteCodeHar: true`），参与类型检查的只是它的 `.d.ets` 声明；
  构建时会出现少量 `arkts-strict-typing-required` 等来自依赖包声明的 WARN，不影响打包；
- MPV 为可选内核：初始化 / 加载 / 播放失败时，`InlinePlayer` 会置回 `exo` 重试系统 AVPlayer；
- 若后续升级 HAR 版本，需同步更新 `entry/libs/` 文件名、`entry/oh-package.json5` 的 `file:` 路径，
  并重新 `ohpm install`。
