import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/app/bootstrap/app.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/app/router/app_router.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/storage/application/storage_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/directory_storage_service.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

const root = '/Users/example/Developer/toolchains';
const alias = '/Users/example/.m2';
const outside = '/Users/example/Library/Caches/JetBrains/IntelliJIdea2026.2';
StorageSnapshot fixture({
  bool scanning = false,
  bool cancelled = false,
}) => StorageSnapshot(
  scannedAt: DateTime(2026, 10, 18, 18),
  scanning: scanning,
  cancelled: cancelled,
  completed: scanning ? 1 : 4,
  total: 4,
  entries: const [
    StorageEntry(
      path: root,
      canonicalPath: root,
      owners: [
        StorageOwner('shared', '共享工具目录', '分类根目录', ToolLocationKind.other),
      ],
      linkState: StorageLinkState.direct,
      compliance: StorageCompliance.classified,
      policyNote: '分类根目录',
      usage: StorageUsage(
        StorageUsageState.complete,
        bytes: 40 * 1024 * 1024 * 1024,
      ),
    ),
    StorageEntry(
      path: '$root/.m2/repository',
      canonicalPath: '$root/.m2/repository',
      owners: [StorageOwner('maven', 'Maven', '本地仓库', ToolLocationKind.cache)],
      linkState: StorageLinkState.direct,
      compliance: StorageCompliance.classified,
      policyNote: '分类目录',
      usage: StorageUsage(
        StorageUsageState.complete,
        bytes: 3 * 1024 * 1024 * 1024,
      ),
      coveredBy: root,
    ),
    StorageEntry(
      path: alias,
      canonicalPath: '$root/.m2',
      owners: [StorageOwner('maven', 'Maven', '兼容路径', ToolLocationKind.other)],
      linkState: StorageLinkState.linked,
      compliance: StorageCompliance.classified,
      policyNote: '兼容链接正确',
      usage: StorageUsage(
        StorageUsageState.complete,
        bytes: 3 * 1024 * 1024 * 1024,
      ),
      links: [StorageLinkHop(alias, '$root/.m2')],
      coveredBy: root,
    ),
    StorageEntry(
      path: outside,
      canonicalPath: outside,
      owners: [StorageOwner('idea', 'IDEA', 'IDE 缓存', ToolLocationKind.cache)],
      linkState: StorageLinkState.direct,
      compliance: StorageCompliance.outside,
      policyNote: '分类外，待核对',
      usage: StorageUsage(StorageUsageState.complete, bytes: 512 * 1024 * 1024),
    ),
    StorageEntry(
      path: '/Users/example/.gradle',
      owners: [
        StorageOwner('gradle', 'Gradle', '兼容路径', ToolLocationKind.other),
      ],
      linkState: StorageLinkState.broken,
      compliance: StorageCompliance.classified,
      policyNote: '预期 Gradle 分类目录',
      usage: StorageUsage(StorageUsageState.skipped, note: '没有有效目标'),
      links: [StorageLinkHop('/Users/example/.gradle', '/absent')],
    ),
    StorageEntry(
      path: '$root/go/missing',
      owners: [StorageOwner('go', 'Go', '配置', ToolLocationKind.configuration)],
      linkState: StorageLinkState.missing,
      compliance: StorageCompliance.classified,
      policyNote: '未创建',
      usage: StorageUsage(StorageUsageState.skipped),
    ),
  ],
);

class Service extends DirectoryStorageService {
  Service({this.hold = false, this.fail = false})
    : super(
        layout: ToolchainLayout(home: '/unused'),
        reader: const PosixDirectoryUsageReader(),
      );
  final bool hold;
  bool fail;
  int calls = 0;
  @override
  Stream<StorageSnapshot> scan(
    LocalToolSnapshot inventory,
    DirectoryScanCancellation cancellation,
  ) async* {
    calls++;
    if (fail) throw StateError('scan failed');
    if (hold) {
      yield fixture(scanning: true);
      final stopped = Completer<void>();
      final unsubscribe = cancellation.listen(() => stopped.complete());
      try {
        await stopped.future;
      } finally {
        unsubscribe();
      }
      yield fixture(cancelled: true);
    } else {
      yield fixture();
    }
  }
}

class Opener implements LocalToolOpener {
  final paths = <String>[];
  bool fail = false;
  @override
  Future<void> open(String path, {bool application = false}) async {
    paths.add(path);
    if (fail) throw StateError('Path no longer exists');
  }
}

void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_STORAGE'] == '1';
  setUpAll(() async {
    if (!render) return;
    for (final (key, families) in [
      (
        'MISE_GUI_PREVIEW_CJK_FONT',
        [
          'IBM Plex Sans',
          'JetBrains Mono',
          'monospace',
          'FiraCode',
          'Ahem',
          'Roboto',
          'RobotoFlex',
        ],
      ),
      ('MISE_GUI_PREVIEW_MATERIAL_FONT', ['MaterialIcons']),
    ]) {
      final path = Platform.environment[key];
      if (path == null) continue;
      final bytes = await File(path).readAsBytes();
      for (final family in families) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    }
  });
  Future<ProviderContainer> app(
    WidgetTester tester, {
    Service? service,
    Opener? opener,
    Size size = const Size(1640, 1500),
    String route = '/storage',
    GlobalKey? boundary,
    StorageSnapshot? snapshot,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        miseAvailableProvider.overrideWith((ref) async => false),
        localToolsProvider.overrideWith(
          (ref) async => LocalToolSnapshot(
            tools: const [
              LocalTool(
                id: 'maven',
                name: 'Maven',
                category: LocalToolCategory.build,
                description: 'Java 构建',
                status: LocalToolStatus.ready,
                manager: '本地 CLI',
                source: '本地程序',
              ),
            ],
            scannedAt: DateTime(2026),
          ),
        ),
        localToolOpenerProvider.overrideWithValue(opener ?? Opener()),
        directoryStorageServiceProvider.overrideWithValue(service ?? Service()),
        if (snapshot != null)
          directoryStorageProvider.overrideWith(
            (ref) => Stream.value(snapshot),
          ),
        appVersionInfoProvider.overrideWith(
          (ref) async => const AppVersionInfo(
            appName: 'DevWorkbench',
            packageName: 'com.couai.miseGui',
            version: '1.3.0',
            buildNumber: '13',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(themePreferenceProvider.notifier).state = AppThemePreference.dark;
    c.read(appRouterProvider).go(route);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(key: boundary, child: const MiseGuiApp()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  testWidgets(
    'directory page is available without mise and filters known aliases and issues',
    (tester) async {
      await app(tester);
      expect(find.text('这台电脑还没有安装 mise'), findsNothing);
      expect(find.text('40.5 GiB'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilterChip, '仅待检查'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('storage-row-$outside')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('storage-row-$root')), findsNothing);
      await tester.tap(find.widgetWithText(FilterChip, '仅含软链接'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('storage-detail-/Users/example/.gradle')),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '打开所在位置'),
      );
      expect(button.onPressed, isNull);
      expect(find.text('打开父目录'), findsOneWidget);
    },
  );

  testWidgets('tool profile links to directory page with its owner scope', (
    tester,
  ) async {
    final c = await app(tester, route: '/local-tools?tool=maven');
    await tester.tap(find.text('查看目录占用与链接'));
    await tester.pumpAndSettle();
    expect(
      c.read(appRouterProvider).routeInformationProvider.value.uri.toString(),
      '/storage?tool=maven',
    );
    expect(find.text('工具：Maven'), findsOneWidget);
  });

  testWidgets(
    'owner filtering, search and missing-item visibility work together',
    (tester) async {
      final c = await app(tester, route: '/storage?tool=maven');
      expect(find.text('工具：Maven'), findsOneWidget);
      expect(find.byKey(const ValueKey('storage-row-$outside')), findsNothing);
      await tester.enterText(find.byType(TextField), 'repository');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('storage-detail-$root/.m2/repository')),
        findsOneWidget,
      );
      c.read(appRouterProvider).go('/storage');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '显示未找到项'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'go/missing');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('storage-detail-$root/go/missing')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'quick open preserves literal paths, stale paths show errors, owner links open tool profiles',
    (tester) async {
      final opener = Opener();
      final c = await app(tester, route: '/storage?tool=maven', opener: opener);
      await tester.tap(find.text('打开所在位置'));
      await tester.pumpAndSettle();
      expect(opener.paths.single, alias);
      opener.fail = true;
      await tester.tap(find.text('打开所在位置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('打开失败'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('查看Maven工具档案'));
      await tester.tap(find.byTooltip('查看Maven工具档案'));
      await tester.pumpAndSettle();
      expect(
        c.read(appRouterProvider).routeInformationProvider.value.uri.toString(),
        '/local-tools?tool=maven',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stopping work preserves results and explicit refresh starts a new session',
    (tester) async {
      final service = Service(hold: true);
      await app(tester, service: service);
      expect(find.text('停止扫描'), findsOneWidget);
      await tester.tap(find.text('停止扫描'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已停止，保留已测结果'), findsOneWidget);
      expect(find.text('停止扫描'), findsNothing);
      await tester.tap(find.text('重新扫描目录'));
      await tester.pumpAndSettle();
      expect(service.calls, 2);
      await tester.tap(find.text('停止扫描'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'navigation retains measured results, scan failure can retry and narrow layout stays usable',
    (tester) async {
      final service = Service()..fail = true;
      final c = await app(
        tester,
        service: service,
        size: const Size(430, 1000),
      );
      expect(find.text('重试目录扫描'), findsOneWidget);
      service.fail = false;
      await tester.tap(find.text('重试目录扫描'));
      await tester.pumpAndSettle();
      expect(service.calls, 2);
      expect(find.text('已测目录占用'), findsOneWidget);
      c.read(appRouterProvider).go('/local-tools');
      await tester.pumpAndSettle();
      c.read(appRouterProvider).go('/storage');
      await tester.pumpAndSettle();
      expect(service.calls, 2);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'storage preview renders measured filesystem results in the actual Flutter shell',
    (tester) async {
      StorageSnapshot? live;
      if (render) {
        live = await tester.runAsync(() async {
          const process = LocalMiseProcessService();
          final shell = await process.inspectShellEnvironment();
          final layout = ToolchainLayout(
            home: Platform.environment['HOME']!,
            environment: {...Platform.environment, ...?shell.environment},
          );
          final inventory = await SystemLocalToolInventory(
            layout: layout,
            process: const SystemLocalToolProcess(),
            loadVersions: ClassifiedToolchainService(process, layout).inventory,
          ).scan();
          return DirectoryStorageService(
            layout: layout,
            reader: const PosixDirectoryUsageReader(),
          ).scan(inventory, DirectoryScanCancellation()).last;
        });
      }
      final key = GlobalKey();
      await app(
        tester,
        boundary: key,
        snapshot: live ?? fixture(),
        route: render ? '/storage?tool=maven' : '/storage',
      );
      expect(find.text('已测目录占用'), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (render) {
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/design/storage.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    },
  );
}
