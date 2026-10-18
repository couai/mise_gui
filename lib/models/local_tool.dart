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

enum ToolLocationKind {
  installation('安装与命令'),
  configuration('配置与数据'),
  cache('缓存'),
  logs('日志'),
  other('其他位置');

  const ToolLocationKind(this.label);
  final String label;
}

class ToolLocation {
  const ToolLocation({
    required this.label,
    required this.path,
    required this.exists,
    this.application = false,
    this.kind = ToolLocationKind.other,
  });
  final String label, path;
  final bool exists, application;
  final ToolLocationKind kind;
}

class LocalToolRelation {
  const LocalToolRelation(this.toolId, this.reason);
  final String toolId, reason;
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
    this.relations = const [],
    this.imported = false,
  });
  final String id, name, description, manager, source;
  final String? version, executable, miseTool, iconPath;
  final LocalToolCategory category;
  final LocalToolStatus status;
  final List<LocalToolVersion> versions;
  final List<ToolLocation> locations;
  final List<String> notes;
  final List<LocalToolRelation> relations;
  final bool imported;
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
    ...relations.map((r) => r.reason),
  ].join(' ').toLowerCase().contains(query.trim().toLowerCase());

  LocalTool withProfile({
    required List<ToolLocation> locations,
    required List<LocalToolRelation> relations,
  }) => LocalTool(
    id: id,
    name: name,
    category: category,
    description: description,
    status: status,
    manager: manager,
    source: source,
    version: version,
    executable: executable,
    versions: versions,
    locations: locations,
    notes: notes,
    miseTool: miseTool,
    iconPath: iconPath,
    imported: imported,
    relations: relations,
  );
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

  int get installedCount => tools.where((t) => t.installed).length;
  int get attentionCount => tools
      .where(
        (t) =>
            t.status == LocalToolStatus.attention ||
            t.status == LocalToolStatus.unavailable,
      )
      .length;
  int get missingCount =>
      tools.where((t) => t.status == LocalToolStatus.missing).length;
  int get miseCount =>
      tools.where((t) => t.installed && t.miseTool != null).length;
  LocalTool? tool(String id) => tools.where((t) => t.id == id).firstOrNull;
}
