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
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'workbench_test_overrides.dart';

void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_TASKS'] == '1';
  setUpAll(() async {
    if (!render) return;
    final font = File(
      Platform.environment['MISE_GUI_PREVIEW_CJK_FONT']!,
    ).readAsBytesSync();
    for (final family in [
      'IBM Plex Sans',
      'JetBrains Mono',
      'monospace',
      'FiraCode',
      'Ahem',
      'Roboto',
      'RobotoFlex',
    ]) {
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(font)))).load();
    }
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(
            ByteData.sublistView(
              File(
                Platform.environment['MISE_GUI_PREVIEW_MATERIAL_FONT']!,
              ).readAsBytesSync(),
            ),
          ),
        ))
        .load();
  });
  final key = GlobalKey();
  Future<ProviderContainer> app(
    WidgetTester tester, {
    String route = '/tasks',
    double width = 1500,
  }) async {
    tester.view.physicalSize = Size(width, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        ...isolatedWorkbenchOverrides(),
        miseAvailableProvider.overrideWith((ref) async => false),
        appVersionInfoProvider.overrideWith(
          (ref) async => const AppVersionInfo(
            appName: 'DevWorkbench',
            packageName: 'com.couai.miseGui',
            version: '1.4.0',
            buildNumber: '14',
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
        child: RepaintBoundary(key: key, child: const MiseGuiApp()),
      ),
    );
    await tester.pumpAndSettle();
    return c;
  }

  Future<void> image(String name) async {
    final capture =
        await (key.currentContext!.findRenderObject()! as RenderRepaintBoundary)
            .toImage(pixelRatio: 1.5);
    final bytes = await capture.toByteData(format: ui.ImageByteFormat.png);
    await File(
      'docs/design/$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    capture.dispose();
  }

  testWidgets(
    'task center is available without mise and tracks live completion, output and filters',
    (tester) async {
      final c = await app(tester);
      expect(find.textContaining('暂无任务'), findsOneWidget);
      final center = c.read(taskCenterProvider.notifier);
      final task = center.start('测试版本切换', 'mise', ['运行命令', '验证版本']);
      task.step(0, TaskStepStatus.running);
      task.output('node 24.21.0\n');
      await tester.pumpAndSettle();
      expect(find.text('1/2 步完成'), findsNothing);
      expect(find.text('0/2 步完成'), findsOneWidget);
      expect(find.textContaining('node 24.21.0'), findsOneWidget);
      task.step(0, TaskStepStatus.succeeded, exitCode: 0);
      task.step(1, TaskStepStatus.succeeded);
      task.finish(const TaskVerification(true, '全局版本选择已验证'));
      await tester.pumpAndSettle();
      expect(find.text('2/2 步完成'), findsOneWidget);
      expect(find.text('全局版本选择已验证'), findsOneWidget);
      await tester.tap(find.widgetWithText(ChoiceChip, '需检查'));
      await tester.pumpAndSettle();
      expect(find.textContaining('暂无任务'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manager settings remain usable without mise and block saves during running work',
    (tester) async {
      final c = await app(tester, route: '/managers', width: 760);
      expect(find.text('这台电脑还没有安装 mise'), findsNothing);
      expect(find.text('mise 程序路径'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
            .onPressed,
        isNotNull,
      );
      final task = c.read(taskCenterProvider.notifier).start('测量目录', '目录扫描', [
        'measure',
      ]);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
            .onPressed,
        isNull,
      );
      task.finish(const TaskVerification(true, 'done'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存设置'))
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'task navigation retains work; narrow detail shows failed verification',
    (tester) async {
      final c = await app(tester, width: 720);
      final task = c.read(taskCenterProvider.notifier).start('检查工具链', '管理器检查', [
        '版本命令',
        '验证',
      ]);
      task.step(0, TaskStepStatus.succeeded);
      task.step(1, TaskStepStatus.failed);
      task.finish(const TaskVerification(false, '所选版本未生效'));
      c.read(appRouterProvider).go('/managers');
      await tester.pumpAndSettle();
      c.read(appRouterProvider).go('/tasks');
      await tester.pumpAndSettle();
      expect(find.text('所选版本未生效'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('render task and manager settings previews', (tester) async {
    final c = await app(tester);
    final center = c.read(taskCenterProvider.notifier);
    final check = center.start('检查管理器配置', '管理器检查', [
      '检查路径与选项',
      'mise 版本',
      'Homebrew 版本',
      'Android SDK 管理器',
      'Xcode 工具链',
      '汇总验证结果',
    ]);
    for (var i = 0; i < 6; i++) {
      check.step(
        i,
        TaskStepStatus.succeeded,
        exitCode: i > 0 && i < 5 ? 0 : null,
      );
    }
    check.output(
      '\$ mise --version\n2026.10.8 macos-arm64\n\$ brew --version\nHomebrew 7.0.9\n\$ sdkmanager --version\n1.0.16500706\n\$ xcodebuild -version\nXcode 27.0\n',
    );
    check.finish(const TaskVerification(true, '四个管理器均返回版本信息，配置路径可用。'));
    final scan = center.start('扫描目录与缓存', '目录扫描', [
      '读取工具档案',
      '检查目录与软链接',
      '测量磁盘占用',
      '汇总验证结果',
    ]);
    for (var i = 0; i < 4; i++) {
      scan.step(i, TaskStepStatus.succeeded);
    }
    scan.finish(
      const TaskVerification(
        true,
        '182/182 个测量目标；18 个分类外路径待检查。',
        warning: true,
      ),
    );
    final running = center.start('切换版本 · node@24.21.0', 'mise', [
      '检查操作计划',
      'mise use --global node@24.21.0',
      '验证安装与版本选择',
    ]);
    running.step(0, TaskStepStatus.succeeded);
    running.step(1, TaskStepStatus.succeeded, exitCode: 0);
    running.step(2, TaskStepStatus.running);
    running.output(
      '\$ mise use --global node@24.21.0\nmise /Users/cua/Developer/toolchains/mise/config/config.toml tools: node@24.21.0\nexit 0\n\n正在读取全局版本选择…\n',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (render) await tester.runAsync(() => image('tasks'));
    running.step(2, TaskStepStatus.succeeded);
    running.finish(const TaskVerification(true, 'node@24.21.0 作用域选择通过'));
    c.read(appRouterProvider).go('/managers');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    if (render) await tester.runAsync(() => image('manager-settings'));
  });
}
