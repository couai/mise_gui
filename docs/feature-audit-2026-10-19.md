# DevWorkbench 功能验收与后续优先级

验收对象：源码 `7031f71`、`/Applications/DevWorkbench.app` 1.6.0（build 16），macOS ARM64。依据已选择的“工具工作台”样例、五阶段实施记录及各模块约定核对。样例中的演示数据不作为当前机器状态。

结论：五阶段的首版范围已落地，但不能等同于所有开发工具、项目环境均已完整管理。本轮常规回归通过，额外验收复现三类逻辑错误，应先发布稳定性修复，再扩展功能。

## 规划完成情况

| 阶段 | 当前状态 | 现有能力 | 边界与尚未实现 |
|---|---|---|---|
| 1. 统一总览与工具档案 | 首版完成 | 六类工具识别、共享清单、工具详情与关联、手动导入、官方图标、快速打开 | 内置目录支持 46 项；导入 CLI 不执行自定义程序探测版本。不是全盘任意软件资产扫描；常用工具收藏／自定义启动配置未实现 |
| 2. 目录与缓存 | 首版完成 | 实际已分配占用、归属、去重、软链接链路、异常路径、筛选、快速打开、停止／刷新 | 目录自动迁移、软链接自动修复未实现；缓存维护只开放明确的四类原生范围，Maven／Gradle／IDE／证书和抓包等混合目录不提供通用删除 |
| 3. 任务中心与管理器设置 | 首版完成 | 步骤、输出、退出码、验证、持久化、中断标记、写操作锁；mise／Homebrew／Android／Xcode 路径与选项 | 只有目录扫描支持停止；安装任务取消、自动重试、跨重启恢复执行、日志导出未实现。这些是后续扩展，不是现有任务记录失效 |
| 4. 工具维护 | 约定范围完成，覆盖有限 | Homebrew Formula／Cask、Android 组件的原生单项维护；npm／pip／uv／Go 编译缓存定向清理；确认、复查、任务和结果验证 | mise SDK 的实际卸载、批量升级、手动安装工具自动维护、Apple／模拟器安装管理未开放。现有 SDK、共享 rustup、手动应用继续保护；不是每个工具都能从工作台安装／更新／卸载 |
| 5. 项目工作台 | 基础完成，诊断待完善 | manifest／版本文件发现、技术栈、声明与实际 mise 环境对照、固定已安装项目 SDK、IDE／终端／集合目录入口、复制已声明脚本 | Corepack／项目包管理器、Python venv／Poetry、复杂约束、多模块继承及完整构建验证尚未实现；未提供项目脚本执行、依赖自动安装或 Bruno 自动导入。发现下列判断错误 |

唯一的“mise 版本管理”入口、分类安装和全局／项目作用域分离均保留。GUI 与 mise 本体升级入口按既有决定移除，不计为待恢复功能。各阶段细则分别见 [工作台](dev-workbench.md)、[目录](storage.md)、[任务](tasks-settings.md)、[维护](maintenance.md)、[项目](projects.md)。

## 本轮测试结果

| 检查 | 结果与口径 |
|---|---|
| 静态分析 | `flutter analyze --no-pub` 通过 |
| 常规自动化 | `flutter test --no-pub --reporter expanded`：191 通过、2 个显式本机验收跳过；包括服务、隔离写入和 Flutter 界面流程 |
| 格式 | `dart format --output=none --set-exit-if-changed lib test tool` 通过 |
| 实际管理器 | mise 2026.10.8、Homebrew 7.0.9、Android 管理器 1.0.16500706、Xcode 27.1 均返回版本，四项通过；任务保存在内存，不保存实际管理器配置或任务记录 |
| 原生维护验收 | 显式运行 `DEVWORKBENCH_LIVE_MAINTENANCE=1 flutter test test/maintenance_live_test.dart`：1 项通过；识别 76 个归属安装记录，生成 wget 卸载和四类缓存计划，未执行维护 |
| 本地工具 | 45/46 项识别；旧独立 Simulator.app 未识别，Device Hub 可用。不是缺少模拟器运行时 |
| 分类 SDK | 六类运行时、8 个已安装 SDK 仍符合分类目录，全局默认选择保持一致 |
| 项目实际环境 | DevWorkbench 的 Flutter 3.47.7、配套 Dart 3.13.5、Node.js 24.21.0 均识别；npm 11.19.0 是本机探测值，保留项目专用配置待核对 |
| 目录实际扫描 | 225 个登记路径、183/183 个测量目标、37 个含链接路径；约 76.5 GiB 已分配占用，其中已声明缓存约 18.3 GiB，约 23 秒；18 项分类外 IDE 路径待核对。不是 APFS 可释放空间承诺 |
| 已安装应用 | 1.6.0+16 进程在运行；`codesign --verify --deep --strict` 通过 |
| 补充预期验收 | `dart run tool/audit_project_environment.dart`：6 个断言失败，对应下面 3 类逻辑错误；另观察到扫描截断无完整性标记 |

本轮没有对用户环境执行真实安装、卸载、SDK 切换、项目依赖安装或缓存删除。写操作语义由既有隔离测试验证；不能把常规测试通过表述为所有真实下载、系统认证或人工 GUI 操作都已端到端验收。已安装版本的签名与进程检查不替代按钮交互测试，交互证据来自 Flutter 界面测试。

## 已复现的逻辑错误

### A1：Java 旧版本转换影响 Go 与 Rust（优先修复）

位置：`lib/services/project_environment_service.dart` 的 `satisfies()`，约第 160 行。`1.8 → 8` 转换没有限定工具为 Java，也把 `1.85.0` 这样的版本前缀改写。

| 输入 | 正确预期 | 1.6.0 实际 |
|---|---|---|
| Rust 1.85.0，要求最低 1.90 | 不符合 | 符合 |
| Rust 1.99.0，要求最低 1.85 | 符合 | 不符合 |
| Go 1.27.2，要求最低 1.8 | 符合 | 不符合 |
| Oracle Java 8.0.503，要求最低 1.8 | 符合 | 符合（控制用例） |

修复方向：按语言规范化版本；Java 旧编号转换限定合法边界；为 Go、Rust 保留完整数字序列。增加跨语言矩阵，不能只测试本机当前版本。

### A2：项目覆盖使用旧 TOML 字符串解析，注释成为版本号

位置：`lib/services/project_scan_service.dart` 的 `_parseAssignments()`，约第 520 行。

全局 `node = "24.21.0"`，项目 `node = "24.21.0" # project comment`。实际项目版本被读成 `24.21.0 # project comment`，继而误报覆盖全局。新项目档案使用正式 TOML 解析，旧覆盖列表仍使用删引号的文本解析，两处结论会不一致。

修复方向：统一 TOML 语义与来源解析，保留注释不影响值；补单引号、行尾注释、inline table、嵌套 version 和全局／项目同值用例。需要按实际作用域判定，不直接比较原始文本。

### A3：探测失败被判为缺少工具

位置：`lib/services/project_environment_service.dart` 的缺项分支，约第 99 行。

本机工具清单中 uv 的状态为 `unavailable`（探测失败）、没有版本时，项目检查输出 `missing`。无法读取与确认不存在是不同事实，此时应为待核对。可能使用户误以为必须重新安装。

修复方向：保留 `missing`／`unavailable`／`attention` 的证据区别；未知版本不能被折叠成未安装，新增超时、权限和缺少程序的不同预期。

## 其他待完善项

1. **项目扫描完整性**：达到深度、240 目录／80 项目上限，或根目录读取失败时，返回模型缺少完整性与错误摘要。隔离验收以 3 个项目、上限 1 复现：只返回 1 个且记录仍为 healthy。需要给用户显示“部分扫描／已截断”，避免把结果当成完整清单。
2. **来源与文案**：项目扫描的全局来源识别仍硬编码 `/.config/mise/`，对当前分类配置路径显示“解析结果”；管理器 Homebrew 卡片仍写“安装和更新将在后续阶段接入”；空项目提示仍写“未发现 mise 项目”。实际功能已扩展，需要同步表述。
3. **环境说明缓存过时**：本轮实际 Xcode／Device Hub 已为 27.1，全局 AGENTS.md 仍记录 27.0。这是环境说明待同步，不是本轮执行升级。iOS SDK／模拟器版本应另行核实后再更新，不能随 Xcode 数字推断。
4. **真实维护写入验收范围**：现有大型 SDK 下载、系统安装认证、手动应用维护没有在本轮对用户环境重复操作；后续适合增加独立沙盒或可回收测试项目，形成可重复的端到端验收，而非为了测试重装现有环境。

## 下一步顺序

**先做 1.6.1 稳定性修复。** 完成 A1–A3、扫描完整性与失败提示、过时文案／来源标签，补普通回归测试；使额外验收脚本退出码为 0，再运行全套测试、隔离 mise 操作、实际只读验收、macOS 构建与安装验证。同步全局／项目说明，保留当前 SDK、默认版本和项目依赖。

随后做项目环境诊断增强：优先核对项目实际 Node 包管理器与 Python 虚拟环境、Java／Gradle 多模块声明；按用户选择进行项目级验证。再考虑更多原生维护适配与目录迁移方案，最后考虑通用任务取消／重试等能力。不优先增加新的重复导航页面或全面批量升级。

## 重现

```sh
mise exec -- flutter analyze --no-pub
mise exec -- flutter test --no-pub --reporter expanded
DEVWORKBENCH_LIVE_MAINTENANCE=1 mise exec -- flutter test --no-pub test/maintenance_live_test.dart
mise exec -- dart run tool/check_environment.dart
mise exec -- dart run tool/check_local_tools.dart
mise exec -- dart run tool/check_projects.dart
mise exec -- dart run tool/check_storage.dart
mise exec -- dart run tool/audit_project_environment.dart
```

最后一项在已知错误修复前应退出 1；它使用真实服务函数与隔离夹具，保留可复验的失败信号，不修改用户配置。报告和验收脚本的加入不改变已安装应用或运行时逻辑。
