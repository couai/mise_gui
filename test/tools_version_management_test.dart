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
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/features/tools/application/tools_provider.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

List<ClassifiedVersion> snapshot() {
  final layout = ToolchainLayout.current;
  return [
    for (final entry in {
      'java': ['oracle-21.0.12.1', 'oracle-17.0.20', 'oracle-8.0.503'],
      'node': ['24.21.0'],
      'python': ['3.14.8'],
      'go': ['1.27.2'],
      'rust': ['1.99.0'],
      'flutter': ['3.47.7'],
    }.entries)
      for (final version in entry.value)
        ClassifiedVersion(
          tool: entry.key,
          version: version,
          active: version == entry.value.first,
          registeredPath: '${layout.dataDir}/installs/${entry.key}/$version',
          actualPath: entry.key == 'java'
              ? '${layout.root}/jdk/versions/$version/Contents/Home'
              : layout.installTarget(entry.key, version),
          classified: true,
          sourcePath: version == entry.value.first
              ? layout.globalConfigPath
              : null,
          rustSdkPath: entry.key == 'rust'
              ? '${layout.rustupHome}/toolchains/$version-aarch64-apple-darwin'
              : null,
          dartVersion: entry.key == 'flutter' ? '3.13.5' : null,
        ),
  ];
}

void main() {
  final render = Platform.environment['MISE_GUI_RENDER_PREVIEW'] == '1';

  setUpAll(() async {
    if (!render) return;
    // System fonts are loaded locally for preview rendering, never redistributed.
    final cjk = Platform.environment['MISE_GUI_PREVIEW_CJK_FONT'];
    if (cjk != null) {
      for (final family in [
        'IBM Plex Sans',
        'JetBrains Mono',
        'monospace',
        'FiraCode',
        'Ahem',
        'Roboto',
        'RobotoFlex',
      ]) {
        final loader = FontLoader(family);
        loader.addFont(
          Future.value(ByteData.sublistView(await File(cjk).readAsBytes())),
        );
        await loader.load();
      }
    }
    final iconFont = Platform.environment['MISE_GUI_PREVIEW_MATERIAL_FONT'];
    if (iconFont != null) {
      final loader = FontLoader('MaterialIcons');
      loader.addFont(
        Future.value(ByteData.sublistView(await File(iconFont).readAsBytes())),
      );
      await loader.load();
    }
  });

  testWidgets(
    'one navigation entry and legacy deep links select the requested runtime',
    (tester) async {
      tester.view.physicalSize = const Size(1640, 1120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          miseAvailableProvider.overrideWith((ref) async => true),
          classifiedVersionsProvider.overrideWith((ref) async => snapshot()),
          toolsProvider.overrideWith((ref) async => toolSnapshot()),
        ],
      );
      addTearDown(container.dispose);
      final router = container.read(appRouterProvider);
      router.go('/toolchains?tool=flutter');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MiseGuiApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.toString(),
        '/tools?tool=flutter',
      );
      expect(find.text('配套 Dart 3.13.5'), findsOneWidget);
      expect(find.text('mise 工具链'), findsNothing);
      expect(find.text('工具版本'), findsNothing);
      final java = find.text('Java').first;
      await tester.ensureVisible(java);
      await tester.pumpAndSettle();
      await tester.tap(java);
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.queryParameters['tool'],
        'java',
      );
      // Returning from the workbench to the same original link selects Flutter again.
      router.go('/tools?tool=flutter');
      await tester.pumpAndSettle();
      expect(find.text('配套 Dart 3.13.5'), findsOneWidget);
      router.go('/tools?tool=rust');
      await tester.pumpAndSettle();
      expect(find.text('共享代理位置'), findsOneWidget);
      expect(find.text('rustup 工具链位置'), findsOneWidget);
      expect(find.text('配套 Dart 3.13.5'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'accordion version cards retain SDK metadata and project scope controls',
    (tester) async {
      tester.view.physicalSize = const Size(1640, 1120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final boundaryKey = GlobalKey();
      final container = ProviderContainer(
        overrides: [
          miseAvailableProvider.overrideWith((ref) async => true),
          classifiedVersionsProvider.overrideWith((ref) async => snapshot()),
          toolsProvider.overrideWith((ref) async => toolSnapshot()),
          appVersionInfoProvider.overrideWith(
            (ref) async => const AppVersionInfo(
              appName: 'DevWorkbench',
              packageName: 'com.couai.miseGui',
              version: '1.1.1',
              buildNumber: '11',
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(themePreferenceProvider.notifier).state =
          AppThemePreference.dark;
      container.read(appRouterProvider).go('/tools?tool=java');
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: RepaintBoundary(key: boundaryKey, child: const MiseGuiApp()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('mise 版本管理'), findsWidgets);
      expect(
        find.byKey(const ValueKey('installed-java-oracle-17.0.20')),
        findsOneWidget,
      );
      expect(find.text('SDK 实际位置'), findsNWidgets(3));
      expect(find.text('用于指定项目'), findsNWidgets(3));
      expect(find.text('卸载工具'), findsNothing);
      expect(tester.takeException(), isNull);
      Future<void> capture(String path) async {
        if (!render) return;
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await File(path).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
      }

      await capture('docs/design/mise-version-management.png');
      container.read(appRouterProvider).go('/tools?tool=flutter');
      await tester.pumpAndSettle();
      expect(find.text('配套 Dart 3.13.5'), findsOneWidget);
      await capture('docs/design/flutter-detail.png');
      tester.view.physicalSize = const Size(800, 1100);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
}

List<ToolRecord> toolSnapshot() {
  final entries = snapshot();
  return [
    for (final tool in ['java', 'node', 'python', 'go', 'rust', 'flutter'])
      ToolRecord(
        id: tool,
        name: {
          'java': 'Java',
          'node': 'Node.js',
          'python': 'Python',
          'go': 'Go',
          'rust': 'Rust',
          'flutter': 'Flutter / Dart',
        }[tool]!,
        category: 'mise 运行时',
        description: '本机已安装的运行时',
        activeVersion: entries
            .firstWhere((v) => v.tool == tool && v.active)
            .version,
        requestedVersion: '',
        source: '全局配置',
        strategy: '分类目录',
        latestStableVersion: '待查询',
        latestPreviewVersion: '待查询',
        installedVersions: [
          for (final entry in entries.where((v) => v.tool == tool))
            ToolVersionRecord(
              version: entry.version,
              channel: '本机',
              note: '',
              commandPreview: '',
              level: HealthLevel.info,
              isInstalled: true,
              isActive: entry.active,
            ),
        ],
        remoteVersions: const [],
        projectImpacts: const [],
        quickActions: const [],
        commandPreview: '',
        level: HealthLevel.info,
        remoteState: ToolRemoteState.pending,
      ),
  ];
}
