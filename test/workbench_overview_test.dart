import 'workbench_test_overrides.dart';
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
import 'package:mise_gui/features/dashboard/application/dashboard_provider.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/local_tool_registry.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

LocalToolSnapshot fixture() => LocalToolSnapshot(
  scannedAt: DateTime(2026, 10, 18, 12),
  tools: const [
    LocalTool(
      id: 'java',
      name: 'Java',
      category: LocalToolCategory.runtime,
      description: '本地 JDK',
      status: LocalToolStatus.ready,
      manager: 'mise',
      source: 'Oracle JDK',
      version: '21.0.12.1',
      miseTool: 'java',
    ),
    LocalTool(
      id: 'maven',
      name: 'Maven',
      category: LocalToolCategory.build,
      description: 'Java 构建',
      status: LocalToolStatus.attention,
      manager: '本地 CLI',
      source: '本地程序',
      version: '3.10.0',
      relations: [LocalToolRelation('java', '通过 JAVA_HOME 使用所选 JDK')],
      notes: ['版本命令检查失败'],
      locations: [
        ToolLocation(
          label: '配置',
          path: '/example/settings.xml',
          exists: true,
          kind: ToolLocationKind.configuration,
        ),
      ],
    ),
    LocalTool(
      id: 'bruno',
      name: 'Bruno',
      category: LocalToolCategory.network,
      description: 'API 工具',
      status: LocalToolStatus.ready,
      manager: 'macOS 应用',
      source: '应用包',
      version: '4.2.1',
    ),
    LocalTool(
      id: 'unavailable',
      name: 'Unavailable',
      category: LocalToolCategory.utility,
      description: '',
      status: LocalToolStatus.unavailable,
      manager: '待识别',
      source: '',
    ),
    LocalTool(
      id: 'missing',
      name: 'Missing',
      category: LocalToolCategory.editor,
      description: '',
      status: LocalToolStatus.missing,
      manager: '待识别',
      source: '',
    ),
  ],
);

class Inventory implements LocalToolInventory {
  LocalToolSnapshot snapshot = fixture();
  int scans = 0;
  bool fail = false;
  @override
  Future<LocalToolSnapshot> scan() async {
    scans++;
    if (fail) throw StateError('inventory unavailable');
    return snapshot;
  }
}

class Registry extends LocalToolRegistry {
  Registry(this.inventory)
    : super(
        file: File('/unused/imported_tools.json'),
        process: const SystemLocalToolProcess(),
      );
  final Inventory inventory;
  ImportedTool? draft;
  @override
  Future<ImportedTool> importTool(
    ImportedTool draft, {
    required List<LocalTool> knownTools,
  }) async {
    this.draft = draft;
    if (draft.name.isEmpty) throw StateError('请填写工具名称');
    inventory.snapshot = LocalToolSnapshot(
      scannedAt: DateTime(2026),
      tools: [
        ...inventory.snapshot.tools,
        LocalTool(
          id: 'imported-123',
          name: draft.name,
          category: draft.category,
          description: '自定义工具',
          status: LocalToolStatus.ready,
          manager: '手动登记',
          source: '',
          imported: true,
        ),
      ],
    );
    return ImportedTool(
      id: 'imported-123',
      name: draft.name,
      category: draft.category,
      path: draft.path,
      application: draft.application,
    );
  }

  @override
  Future<void> forget(String id) async {
    inventory.snapshot = LocalToolSnapshot(
      scannedAt: DateTime(2026),
      tools: inventory.snapshot.tools.where((t) => t.id != id).toList(),
    );
  }
}

const dashboard = DashboardSnapshot(
  title: '环境总览',
  subtitle: '',
  metrics: [],
  signals: [],
  toolSummary: DashboardToolSummary(
    activeToolCount: 0,
    installedToolCount: 0,
    commandPreview: '',
  ),
  recentHistory: [],
  riskHighlights: [],
);

void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_PREVIEW'] == '1';
  setUpAll(() async {
    if (!render) return;
    for (final (env, families) in [
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
      final path = Platform.environment[env];
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
    WidgetTester tester,
    Inventory inventory, {
    bool mise = true,
    Size size = const Size(1640, 1250),
    GlobalKey? boundary,
    DashboardSnapshot? overview,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        ...isolatedWorkbenchOverrides(),
        miseAvailableProvider.overrideWith((ref) async => mise),
        localToolInventoryProvider.overrideWithValue(inventory),
        localToolRegistryProvider.overrideWithValue(Registry(inventory)),
        classifiedVersionsProvider.overrideWith((ref) async => []),
        dashboardProvider.overrideWith((ref) async => overview ?? dashboard),
        appVersionInfoProvider.overrideWith(
          (ref) async => const AppVersionInfo(
            appName: 'DevWorkbench',
            packageName: 'com.couai.miseGui',
            version: '1.2.0',
            buildNumber: '12',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(themePreferenceProvider.notifier).state =
        AppThemePreference.dark;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: boundary, child: const MiseGuiApp()),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  test(
    'overview counts distinguish missing and failed probes from installed tools',
    () {
      final s = fixture();
      expect(s.installedCount, 3);
      expect(s.attentionCount, 2);
      expect(s.missingCount, 1);
      expect(s.miseCount, 1);
    },
  );

  testWidgets(
    'category and status links share one scan and retain correct selection on repeat visits',
    (tester) async {
      final inventory = Inventory();
      final c = await app(tester, inventory);
      await tester.tap(find.byKey(const ValueKey('overview-category-build')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-maven')), findsOneWidget);
      expect(find.byKey(const ValueKey('local-tool-bruno')), findsNothing);
      expect(inventory.scans, 1);
      c.read(appRouterProvider).go('/dashboard');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('overview-attention')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('local-tool-unavailable')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('local-tool-bruno')), findsNothing);
      c.read(appRouterProvider).go('/local-tools?tool=maven');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('查看Java档案'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-java')), findsOneWidget);
      c.read(appRouterProvider).go('/local-tools?tool=maven');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-maven')), findsOneWidget);
      expect(find.text('配置与数据'), findsOneWidget);
      expect(inventory.scans, 1);
    },
  );

  testWidgets(
    'overview remains usable without mise and supports a narrow window',
    (tester) async {
      await app(tester, Inventory(), mise: false, size: const Size(430, 950));
      expect(find.text('已识别工具'), findsOneWidget);
      expect(find.text('这台电脑还没有安装 mise'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed inventory can retry without hiding independent dashboard data',
    (tester) async {
      final inventory = Inventory()..fail = true;
      await app(tester, inventory);
      expect(find.text('本地工具清单暂不可用。'), findsOneWidget);
      expect(find.text('最近活动'), findsOneWidget);
      inventory.fail = false;
      await tester.tap(find.text('重新扫描工具'));
      await tester.pumpAndSettle();
      expect(find.text('已识别工具'), findsOneWidget);
      expect(inventory.scans, 2);
    },
  );

  testWidgets(
    'import dialog persists registration, selects new entry and refreshes shared overview; forget removes entry',
    (tester) async {
      final inventory = Inventory();
      final c = await app(tester, inventory);
      c.read(appRouterProvider).go('/local-tools');
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入已有工具'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('CLI 文件'));
      await tester.tap(find.text('导入工具'));
      await tester.pumpAndSettle();
      expect(find.textContaining('导入失败'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), 'Custom CLI');
      await tester.enterText(fields.at(1), '/example/custom-cli');
      await tester.tap(find.text('导入工具'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byKey(const ValueKey('detail-imported-123')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('local-tool-imported-123')).hitTestable(),
        findsOneWidget,
      );
      expect(
        (c.read(localToolRegistryProvider) as Registry).draft!.application,
        isFalse,
      );
      expect(inventory.scans, 2);
      c.read(appRouterProvider).go('/dashboard');
      await tester.pumpAndSettle();
      expect(c.read(localToolsProvider).value!.installedCount, 4);
      c.read(appRouterProvider).go('/local-tools?tool=imported-123');
      await tester.pumpAndSettle();
      await tester.tap(find.text('移除登记（保留程序和数据）'));
      await tester.pumpAndSettle();
      expect(c.read(localToolsProvider).value!.installedCount, 3);
      expect(find.byKey(const ValueKey('detail-imported-123')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unified overview and profile preview render actual Flutter pages',
    (tester) async {
      final inventory = Inventory();
      DashboardSnapshot? liveOverview;
      if (render) {
        inventory.snapshot = (await tester.runAsync(() async {
          const p = LocalMiseProcessService();
          final shell = await p.inspectShellEnvironment();
          final layout = ToolchainLayout(
            home: Platform.environment['HOME']!,
            environment: {...Platform.environment, ...?shell.environment},
          );
          return SystemLocalToolInventory(
            layout: layout,
            process: const SystemLocalToolProcess(),
            loadVersions: ClassifiedToolchainService(p, layout).inventory,
          ).scan();
        }))!;
      }
      if (render) {
        liveOverview = await tester.runAsync(() async {
          final c = ProviderContainer();
          try {
            return await c.read(dashboardRepositoryProvider).loadDashboard();
          } finally {
            c.dispose();
          }
        });
      }
      final key = GlobalKey();
      final c = await app(
        tester,
        inventory,
        boundary: key,
        overview: liveOverview,
        size: const Size(1640, 1400),
      );
      expect(find.text('已识别工具'), findsOneWidget);
      Future<void> capture(String path) async {
        if (!render) return;
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary)
                  .toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('docs/design/environment-overview.png');
      c.read(appRouterProvider).go('/local-tools?tool=maven');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-maven')), findsOneWidget);
      await capture('docs/design/tool-profile.png');
      expect(tester.takeException(), isNull);
    },
  );
}
