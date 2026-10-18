import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/models/storage_models.dart';

class DirectoryScanCancellation {
  bool get cancelled => _cancelled;
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  void Function() listen(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
    return () => _listeners.remove(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }
}

abstract interface class DirectoryUsageReader {
  Future<StorageUsage> measure(
    String path,
    DirectoryScanCancellation cancellation,
  );
}

/// Allocated blocks from native du; never reads file payloads or follows inner
/// symlinks. Each invocation stays on one filesystem and can be killed on cancel.
class PosixDirectoryUsageReader implements DirectoryUsageReader {
  const PosixDirectoryUsageReader({
    this.timeout = const Duration(seconds: 30),
    this.executable = '/usr/bin/du',
  });
  final Duration timeout;
  final String executable;
  @override
  Future<StorageUsage> measure(
    String path,
    DirectoryScanCancellation cancellation,
  ) async {
    if (cancellation.cancelled) {
      return const StorageUsage(StorageUsageState.cancelled);
    }
    Process? process;
    var running = false;
    void Function()? unsubscribe;
    StreamSubscription<List<int>>? outSub, errSub;
    final output = <int>[];
    try {
      process = await Process.start(
        executable,
        ['-sk', '-P', '-x', path],
        runInShell: false,
        environment: const {'LC_ALL': 'C'},
        workingDirectory: '/',
      );
      final child = process;
      running = true;
      unsubscribe = cancellation.listen(() {
        if (running) child.kill(ProcessSignal.sigkill);
      });
      outSub = child.stdout.listen((chunk) {
        if (output.length < 65536) {
          output.addAll(chunk.take(65536 - output.length));
        }
      });
      errSub = child.stderr.listen((_) {});
      final drained = Future.wait([
        outSub.asFuture<void>(),
        errSub.asFuture<void>(),
      ]);
      final code = await child.exitCode
          .then((code) {
            running = false;
            return code;
          })
          .timeout(timeout);
      await drained.timeout(const Duration(seconds: 1));
      if (cancellation.cancelled) {
        return const StorageUsage(StorageUsageState.cancelled);
      }
      final value = RegExp(
        r'^\s*(\d+)\s',
      ).firstMatch(utf8.decode(output, allowMalformed: true))?.group(1);
      final kib = value == null ? null : int.tryParse(value);
      if (kib == null) {
        return const StorageUsage(
          StorageUsageState.failed,
          note: '未取得有效的磁盘占用结果。',
        );
      }
      return StorageUsage(
        code == 0 ? StorageUsageState.complete : StorageUsageState.partial,
        bytes: kib * 1024,
        note: code == 0 ? '' : '部分目录不可读，显示已测下限。',
      );
    } on TimeoutException {
      if (running) process?.kill(ProcessSignal.sigkill);
      return const StorageUsage(
        StorageUsageState.timeout,
        note: '单项测量超过时限，可重新扫描。',
      );
    } catch (_) {
      return StorageUsage(
        cancellation.cancelled
            ? StorageUsageState.cancelled
            : StorageUsageState.failed,
        note: '无法测量，请检查路径和读取权限。',
      );
    } finally {
      unsubscribe?.call();
      if (running) process?.kill(ProcessSignal.sigkill);
      await outSub?.cancel();
      await errSub?.cancel();
    }
  }
}
