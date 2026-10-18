import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/manager_check_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';

final managerCheckServiceProvider = Provider(
  (ref) => ManagerCheckService(
    ref.watch(localToolProcessProvider),
    ref.watch(miseProcessServiceProvider),
  ),
);

class ManagerSettingsPage extends ConsumerStatefulWidget {
  const ManagerSettingsPage({super.key});
  @override
  ConsumerState<ManagerSettingsPage> createState() =>
      _ManagerSettingsPageState();
}

class _ManagerSettingsPageState extends ConsumerState<ManagerSettingsPage> {
  late final List<TextEditingController> fields;
  late bool offline;
  bool saving = false;
  String? feedback;
  @override
  void initState() {
    super.initState();
    final s = ref.read(managerSettingsProvider);
    fields = [
      s.miseExecutable,
      s.brewExecutable,
      s.homebrewPrefix,
      s.androidSdk,
      s.xcodeDeveloper,
      '${s.actionTimeoutMinutes}',
      '${s.probeTimeoutSeconds}',
      '${s.storageTimeoutSeconds}',
    ].map((v) => TextEditingController(text: v)).toList();
    offline = s.miseOffline;
  }

  @override
  void dispose() {
    for (final f in fields) {
      f.dispose();
    }
    super.dispose();
  }

  ManagerSettings draft() => ManagerSettings(
    miseExecutable: fields[0].text.trim(),
    brewExecutable: fields[1].text.trim(),
    homebrewPrefix: fields[2].text.trim(),
    androidSdk: fields[3].text.trim(),
    xcodeDeveloper: fields[4].text.trim(),
    miseOffline: offline,
    actionTimeoutMinutes: int.tryParse(fields[5].text) ?? 0,
    probeTimeoutSeconds: int.tryParse(fields[6].text) ?? 0,
    storageTimeoutSeconds: int.tryParse(fields[7].text) ?? 0,
  );
  Future<void> save() async {
    final center = ref.read(taskCenterProvider.notifier);
    if (center.busy || saving) return;
    setState(() => saving = true);
    final task = center.startMutation('保存管理器配置', '管理器设置', [
      '验证配置路径',
      '原子保存配置',
      '应用后续操作设置',
    ]);
    task.step(0, TaskStepStatus.running);
    try {
      final value = draft();
      await value.validatePaths();
      task.step(0, TaskStepStatus.succeeded);
      task.step(1, TaskStepStatus.running);
      await ref.read(managerSettingsProvider.notifier).save(value);
      task.step(1, TaskStepStatus.succeeded);
      task.step(2, TaskStepStatus.succeeded);
      task.finish(
        const TaskVerification(
          true,
          '配置已保存，后续命令、工具识别和目录扫描使用新设置。可运行“检查管理器”验证版本。',
        ),
      );
      if (mounted) setState(() => feedback = '配置已保存并生效。');
    } catch (error) {
      task.output('$error\n');
      task.finish(TaskVerification(false, '配置保存失败：$error'));
      if (mounted) setState(() => feedback = '$error');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> check() async {
    try {
      final value = draft();
      value.validate();
      final future = ref
          .read(managerCheckServiceProvider)
          .check(
            value,
            ref.read(managerLayoutProvider),
            ref.read(taskCenterProvider.notifier),
          );
      context.go('/tasks');
      await future;
    } catch (error) {
      if (mounted) setState(() => feedback = '$error');
    }
  }

  Widget field(
    int index,
    String label, {
    String? helper,
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 14),
    child: TextField(
      controller: fields[index],
      readOnly: saving,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
      ),
    ),
  );
  Widget card(String title, String description, List<Widget> children) =>
      AppPanel(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(description),
              ...children,
            ],
          ),
        ),
      );
  @override
  Widget build(BuildContext context) {
    final busy = ref.watch(taskCenterProvider).busy;
    final error = ref.watch(managerSettingsStoreProvider).error;
    return AppPageScaffold(
      title: '管理器设置',
      description: '配置管理器路径与执行选项',
      actions: [
        OutlinedButton.icon(
          onPressed: busy || saving ? null : check,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('检查管理器'),
        ),
        FilledButton.icon(
          onPressed: busy || saving || error != null ? null : save,
          icon: const Icon(Icons.save_outlined),
          label: Text(saving ? '保存中…' : '保存设置'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设置仅作用于 DevWorkbench。路径变更后重新识别工具和扫描目录；已有 SDK 与缓存保留在原处。',
                ),
                const SizedBox(height: 6),
                Text(
                  '配置文件：${ToolchainLayout.current.appDir}/config/managers.json',
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('任务执行期间暂不能保存配置或启动检查。'),
                  ),
                if (error != null)
                  Text(error, style: const TextStyle(color: Colors.orange)),
                if (feedback != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(feedback!),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          LayoutBuilder(
            builder: (context, c) {
              final width = c.maxWidth >= 900
                  ? (c.maxWidth - 18) / 2
                  : c.maxWidth;
              return Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  SizedBox(
                    width: width,
                    child: card(
                      'mise',
                      '负责六类运行时的分类安装、注册与版本切换；Rust 继续由 rustup 提供工具链。',
                      [
                        field(
                          0,
                          'mise 程序路径',
                          helper: '留空沿用登录 Shell 自动查找；填写可执行文件绝对路径。',
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('强制离线模式'),
                          subtitle: const Text(
                            '开启后限制远端查询与下载；关闭时沿用 mise 自身的网络配置。',
                          ),
                          value: offline,
                          onChanged: saving
                              ? null
                              : (v) => setState(() => offline = v),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: card('Homebrew', '用于程序识别与本地版本检查。安装和更新操作将在后续阶段接入。', [
                      field(1, 'brew 程序路径'),
                      field(
                        2,
                        'Homebrew 安装前缀',
                        helper: '用于目录归属判断；本地检查固定关闭自动更新与分析。',
                      ),
                    ]),
                  ),
                  SizedBox(
                    width: width,
                    child: card(
                      'Android SDK',
                      '用于平台、NDK、CMake 与 ADB 的识别，以及 SDK 管理器版本检查。',
                      [
                        field(
                          3,
                          'Android SDK 目录',
                          helper:
                              '设置 ANDROID_HOME / ANDROID_SDK_ROOT；使用 cmdline-tools/latest/bin/sdkmanager 检查。',
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: width,
                    child: card(
                      'Xcode',
                      '用于 Apple 工具链检查，并通过 DEVELOPER_DIR 传递给后续命令。',
                      [
                        field(
                          4,
                          'Xcode Developer 目录',
                          helper:
                              '通常为 /Applications/Xcode.app/Contents/Developer；应用仍安装在 /Applications。',
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          card('执行与扫描', '在任务中心查看命令结果和失败详情。', [
            field(5, 'mise 操作超时（分钟，1–120）', numeric: true),
            field(6, '本地版本检查超时（秒，1–30）', numeric: true),
            field(7, '单目录测量超时（秒，1–300）', numeric: true),
          ]),
        ],
      ),
    );
  }
}
