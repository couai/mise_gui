enum LocalToolCategory {
  runtime('语言运行时'),
  build('构建与包管理'),
  mobile('移动开发'),
  network('API 与网络调试'),
  editor('IDE 与编辑器'),
  utility('开发辅助');

  const LocalToolCategory(this.label);
  final String label;
}

enum LocalToolStatus { ready, attention, missing, unavailable }

class ToolLocation {
  const ToolLocation({
    required this.label,
    required this.path,
    required this.exists,
    this.application = false,
  });
  final String label, path;
  final bool exists, application;
}

class LocalToolVersion {
  const LocalToolVersion(this.version, this.path, {this.active = false});
  final String version, path;
  final bool active;
}

class LocalTool {
  const LocalTool({
    required this.id,
    required this.name,
    required this.category,
    required this.description,
    required this.status,
    required this.manager,
    required this.source,
    this.version,
    this.executable,
    this.versions = const [],
    this.locations = const [],
    this.notes = const [],
    this.miseTool,
    this.iconPath,
  });
  final String id, name, description, manager, source;
  final String? version, executable, miseTool, iconPath;
  final LocalToolCategory category;
  final LocalToolStatus status;
  final List<LocalToolVersion> versions;
  final List<ToolLocation> locations;
  final List<String> notes;
  bool get installed =>
      status == LocalToolStatus.ready || status == LocalToolStatus.attention;

  String get statusLabel => switch (status) {
    LocalToolStatus.ready => '可用',
    LocalToolStatus.attention => '需检查',
    LocalToolStatus.missing => '未检测到',
    LocalToolStatus.unavailable => '检查失败',
  };

  bool matches(String query) => [
    name,
    description,
    manager,
    source,
    category.label,
    executable ?? '',
    ...locations.map((p) => p.path),
  ].join(' ').toLowerCase().contains(query.trim().toLowerCase());
}

class LocalToolSnapshot {
  const LocalToolSnapshot({
    required this.tools,
    required this.scannedAt,
    this.warnings = const [],
  });
  final List<LocalTool> tools;
  final DateTime scannedAt;
  final List<String> warnings;
}
