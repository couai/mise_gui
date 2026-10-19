# 项目工作台

“项目”统一提供项目发现、技术栈档案、环境对照、项目版本固定与快速打开。原扫描目录设置和全局版本覆盖列表继续保留；工具安装和新增 SDK 仍进入唯一的 mise 版本管理或原管理器页面。

## 项目发现与声明

`LiveProjectScanService` 发现 mise／版本文件，也发现只有 `package.json`、`pom.xml`、Gradle、`pyproject.toml`／`requirements.txt`、`go.mod`、`Cargo.toml` 或 `pubspec.yaml` 的项目。没有版本文件的项目仅做静态发现，不为每个项目启动 mise。支持按名称、路径和技术栈搜索。缺少 mise 时仍可浏览项目，解析失败不等于没有项目。

扫描沿用启用的根目录、根目录重叠去重、每根深度 3、最多 240 个目录和 80 个项目的上限。跳过隐藏目录、node_modules、build、dist、target 和 venv；不跟随子目录软链接。新增文件的自动发现以重新扫描为准，已有元数据文件变动沿用原文件监听。

`ProjectScanService.scan()` 返回项目及每个根目录的 `ProjectScanRootReport`：已访问目录数、已发现项目数、完整性和原因。达到上限且仍有待扫描目录、深度边界外存在可扫描子目录、目录读取失败或项目读取异常时，保留已发现结果并报告部分扫描；一个根失败不丢弃其他根的结果。忽略目录不计为遗漏，恰好达到项目数且已无剩余目录时可报告完成。全局配置解析失败单独报告。项目页、刷新反馈与总览同时反映这些信息，不把截断结果显示为完整的空结果。

`ProjectProfileService` 只读取列明的元数据，单文件最大 256 KiB，同时检查 stat 和实际读取量。文件软链接、父路径中的额外软链接、非普通文件、超限或无法解析的数据会产生警告；项目根目录先规范化。锁文件、Wrapper 脚本和 `api/bruno/bruno.json`／`opencollection.yml` 只检查存在性。Gradle Wrapper properties、settings、构建文件、Gradle 属性、模块 POM、pyvenv.cfg 与 pip 安装元数据按相同上限读取；属性内容仅保留识别的 Java 配置，不写日志。扫描不读取 .env、私钥或执行项目代码。

| 项目类型 | 当前识别 |
|---|---|
| Node | Vue、TypeScript、React、Next.js、Nuxt；engines、packageManager、devEngines.packageManager、版本文件；锁文件冲突；项目 npm/pnpm 离线版本 |
| Java | Maven 模块、项目内匹配 parent、属性插值及 compiler plugin 编译级别；Gradle Groovy/Kotlin include、字面量 projectDir、共享 Java 声明、source/target、options.release、Wrapper 声明版本；Spring Boot／Android 标识 |
| Python | pyproject.toml 的 requires-python 与直接声明的 FastAPI；requirements.txt、uv.lock；.venv／venv、mise 虚拟环境声明与项目内 VIRTUAL_ENV；解释器链接和 pip 安装元数据 |
| Go | go.mod 的 go 最低版本和 toolchain 声明 |
| Rust | Cargo 的 rust-version 最低版本与 rust-toolchain 文件 |
| Flutter / Dart | pubspec 的 SDK 约束；Dart 从项目实际选择的 Flutter SDK 读取 |

动态 Gradle、外部／远端 parent、Maven profiles、约定插件、平台签名等需由项目构建验证。Wrapper 存在标为“项目提供”，不代表已经下载或构建成功。没有从 manifest 推测启动入口；package.json 已声明脚本仅生成带项目目录和参数转义的复制命令，不自动运行。

## 环境对照

项目详情通过 `ProjectEnvironmentService` 合并静态声明、共享本机工具清单与项目目录下 `mise ls --json` 的实际结果。项目查询使用管理器指定的 mise 路径，固定离线并禁止自动安装，独立于安装页面的网络选项。分别显示项目要求、实际生效、来源和本地安装版本。已安装不代表生效；mise 缺失、未受信任或查询失败时，保留声明并显示未确认，不调用 trust 或安装命令。

数值精确／前缀、最低版本及受支持的数值范围、caret、完整 tilde 和范围并集可自动比较；Oracle Java 前缀与 Java 1.8 声明按数值版本处理。无法判断的别名、动态表达式或复杂约束显示“待核对”。并存声明逐项核对，冲突保留可见。没有项目级证据的其他包管理器继续显示本机探测值并保留待核对。npm／pnpm 使用下面的项目作用域诊断。

Java 的旧编号转换仅作用于 Java，且以完整的 `1.8` 段为边界；Go／Rust 等保留数字序列。工具清单的 unavailable／attention 状态继续显示待核对，即使保留了先前版本，也不据此声称可用或未安装。项目覆盖与工具档案共用 `ProjectProfileService.miseVersions()` 的 TOML 解析，支持注释、单双引号、inline table 和嵌套 version；覆盖比较使用解析后的声明值，项目实际生效版本另由 mise 查询。

### 项目 npm / pnpm

`ProjectRuntimeInspector` 先查询项目下 `mise which <固定命令>`；此命令只解析 mise 管理的程序，独立安装的 pnpm 则按项目 Node SDK 的 bin、已配置 PATH 的顺序查找。首个候选如果是项目程序或不在分类工具目录／配置 Homebrew 前缀／系统 bin 的真实路径内，报告待核对，不跳过它冒用后面的全局版本。项目 Node SDK 也必须属于可信安装。

在项目目录对该程序执行固定 `--version`，使用项目 Node 的 PATH，清除 Node/Bun 注入选项。Corepack 强制离线、禁止 auto-pin 和自定义 URL，禁读 `.corepack.env`；pnpm 禁止自动管理／下载包管理器版本。显示的是当前离线可运行入口；普通执行若会自动下载或切换版本，诊断不会替它执行。缓存缺少、版本声明为自定义来源、命令超时或项目 mise 未确认时显示待核对，不退回全局清单声称符合。Corepack 没有项目内包管理器声明时保留待核对，避免跟随未知父目录来源。工具路径与检查超时使用管理器设置。

### Python 虚拟环境

检查项目的 `.venv`、`venv` 以及静态 mise `[env._.python].venv` 指定的项目内路径；支持字符串和 `{path=..., create=...}`。明确的 mise 声明（且项目查询成功）优先，其次使用属于当前项目的 `VIRTUAL_ENV`。没有选择证据的目录标为候选，继续对照 mise 基础 Python；GUI 的环境不代表另一个终端的激活状态。没有环境时明确显示未发现，诊断不创建环境。

读取 pyvenv.cfg 并解析 bin/python 的真实目标。只对可信基础解释器运行 `-I -S` 固定版本查询，不运行项目内解释器副本、activate 或 site hooks；配置版本与基础解释器不一致、失效链接、缺少配置或外部路径均显示待核对。复制而非链接的解释器、Conda、外部 Poetry 环境等保留人工核对。只读检查已识别 Python 对应 site-packages 中 pip 的 dist-info/METADATA，最多检查 512 个条目；没有 pip 对 uv 环境是允许的。已选择且已验证的虚拟环境用于 Python 约束对照及其 pip 安装版本展示，不调用全局 pip 代替。

### Java / Gradle 模块

模块图仅沿 manifest 声明读取，限制 40 个目录、深度 8，每文件 256 KiB；限制、缺文件、解析失败、软链接、越界、动态 include／projectDir 和复合构建保留警告。模块与 parent 路径限定在项目根内，父目录循环去重。Maven 的聚合关系不等于继承，仅对坐标匹配的项目内 parent 合并属性及 compiler plugin 配置；属性展开最多 12 次，未展开表达式保持待核对。

Gradle 识别 `include("...", "...")` 和 Groovy 字面量列表、`project(...).projectDir = file(...)`／`File(rootDir, ...)`、根／模块 gradle.properties 的已列明 Java 版本属性。只把明确 subprojects/allprojects 中的编译声明作为子模块依据；根 Java 插件不会自动继承。同字段采用最后识别到的设置，子模块只覆盖同字段的共享声明。分别显示 JavaLanguageVersion、source／targetCompatibility、options.release 与 Gradle Wrapper 的 distributionUrl 版本。

根和子模块之间存在版本文件时，在模块目录重新查询 mise Java。编译级别是最低能力约束，不要求启动 JDK 与目标字节码版本相等；存在 Gradle 工具链时对照该工具链的静态能力，避免把启动 JVM 与编译 JDK 混为一谈。显示的 mise JDK 不是 IDE 或 `org.gradle.java.home` 的实际 Gradle JVM；工具链实际选择、Gradle 与 JVM 的完整兼容关系、依赖解析和构建成功均需构建验证。

首次打开的读取不生成任务。点击“检查环境”刷新本机清单，记录元数据读取、工具对照、验证结果；缺项／不符／未知或元数据警告标为需检查。检查由服务与 TaskCenter 完成，离开页面不停止已开始的检查。检查范围是工具与声明，不代表依赖、构建或测试通过。

## 固定版本与快速打开

固定版本的选项仅来自真实 mise 已安装清单，支持既有六类运行时；Dart 继续跟随 Flutter。`ProjectVersionService` 生成明确的 `<项目>/mise.toml` 写入计划，预览显示工具、精确版本、命令和目标路径，确认后复查版本文件快照、目录真实路径及安装状态。文件新增／改动、目标软链接或缺少版本时拒绝旧计划；用户主目录与系统根目录不能作为项目作用域。

实际执行复用 `ClassifiedToolchainService` 和 `TrackedMiseActionService`：写操作共用任务锁，由 mise 保留其他 TOML 段，再检查注册、分类目录、必要程序与项目实际生效版本。验证不通过明确失败；不改全局默认或现有 SDK 分类目录。其他版本文件可能覆盖 mise.toml，需按验证结果核对，不能只凭 exit 0 报成功。

快速打开提供 Finder、终端、已识别 IDE、声明文件的 Finder 定位和接口集合目录。通过 `/usr/bin/open` 参数数组调用，点击时复查路径，不拼接 Shell。Bruno 入口打开同一 `api/bruno/` 目录，用户在 Bruno 中选择该集合；不宣称已自动导入 GUI。项目依赖和构建产物继续留在项目中。

## 验证

普通测试使用临时项目、模拟 CLI 与内存工作台存储；真实 mise 写入测试限定隔离 HOME／MISE 目录，不下载 SDK。运行：

```sh
mise exec -- flutter test test/project_environment_test.dart test/project_diagnostics_test.dart test/project_environment_page_test.dart test/project_runtime_details_test.dart
mise exec -- dart run tool/check_project_diagnostics.dart
mise exec -- dart run tool/check_projects.dart
mise exec -- dart run tool/check_projects.dart --scan /path/to/code
```

check_projects 是本机只读验收；check_project_diagnostics 调用真实工具核对临时项目并创建一个无依赖临时 venv，finally 删除夹具。均不写用户任务或管理器设置。页面预览和验收记录见 [界面验证](design/README.md)。

## 原生语义参考

- [Corepack 官方说明](https://github.com/nodejs/corepack)：项目 packageManager、离线和 auto-pin／env 文件控制。
- [Python venv](https://docs.python.org/3/library/venv.html)：pyvenv.cfg、解释器与激活的区别。
- [Gradle 多模块](https://docs.gradle.org/current/userguide/multi_project_builds.html)：include 与 projectDir。
- [Maven POM](https://maven.apache.org/guides/introduction/introduction-to-the-pom.html)：聚合、parent 与继承。
