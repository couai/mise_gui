# 界面预览与验证

这些图片由实际 Flutter 页面和应用外壳渲染，使用本机版本配置的测试快照；它们不是运行中的 GUI 截屏。真实应用通过本地识别服务和 mise 查询版本、目录，不读取测试快照。

## DevWorkbench 工具工作台

![DevWorkbench](dev-workbench.png)

工作台图由实际 Flutter 页面渲染。设置 `DEVWORKBENCH_RENDER_PREVIEW=1` 时会先只读扫描本机工具，再把真实清单注入页面生成此图；普通测试使用隔离的固定快照，不运行本机探测。重现方式：

```sh
DEVWORKBENCH_RENDER_PREVIEW=1 \
MISE_GUI_PREVIEW_CJK_FONT="<本机中文字体路径>" \
MISE_GUI_PREVIEW_MATERIAL_FONT="$(mise where flutter)/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf" \
flutter test test/local_tools_page_test.dart
```

## 分类工具链

![分类工具链](toolchains-overview.png)

## Flutter 与配套 Dart

![Flutter / Dart](flutter-detail.png)

## 重现预览

普通界面测试：

```sh
flutter test test/toolchains_page_test.dart
```

生成图片时，通过环境变量传入本机中文字体和当前 Flutter SDK 自带的 Material Icons 字体：

```sh
MISE_GUI_RENDER_PREVIEW=1 \
MISE_GUI_PREVIEW_CJK_FONT="<本机 PingFang.ttc 路径>" \
MISE_GUI_PREVIEW_MATERIAL_FONT="$(mise where flutter)/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf" \
flutter test test/toolchains_page_test.dart
```

字体仅在本机加载，不复制到仓库。

## DevWorkbench 验证记录

2026-10-18，macOS ARM64，Flutter 3.47.7：

- 本机识别 45 项已安装工具，分 6 类；检测目录共支持 46 项。旧版独立 Simulator.app 未检测到，Xcode 27 的 Device Hub 已识别；这不代表模拟器运行时被删除。
- 静态分析和 86 项测试通过，包含分类筛选、窄窗口、mise 缺失、指定工具跳转、SDK 元数据、超时与输出上限、原有分类安装及全局/项目切换。
- macOS Release 构建和严格签名校验通过，已安装到 `/Applications/DevWorkbench.app`；实际打开功能通过系统 `open` 验证，原生进程持续正常运行。
- 本次扫描只读，现有 6 类运行时、8 个 SDK 版本及全局默认选择已复查；分类目录、项目文件和历史数据保留。
- 构建仍使用既有 CocoaPods 接入；Flutter 提示可在后续迁移到 Swift Package Manager，本次不改变用户 CocoaPods 环境。

## 原分类工具链阶段验证记录

2026-10-18，macOS ARM64，Flutter 3.47.7 / Dart 3.13.5：

- 真实登录 Shell 与分类目录查询通过，发现 6 类运行时、8 个已安装版本。
- 静态分析、71 项测试及 macOS Release 构建通过。移除 GUI / mise 本体升级功能时，同步删除了 5 项专属服务测试，并将启动更新弹窗测试替换为无升级入口的启动验证。测试包含真实 mise 在隔离 HOME、配置和数据目录中的注册、全局切换、项目切换、未知配置段保留、安装失败时对并发锁文件的保护，以及工具菜单的安装流程。
- 安装流程验证了命令计划、目标目录保护、软链接越界保护；没有为测试下载或增加新的 SDK 版本。
- 上游作者的签名团队已移除，本机采用 ad-hoc 签名。公开分发和公证需另外配置签名证书。
- 本地 Release 入口为 `bash scripts/build_local_macos.sh`，构建后按由内到外的顺序刷新 App.framework 与应用签名，避免增量构建的旧签名造成校验失败。
- 工具图标使用官方素材，来源、校验值与版权说明见 [素材目录](../../assets/toolchains/README.md)。

应用源码的首期适配针对 macOS；Linux、Windows 构建没有在本机验证。
