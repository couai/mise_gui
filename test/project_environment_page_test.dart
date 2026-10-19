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
import 'package:mise_gui/features/projects/application/projects_provider.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/project_launcher.dart';
import 'package:mise_gui/services/project_version_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'classified_toolchain_service_test.dart' show InventoryProcess;
import 'tools_version_scope_test.dart' show settleIO;
import 'project_environment_test.dart' show OpenProcess;
import 'workbench_test_overrides.dart';

class PreviewActions implements MiseActionService {
  int executions = 0;
  @override
  Future<MiseActionResult> runScript(
    String script, {
    String? workingDirectory,
    void Function(MiseActionProgressEvent)? onProgress,
  }) async {
    executions++;
    return MiseActionResult(
      script: script,
      commands: [
        ExecutedMiseCommand(
          command: script,
          stdout: '',
          stderr: '',
          exitCode: 0,
          duration: Duration.zero,
        ),
      ],
    );
  }
}

ProjectRecord project(String name, String stack, String path) => ProjectRecord(
  name: name,
  path: path,
  scanRootPath: '/Users/example/WorkSpace',
  configPath: '$path/package.json',
  environment: stack,
  lastScan: '10:30',
  commandPreview: '',
  bindings: [],
  level: HealthLevel.healthy,
  notes: 'fixture',
);

void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_PROJECTS'] == '1';
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
  late Directory temp;
  late String path;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'devworkbench-project-ui-',
    );
    temp = Directory(await created.resolveSymbolicLinks());
    path = '${temp.path}/shop-web';
    Directory(path).createSync();
  });
  tearDown(() async => temp.delete(recursive: true));

  Future<(ProviderContainer, PreviewActions, OpenProcess)> app(
    WidgetTester tester, {
    double width = 1500,
    String? route,
    ProjectCoverageSnapshot? coverage,
  }) async {
    tester.view.physicalSize = Size(width, 1350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final layout = ToolchainLayout(home: temp.path),
        actions = PreviewActions(),
        open = OpenProcess();
    final policy = ClassifiedToolchainService(
      InventoryProcess({
        'node': [
          for (final v in ['24.21.0', '22.20.0'])
            {
              'version': v,
              'installed': true,
              'active': v == '24.21.0',
              'install_path': layout.installTarget('node', v),
            },
        ],
      }),
      layout,
    );
    final c = ProviderContainer(
      overrides: [
        ...isolatedWorkbenchOverrides(),
        miseAvailableProvider.overrideWith((ref) async => false),
        projectVersionServiceProvider.overrideWithValue(
          ProjectVersionService(policy, actions),
        ),
        projectLauncherProvider.overrideWithValue(ProjectLauncher(open)),
        localToolsProvider.overrideWith(
          (ref) async => LocalToolSnapshot(
            tools: [
              const LocalTool(
                id: 'vscode',
                name: 'Visual Studio Code',
                category: LocalToolCategory.editor,
                description: '',
                status: LocalToolStatus.ready,
                manager: 'Applications',
                source: 'fixture',
                locations: [
                  ToolLocation(
                    label: '应用',
                    path: '/Applications/Visual Studio Code.app',
                    exists: true,
                    application: true,
                  ),
                ],
              ),
              const LocalTool(
                id: 'idea',
                name: 'IntelliJ IDEA',
                category: LocalToolCategory.editor,
                description: '',
                status: LocalToolStatus.ready,
                manager: 'Applications',
                source: 'fixture',
                locations: [
                  ToolLocation(
                    label: '应用',
                    path: '/Applications/IntelliJ IDEA.app',
                    exists: true,
                    application: true,
                  ),
                ],
              ),
            ],
            scannedAt: DateTime.now(),
          ),
        ),
        classifiedVersionsProvider.overrideWith(
          (ref) async => [
            for (final v in ['24.21.0', '22.20.0'])
              ClassifiedVersion(
                tool: 'node',
                version: v,
                active: v == '24.21.0',
                registeredPath: layout.installTarget('node', v),
                actualPath: layout.installTarget('node', v),
                classified: true,
              ),
          ],
        ),
        projectEnvironmentProvider.overrideWith(
          (ref, arg) async => ProjectEnvironment(
            ProjectProfile(
              path: arg,
              name: 'shop-web',
              stacks: ['Node.js', 'Vue', 'TypeScript'],
              evidence: ['package.json', 'mise.toml'],
              toolIds: ['node', 'pnpm'],
              scripts: [ProjectScript('dev', "cd '$arg' && pnpm run 'dev'")],
              brunoPath: '$arg/api/bruno',
            ),
            const [
              ProjectToolCheck(
                tool: 'node',
                requirements: [
                  ProjectRequirement(
                    'node',
                    '>=24.0.0 <25.0.0',
                    'package.json · engines',
                    kind: ProjectRequirementKind.constraint,
                  ),
                ],
                installed: ['24.21.0', '22.20.0'],
                effective: '24.21.0',
                source: 'mise.toml',
                state: ProjectToolState.satisfied,
              ),
              ProjectToolCheck(
                tool: 'pnpm',
                requirements: [
                  ProjectRequirement(
                    'pnpm',
                    '12.11.2',
                    'package.json · packageManager',
                    kind: ProjectRequirementKind.exact,
                  ),
                ],
                installed: ['12.11.2'],
                effective: '12.11.2',
                source: '本机工具探测',
                state: ProjectToolState.review,
                detail: '项目包管理器版本需核对 Corepack 设置。',
              ),
            ],
            DateTime(2026, 10, 19, 10, 30),
          ),
        ),
        projectCoverageProvider.overrideWith(
          (ref) async =>
              coverage ??
              ProjectCoverageSnapshot(
                scanDirectories: const [
                  ScanDirectoryRecord(path: '/Users/example/WorkSpace'),
                ],
                projects: [
                  project(
                    'shop-web',
                    'Node.js · Vue · TypeScript',
                    render ? '/Users/example/WorkSpace/shop-web' : path,
                  ),
                  project(
                    'order-api',
                    'Java / Maven · Spring Boot',
                    '/Users/example/WorkSpace/order-api',
                  ),
                  project(
                    'analysis-service',
                    'Python · FastAPI',
                    '/Users/example/WorkSpace/analysis-service',
                  ),
                  project(
                    'mobile-client',
                    'Flutter',
                    '/Users/example/WorkSpace/mobile-client',
                  ),
                ],
              ),
        ),
        appVersionInfoProvider.overrideWith(
          (ref) async => const AppVersionInfo(
            appName: 'DevWorkbench',
            packageName: 'com.couai.miseGui',
            version: '1.6.1',
            buildNumber: '17',
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.read(themePreferenceProvider.notifier).state = AppThemePreference.dark;
    c
        .read(appRouterProvider)
        .go(
          route ??
              Uri(
                path: '/projects/environment',
                queryParameters: {'path': path},
              ).toString(),
        );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: RepaintBoundary(key: boundary, child: const MiseGuiApp()),
      ),
    );
    await tester.pumpAndSettle();
    return (c, actions, open);
  }

  testWidgets(
    'projects remain accessible without mise and link manifest-only projects',
    (tester) async {
      final (c, _, _) = await app(tester, route: '/projects');
      expect(find.text('这台电脑还没有安装 mise'), findsNothing);
      expect(find.text('Node.js · Vue · TypeScript'), findsOneWidget);
      await tester.tap(find.text('Node.js · Vue · TypeScript'));
      await tester.pumpAndSettle();
      expect(
        c.read(appRouterProvider).routeInformationProvider.value.uri.path,
        '/projects/environment',
      );
      expect(find.text('版本要求与实际环境'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pinning requires preview confirmation; cancel performs no action',
    (tester) async {
      final (_, actions, _) = await app(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('22.20.0').last);
      await tester.pumpAndSettle();
      Future<void> preview() async {
        await tester.ensureVisible(find.text('固定到本项目'));
        await tester.tap(find.text('固定到本项目'));
        await settleIO(tester, () => find.byType(Dialog).evaluate().isNotEmpty);
      }

      await preview();
      expect(find.text('$path/mise.toml'), findsWidgets);
      expect(actions.executions, 0);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(actions.executions, 0);
      await preview();
      await tester.tap(find.text('确认固定项目版本'));
      await settleIO(tester, () => actions.executions == 1);
      expect(actions.executions, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('search and project detail fit narrow windows', (tester) async {
    final (c, _, _) = await app(tester, width: 740, route: '/projects');
    await tester.enterText(find.byType(TextField).first, 'FastAPI');
    await tester.pumpAndSettle();
    expect(find.text('Python · FastAPI'), findsOneWidget);
    expect(find.text('Node.js · Vue · TypeScript'), findsNothing);
    c
        .read(appRouterProvider)
        .go(
          Uri(
            path: '/projects/environment',
            queryParameters: {'path': path},
          ).toString(),
        );
    await tester.pumpAndSettle();
    expect(find.text('实际生效：24.21.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final width in [1500.0, 740.0]) {
    testWidgets(
      'partial scan shows root failures and bounded discovery at width $width',
      (tester) async {
        const root = '/Users/example/WorkSpace';
        await app(
          tester,
          width: width,
          route: '/projects',
          coverage: ProjectCoverageSnapshot(
            scanDirectories: const [ScanDirectoryRecord(path: root)],
            projects: [project('order-api', 'Java / Maven', '$root/order-api')],
            scanRoots: const [
              ProjectScanRootReport(
                path: root,
                visitedDirectories: 240,
                projectCount: 1,
                issues: [
                  '达到目录上限 240，部分路径未扫描。',
                  '目录读取失败：/Users/example/WorkSpace/denied',
                ],
              ),
            ],
          ),
        );
        expect(find.text('项目扫描不完整'), findsOneWidget);
        expect(find.text('项目环境 · 已发现 1'), findsOneWidget);
        expect(find.text('扫描中'), findsNothing);
        await tester.tap(find.text('查看扫描范围和原因'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('目录读取失败：/Users/example/WorkSpace/denied'),
          findsWidgets,
        );
        expect(tester.takeException(), isNull);
        if (render && width == 1500) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1.5);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'docs/design/project-scan-incomplete.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }

  testWidgets('render real project pages with isolated metadata fixtures', (
    tester,
  ) async {
    final (c, _, _) = await app(tester, route: '/projects');
    Future<void> save(String file) async {
      if (!render) return;
      await tester.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1.5);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          'docs/design/$file.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }

    await save('project-workbench');
    c
        .read(appRouterProvider)
        .go(
          Uri(
            path: '/projects/environment',
            queryParameters: {'path': '/Users/example/WorkSpace/shop-web'},
          ).toString(),
        );
    await tester.pumpAndSettle();
    await save('project-environment');
    expect(tester.takeException(), isNull);
  });
}
