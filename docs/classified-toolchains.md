# 分类工具链适配设计

## 目标与边界

在上游 Mise GUI 上增加分类工具链管理，继续以真实 mise CLI 状态为依据。首期覆盖 Java、Node.js、Python、Go、Rust、Flutter；Dart 跟随 Flutter。保留已安装 SDK、别名、全局默认版本和项目配置，不在首次启动时迁移目录。

本项目使用当前 Flutter 3.47.7 / Dart 3.13.5。GUI 最终部署到 `/Applications`；应用自身配置、状态、日志归入 `$HOME/Developer/toolchains/mise-gui/`。项目代码、构建产物留在项目内。

## 信息架构

- 分类工具链：已安装版本、当前全局默认、真实路径、mise 注册路径、目录符合性；进入版本详情后选择全局或指定项目。
- 工具版本：沿用上游远端版本浏览，操作接入分类安装策略。
- 项目覆盖：沿用项目扫描；增加对 Rust 工具链文件的识别。
- 配置管理：沿用差异预览；解析有效的 mise 配置目录，保留未知 TOML 段和 HTTP backend 配置。

此 fork 不提供 GUI 自身或 mise CLI 本体的更新检测与升级入口；二者由用户在应用外维护。开发工具的远端版本查询、分类安装和版本切换继续保留。

新页面强调两个不同事实：磁盘上安装了哪些版本，以及某个作用域选择了哪个版本。查询失败显示错误，不展示示例数据作为本机状态。

## 数据与操作分层

`页面 → 分类工具链服务 → 安装/切换计划 → mise / rustup`

目录规则集中定义，不散落在按钮中。数据从 `mise ls --json` 获取；SDK 路径使用文件系统解析软链接，不能把 mise JSON 的 `symlinked_to` 字段直接当成真实路径。环境来自登录 Shell；显式支持 `MISE_CONFIG_DIR`、`MISE_DATA_DIR`、`MISE_CACHE_DIR`、`MISE_STATE_DIR`。

| 工具 | 新版本目标目录 | 安装机制 |
|---|---|---|
| Java | `jdk/versions/<精确版本>` | mise install-into，再 link；识别 SDK Home |
| Node.js | `nodejs/versions/<精确版本>` | mise install-into，再 link |
| Python | `python/versions/<精确版本>` | mise install-into，再 link |
| Go | `go/versions/<精确版本>` | mise install-into，再 link |
| Flutter | `flutter/versions/<精确版本>` | mise install-into，再 link；Dart 配套提供 |
| Rust | `rust/rustup/`、`rust/cargo/` | rustup 管理真实工具链；mise 负责选择 |

已有 `python/default`、JDK `.app/Contents/Home` 等布局只做识别，不重命名。包管理器和缓存保留现有环境变量。

## 操作流程

安装：选择精确版本 → 展示目标目录和实际命令 → 检查目标不存在、路径在分类根目录内 → 安装 → 注册 → 刷新。安装本身不自动改变全局默认。目标已存在时拒绝覆盖；失败保留可诊断状态，不删除不明确归属的数据，也不自动删除其他终端可能持有的 mise 锁文件。单条安装操作超时为 30 分钟。

切换：选择已安装版本 → 选择全局或项目路径 → 预览 → 使用 mise 写入该作用域 → 刷新并查询实际生效版本。明确指定项目配置，避免桌面进程工作目录影响写入。切换不隐式下载缺失版本。

Rust：设置已有的 RUSTUP_HOME/CARGO_HOME；安装采用 rustup，选择采用 mise。禁止把共享 cargo/bin 当成某个版本的独立 SDK 删除。

卸载：首期对分类 SDK 提供路径展示和保护提示；不开放跨项目批量删除。mise 原有安装与升级入口必须经过分类策略或拒绝不支持的操作，避免绕过规范。

## 界面思路

运行时使用官方图标，素材与来源统一维护在 `assets/toolchains/`，界面统一通过 ToolLogo 显示，保留原始比例与颜色。Java 使用 OpenJDK Duke，Go 使用官方 Gopher；Flutter、Dart、Python、Node.js、Rust 使用各自官方标识。

延续上游深色主题，使用绿色标记正常状态，蓝色标记作用域。首屏为分类根目录、已识别运行时和版本列表；右侧或下方展示所选版本的实际目录和操作。明确标记“全局默认”“已安装”“共享工具链”，不以绿色暗示所有项目都使用同一版本。

界面预览位于 `docs/design/`。设计稿使用环境快照，实际应用以运行时查询为准。

## 验证要求

- 安装计划不会写回 mise 默认安装目录；目标存在、目录穿越和浮动版本被拒绝。
- 分类路径、软链接解析、Rust 共享目录和 Flutter/Dart 配套识别有测试。
- 全局和项目切换预览明确，缺失版本不会触发安装。
- 保留上游测试并运行 flutter analyze、flutter test、macOS 构建。
- 在隔离 mise 配置和临时目录验证实际注册/切换，不为测试修改用户默认版本。

后续再扩展 Android SDK、Xcode、缓存体积统计和更新通知；它们不属于首期运行时安装适配。
