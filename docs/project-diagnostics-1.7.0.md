# DevWorkbench 1.7.0 项目环境诊断

2026-10-19，macOS 26.7.1 / ARM64，Flutter 3.47.7。此轮补充项目作用域诊断，沿用分类工具目录、唯一的 mise 版本入口和原任务中心。

## 变化

- npm/pnpm 从项目选择的 Node SDK 与配置 PATH 解析实际命令，离线查询版本；独立安装 pnpm 与 Corepack 分开处理。项目工具覆盖、未受信任配置、缓存缺少、失败或未知来源保留待核对。禁用自动下载、auto-pin、自定义包管理器来源及 `.corepack.env` 加载。
- Python 支持 pyproject、requirements-only 项目；展示 `.venv`、`venv` 和 mise 指定环境，区分候选与已选择。读取 pyvenv.cfg，验证解释器链接到可信安装后对基础解释器作隔离版本查询；检查版本不一致、失效或外部路径，展示项目 pip 安装元数据。无 pip 的 uv 风格环境允许存在。
- Maven 支持项目内模块、匹配本地 parent、属性插值与 compiler plugin 配置继承；聚合不冒充继承。Gradle 支持 Groovy/Kotlin 的字面量模块声明、projectDir、共享编译配置、source/target、options.release、工具链和 Wrapper 声明版本。
- 模块分别显示 mise JDK、编译级别与编译工具链。模块或中间目录有版本文件时重新查询模块作用域；JDK 能编译较低目标版本不再当成冲突。Gradle 编译工具链可以独立于 mise 启动 JDK，无法从静态信息确认的实际编译选择保留待核对。
- 项目详情新增环境与模块档案、目录打开；显式检查任务保留环境选择与模块结果。扫描深度／数量限制、缺少或不安全元数据仍有警告。

详细读取范围、路径限制和未执行的动态逻辑见 [项目工作台约定](projects.md)；[界面预览](design/README.md) 来自实际 Flutter 组件和隔离快照。

## 验证结果

| 检查 | 结果 |
|---|---|
| 静态分析与格式 | `flutter analyze --no-pub` 无问题；128 个 Dart 文件格式检查通过 |
| 全量回归 | 246 通过，2 个显式本机验收按约定默认跳过；较 1.6.1 新增 28 项测试 |
| 界面 | 新组件在 1200 / 400 宽度验证内容、换行与准确的目录打开；原项目页宽／窄窗口、确认／取消、导航和扫描完整性继续通过 |
| 本机新诊断 | `dart run tool/check_project_diagnostics.dart`：11 项断言通过，0 失败；真实 npm 11.19.0、pnpm 12.11.2、Python 3.14.8 与临时 venv、Maven 继承和 Gradle 模块验证通过 |
| 稳定性补充验收 | `dart run tool/audit_project_environment.dart`：0 失败，1.6.1 的跨语言／TOML／失败状态／扫描上限回归保留 |
| 现有 SDK | `check_environment.dart`：6 类、8 个 SDK 均符合分类目录，原全局默认版本保持一致 |
| 实际源码项目 | Flutter 3.47.7 / Dart 3.13.5 / Node 24.21.0 正确识别；npm 声明与实际已同步为 11.19.0，符合声明，0 项工具问题；后续同步验证见下文 |

新诊断本机验收只创建临时夹具和 `--without-pip` venv，在 finally 中删除；没有安装项目依赖、运行脚本或 Wrapper，也没有写用户任务、管理器设置或项目版本文件。常规测试中的真实 mise 写入仍使用隔离 HOME/MISE 目录。这里的成功不代表项目完整构建、依赖解析、签名或真实设备调试已通过。

本地 Release 构建完成，已安装 `/Applications/DevWorkbench.app` 1.7.0（build 18）。构建产物与已安装主程序／Dart App.framework 的 SHA-256 一致，严格签名校验通过，已验证新应用持续运行超过 30 秒。环境入口、mise 全局配置、工作台管理器设置、扫描目录及导入清单的校验值与本轮修改前一致；全局和源码 AGENTS.md 已更新。本轮临时项目、验证日志及旧应用备份已清理。

## npm 声明同步与脚本兼容性

同日后续验证：初次 1.7.0 验收发现源码声明 npm 10.8.2、实际 11.19.0，诊断正确报告不符。本次按用户要求将 `package.json` 同步为 `npm@11.19.0`；真实 `check_projects.dart` 重新检查后，npm 显示“符合声明”，0 项工具问题、0 项元数据警告。

- 本机 Node.js 24.21.0、npm 11.19.0；用 npm 自带 semver 核对其 Node engine `^20.17.0 || >=22.9.0`，结果符合。现有 CI 选择 Node 24；此轮没有执行远端 CI。
- 7 个 Bash 脚本语法、3 个 Node ESM 的 `node --check`、2 个 Python AST 检查通过。15 个 npm 入口全部在临时源码副本中核对：12 个通过，3 个 Windows/Linux 入口在 macOS 按预期由平台保护拒绝。
- 隔离流程核对 npm 参数传递、三个 skip-notarization 入口和 unsigned ZIP 的条件、真实 PNG 1x/2x 输出、Node 文件复制及真实 ZIP/tar.gz 内容。版本发布入口仅运行 `--help`；Flutter 构建、签名、公证和 DMG 创建使用替身，没有实际发布、提交 tag 或触发系统认证。Windows/Linux 完整构建仍由各自原生 runner 验证。
- 修复 `package_macos_release_app.sh` 硬编码上游作者用户目录的问题。默认只输出 `dist/macos/`；可选 `EXTERNAL_OUTPUT_DIR` 的额外导出在含空格路径上验证通过。
- 基础 Python 3.14.8 缺少 Pillow，这是已有图像脚本的独立依赖；PNG 验收使用已有独立运行时 Python 3.12.14 / Pillow 12.3.0，没有安装全局或项目依赖。运行方法已补入 [打包脚本说明](../scripts/README.md)。

临时源码副本、npm 验证缓存、图片、归档和模拟构建产物均随临时目录删除；项目没有新增 node_modules、锁文件或发布产物。已安装应用继续为 1.7.0（build 18），项目环境重新检查时读取更新后的声明。

## 重现

```sh
mise exec -- flutter analyze --no-pub
mise exec -- flutter test --no-pub --reporter expanded
mise exec -- dart format --output=none --set-exit-if-changed lib test tool
mise exec -- dart run tool/check_project_diagnostics.dart
mise exec -- dart run tool/audit_project_environment.dart
mise exec -- dart run tool/check_environment.dart
mise exec -- dart run tool/check_projects.dart
bash scripts/build_local_macos.sh
```

剩余边界包括外部 Poetry/Conda、解释器副本、动态 Gradle／复合构建、远端 Maven parent／profiles、完整 JVM/Gradle 兼容性与构建结果；这些会继续作为待核对项，当前没有自动下载或执行验证。
