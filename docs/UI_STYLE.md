# UI 设计系统：灰底 + 卡片 + 玻璃栏（PuraPily 默认观感）

> 视觉基线参考 [PuraPily](https://github.com/aryue/PuraPily)（HarmonyOS ArkTS 客户端，GPL-3.0）的
> 观感与设计规格（灰底、卡片、悬浮底栏、系统材质、设置分组）。**本项目未复制其代码**：仅采用公开可见的设计参数，
> 代码为本项目独立实现；GPL-3.0 代码与 Apache-2.0 不兼容，因此不存在源码复制。

## 1. 总体分层

```text
Index（根）
├── 灰底：#F1F2F4（浅色）/ #101114（深色）——不再使用渐变/壁纸
├── Navigation（透明）
│   ├── Tabs
│   │   ├── HomePage：搜索胶囊头部 + 频道胶囊 + 轮播(338/圆角30) + 2 列视频网格
│   │   ├── SearchPage：胶囊搜索框 + 历史/筛选 chips + 2 列结果网格
│   │   └── LibraryPage：账号大卡 + 分组卡片
│   └── NavDestination 二级页（视频详情/设置/收藏/登录/Web，透明背景）
├── 顶部栏：内容延伸到状态栏，状态栏区域也铺玻璃模糊（barTint + BAR_BLUR）
│   状态栏高度由 EntryAbility 写入 AppStorage['statusBarHeight']，页面头部用 padding 下沉内容
└── 悬浮底栏（56 高、圆角 28、约 264 宽，距导航条 12）
    ├── API 26 + 材质可用：Tabs barModifier + uiMaterial 真沉浸材质
    └── 否则：手写毛玻璃
```

## 2. 颜色令牌（`common/Theme.ets`）

| 令牌 | 用途 | 浅色 | 深色 |
| --- | --- | --- | --- |
| `primary` | 主色/选中/链接（可由设置页主题色覆盖） | `#007DFF` | `#007DFF`（同色，深底自动派生容器） |
| `primaryContainer` | 图标块/浅底 | `#E6F0FF` | 由主色压暗派生 |
| `secondary` | 强调（点赞/收藏） | `#FB7299` | `#FB7299` |
| `background` | 页面灰底 | `#F1F2F4` | `#101114` |
| `surface` / `surfaceVariant` | 卡片/次级底 | `#FFFFFF` / `#E8EAEE` | `#17181A` / `#1F2126` |
| `cardBg` | 卡片底（纯色） | `#FFFFFF` | `#17181A` |
| `textPrimary` | 主文字 | `#18191C` | `#F2F4F8` |
| `textSecondary` | 次级文字 | `#50545A` | `#C9CDD3` |
| `textHint` | 三级/提示 | `#606773` | `#A2A7AE` |
| `divider` | 发丝线 | `#1A000000` | `#1AFFFFFF` |
| `glassBorder` | 卡片描边 | `#14000000` | `#1FFFFFFF` |
| `barTint` | 顶栏/底栏玻璃底 | `#F2FFFFFF` | `#F217181A` |
| `chipTint` | 胶囊/标签底 | `#F2FFFFFF` | `#26282D` |

主题色：设置 → 通用 → 主题色，5 个预设（蓝 `#007DFF` 默认、粉 `#FB7299`、绿 `#00B578`、紫 `#8A2BFF`、橙 `#FF8F1F`），
写入 `AppStorage['themeColor']`，`Theme.accent()` 读取后覆盖 `primary/primaryContainer`。

## 3. 尺寸与圆角（`Dimens`）

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `pagePadding` | 12 | 页面左右边距 |
| `gap` | 12 | 网格间距 |
| `cardRadius` | 8 | 视频卡片（16:9 封面） |
| `listRadius` | 12 | 设置/列表分组、评论卡 |
| `panelRadius` | 30 | 轮播、账号大卡、信息大卡、弹层 |
| `smallRadius` | 6 | 封面小圆角/图标块 |
| `bottomInset` | 96 | Tab 页内容底部预留（悬浮底栏 + 导航条） |
| 文字 | 17 / 15 / 14 / 12 | 页面标题 / 区块标题 / 正文 / 辅助 |

## 4. 组件规范（`components/common/Widgets.ets`）

- **VideoCard**：16:9 封面（圆角 8）+ 底部渐变 + 左下播放量 + 右下时长；标题固定两行（36 高，13 号）+
  元信息固定 18 高（11 号）→ **两列网格中卡片严格等高**；卡片纯色 `cardBg` + 1vp `glassBorder` 阴影。
- **VideoListTile**：116×66 封面 + 标题 14 + 副标题 11，卡片圆角 12。
- **AppTopBar**：状态栏玻璃（外层 padding top = statusBarHeight，背景覆盖状态栏）；标题行 52 高。
- **SectionHeader**：15 粗体 + 右侧“更多”小胶囊。
- **TagChip**：高约 28 胶囊，选中 primary 填充。
- **Loading/Error/Empty**：居中纯色卡片，圆角 30。
- **NavRow / SwitchRow / SegmentRow**：行高 52，图标块 30×30 圆角 10。

## 5. 系统沉浸材质（API 26）

真材质只在系统作用域内渲染（底部 TabBar / Navigation 标题栏 / 弹窗）。本工程用于**悬浮底栏**：

1. 应用级开关：`module.json5` metadata `{"name":"ohos.arkui.UIMaterial.state","value":"enable"}`；
2. 挂载：`Tabs({ barModifier: CommonModifier.systemMaterial(uiMaterial.ImmersiveMaterial) })` +
   `barFloatingStyle({...})`，不设置 `barBackgroundColor`；
3. 回退：`Material.usable()` 检查 API 26 / 应用状态 / 用户开关（设置 → 外观 → 沉浸材质底栏）。

## 6. 注意事项

1. 页面根容器透明，底色由 Index 灰底提供；卡片纯色不透明，保证文字可读。
2. 顶部栏必须覆盖状态栏（padding + blur），否则状态栏区域会露出灰底、割裂。
3. 底部栏/内容要避让导航条：`AppStorage['navBarHeight']`。
4. 播放器页全屏（横屏）时隐藏状态栏并恢复竖屏；播放区黑底不受主题影响。
