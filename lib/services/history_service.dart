import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/services/toolchain_layout.dart';

import 'package:mise_gui/models/app_models.dart';

abstract class HistoryService {
  Future<List<HistoryEntry>> fetchHistory();

  Future<void> appendEntry(HistoryEntry entry);
}

class LocalHistoryService implements HistoryService {
  const LocalHistoryService({this.maxEntries = 40});
  final int maxEntries;

  @override
  Future<void> appendEntry(HistoryEntry entry) async {
    try {
      final historyFile = await _resolveHistoryFile();
      await historyFile.parent.create(recursive: true);

      final entries = await _readEntries(historyFile);
      final nextEntries = <HistoryEntry>[
        entry,
        ...entries,
      ].take(maxEntries).toList();
      final encoded = nextEntries.map(_encodeEntry).toList();
      await historyFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(encoded),
      );
    } catch (_) {
      // Keep history best-effort so UI actions are not blocked by persistence.
    }
  }

  @override
  Future<List<HistoryEntry>> fetchHistory() async {
    try {
      final historyFile = await _resolveHistoryFile();
      if (!await historyFile.exists()) {
        return const <HistoryEntry>[];
      }

      final entries = await _readEntries(historyFile);
      if (entries.isEmpty) {
        return const <HistoryEntry>[];
      }
      return entries;
    } catch (_) {
      return const <HistoryEntry>[];
    }
  }

  Future<File> _resolveHistoryFile() async {
    final home = Platform.environment['HOME'];
    final appData = Platform.environment['APPDATA'];

    if (Platform.isMacOS && home != null && home.isNotEmpty) {
      return File('${ToolchainLayout.current.appDir}/state/gui_history.json');
    }
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return File('$appData\\mise_gui\\gui_history.json');
    }
    if (home != null && home.isNotEmpty) {
      return File('$home/.local/state/mise_gui/gui_history.json');
    }
    return File('${Directory.current.path}/.mise_gui_history.json');
  }

  Future<List<HistoryEntry>> _readEntries(File file) async {
    if (!await file.exists()) {
      return const <HistoryEntry>[];
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const <HistoryEntry>[];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return const <HistoryEntry>[];
    }

    return decoded.whereType<Map<String, dynamic>>().map(_decodeEntry).toList();
  }

  Map<String, dynamic> _encodeEntry(HistoryEntry entry) {
    return <String, dynamic>{
      'command': entry.command,
      'timestamp': entry.timestamp,
      'detail': entry.detail,
      'level': entry.level.name,
      'status': entry.status.name,
      'exitCode': entry.exitCode,
      'durationMs': entry.durationMs,
      'stdout': entry.stdout,
      'stderr': entry.stderr,
      'stdoutSnippet': entry.stdoutSnippet,
      'stderrSnippet': entry.stderrSnippet,
    };
  }

  HistoryEntry _decodeEntry(Map<String, dynamic> json) {
    final levelName = json['level']?.toString();
    final level = HealthLevel.values.firstWhere(
      (candidate) => candidate.name == levelName,
      orElse: () => HealthLevel.info,
    );
    final statusName = json['status']?.toString();
    final status = HistoryStatus.values.firstWhere(
      (candidate) => candidate.name == statusName,
      orElse: () => HistoryStatus.success,
    );

    return HistoryEntry(
      command: json['command']?.toString() ?? '',
      timestamp: json['timestamp']?.toString() ?? '--:--',
      detail: json['detail']?.toString() ?? '',
      level: level,
      status: status,
      exitCode: json['exitCode'] is int
          ? json['exitCode'] as int
          : int.tryParse(json['exitCode']?.toString() ?? ''),
      durationMs: json['durationMs'] is int
          ? json['durationMs'] as int
          : int.tryParse(json['durationMs']?.toString() ?? ''),
      stdout: json['stdout']?.toString(),
      stderr: json['stderr']?.toString(),
      stdoutSnippet: json['stdoutSnippet']?.toString(),
      stderrSnippet: json['stderrSnippet']?.toString(),
    );
  }
}

class MockHistoryService implements HistoryService {
  const MockHistoryService();

  @override
  Future<List<HistoryEntry>> fetchHistory() async {
    await Future<void>.delayed(const Duration(milliseconds: 100));

    return const [
      HistoryEntry(
        command: 'mise install node@20.16.0',
        timestamp: '09:14',
        detail: '成功安装并写入全局激活版本。',
        level: HealthLevel.healthy,
        status: HistoryStatus.success,
      ),
      HistoryEntry(
        command: 'mise use python@3.11.9',
        timestamp: '08:56',
        detail: '项目级版本覆盖了全局 Python 3.12.4。',
        level: HealthLevel.info,
        status: HistoryStatus.success,
      ),
      HistoryEntry(
        command: 'mise doctor',
        timestamp: '08:41',
        detail: '检测到 PATH 顺序存在潜在冲突。',
        level: HealthLevel.warning,
        status: HistoryStatus.failure,
        exitCode: 1,
      ),
      HistoryEntry(
        command: 'mise settings set java.vendor temurin',
        timestamp: '08:03',
        detail: 'Java 发行版已更新，但历史项目仍保留 Zulu 17。',
        level: HealthLevel.info,
        status: HistoryStatus.success,
      ),
    ];
  }

  @override
  Future<void> appendEntry(HistoryEntry entry) async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
