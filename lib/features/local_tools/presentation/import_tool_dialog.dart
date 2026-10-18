import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/local_tool_registry.dart';

class ImportToolDialog extends ConsumerStatefulWidget {
  const ImportToolDialog({super.key, required this.knownTools});
  final List<LocalTool> knownTools;
  @override
  ConsumerState<ImportToolDialog> createState() => _ImportToolDialogState();
}

class _ImportToolDialogState extends ConsumerState<ImportToolDialog> {
  final fields = List.generate(7, (_) => TextEditingController());
  bool application = true, saving = false, selecting = false;
  LocalToolCategory category = LocalToolCategory.utility;
  String? error;
  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> browse() async {
    setState(() {
      selecting = true;
      error = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: application
            ? const [
                XTypeGroup(
                  label: 'macOS 应用',
                  extensions: ['app'],
                  uniformTypeIdentifiers: ['com.apple.application-bundle'],
                ),
              ]
            : const [],
      );
      if (!mounted || file == null) return;
      fields[1].text = file.path;
      if (fields[0].text.isEmpty) {
        fields[0].text = file.name.replaceFirst(RegExp(r'\.app$'), '');
      }
    } catch (_) {
      if (mounted) setState(() => error = '无法打开文件选择器，请直接填写完整路径。');
    } finally {
      if (mounted) setState(() => selecting = false);
    }
  }

  Future<void> save() async {
    if (saving) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final result = await ref
          .read(localToolRegistryProvider)
          .importTool(
            ImportedTool(
              id: '',
              name: fields[0].text,
              path: fields[1].text.trim(),
              category: category,
              application: application,
              version: fields[2].text,
              description: fields[3].text,
              configPath: fields[4].text.trim(),
              cachePath: fields[5].text.trim(),
              logsPath: fields[6].text.trim(),
            ),
            knownTools: widget.knownTools,
          );
      if (mounted) Navigator.of(context).pop(result.id);
    } catch (e) {
      if (mounted) setState(() => error = '导入失败：$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Widget field(int i, String label, {String? hint}) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: TextField(
      controller: fields[i],
      enabled: !saving,
      decoration: InputDecoration(labelText: label, hintText: hint),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('导入已有工具'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('选择本机已安装的应用或 CLI，登记到工作台。文件保留在原位置，扫描不会运行导入的 CLI。'),
            const SizedBox(height: 20),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: true, label: Text('macOS 应用')),
                ButtonSegment(value: false, label: Text('CLI 文件')),
              ],
              selected: {application},
              onSelectionChanged: saving
                  ? null
                  : (v) => setState(() {
                      application = v.first;
                      error = null;
                    }),
            ),
            const SizedBox(height: 20),
            field(0, '工具名称'),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: field(
                    1,
                    application ? '应用完整路径' : '可执行文件完整路径',
                    hint: application
                        ? '/Applications/Example.app'
                        : '/opt/homebrew/bin/example',
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: saving || selecting ? null : browse,
                  child: const Text('浏览'),
                ),
              ],
            ),
            DropdownButtonFormField<LocalToolCategory>(
              initialValue: category,
              decoration: const InputDecoration(labelText: '分类'),
              items: [
                for (final c in LocalToolCategory.values)
                  DropdownMenuItem(value: c, child: Text(c.label)),
              ],
              onChanged: saving ? null : (v) => setState(() => category = v!),
            ),
            const SizedBox(height: 16),
            field(2, '版本（可选，手动登记）', hint: '应用优先读取包版本；CLI 不执行探测'),
            field(3, '用途说明（可选）'),
            ExpansionTile(
              title: const Text('配置、缓存与日志位置（可选）'),
              tilePadding: EdgeInsets.zero,
              children: [
                field(4, '配置 / 数据路径'),
                field(5, '缓存路径'),
                field(6, '日志路径'),
              ],
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.of(context).pop(),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: saving || selecting ? null : save,
        child: Text(saving ? '正在登记…' : '导入工具'),
      ),
    ],
  );
}
