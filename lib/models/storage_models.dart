import 'package:mise_gui/models/local_tool.dart';

enum StorageLinkState {
  direct('普通路径'),
  linked('软链接'),
  inherited('父目录含软链接'),
  broken('链接目标不存在'),
  cycle('链接循环'),
  missing('未创建 / 已移除'),
  unavailable('无法检查');

  const StorageLinkState(this.label);
  final String label;
}

enum StorageCompliance {
  classified('符合分类目录'),
  exception('保留原生位置'),
  outside('分类目录外'),
  misplaced('分类不匹配'),
  wrongAlias('兼容路径指向异常'),
  unassigned('未关联分类');

  const StorageCompliance(this.label);
  final String label;
  bool get needsReview => this != classified && this != exception;
}

enum StorageUsageState {
  pending,
  complete,
  partial,
  failed,
  timeout,
  cancelled,
  skipped,
}

class StorageUsage {
  const StorageUsage(this.state, {this.bytes, this.note = ''});
  final StorageUsageState state;
  final int? bytes;
  final String note;
  String get label => switch (state) {
    StorageUsageState.pending => '待测量',
    StorageUsageState.complete => '已测量',
    StorageUsageState.partial => '部分可读 · 下限',
    StorageUsageState.failed => '测量失败',
    StorageUsageState.timeout => '测量超时',
    StorageUsageState.cancelled => '已取消',
    StorageUsageState.skipped => '未测量',
  };
}

class StorageOwner {
  const StorageOwner(
    this.id,
    this.name,
    this.label,
    this.kind, {
    this.imported = false,
  });
  final String id, name, label;
  final ToolLocationKind kind;
  final bool imported;
}

class StorageLinkHop {
  const StorageLinkHop(this.path, this.target);
  final String path, target;
}

class StorageEntry {
  const StorageEntry({
    required this.path,
    required this.owners,
    required this.linkState,
    required this.compliance,
    required this.policyNote,
    this.canonicalPath,
    this.links = const [],
    this.usage = const StorageUsage(StorageUsageState.pending),
    this.coveredBy,
  });
  final String path, policyNote;
  final String? canonicalPath, coveredBy;
  final List<StorageOwner> owners;
  final StorageLinkState linkState;
  final StorageCompliance compliance;
  final List<StorageLinkHop> links;
  final StorageUsage usage;
  bool get exists =>
      canonicalPath != null &&
      linkState != StorageLinkState.missing &&
      linkState != StorageLinkState.broken &&
      linkState != StorageLinkState.cycle &&
      linkState != StorageLinkState.unavailable;
  bool get needsReview =>
      compliance.needsReview ||
      const [
        StorageLinkState.broken,
        StorageLinkState.cycle,
        StorageLinkState.unavailable,
      ].contains(linkState) ||
      const [
        StorageUsageState.partial,
        StorageUsageState.failed,
        StorageUsageState.timeout,
      ].contains(usage.state);
  Set<ToolLocationKind> get kinds => owners.map((o) => o.kind).toSet();
  bool matches(String query) => [
    path,
    canonicalPath ?? '',
    ...owners.map((o) => '${o.name} ${o.label}'),
  ].join(' ').toLowerCase().contains(query.toLowerCase().trim());
  StorageEntry measured(StorageUsage value, {String? coveredBy}) =>
      StorageEntry(
        path: path,
        owners: owners,
        canonicalPath: canonicalPath,
        linkState: linkState,
        compliance: compliance,
        policyNote: policyNote,
        links: links,
        usage: value,
        coveredBy: coveredBy,
      );
}

class StorageSnapshot {
  const StorageSnapshot({
    required this.entries,
    required this.scannedAt,
    this.scanning = false,
    this.cancelled = false,
    this.completed = 0,
    this.total = 0,
    this.warnings = const [],
  });
  final List<StorageEntry> entries;
  final DateTime scannedAt;
  final bool scanning, cancelled;
  final int completed, total;
  final List<String> warnings;
  List<StorageEntry> get roots => storageRoots(
    entries.where(
      (e) => e.exists && e.usage.state != StorageUsageState.skipped,
    ),
  );
  int get measuredBytes =>
      roots.fold(0, (sum, e) => sum + (e.usage.bytes ?? 0));
  int get cacheBytes => storageRoots(
    entries.where(
      (e) =>
          e.exists &&
          e.kinds.contains(ToolLocationKind.cache) &&
          e.usage.state != StorageUsageState.skipped,
    ),
  ).fold(0, (sum, e) => sum + (e.usage.bytes ?? 0));
  bool get complete =>
      !scanning &&
      !cancelled &&
      !entries.any((e) => e.linkState == StorageLinkState.unavailable) &&
      roots.every((e) => e.usage.state == StorageUsageState.complete);
}

bool storageContains(String root, String path) =>
    path == root || path.startsWith(root == '/' ? '/' : '$root/');

/// Root/child containment and identical resolved targets are deduplicated.
/// Hardlinks across separate roots and APFS shared extents remain filesystem-specific.
List<StorageEntry> storageRoots(Iterable<StorageEntry> entries) {
  final sorted = entries.where((e) => e.canonicalPath != null).toList()
    ..sort((a, b) {
      final order = a.canonicalPath!.length.compareTo(b.canonicalPath!.length);
      if (order != 0) return order;
      if (a.path == a.canonicalPath && b.path != b.canonicalPath) return -1;
      if (b.path == b.canonicalPath && a.path != a.canonicalPath) return 1;
      return a.path.compareTo(b.path);
    });
  final roots = <StorageEntry>[];
  for (final entry in sorted) {
    if (!roots.any(
      (root) => storageContains(root.canonicalPath!, entry.canonicalPath!),
    )) {
      roots.add(entry);
    }
  }
  return roots;
}

String formatStorageBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var i = 0;
  while (value >= 1024 && i < units.length - 1) {
    value /= 1024;
    i++;
  }
  return '${value.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}
