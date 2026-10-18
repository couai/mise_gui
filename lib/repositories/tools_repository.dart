import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/mise_cli_service.dart';

/// Display metadata only. Missing runtimes have no fabricated local/remote versions.
const managedRuntimeNames = {
  'java': 'Java',
  'node': 'Node.js',
  'python': 'Python',
  'go': 'Go',
  'rust': 'Rust',
  'flutter': 'Flutter / Dart',
};

class ToolsRepository {
  ToolsRepository(this._miseCliService);
  final MiseCliService _miseCliService;

  Future<List<ToolRecord>> loadTools() async {
    final tools = [...await _miseCliService.fetchTools()];
    for (final entry in managedRuntimeNames.entries) {
      if (tools.any((t) => t.id == entry.key)) continue;
      tools.add(
        ToolRecord(
          id: entry.key,
          name: entry.value,
          category: '${entry.value} 版本管理',
          description: '通过 mise 管理的运行时。',
          activeVersion: '未安装',
          requestedVersion: '',
          source: '尚未选择全局版本',
          strategy: '安装与版本选择分开',
          latestStableVersion: '待同步',
          latestPreviewVersion: '待同步',
          installedVersions: const [],
          remoteVersions: const [],
          projectImpacts: const [],
          quickActions: const [],
          commandPreview: '',
          level: HealthLevel.info,
          remoteState: ToolRemoteState.pending,
        ),
      );
    }
    return tools;
  }

  Future<ToolRecord> hydrateToolRemoteState(ToolRecord tool) =>
      _miseCliService.hydrateToolRemoteState(tool);
}
