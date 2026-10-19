# 项目工作台

“项目”统一提供项目发现、技术栈档案、环境对照、项目版本固定与快速打开。原扫描目录设置和全局版本覆盖列表继续保留；工具安装和新增 SDK 仍进入唯一的 mise 版本管理或原管理器页面。

## 项目发现与声明

`LiveProjectScanService` 发现 mise／版本文件，也发现只有 `package.json`、`pom.xml`、Gradle、`pyproject.toml`、`go.mod`、`Cargo.toml` 或 `pubspec.yaml` 的项目。没有版本文件的项目仅做静态发现，不为每个项目启动 mise。支持按名称、路径和技术栈搜索。缺少 mise 时仍可浏览项目，解析失败不等于没有项目。

扫描沿用启用的根目录、根目录重叠去重、每根深度 3、最多 240 个目录和 80 个项目的上限。跳过隐藏目录、node_modules、build、dist、target 和 venv；不跟随子目录软链接。新增文件的自动发现以重新扫描为准，已有元数据文件变动沿用原文件监听。

`ProjectScanService.scan()` 返回项目及每个根目录的 `ProjectScanRootReport`：已访问目录数、已发现项目数、完整性和原因。达到上限且仍有待扫描目录、深度边界外存在可扫描子目录、目录读取失败或项目读取异常时，保留已发现结果并报告部分扫描；一个根失败不丢弃其他根的结果。忽略目录不计为遗漏，恰好达到项目数且已无剩余目录时可报告完成。全局配置解析失败单独报告。项目页、刷新反馈与总览同时反映这些信息，不把截断结果显示为完整的空结果。

`ProjectProfileService` 只读取列明的元数据，单文件最大 256 KiB，同时检查 stat 和实际读取量。文件软链接、父路径中的额外软链接、非普通文件、超限或无法解析的数据会产生警告；项目根目录先规范化。锁文件、Wrapper 和 `api/bruno/bruno.json`／`opencollection.yml` 只检查是否存在，不读取其内容。扫描不读取 .env、私钥、数据库凭据或执行项目代码。

| 项目类型 | 当前识别 |
|---|---|
| Node | Vue、TypeScript、React、Next.js、Nuxt；engines、packageManager、版本文件；锁文件冲突 |
| Java | Maven 的 compiler.release／java.version／compiler.target；Gradle 字面量 JavaLanguageVersion；Spring Boot、Android 静态标识；Wrapper 存在性 |
| Python | pyproject.toml 的 requires-python 与直接声明的 FastAPI；uv.lock |
| Go | go.mod 的 go 最低版本和 toolchain 声明 |
| Rust | Cargo 的 rust-version 最低版本与 rust-toolchain 文件 |
| Flutter / Dart | pubspec 的 SDK 约束；Dart 从项目实际选择的 Flutter SDK 读取 |

动态 Gradle、继承 POM、工作区共享属性、插件、平台签名等需由项目构建验证。Wrapper 存在标为“项目提供”，不代表已经下载或构建成功。没有从 manifest 推测启动入口；package.json 已声明脚本仅生成带项目目录和参数转义的复制命令，不自动运行。

## 环境对照

项目详情通过 `ProjectEnvironmentService` 合并静态声明、共享本机工具清单与项目目录下 `mise ls --json` 的实际结果。项目查询使用管理器指定的 mise 路径，固定离线并禁止自动安装，独立于安装页面的网络选项。分别显示项目要求、实际生效、来源和本地安装版本。已安装不代表生效；mise 缺失、未受信任或查询失败时，保留声明并显示未确认，不调用 trust 或安装命令。

数值精确／前缀、最低版本及受支持的数值范围、caret、完整 tilde 和范围并集可自动比较；Oracle Java 前缀与 Java 1.8 声明按数值版本处理。无法判断的别名、动态表达式或复杂约束显示“待核对”。并存声明逐项核对，冲突保留可见。npm／pnpm 等本机探测结果不冒充项目 Corepack 或虚拟环境版本，有版本要求时保留待核对。

Java 的旧编号转换仅作用于 Java，且以完整的 `1.8` 段为边界；Go／Rust 等保留数字序列。工具清单的 unavailable／attention 状态继续显示待核对，即使保留了先前版本，也不据此声称可用或未安装。项目覆盖与工具档案共用 `ProjectProfileService.miseVersions()` 的 TOML 解析，支持注释、单双引号、inline table 和嵌套 version；覆盖比较使用解析后的声明值，项目实际生效版本另由 mise 查询。

首次打开的读取不生成任务。点击“检查环境”刷新本机清单，记录元数据读取、工具对照、验证结果；缺项／不符／未知或元数据警告标为需检查。检查由服务与 TaskCenter 完成，离开页面不停止已开始的检查。检查范围是工具与声明，不代表依赖、构建或测试通过。

## 固定版本与快速打开

固定版本的选项仅来自真实 mise 已安装清单，支持既有六类运行时；Dart 继续跟随 Flutter。`ProjectVersionService` 生成明确的 `<项目>/mise.toml` 写入计划，预览显示工具、精确版本、命令和目标路径，确认后复查版本文件快照、目录真实路径及安装状态。文件新增／改动、目标软链接或缺少版本时拒绝旧计划；用户主目录与系统根目录不能作为项目作用域。

实际执行复用 `ClassifiedToolchainService` 和 `TrackedMiseActionService`：写操作共用任务锁，由 mise 保留其他 TOML 段，再检查注册、分类目录、必要程序与项目实际生效版本。验证不通过明确失败；不改全局默认或现有 SDK 分类目录。其他版本文件可能覆盖 mise.toml，需按验证结果核对，不能只凭 exit 0 报成功。

快速打开提供 Finder、终端、已识别 IDE、声明文件的 Finder 定位和接口集合目录。通过 `/usr/bin/open` 参数数组调用，点击时复查路径，不拼接 Shell。Bruno 入口打开同一 `api/bruno/` 目录，用户在 Bruno 中选择该集合；不宣称已自动导入 GUI。项目依赖和构建产物继续留在项目中。

## 验证

普通测试使用临时项目、模拟 CLI 与内存工作台存储；真实 mise 写入测试限定隔离 HOME／MISE 目录，不下载 SDK。运行：

```sh
mise exec -- flutter test test/project_environment_test.dart test/project_environment_page_test.dart
mise exec -- dart run tool/check_projects.dart
mise exec -- dart run tool/check_projects.dart --scan /path/to/code
```

后两项是本机只读验收，不写任务或管理器设置。页面预览和验收记录见 [界面验证](design/README.md)。
