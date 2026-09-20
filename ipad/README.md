# KoKo iPad & iPhone Duo

`ipad/` 与 `ios/` 同级，承载**大屏 GUI**：iPad 三栏布局与折叠屏 iPhone（Duo）展开态的双栏布局。SSH / Agent 核心逻辑仍复用 `../ios/KoKo/`。

## 布局

| 场景 | 视图 | 说明 |
|------|------|------|
| iPhone 竖屏 / 折叠屏外屏 | `PhoneRootView`（在 `ios` 工程） | 底部 Tab + 栈式导航 |
| 折叠屏展开（`horizontalSizeClass == .regular`） | `DuoRootView` | 分段切换 + 双栏 `NavigationSplitView` |
| iPad | `TabletRootView` | 侧边栏 + 列表 + 详情/终端 三栏 |

`AdaptiveRootView` 根据 `DeviceLayout` 自动选择上述布局。

## 打开 iPad 工程

```bash
cd ipad
chmod +x scripts/setup.sh
./scripts/setup.sh    # 先准备 ../ios/Packages，再生成 KoKoPad.xcodeproj
open KoKoPad.xcodeproj
```

- **Bundle ID**：`com.foqerhk.koko.pad`
- **设备**：iPad（`TARGETED_DEVICE_FAMILY = 2`）
- **依赖**：与 iOS 共用 `../ios/Packages/` 与同一套 Services / Store / Terminal 源码

## iPhone 折叠屏

折叠屏用户在 **iOS 工程（KoKo）** 中运行同一套 `AdaptiveRootView`：展开后自动切换到 `DuoRootView`，无需单独安装 iPad App。

在模拟器中测试 Duo：使用 iPhone 16 Pro Max 等设备横屏，或支持 regular width 的折叠屏模拟器。

## 目录

```
ipad/
├── project.yml
├── scripts/setup.sh
└── KoKoPad/
    ├── App/KoKoPadApp.swift
    ├── Support/DeviceLayout.swift
    ├── Support/SidebarSection.swift
    └── Views/
        ├── AdaptiveRootView.swift
        ├── TabletRootView.swift
        ├── DuoRootView.swift
        └── SplitRootChrome.swift
```
