# ClashBar 图标设计与素材

图标素材和预览统一保存在本仓库的 `design/icons/`。可编辑的 [Pencil 主设计稿](../../ClashBar-Pencil-Migrated.pen) 保留在仓库根目录，图片引用使用仓库内相对路径。

## 当前定稿

| 内容 | 文件 |
| --- | --- |
| 应用图标 | [已确认大五官 1024px PNG](app-icon-large-face-1024.png) · [macOS ICNS](ClashBar.icns) · [Iconset](ClashBar.iconset/) |
| 面板左上角四态图标 | 关闭为 G 版加粗系统黑白模板；运行和 TUN 为 C 翡翠绿；异常为无感叹号的黄色担忧表情；[实际渲染预览](applied-header-states/) |
| 菜单栏四态设计 | 当前 `.pen` 中 `ou3yE` 的原生几何 · [透明模板素材](monochrome-g/) |
| 代码渲染结果 | [浅色运行态](applied-monochrome-g/NSAppearanceNameAqua-icon_only-run.png) · [深色运行态](applied-monochrome-g/NSAppearanceNameDarkAqua-icon_only-run.png) |

当前菜单栏采用 **G 版单色模板**，保留圆润半身猫、放大的五官和眼嘴间距。图形绘制高度为 **18pt**，普通图标槽位为 **24pt**，TUN 槽位为 **28pt**。图形在槽位内居中，合成阶段也限制为 18pt，避免再次放大。四态均由系统根据菜单栏外观适配黑白，使用轮廓、实心、盾牌和异常表情区分状态：

| 状态 | 设计 | 导出素材 |
| --- | --- | --- |
| 关闭 | 8px 内描边轮廓、8px 圆头闭眼与微笑 | [关闭态](monochrome-g/icon-sleep.png) |
| 运行 | 实心半身猫，眼睛和嘴巴透明镂空 | [运行态](monochrome-g/icon-run.png) |
| TUN | 实心半身猫，半空心盾牌嵌入脸颊 | [TUN 态](monochrome-g/icon-tun.png) |
| 异常 | 8px 内描边轮廓、椭圆眼与 8px 圆头担忧嘴，无感叹号 | [异常态](monochrome-g/icon-warning.png) |

Pencil 的 G 版四态节点分别为 `A5IDi`、`zDtFj`、`Fw7dr`、`rt09c`。生成脚本直接读取当前保存的 `.pen`，将浅色五官和盾牌绘制成透明镂空，避免系统模板渲染后糊成实心。`monochrome-g/source/` 是旧导出存档，不再作为生成输入。TUN 保留 128×88 画幅，对应 18pt 预览 `qGRws`；其余资源使用 112×88 画幅，异常态仅裁掉右侧空白，不移动表情。

应用主图标使用已确认的蓝色整猫加白色圆角方块：眼睛 1.75 倍、嘴 1.8 倍并下移 65px。`BrandAppIcon`、`AppIcon.appiconset` 与 `.icns` 均由 `app-icon-large-face-1024.png` 生成；`AppDelegate` 通过独立的 `BrandIcon.appImage` 设置 `applicationIconImage`。旧 `app-icon-1024.png` 仅为历史素材。

面板关闭态使用独立的 `BrandHeaderSleep` 资源，但图形与 G 版加粗线框保持同步；异常态由无感叹号的 G 版担忧表情着黄色生成。这样面板 40pt 图标和菜单栏状态不会再出现线条或表情版本差异。

面板左上角的 40pt 半身猫与菜单栏共用 `menuBarDisplaySnapshot.iconState`，状态变化时自动同步，无须重新打开面板。关闭态使用 G 版加粗黑白空心模板；运行态使用 [C 翡翠绿](menu-bar-emerald/Lnf10.png) `#169568` 配柔白五官 `#F3FFF9`；TUN 使用 [翡翠绿嵌入式盾牌](menu-bar-emerald/eDYDX.png)；异常态使用黄色 `#FFB020` 的空心轮廓及 G 版圆眼担忧表情，不带感叹号。异常状态优先于 TUN 和运行状态，内核停止或代理与 TUN 均关闭时显示关闭态。

## 配色探索 · 面板品牌采用 C 翡翠绿

针对 18pt 灰蓝在绿植壁纸上不够清晰的反馈，曾制作六组运行/TUN 配色。菜单栏现改用 G 版单色模板，C 翡翠绿用于面板左上角品牌图标；其他方案保留供比较：

[A–F 配色预览](color-studies-2026-11-11/preview.html) · [完整画板](color-studies-2026-11-11/N9jU3.png) · [颜色与素材说明](color-studies-2026-11-11/README.md)。Pencil 中对应 `N9jU3` 图标设计总览下方的 A–F 区域；可对比清透蓝、湖水青、翡翠绿、薄荷绿、珍珠白配墨绿、瓷白配深蓝。

## 历史方案

根目录的 `mb-*.png`、`final-sheet.png`，以及 `upper-body-*`、`pencil-*` 和 `production/` 目录，保留先前的整猫、半身、文字徽章和盾牌探索版本，供对照。`applied-four-states/` 保留调整前的 22pt 代码渲染结果，`menu-bar-balanced/` 与 `applied-balanced-states/` 保留 18pt 灰蓝版本，`menu-bar-emerald/` 与 `applied-emerald-states/` 保留翡翠绿菜单栏版本。

## 后续导出

新素材和预览继续保存到此目录，Pencil 和 HTML 均使用相对路径，避免依赖个人目录或仓库外的文件。

如需从当前代码重新导出菜单栏预览，在仓库根目录执行：

```sh
bash design/icons/build-app-icon-assets.sh
swift design/icons/monochrome-g/build-template-assets.swift
swift design/icons/build-header-assets.swift
PREPARE_MIHOMO_BINARY=0 Scripts/preprocess.sh
CLASHBAR_ICON_PREVIEW_DIR="$PWD/design/icons/applied-monochrome-g" swift test --filter BrandIconRenderingTests
CLASHBAR_HEADER_PREVIEW_DIR="$PWD/design/icons/applied-header-states" swift test --filter SystemProxyStateTests.testHeaderIconTracksAllStatesWithoutReopeningInBothThemes
```

`build-header-assets.swift` 会从当前菜单栏母图同步面板关闭态、翡翠绿运行/TUN 资源，并生成无感叹号的黄色异常资源。
