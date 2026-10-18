import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/directory_storage_service.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class UsageReader implements DirectoryUsageReader {
  final calls = <String>[];
  final results = <String, StorageUsage>{};
  int active = 0, peak = 0;
  @override
  Future<StorageUsage> measure(
    String path,
    DirectoryScanCancellation cancellation,
  ) async {
    calls.add(path);
    active++;
    if (active > peak) peak = active;
    await Future<void>.delayed(const Duration(milliseconds: 1));
    active--;
    return cancellation.cancelled
        ? const StorageUsage(StorageUsageState.cancelled)
        : results[path] ??
              const StorageUsage(StorageUsageState.complete, bytes: 4096);
  }
}

void main() {
  late Directory temp;
  late ToolchainLayout layout;
  late UsageReader reader;
  late DirectoryStorageService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('devworkbench-storage-test-');
    layout = ToolchainLayout(home: temp.path);
    await Directory(layout.root).create(recursive: true);
    reader = UsageReader();
    service = DirectoryStorageService(layout: layout, reader: reader);
  });
  tearDown(() async => temp.delete(recursive: true));
  LocalTool tool(
    String id,
    List<ToolLocation> paths, {
    bool imported = false,
  }) => LocalTool(
    id: id,
    name: id,
    category: LocalToolCategory.build,
    description: '',
    status: LocalToolStatus.ready,
    manager: 'local',
    source: '',
    locations: paths,
    imported: imported,
  );
  ToolLocation location(
    String path, {
    ToolLocationKind kind = ToolLocationKind.cache,
  }) => ToolLocation(label: '测试路径', path: path, exists: true, kind: kind);
  Future<StorageSnapshot> scan(
    List<LocalTool> tools, {
    DirectoryScanCancellation? token,
  }) async => service
      .scan(
        LocalToolSnapshot(tools: tools, scannedAt: DateTime(2026)),
        token ?? DirectoryScanCancellation(),
      )
      .last;
  Future<String> dir(String path) async {
    await Directory(path).create(recursive: true);
    return path;
  }

  StorageEntry entry(StorageSnapshot s, String path) =>
      s.entries.singleWhere((e) => e.path == path);

  test(
    'root, children, duplicate owners and aliases share measurements without inflating aggregates',
    () async {
      final cache = await dir('${layout.root}/go/cache');
      final alias = '${temp.path}/alias';
      await Link(alias).create(cache);
      final external = await dir('${temp.path}/outside');
      reader.results[await Directory(layout.root).resolveSymbolicLinks()] =
          const StorageUsage(StorageUsageState.complete, bytes: 10000);
      reader.results[await Directory(cache).resolveSymbolicLinks()] =
          const StorageUsage(StorageUsageState.complete, bytes: 2000);
      reader.results[await Directory(external).resolveSymbolicLinks()] =
          const StorageUsage(StorageUsageState.complete, bytes: 3000);
      final s = await scan([
        tool('go', [location(cache), location(alias)]),
        tool('gopls', [location(cache)]),
        tool('custom', [location(external)], imported: true),
      ]);
      expect(s.measuredBytes, 13000);
      expect(s.cacheBytes, 5000);
      expect(entry(s, cache).owners.length, 2);
      expect(entry(s, alias).usage.bytes, 2000);
      expect(entry(s, alias).coveredBy, layout.root);
      expect(reader.calls.length, reader.calls.toSet().length);
      expect(reader.peak, lessThanOrEqualTo(2));
    },
  );

  test(
    'relative links and inherited links resolve; absent children are not broken aliases',
    () async {
      final real = await dir('${layout.root}/go/real');
      await File('$real/file').writeAsString('payload');
      final link = '${layout.root}/go/alias';
      await Link(link).create('real');
      final s = await scan([
        tool('go', [
          location(link),
          location('$link/file'),
          location('$link/absent'),
        ]),
      ]);
      expect(
        entry(s, link).canonicalPath,
        await Directory(real).resolveSymbolicLinks(),
      );
      expect(entry(s, link).linkState, StorageLinkState.linked);
      expect(entry(s, '$link/file').linkState, StorageLinkState.inherited);
      expect(entry(s, '$link/absent').linkState, StorageLinkState.missing);
    },
  );

  test(
    'broken and cyclic links retain diagnostic entries and are never measured as zero',
    () async {
      final broken = '${layout.root}/go/broken',
          cycle = '${layout.root}/go/cycle';
      await Directory('${layout.root}/go').create();
      await Link(broken).create('absent');
      await Link(cycle).create('cycle');
      final s = await scan([
        tool('go', [location(broken), location(cycle)]),
      ]);
      expect(entry(s, broken).linkState, StorageLinkState.broken);
      expect(entry(s, cycle).linkState, StorageLinkState.cycle);
      expect(entry(s, cycle).needsReview, isTrue);
      expect(entry(s, broken).usage.bytes, isNull);
      expect(reader.calls, isNot(contains(cycle)));
    },
  );

  test(
    'compatibility paths validate their exact target and distinguish wrong categories and external installs',
    () async {
      final wrong = await dir('${layout.root}/go/wrong');
      await Link('${temp.path}/.m2').create(wrong);
      final misplaced = await dir('${layout.root}/python/not-go');
      final external = await dir('${temp.path}/outside');
      final s = await scan([
        tool('go', [location(misplaced), location(external)]),
      ]);
      expect(
        entry(s, '${temp.path}/.m2').compliance,
        StorageCompliance.wrongAlias,
      );
      expect(entry(s, misplaced).compliance, StorageCompliance.misplaced);
      expect(entry(s, external).compliance, StorageCompliance.outside);
      expect(entry(s, external).needsReview, isTrue);
    },
  );

  test(
    'valid aliases, system/Homebrew apps and retained Apple data have explicit policies',
    () async {
      final target = await dir('${layout.root}/.m2');
      await Link('${temp.path}/.m2').create(target);
      final app = await dir('${temp.path}/Applications/Example.app');
      final brew = await dir('${temp.path}/brew/bin');
      final apple = await dir(
        '${temp.path}/Library/Developer/CoreSimulator/Devices',
      );
      service = DirectoryStorageService(
        layout: layout,
        reader: reader,
        applications: '${temp.path}/Applications',
        homebrew: '${temp.path}/brew',
      );
      final s = await scan([
        tool('custom', [location(app), location(brew), location(apple)]),
      ]);
      expect(
        entry(s, '${temp.path}/.m2').compliance,
        StorageCompliance.classified,
      );
      for (final path in [app, brew, apple]) {
        expect(entry(s, path).compliance, StorageCompliance.exception);
      }
      expect(entry(s, app).needsReview, isFalse);
    },
  );

  test(
    'runtime-bundled npm and pip are valid installation locations',
    () async {
      final npm = await dir(
        '${layout.root}/nodejs/versions/24/lib/node_modules/npm',
      );
      final pip = await dir('${layout.root}/python/default/bin');
      final s = await scan([
        tool('npm', [location(npm)]),
        tool('pip', [location(pip)]),
      ]);
      expect(entry(s, npm).compliance, StorageCompliance.classified);
      expect(entry(s, pip).compliance, StorageCompliance.classified);
    },
  );

  test(
    'unknown root entries are visible and assigned paths merge existing ownership',
    () async {
      final unknown = await dir('${layout.root}/old-installers');
      final go = await dir('${layout.root}/go');
      final s = await scan([
        tool('go', [location(go)]),
      ]);
      expect(entry(s, unknown).compliance, StorageCompliance.unassigned);
      expect(entry(s, go).owners.every((o) => o.id == 'go'), isTrue);
      expect(s.entries.map((e) => e.path).toSet().length, s.entries.length);
    },
  );

  test(
    'custom imported directories retain ownership instead of being marked unassigned',
    () async {
      final folder = await dir('${layout.root}/custom-cli/bin');
      final s = await scan([
        tool('imported-1', [location(folder)], imported: true),
      ]);
      final parent = entry(s, '${layout.root}/custom-cli');
      expect(parent.owners.single.id, 'imported-1');
      expect(parent.compliance, StorageCompliance.classified);
    },
  );

  test(
    'partial results and timeouts remain unknown or lower bounds, never successful zeroes',
    () async {
      final root = await Directory(layout.root).resolveSymbolicLinks();
      reader.results[root] = const StorageUsage(
        StorageUsageState.partial,
        bytes: 1024,
        note: 'partial',
      );
      final cache = await dir('${layout.root}/go/cache');
      reader.results[await Directory(cache).resolveSymbolicLinks()] =
          const StorageUsage(StorageUsageState.timeout);
      final s = await scan([
        tool('go', [location(cache)]),
      ]);
      expect(s.complete, isFalse);
      expect(s.measuredBytes, 1024);
      expect(entry(s, cache).usage.bytes, isNull);
      expect(entry(s, cache).needsReview, isTrue);
    },
  );

  test(
    'cancellation stops queued work, preserves completed usage and marks remaining work cancelled',
    () async {
      final dirs = [
        for (var i = 0; i < 8; i++) await dir('${layout.root}/go/$i'),
      ];
      final token = DirectoryScanCancellation();
      StorageSnapshot? last;
      await for (final s in service.scan(
        LocalToolSnapshot(
          tools: [tool('go', dirs.map(location).toList())],
          scannedAt: DateTime(2026),
        ),
        token,
      )) {
        last = s;
        if (s.completed >= 2) token.cancel();
      }
      expect(last!.cancelled, isTrue);
      expect(last.scanning, isFalse);
      expect(reader.calls.length, 2);
      expect(
        last.entries.any((e) => e.usage.state == StorageUsageState.cancelled),
        isTrue,
      );
      expect(last.measuredBytes, greaterThan(0));
    },
  );

  test(
    'overly broad and mounted directory records are inspected but not recursively measured',
    () async {
      final s = await scan([
        tool('custom', [location(temp.path)]),
      ]);
      expect(entry(s, temp.path).usage.state, StorageUsageState.skipped);
      expect(reader.calls, isNot(contains(await temp.resolveSymbolicLinks())));
      expect(normalizeStoragePath('/'), '/');
    },
  );

  test(
    'native reader measures allocated sparse-file space and does not traverse inner links',
    () async {
      final data = await dir('${temp.path}/data with spaces;literal');
      final sparse = File('$data/sparse');
      final handle = await sparse.open(mode: FileMode.write);
      await handle.writeFrom(List.filled(4096, 1));
      await handle.truncate(128 * 1024 * 1024);
      await handle.close();
      final outside = await dir('${temp.path}/external');
      await File(
        '$outside/large',
      ).writeAsBytes(List.filled(4 * 1024 * 1024, 1));
      await Link('$data/external').create(outside);
      final result = await const PosixDirectoryUsageReader().measure(
        data,
        DirectoryScanCancellation(),
      );
      expect(result.state, StorageUsageState.complete);
      expect(result.bytes, lessThan(4 * 1024 * 1024));
      expect(await sparse.length(), 128 * 1024 * 1024);
    },
  );

  Future<String> script(String body) async {
    final f = File('${temp.path}/du-test');
    await f.writeAsString('#!/bin/sh\n$body\n');
    await Process.run('/bin/chmod', ['700', f.path]);
    return f.path;
  }

  test(
    'native timeout terminates work and cancelled scans do not start commands',
    () async {
      final executable = await script('exec /bin/sleep 20');
      final result = await PosixDirectoryUsageReader(
        executable: executable,
        timeout: const Duration(milliseconds: 70),
      ).measure(temp.path, DirectoryScanCancellation());
      expect(result.state, StorageUsageState.timeout);
      final token = DirectoryScanCancellation()..cancel();
      expect(
        (await const PosixDirectoryUsageReader(
          executable: '/does/not/exist',
        ).measure(temp.path, token)).state,
        StorageUsageState.cancelled,
      );
    },
  );

  test(
    'native cancellation interrupts an active process, not just later queue items',
    () async {
      final executable = await script('exec /bin/sleep 20');
      final token = DirectoryScanCancellation();
      final timer = Timer(const Duration(milliseconds: 70), token.cancel);
      final watch = Stopwatch()..start();
      final result = await PosixDirectoryUsageReader(
        executable: executable,
      ).measure(temp.path, token);
      timer.cancel();
      expect(result.state, StorageUsageState.cancelled);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    },
  );

  test(
    'native permission/partial failure never reports a complete measurement',
    () async {
      final executable = await script("printf '4\\tpartial\\n'\nexit 1");
      final result = await PosixDirectoryUsageReader(
        executable: executable,
      ).measure(temp.path, DirectoryScanCancellation());
      expect(result.state, StorageUsageState.partial);
      expect(result.bytes, 4096);
    },
  );
}
