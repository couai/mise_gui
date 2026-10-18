# DevWorkbench：本地工具工作台

DevWorkbench 在原 Mise GUI fork 上扩展本地工具管理。首页保留“总览”第一位，新增“开发工具”；原分类工具链、工具版本安装、项目覆盖和配置编辑继续作为 mise 功能使用。此阶段完成识别、分类、详情和快速打开，不在扫描时安装或迁移软件。

## 识别范围

| 分类 | 工具 |
|---|---|
| 语言运行时 | Java、Node.js、Python、Go、Rust、Flutter、配套 Dart |
| 构建与包管理 | npm、pnpm、pip、uv、Maven、Gradle Wrapper、Cargo、rustup、CocoaPods、Homebrew |
| 移动开发 | Android SDK、NDK、CMake、ADB、Android Studio、Xcode、Device Hub；兼容旧版 Simulator 应用路径 |
| API 与网络调试 | Bruno（含 CLI）、Reqable、mitmproxy、MCP Toolbox |
| IDE 与编辑器 | IDEA、DataGrip、VS Code、Cursor、HBuilderX、JetBrains Toolbox、Navicat |
| 开发辅助 | Git、Git LFS、gh、wget、mise、gopls、Delve、rustfmt、Clippy、rust-analyzer |

这是已支持工具的本地目录与命令识别目录，不是对电脑上任意程序的完整软件资产扫描。新增工具时扩展 `SystemLocalToolInventory` 的目录定义和证据检查；配置目录存在本身不代表程序安装成功。

## 数据和边界

- `LocalToolInventory.scan()` 返回工具、状态、时间和局部警告；页面不执行探测命令。分类、搜索和详情使用同一份快照。
- 运行时复用 `ClassifiedToolchainService` 的真实 mise 清单，显示全局选择、所有已安装版本及真实 SDK 路径。Dart 从 Flutter 的配套 SDK 读取；Rust 显示 rustup 的实际工具链路径。
- GUI 读取 `/Applications` 下的应用包元数据；命令从登录 Shell 环境、分类目录和系统路径解析。CLI 版本输出与 GUI 元数据分别核对；mitmproxy 的 `0.0.0` 包元数据用实际 CLI 版本补齐。
- Android 平台需有实际的 `android.jar`，NDK/CMake 读取 `source.properties`；Gradle 从已有 Wrapper 分发包中的程序识别，不执行项目 Wrapper，也不下载依赖。Xcode 27 的 Device Hub 位于应用内部的 `Contents/Applications`。
- 管理方式和来源分别展示。例如 Oracle JDK 是本地 Oracle SDK，由 mise 选择；CocoaPods 可由 Homebrew 安装；Bruno GUI 与 CLI 在同一详情中展示。
- 最多四个探测任务并发；单个 CLI/元数据命令限时五秒、每路输出限 128 KiB，mise 清单限时十秒。扫描不会访问远端版本列表；mise 失败只产生警告，不阻断其他工具。
- 探测只使用固定版本参数和安装元数据；保留离线/禁止自动安装选项，不执行未解析的 mise shim。扫描不读取 SSH 私钥、数据库凭据、GitHub token 或 Reqable 会话数据。
- 目录逐项检查，未创建或已移除的路径禁用打开操作。点击打开时再检查路径，使用 `/usr/bin/open` 的参数数组；文件在 Finder 中定位，文件夹正常打开，应用直接启动。路径不会拼进 Shell 命令。

## 版本管理和目录兼容

运行时详情的“版本管理”进入相应的 mise 工具链页。安装计划、全局/项目切换、目录保护、Rust 共享代理和 Flutter/Dart 配套规则继续由 [分类工具链策略](classified-toolchains.md) 负责。

应用发布名称、窗口与安装包名称为 `DevWorkbench`，版本从 `pubspec.yaml` 读取；macOS 应用部署在 `/Applications/DevWorkbench.app`。代码仓库、内部 Dart 包名 `mise_gui`、bundle identifier `com.couai.miseGui` 保留，避免打断已有导入、系统设置和签名标识。

应用自己的扫描目录设置、历史记录继续使用 `$HOME/Developer/toolchains/mise-gui/`。这是兼容现有数据的有意保留；本次改名不复制或合并历史目录。其他 SDK、配置、缓存、日志与项目路径保持原分类规范。

本地识别与快速打开首期验证平台为 macOS。其他系统沿用既有 mise 界面，本次未验证其构建和本地发现。

## 验证和维护

```sh
mise exec -- flutter analyze
mise exec -- flutter test
mise exec -- dart run tool/check_environment.dart
mise exec -- dart run tool/check_local_tools.dart
bash scripts/build_local_macos.sh
```

测试覆盖本地证据、空目录、损坏注册、shim 跳过、mise 缺失时的独立识别、Android 包和 Gradle 元数据、CLI 失败时保留 GUI、带空格和 Shell 字符的路径、命令超时及输出上限，以及分类、搜索、详情、失效路径提示和窄窗口布局。实际 mise 安装/切换测试使用隔离目录。

实际 Flutter 页面预览及重现方式见 [设计预览](design/README.md)。工具官方图标分别记录在 [运行时素材](../assets/toolchains/README.md) 和 [本地工具素材](../assets/local_tools/README.md)；DevWorkbench 自有图标使用独立素材，保留上游品牌素材及 MIT 署名。
