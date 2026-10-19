import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/features/projects/presentation/project_runtime_details.dart';
import 'package:mise_gui/models/project_environment.dart';

void main() {
  final render = Platform.environment['DEVWORKBENCH_RENDER_PROJECTS'] == '1';
  setUpAll(() async {
    if (!render) return;
    final bytes = File(
      Platform.environment['MISE_GUI_PREVIEW_CJK_FONT']!,
    ).readAsBytesSync();
    await (FontLoader(
      'Roboto',
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    final icons = File(
      Platform.environment['MISE_GUI_PREVIEW_MATERIAL_FONT']!,
    ).readAsBytesSync();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(Future.value(ByteData.sublistView(icons)))).load();
  });
  for (final width in [1200.0, 400.0]) {
    testWidgets(
      'project diagnostics fit width $width and open exact module/venv paths',
      (tester) async {
        tester.view.physicalSize = Size(width, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final opened = <String>[];
        final boundary = GlobalKey();
        const base = '/Users/example/WorkSpace/order-service';
        const module = ProjectJavaModule(
          path: '$base/api',
          name: 'api',
          manager: 'Gradle',
          buildFile: 'api/build.gradle.kts',
          wrapperVersion: '8.14.3',
          requirements: [
            ProjectRequirement(
              'java',
              '17',
              'build.gradle.kts · java.toolchain',
            ),
          ],
        );
        final environment = ProjectEnvironment(
          const ProjectProfile(path: base, name: 'order-service'),
          const [],
          DateTime(2026, 10, 19),
          pythonEnvironments: const [
            ProjectPythonEnvironment(
              path: '$base/.venv',
              selected: true,
              selection: 'mise 项目虚拟环境声明',
              version: '3.14.8',
              pipVersion: '26.2.1',
              interpreter:
                  '/Users/example/Developer/toolchains/python/versions/3.14.8/bin/python3.14',
            ),
            ProjectPythonEnvironment(
              path: '$base/venv',
              selected: false,
              selection: '项目候选环境 · 未确认终端已激活',
              issue: '虚拟环境解释器链接失效。',
            ),
          ],
          modules: [
            const ProjectModuleCheck(
              module,
              javaVersion: 'oracle-21.0.12.1',
              javaSource: '$base/mise.toml',
              state: ProjectToolState.review,
              detail: '编译工具链与启动 JVM 分开；Gradle 实际编译 JDK 需由构建确认。',
            ),
          ],
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark(useMaterial3: true),
            home: Scaffold(
              body: RepaintBoundary(
                key: boundary,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ProjectRuntimeDetails(
                    environment: environment,
                    onOpen: opened.add,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Python 项目虚拟环境'), findsOneWidget);
        expect(find.text('项目已选择 · mise 项目虚拟环境声明'), findsOneWidget);
        expect(find.text('Java / Gradle 模块 · 1'), findsOneWidget);
        expect(find.text('Gradle Wrapper 声明：8.14.3'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (render && width == 1200) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()!
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File(
              'docs/design/project-diagnostics.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.ensureVisible(find.text('打开模块目录'));
        await tester.tap(find.text('打开模块目录'));
        expect(opened, ['$base/api']);
        await tester.ensureVisible(find.text('打开虚拟环境目录').first);
        await tester.tap(find.text('打开虚拟环境目录').first);
        expect(opened.last, '$base/.venv');
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('empty runtime details do not add an empty panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectRuntimeDetails(
          environment: ProjectEnvironment(
            const ProjectProfile(path: '/fixture', name: 'fixture'),
            const [],
            DateTime(2026),
          ),
          onOpen: (_) => fail('No open expected'),
        ),
      ),
    );
    expect(find.text('Python 项目虚拟环境'), findsNothing);
    expect(find.byType(Card), findsNothing);
  });
}
