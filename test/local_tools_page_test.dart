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
import 'package:mise_gui/features/local_tools/presentation/local_tools_page.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class Opener implements LocalToolOpener {
  final opened = <String>[];
  bool fail = false;
  @override
  Future<void> open(String path, {bool application = false}) async {
    if (fail) throw StateError('路径已不存在，请重新扫描。');
    opened.add(path);
  }
}

LocalToolSnapshot fixture() {
  final r = ToolchainLayout.current.root;
  return LocalToolSnapshot(
    scannedAt: DateTime(2026, 10, 18, 18, 30),
    tools: [
      LocalTool(
        id: 'java',
        name: 'Java',
        category: LocalToolCategory.runtime,
        description: 'JVM 运行时与编译器；支持多个 JDK。',
        status: LocalToolStatus.ready,
        manager: 'mise',
        source: 'Oracle JDK（本地 SDK）',
        version: 'oracle-21.0.12.1',
        miseTool: 'java',
        versions: [
          for (final v in [
            'oracle-21.0.12.1',
            'oracle-17.0.20',
            'oracle-8.0.503',
          ])
            LocalToolVersion(
              v,
              '$r/jdk/versions/$v/Contents/Home',
              active: v.startsWith('oracle-21'),
            ),
        ],
        locations: [
          ToolLocation(label: '安装目录', path: '$r/jdk', exists: true),
          ToolLocation(
            label: '尚未创建',
            path: '$r/jdk/nonexistent',
            exists: false,
          ),
        ],
      ),
      for (final (id, name, version) in [
        ('node', 'Node.js', '24.21.0'),
        ('python', 'Python', '3.14.8'),
        ('go', 'Go', '1.27.2'),
        ('rust', 'Rust', '1.99.0'),
        ('flutter', 'Flutter', '3.47.7'),
        ('dart', 'Dart', '3.13.5'),
      ])
        LocalTool(
          id: id,
          name: name,
          category: LocalToolCategory.runtime,
          description: '本地运行时',
          status: LocalToolStatus.ready,
          manager: 'mise',
          source: '本地 SDK',
          version: version,
        ),
      LocalTool(
        id: 'bruno',
        name: 'Bruno',
        category: LocalToolCategory.network,
        description: 'API 集合、GUI 和 CLI 共享项目集合。',
        status: LocalToolStatus.ready,
        manager: 'macOS 应用',
        source: '应用包 · com.usebruno.app',
        version: '4.2.1',
        locations: [
          const ToolLocation(
            label: '应用',
            path: '/Applications/Bruno.app',
            exists: true,
            application: true,
          ),
          ToolLocation(label: '缓存', path: '$r/bruno/cache', exists: true),
        ],
      ),
      const LocalTool(
        id: 'cmake',
        name: 'CMake',
        category: LocalToolCategory.mobile,
        description: 'Android 原生构建工具',
        status: LocalToolStatus.missing,
        manager: '待识别',
        source: '未检测到安装',
      ),
    ],
  );
}

void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_PREVIEW'] == '1';
  setUpAll(() async {
    if (!render) return;
    final cjk = Platform.environment['MISE_GUI_PREVIEW_CJK_FONT'];
    if (cjk != null) {
      final bytes = await File(cjk).readAsBytes();
      for (final family in [
        'IBM Plex Sans',
        'JetBrains Mono',
        'monospace',
        'FiraCode',
        'Ahem',
        'Roboto',
        'RobotoFlex',
      ]) {
        final loader = FontLoader(family)
          ..addFont(Future.value(ByteData.sublistView(bytes)));
        await loader.load();
      }
    }
    final icon = Platform.environment['MISE_GUI_PREVIEW_MATERIAL_FONT'];
    if (icon != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(await File(icon).readAsBytes())),
        );
      await loader.load();
    }
  });

  Future<void> page(
    WidgetTester tester,
    Opener opener, {
    Size size = const Size(1450, 1080),
    bool dark = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          localToolsProvider.overrideWith((ref) async => fixture()),
          localToolOpenerProvider.overrideWithValue(opener),
        ],
        child: MaterialApp(
          theme: dark ? ThemeData.dark() : ThemeData.light(),
          home: const Scaffold(body: LocalToolsPage()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'filters actual inventory, shows detail, and opens shared GUI or folders',
    (tester) async {
      final opener = Opener();
      await page(tester, opener);
      expect(find.text('Oracle JDK（本地 SDK）'), findsOneWidget);
      expect(find.text('oracle-17.0.20'), findsOneWidget);
      expect(find.text('未设置全局默认'), findsNothing);
      await tester.enterText(find.byType(TextField), 'Bruno');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('local-tool-java')), findsNothing);
      expect(find.byKey(const ValueKey('detail-bruno')), findsOneWidget);
      await tester.tap(find.text('打开应用'));
      await tester.pumpAndSettle();
      expect(opener.opened, ['/Applications/Bruno.app']);
      await tester.tap(find.byTooltip('打开缓存'));
      await tester.pumpAndSettle();
      expect(opener.opened.last, '${ToolchainLayout.current.root}/bruno/cache');
      opener.fail = true;
      await tester.tap(find.text('打开应用'));
      await tester.pumpAndSettle();
      expect(find.textContaining('打开失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'category selection keeps the details within the visible category',
    (tester) async {
      await page(tester, Opener());
      await tester.tap(find.widgetWithText(ChoiceChip, 'API 与网络调试  1'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-bruno')), findsOneWidget);
      expect(find.byKey(const ValueKey('local-tool-java')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('missing entries are opt-in and empty filters remain usable', (
    tester,
  ) async {
    await page(tester, Opener());
    expect(find.byKey(const ValueKey('local-tool-cmake')), findsNothing);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'CMake');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('detail-cmake')), findsOneWidget);
    expect(find.text('打开应用'), findsNothing);
    await tester.enterText(find.byType(TextField), 'not-installed-example');
    await tester.pumpAndSettle();
    expect(find.textContaining('没有匹配的本地工具'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'small windows show responsive catalog and details without overflow',
    (tester) async {
      await page(tester, Opener(), size: const Size(420, 900));
      await tester.enterText(find.byType(TextField), 'Bruno');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('打开应用'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'mise unavailable does not block local tools navigation and version link retains destination',
    (tester) async {
      tester.view.physicalSize = const Size(1640, 1120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          miseAvailableProvider.overrideWith((ref) async => false),
          localToolsProvider.overrideWith((ref) async => fixture()),
          classifiedVersionsProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(container.dispose);
      container.read(appRouterProvider).go('/local-tools');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MiseGuiApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('DevWorkbench'), findsOneWidget);
      expect(find.text('Oracle JDK（本地 SDK）'), findsOneWidget);
      expect(find.text('这台电脑还没有安装 mise'), findsNothing);
      await tester.tap(find.text('版本管理'));
      await tester.pumpAndSettle();
      expect(
        container
            .read(appRouterProvider)
            .routeInformationProvider
            .value
            .uri
            .toString(),
        '/tools?tool=java',
      );
      expect(find.text('这台电脑还没有安装 mise'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'workbench preview uses the implemented Flutter shell and official icons',
    (tester) async {
      tester.view.physicalSize = const Size(1640, 1120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      LocalToolSnapshot? live;
      if (render) {
        live = await tester.runAsync(() async {
          const process = LocalMiseProcessService();
          final shell = await process.inspectShellEnvironment();
          final layout = ToolchainLayout(
            home: Platform.environment['HOME']!,
            environment: {...Platform.environment, ...?shell.environment},
          );
          return SystemLocalToolInventory(
            layout: layout,
            process: const SystemLocalToolProcess(),
            loadVersions: ClassifiedToolchainService(process, layout).inventory,
          ).scan();
        });
      }
      final container = ProviderContainer(
        overrides: [
          miseAvailableProvider.overrideWith((ref) async => true),
          localToolsProvider.overrideWith((ref) async => live ?? fixture()),
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
      container.read(appRouterProvider).go('/local-tools');
      final key = GlobalKey();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(key: key, child: const MiseGuiApp()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-java')), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (render) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(
            'docs/design/dev-workbench.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}
