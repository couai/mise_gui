import 'dart:convert';
import 'dart:io';

/// Small classified app files. Corrupt originals are retained until repaired.
class WorkbenchJsonStore {
  WorkbenchJsonStore(this.file);
  final File? file;
  bool readable = true;
  String? error;
  dynamic read() {
    try {
      if (file == null || !file!.existsSync()) return null;
      if (file!.lengthSync() > 4 * 1024 * 1024) {
        throw const FormatException('文件过大');
      }
      return jsonDecode(file!.readAsStringSync());
    } catch (_) {
      readable = false;
      error = '配置或记录无法读取，原文件已保留：${file?.path}';
      return null;
    }
  }

  Future<void> write(Object value) async {
    if (!readable) throw StateError(error!);
    if (file == null) return;
    await file!.parent.create(recursive: true);
    final temp = File(
      '${file!.path}.tmp-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(value),
        flush: true,
      );
      if (!Platform.isWindows) {
        final result = await Process.run('/bin/chmod', ['600', temp.path]);
        if (result.exitCode != 0) throw const FileSystemException('无法设置文件权限');
      }
      await temp.rename(file!.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
