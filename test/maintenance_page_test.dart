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
import 'package:mise_gui/features/maintenance/application/maintenance_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/maintenance_process.dart';
import 'package:mise_gui/services/managed_package_catalog.dart';
import 'package:mise_gui/services/maintenance_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'workbench_test_overrides.dart';
import 'maintenance_test.dart' show RuntimeFixture;

class PreviewService extends MaintenanceService {
  PreviewService(TaskCenter tasks)
    : super(
        ManagedPackageCatalog(
          const SystemMaintenanceProcess(),
          ToolchainLayout(home: '/fixture'),
          const ManagerSettings(androidSdk: '/fixture/sdk'),
        ),
        RuntimeFixture(ToolchainLayout(home: '/fixture'), []),
        tasks,
      );
  int executions = 0;
  @override
  Future<MaintenancePlan> prepare(MaintenanceRequest r) async =>
      MaintenancePlan(
        request: r,
        commands: [
          MaintenanceCommand('/opt/homebrew/bin/brew', [
            r.action.name,
            '--formula',
            r.target,
          ]),
        ],
        paths: ['/opt/homebrew/Cellar/${r.target}'],
        identity: 'fixture',
        notes: ['native manager scope'],
        beforeVersion: '1.0.0',
        targetVersion: '2.0.0',
      );
  @override
  Future<TaskVerification> execute(MaintenancePlan p) async {
    executions++;
    final task = tasks.startMutation(p.title, p.request.manager.taskManager, [
      '运行原生命令',
      '验证安装记录',
    ]);
    task.step(0, TaskStepStatus.succeeded, exitCode: 0);
    task.step(1, TaskStepStatus.succeeded);
    task.finish(const TaskVerification(true, '目标版本已验证'));
    return const TaskVerification(true, '目标版本已验证');
  }
}

const snapshot = MaintenanceSnapshot([
  ManagedPackage(
    manager: MaintenanceManager.formula,
    id: 'gh',
    version: '2.102.0',
    latest: '2.102.0',
    location: '/opt/homebrew/Cellar/gh',
  ),
  ManagedPackage(
    manager: MaintenanceManager.formula,
    id: 'wget',
    version: '1.25.0',
    latest: '1.25.0',
    location: '/opt/homebrew/Cellar/wget',
  ),
  ManagedPackage(
    manager: MaintenanceManager.formula,
    id: 'mise',
    version: '2026.10.8',
    latest: '2026.10.12',
    location: '/opt/homebrew/Cellar/mise',
  ),
  ManagedPackage(
    manager: MaintenanceManager.android,
    id: 'platforms;android-33',
    version: '3.0.0',
    location:
        '/Users/example/Developer/toolchains/android/sdk/platforms/android-33',
  ),
]);
void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_MAINTENANCE'] == '1';
  setUpAll(() async {
    if (!render) return;
    final bytes = File(
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
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
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
  final boundary = GlobalKey();
  Future<(ProviderContainer, PreviewService)> app(
    WidgetTester tester, {
    double width = 1500,
    String route = '/maintenance',
  }) async {
    tester.view.physicalSize = Size(width, 1300);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(
      overrides: [
        ...isolatedWorkbenchOverrides(),
        miseAvailableProvider.overrideWith((ref) async => false),
        maintenanceSnapshotProvider.overrideWith((ref) async => snapshot),
        maintenanceServiceProvider.overrideWith(
          (ref) => PreviewService(ref.read(taskCenterProvider.notifier)),
        ),
        appVersionInfoProvider.overrideWith(
          (ref) async => const AppVersionInfo(
            appName: 'DevWorkbench',
            packageName: 'com.couai.miseGui',
            version: '1.5.0',
            buildNumber: '15',
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
    return (c, c.read(maintenanceServiceProvider) as PreviewService);
  }

  testWidgets(
    'maintenance works without mise, filters by actual manager and disables protected package actions',
    (tester) async {
      await app(tester);
      expect(find.text('这台电脑还没有安装 mise'), findsNothing);
      expect(find.text('gh'), findsOneWidget);
      expect(find.text('platforms;android-33'), findsNothing);
      final card = find.byKey(const ValueKey('maintenance-formula:mise'));
      final buttons = find.descendant(
        of: card,
        matching: find.byType(OutlinedButton),
      );
      expect(buttons, findsNWidgets(2));
      for (final element in buttons.evaluate()) {
        expect((element.widget as OutlinedButton).onPressed, isNull);
      }
      await tester.tap(find.widgetWithText(ChoiceChip, 'Android SDK'));
      await tester.pumpAndSettle();
      expect(find.text('platforms;android-33'), findsOneWidget);
      expect(find.text('gh'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'preview can cancel safely and only confirmed operation reaches task center',
    (tester) async {
      final (c, service) = await app(tester);
      await tester.enterText(find.byType(TextField).first, 'jq');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(service.executions, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(service.executions, 0);
      await tester.enterText(find.byType(TextField).first, 'jq');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认安装 jq'));
      await tester.pumpAndSettle();
      expect(service.executions, 1);
      expect(
        c.read(appRouterProvider).routeInformationProvider.value.uri.path,
        '/tasks',
      );
      expect(find.text('目标版本已验证'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'scoped cache actions, deep links and narrow windows remain usable',
    (tester) async {
      final (c, _) = await app(
        tester,
        width: 740,
        route: '/maintenance?tool=pip',
      );
      expect(find.text('预览清理 pip'), findsOneWidget);
      expect(find.text('预览清理 go'), findsOneWidget);
      c.read(appRouterProvider).go('/maintenance?tool=android-sdk');
      await tester.pumpAndSettle();
      expect(find.text('platforms;android-33'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('render maintenance page', (tester) async {
    await app(tester);
    expect(tester.takeException(), isNull);
    if (render) {
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'docs/design/maintenance.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
