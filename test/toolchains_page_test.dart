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
    'tool deep links select the requested runtime on first entry and later navigation',
    (tester) async {
      tester.view.physicalSize = const Size(1640, 1120);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          miseAvailableProvider.overrideWith((ref) async => true),
          classifiedVersionsProvider.overrideWith((ref) async => snapshot()),
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
      expect(find.text('配套 Dart 3.13.5'), findsOneWidget);
      router.go('/toolchains?tool=rust');
      await tester.pumpAndSettle();
      expect(find.text('共享代理位置'), findsOneWidget);
      expect(find.text('配套 Dart 3.13.5'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('shows classified inventory, scope actions and bundled Dart', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1640, 1120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final boundaryKey = GlobalKey();
    final container = ProviderContainer(
      overrides: [
        miseAvailableProvider.overrideWith((ref) async => true),
        classifiedVersionsProvider.overrideWith((ref) async => snapshot()),
        appVersionInfoProvider.overrideWith(
          (ref) async => const AppVersionInfo(
            appName: 'DevWorkbench',
            packageName: 'com.couai.miseGui',
            version: '1.1.0',
            buildNumber: '10',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(themePreferenceProvider.notifier).state =
        AppThemePreference.dark;
    container.read(appRouterProvider).go('/toolchains');
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: RepaintBoundary(key: boundaryKey, child: const MiseGuiApp()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('分类工具链'), findsWidgets);
    expect(find.text('6 类运行时 · 8 个版本'), findsOneWidget);
    expect(find.text('SDK 实际位置'), findsOneWidget);
    expect(find.text('用于指定项目'), findsOneWidget);
    expect(tester.takeException(), isNull);

    if (render) {
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('docs/design').create(recursive: true);
        await File(
          'docs/design/toolchains-overview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.text('Flutter / Dart').first);
    await tester.pumpAndSettle();
    expect(find.text('配套 Dart 3.13.5'), findsOneWidget);
    expect(tester.takeException(), isNull);
    if (render) {
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'docs/design/flutter-detail.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.text('Rust').first);
    await tester.pumpAndSettle();
    expect(find.text('共享代理位置'), findsOneWidget);
    expect(find.text('rustup 工具链位置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(800, 1100);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
