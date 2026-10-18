# 工具维护

入口：“工具维护”（`/maintenance`）。开发工具页的“安装与维护”和目录页的“缓存维护”可直达；现有 mise 版本管理保持唯一入口。

## 能力范围

| 范围 | 实现 | 保留与限制 |
|---|---|---|
| Homebrew Formula | 安装、单包更新、卸载 | 仅原生安装记录可更新／卸载；固定版本、依赖方和多版本 keg 受到保护 |
| Homebrew Cask | 安装、单应用更新、卸载 | GUI 固定 `/Applications`，保留原生默认用户数据行为，关闭扩展清理；无安装登记的手动应用不会被接管 |
| Android SDK | 按完整组件 ID 安装、单组件更新、卸载 | 稳定频道，限定现有分类 SDK 目录；保护 SDK 启动组件和已知 AVD 引用镜像 |
| mise 运行时 | 沿用分类安装、全局／项目切换 | 不增加重复版本入口；链接式卸载仅移除 mise 登记而保留实际 SDK，因此本阶段继续保护已有 SDK 和共享 cargo/rustup |
| npm / pip / uv / Go | 原生命令定向清理分类缓存 | 保留全局包、虚拟环境、工具、Go 模块和项目产物；Go 仅清理编译缓存 |
| Xcode / 手动安装工具 | 保留已有档案和快速打开 | 在原应用、App Store 或官方安装渠道维护；没有跨管理器强制接管或通用目录删除 |

首次进入只读取 Homebrew 安装信息与 SDK `package.xml`，不执行更新或清理。Homebrew 的“可用版本”来自其自身元数据，单项预览重新查询；Android 远端组件列表只在安装／更新预览时查询。页面不会批量升级环境，也不为本功能验证改动本机已安装工具。

## 统一计划与执行

`ManagedPackageCatalog` 查询包归属和版本，`MaintenanceService.prepare()` 生成固定参数的 `MaintenancePlan`。页面仅展示命令、路径、版本和影响；点击确认后 `execute()` 在同一任务锁下重新生成计划，核对设置、安装记录、原生预览和路径是否变化。实际执行使用重新生成的命令与路径。

- `MaintenanceProcess` 使用参数数组、有限输出、流式 UTF-8 和超时，关闭标准输入，不读取密码或代为同意许可。原生安装器可能要求系统窗口或原管理器中的认证；失败保留输出与实际步骤，不强制重试。
- 所有写操作（mise、配置保存、Homebrew、Android、缓存维护、管理器设置）共用 `TaskCenter.startMutation` 保护。已完成、失败、输出和验证沿用任务中心持久化；确认前取消不会执行命令。
- 安装／更新后重新读取原生记录并核对目标版本；命令 exit 为 0 但记录不符仍判失败。卸载后确认记录消失；Android 还检查所选组件目录。原生失败可能留下部分安装状态，界面要求重新核对，不自动删除残留。
- Homebrew 更新允许保留旧 keg；验证目标版本存在，而非要求仅剩一个版本。原生成功不等于所有项目都兼容新版本，项目切换仍由用户控制。

## 管理器约束

Homebrew 使用设置中的程序与安装前缀，先以 `brew --prefix` 核对。Formula 与 Cask 显式区分；安装／更新展示原生 `--dry-run`。卸载 Formula 先查询已安装依赖方。明确关闭自动清理、自动移除、其他依赖方自动升级及 install 隐式升级；不传 `--force`、`--zap`、`--ignore-dependencies` 或接管已有文件的参数。包本身需要的依赖仍由 Homebrew 管理并在原生预览中显示。开发运行时与 mise/Xcode 本体不从此入口维护。

Android 只处理平台、构建工具、NDK、CMake、源码和系统镜像等已支持的完整 ID；从所配置 SDK 的普通 `package.xml` 读取版本，不跟随组件目录或元数据软链接。安装目录已存在但没有有效记录时保留原内容。写操作检查实际路径与 `<toolchains>/android/sdk` 一致；保留 `platform-tools`、`emulator` 和 `cmdline-tools` 的卸载保护，不执行全量 `--update`。AVD 已引用的镜像、外部／链接式或无法核对的 AVD 要在 Android Studio 中处理。其他未登记项目的依赖无法完整推断，预览明确提示卸载影响。

## 缓存范围

| 工具 | 范围（相对 toolchains） | 原生命令 |
|---|---|---|
| npm | `npm/cache` | 当前分类 Node 运行 npm CLI 的 `cache clean --force --cache <目录>` |
| pip | `pip/cache` | 当前分类 Python 的 `-m pip cache purge --cache-dir <目录>` |
| uv | `uv/cache` | 分类 uv 的 `cache clean --cache-dir <目录>` |
| Go | `go/cache` | 当前分类 Go 的 `clean -cache`，显式指定 GOCACHE |

缓存标签、手动导入的目录和任意路径不提供清理许可。环境变量指向其他分类、包目录或分类外路径时拒绝操作；复查父目录及软链接，测量后、清理前再次检查。没有递归删除通用目录的实现。Maven 仓库、Gradle 用户目录、Flutter SDK、IDE、抓包与证书数据继续保留。

清理前后使用既有磁盘测量器报告已分配占用，验证原生命令成功与目标路径保持规范；元数据可能保留，其他进程也可能补写缓存，因此不强求占用为 0，不将测量差值宣传为 APFS 实际释放空间。测量失败标为需检查。执行前应停止其他终端中的安装和构建。

## 验证与来源

普通测试使用内存管理器与隔离文件系统，覆盖原生参数、归属、依赖、固定版本、旧计划、记录验证、路径与 AVD 保护、任务锁、界面取消和确认。额外使用已安装 Python，在临时分类目录实际执行 pip purge，并验证旁边的配置保持不变。

`DEVWORKBENCH_LIVE_MAINTENANCE=1 flutter test test/maintenance_live_test.dart` 是显式本机只读验收：读取实际安装记录并生成卸载／缓存预览，不执行任何维护写操作。界面图重现见 [设计预览](design/README.md)。

原生命令依据当前本机 `--help` 和官方参考核对：[Homebrew 手册](https://docs.brew.sh/Manpage)、[Homebrew JSON 查询](https://docs.brew.sh/Querying-Brew)、[Android sdkmanager](https://developer.android.com/tools/sdkmanager)、[npm cache](https://docs.npmjs.com/cli/commands/npm-cache)、[pip cache](https://pip.pypa.io/en/stable/cli/pip_cache/)、[uv cache](https://docs.astral.sh/uv/reference/cli/#uv-cache-clean)。
