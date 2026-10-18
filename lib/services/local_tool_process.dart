import 'dart:async';
import 'dart:convert';
import 'dart:io';

class LocalCommandResult {
  const LocalCommandResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout, stderr;
}

/// Probes and OS open commands use argument arrays, never shell interpolation.
abstract interface class LocalToolProcess {
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  });
}

class SystemLocalToolProcess implements LocalToolProcess {
  const SystemLocalToolProcess();

  @override
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    // Drain both streams even after the output cap; a noisy probe cannot deadlock.
    final out = <int>[];
    final err = <int>[];
    void collect(List<int> target, List<int> chunk) {
      const cap = 128 * 1024;
      if (target.length < cap) target.addAll(chunk.take(cap - target.length));
    }

    final stdoutSub = process.stdout.listen((chunk) => collect(out, chunk));
    final stderrSub = process.stderr.listen((chunk) => collect(err, chunk));
    final drained = Future.wait([
      stdoutSub.asFuture<void>(),
      stderrSub.asFuture<void>(),
    ]);
    try {
      final code = await process.exitCode.timeout(timeout);
      await drained.timeout(const Duration(seconds: 1));
      return LocalCommandResult(
        code,
        utf8.decode(out, allowMalformed: true),
        utf8.decode(err, allowMalformed: true),
      );
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw TimeoutException('本地命令检查超时', timeout);
    } finally {
      await stdoutSub.cancel();
      await stderrSub.cancel();
    }
  }
}

abstract interface class LocalToolOpener {
  Future<void> open(String path, {bool application = false});
}

class MacLocalToolOpener implements LocalToolOpener {
  const MacLocalToolOpener(this.process);
  final LocalToolProcess process;

  @override
  Future<void> open(String path, {bool application = false}) async {
    if (!Platform.isMacOS) throw UnsupportedError('快速打开目前支持 macOS。');
    if (!File(path).isAbsolute ||
        await FileSystemEntity.type(path) == FileSystemEntityType.notFound) {
      throw StateError('路径已不存在，请重新扫描。');
    }
    final directory = await Directory(path).exists();
    if (application && (!directory || !path.endsWith('.app'))) {
      throw ArgumentError('应用路径必须是现有的 .app。');
    }
    final result = await process.run('/usr/bin/open', [
      if (!directory && !application) '-R',
      path,
    ]);
    if (result.exitCode != 0) throw StateError('macOS 无法打开此路径。');
  }
}
