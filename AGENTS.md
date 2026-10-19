# DevWorkbench 开发约定

- 使用项目 mise.toml 固定的 Flutter；Dart 随 SDK 配套提供。
- 修改统一总览、工具识别/档案、导入或快速打开时，先读 [工具工作台约定](docs/dev-workbench.md)；总览与工具页共用 localToolsProvider，目录类型和关联策略集中在 LocalToolProfiles。
- 修改项目发现、技术栈、环境对照或项目版本固定时，先读 [项目工作台约定](docs/projects.md)；元数据仅静态读取，扫描保留完整性与失败原因，版本写入复用分类策略与任务验证。
- 修改目录扫描、空间汇总、软链接或路径规范检查时，先读 [目录与缓存约定](docs/storage.md)；测量只读，分类标签不作为清理许可。
- 修改任务、操作执行或管理器设置时，先读 [任务与设置约定](docs/tasks-settings.md)；任务由 TaskCenter 持有，管理器配置注入实际服务，写操作成功后验证实际状态。
- 修改工具安装、更新、卸载或缓存清理时，先读 [工具维护约定](docs/maintenance.md)；依据原生安装记录生成计划，确认后复查，写操作共用任务锁，缓存仅调用列明的原生命令。
- 分类目录、安装/切换策略、首期边界和验证要求见 [设计方案](docs/classified-toolchains.md)。修改工具链操作、配置路径或界面时先读该文档。
- 目录策略集中在 ToolchainLayout；页面预览和实际执行共用 ClassifiedToolchainService。运行时状态由 mise CLI 查询，其他工具使用本地程序或安装元数据。
- 版本管理只保留一个导航入口，扩展时沿用工具版本卡片和统一预览／执行流程；已安装视图与远端查询分开。
- SDK 安装与版本选择分开；已有目录拒绝覆盖，Rust 共享代理与 rustup 工具链分别处理。
- 修改操作策略后运行 flutter analyze、flutter test；实际 CLI 测试使用隔离 HOME/MISE 目录，保留用户现有默认版本。
- macOS 本地 Release 使用 bash scripts/build_local_macos.sh，包含构建及签名校验；界面预览生成方式见 docs/design/README.md。
- 保留 MIT 许可证与上游署名，upstream 指向 likaia/mise_gui，origin 指向个人 fork。
