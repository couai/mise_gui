import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/services/toolchain_layout.dart';

import 'package:mise_gui/models/app_models.dart';

abstract class ScanDirectoryService {
  Future<List<ScanDirectoryRecord>> fetchDirectories();

  Future<List<ScanDirectoryRecord>> addDirectory(String path);

  Future<List<ScanDirectoryRecord>> removeDirectory(String path);

  Future<List<ScanDirectoryRecord>> setDirectoryEnabled(
    String path,
    bool enabled,
  );
}

class LocalScanDirectoryService implements ScanDirectoryService {
  const LocalScanDirectoryService();

  @override
  Future<List<ScanDirectoryRecord>> fetchDirectories() async {
    try {
      final file = await _resolveStorageFile();
      if (!await file.exists()) {
        final fallback = _normalizeDirectories(_defaultDirectories());
        await _writeDirectories(file, fallback);
        return fallback;
      }
      final directories = await _readDirectories(file);
      final normalized = _normalizeDirectories(directories);
      if (!_sameDirectories(directories, normalized)) {
        await _writeDirectories(file, normalized);
      }
      return normalized;
    } catch (_) {
      return _normalizeDirectories(_defaultDirectories());
    }
  }

  @override
  Future<List<ScanDirectoryRecord>> addDirectory(String path) async {
    final normalized = _normalizePath(path);
    if (normalized.isEmpty) {
      return fetchDirectories();
    }

    try {
      final file = await _resolveStorageFile();
      final directories = await fetchDirectories();
      final exists = directories.any((entry) => entry.path == normalized);
      if (exists) {
        final next = _normalizeDirectories(
          directories
              .map(
                (entry) => entry.path == normalized
                    ? entry.copyWith(enabled: true)
                    : entry,
              )
              .toList(),
        );
        await _writeDirectories(file, next);
        return next;
      }

      final next = _normalizeDirectories(<ScanDirectoryRecord>[
        ...directories,
        ScanDirectoryRecord(path: normalized),
      ]);
      await _writeDirectories(file, next);
      return next;
    } catch (_) {
      return fetchDirectories();
    }
  }

  @override
  Future<List<ScanDirectoryRecord>> removeDirectory(String path) async {
    final normalized = _normalizePath(path);
    try {
      final file = await _resolveStorageFile();
      final directories = await fetchDirectories();
      final next = _normalizeDirectories(
        directories
            .where((entry) => entry.path != normalized)
            .toList(growable: false),
      );
      await _writeDirectories(file, next);
      return next;
    } catch (_) {
      return fetchDirectories();
    }
  }

  @override
  Future<List<ScanDirectoryRecord>> setDirectoryEnabled(
    String path,
    bool enabled,
  ) async {
    final normalized = _normalizePath(path);
    try {
      final file = await _resolveStorageFile();
      final directories = await fetchDirectories();
      final next = _normalizeDirectories(
        directories
            .map(
              (entry) => entry.path == normalized
                  ? entry.copyWith(enabled: enabled)
                  : entry,
            )
            .toList(growable: false),
      );
      await _writeDirectories(file, next);
      return next;
    } catch (_) {
      return fetchDirectories();
    }
  }

  Future<File> _resolveStorageFile() async {
    final home = Platform.environment['HOME'];
    final appData = Platform.environment['APPDATA'];

    if (Platform.isMacOS && home != null && home.isNotEmpty) {
      return File(
        '${ToolchainLayout.current.appDir}/config/project_scan_directories.json',
      );
    }
    if (Platform.isWindows && appData != null && appData.isNotEmpty) {
      return File('$appData\\mise_gui\\project_scan_directories.json');
    }
    if (home != null && home.isNotEmpty) {
      return File('$home/.local/state/mise_gui/project_scan_directories.json');
    }
    return File(
      '${Directory.current.path}/.mise_gui_project_scan_directories.json',
    );
  }

  Future<List<ScanDirectoryRecord>> _readDirectories(File file) async {
    if (!await file.exists()) {
      return _defaultDirectories();
    }

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) {
      return const <ScanDirectoryRecord>[];
    }

    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return _defaultDirectories();
    }

    final records = decoded
        .whereType<Map<String, dynamic>>()
        .map(_decodeRecord)
        .where((record) => record.path.isNotEmpty)
        .toList();

    return _dedupe(records);
  }

  Future<void> _writeDirectories(
    File file,
    List<ScanDirectoryRecord> directories,
  ) async {
    await file.parent.create(recursive: true);
    final encoded = directories
        .map(
          (directory) => <String, dynamic>{
            'path': directory.path,
            'enabled': directory.enabled,
          },
        )
        .toList(growable: false);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(encoded),
    );
  }

  ScanDirectoryRecord _decodeRecord(Map<String, dynamic> json) {
    return ScanDirectoryRecord(
      path: _normalizePath(json['path']?.toString() ?? ''),
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  List<ScanDirectoryRecord> _defaultDirectories() {
    final workspace = '${ToolchainLayout.current.home}/WorkSpace/code';
    final path = _normalizePath(
      Directory(workspace).existsSync() ? workspace : Directory.current.path,
    );
    if (path.isEmpty) {
      return const <ScanDirectoryRecord>[];
    }
    return [ScanDirectoryRecord(path: path)];
  }

  List<ScanDirectoryRecord> _dedupe(List<ScanDirectoryRecord> directories) {
    final deduped = <String, ScanDirectoryRecord>{};
    for (final directory in directories) {
      deduped[directory.path] = directory;
    }
    return deduped.values.toList(growable: false);
  }

  List<ScanDirectoryRecord> _normalizeDirectories(
    List<ScanDirectoryRecord> directories,
  ) {
    final deduped = _dedupe(directories);
    final sorted = deduped.toList()
      ..sort((a, b) {
        final depthCompare = _pathDepth(a.path).compareTo(_pathDepth(b.path));
        if (depthCompare != 0) {
          return depthCompare;
        }
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

    final kept = <ScanDirectoryRecord>[];
    for (final directory in sorted) {
      final coveredByEnabledAncestor = kept.any(
        (existing) =>
            existing.enabled && _containsPath(existing.path, directory.path),
      );
      if (coveredByEnabledAncestor) {
        continue;
      }

      final coveredByDisabledAncestor = kept.any(
        (existing) =>
            !existing.enabled && _containsPath(existing.path, directory.path),
      );
      if (coveredByDisabledAncestor && !directory.enabled) {
        continue;
      }

      kept.add(directory);
    }
    return kept;
  }

  bool _sameDirectories(
    List<ScanDirectoryRecord> left,
    List<ScanDirectoryRecord> right,
  ) {
    if (left.length != right.length) {
      return false;
    }
    for (var index = 0; index < left.length; index += 1) {
      final a = left[index];
      final b = right[index];
      if (a.path != b.path || a.enabled != b.enabled) {
        return false;
      }
    }
    return true;
  }

  bool _containsPath(String parent, String child) {
    final normalizedParent = _normalizeComparablePath(parent);
    final normalizedChild = _normalizeComparablePath(child);
    return normalizedChild == normalizedParent ||
        normalizedChild.startsWith('$normalizedParent/');
  }

  String _normalizeComparablePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  int _pathDepth(String path) {
    return _normalizeComparablePath(
      path,
    ).split('/').where((segment) => segment.isNotEmpty).length;
  }

  String _normalizePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return '';
    }

    final home = Platform.environment['HOME'];
    final expanded = trimmed.startsWith('~/') && home != null && home.isNotEmpty
        ? '$home/${trimmed.substring(2)}'
        : trimmed;
    var normalized = Directory(expanded).absolute.path;
    final rootPrefix = Platform.isWindows ? RegExp(r'^[A-Za-z]:/$') : null;
    while (normalized.length > 1 &&
        normalized.endsWith(Platform.pathSeparator) &&
        !(rootPrefix?.hasMatch(normalized) ?? false)) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }
}
