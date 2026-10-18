# DevWorkbench 开发约定

- 使用项目 mise.toml 固定的 Flutter；Dart 随 SDK 配套提供。
- 修改本地识别、分类、详情、快速打开或应用命名时，先读 [工具工作台约定](docs/dev-workbench.md)；识别证据与命令执行分别集中在 LocalToolInventory、LocalToolProcess / LocalToolOpener。
- 分类目录、安装/切换策略、首期边界和验证要求见 [设计方案](docs/classified-toolchains.md)。修改工具链操作、配置路径或界面时先读该文档。
- 目录策略集中在 ToolchainLayout；页面预览和实际执行共用 ClassifiedToolchainService。运行时状态由 mise CLI 查询，其他工具使用本地程序或安装元数据。
- SDK 安装与版本选择分开；已有目录拒绝覆盖，Rust 共享代理与 rustup 工具链分别处理。
- 修改操作策略后运行 flutter analyze、flutter test；实际 CLI 测试使用隔离 HOME/MISE 目录，保留用户现有默认版本。
- macOS 本地 Release 使用 bash scripts/build_local_macos.sh，包含构建及签名校验；界面预览生成方式见 docs/design/README.md。
- 保留 MIT 许可证与上游署名，upstream 指向 likaia/mise_gui，origin 指向个人 fork。
