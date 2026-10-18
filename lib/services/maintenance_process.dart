import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/models/maintenance.dart';

abstract interface class MaintenanceProcess {
  Future<LocalCommandResult> run(
    MaintenanceCommand command, {
    required Map<String, String> environment,
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    void Function(String)? onOutput,
  });
}

class SystemMaintenanceProcess implements MaintenanceProcess {
  const SystemMaintenanceProcess();
  @override
  Future<LocalCommandResult> run(
    MaintenanceCommand command, {
    required Map<String, String> environment,
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    void Function(String)? onOutput,
  }) async {
    final process = await Process.start(
      command.executable,
      command.arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    // No automatic agreement/password input; interactive installers fail visibly.
    await process.stdin.close();
    var out = '', err = '';
    final streams = [
      process.stdout.transform(const Utf8Decoder(allowMalformed: true)).listen((
        s,
      ) {
        if (out.length < 8 * 1024 * 1024) {
          out += (s.substring(
            0,
            s.length.clamp(0, 8 * 1024 * 1024 - out.length),
          ));
        }
        onOutput?.call(s);
      }),
      process.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((
        s,
      ) {
        if (err.length < 512 * 1024) {
          err += (s.substring(0, s.length.clamp(0, 512 * 1024 - err.length)));
        }
        onOutput?.call(s);
      }),
    ];
    final drained = Future.wait(streams.map((s) => s.asFuture<void>()));
    try {
      final code = await process.exitCode.timeout(timeout);
      await drained.timeout(const Duration(seconds: 3));
      return LocalCommandResult(code, out, err);
    } on TimeoutException {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 1));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      throw TimeoutException('管理器命令超时，已终止直接启动的进程；请检查任务输出与实际安装状态。', timeout);
    } finally {
      for (final s in streams) {
        await s.cancel();
      }
    }
  }
}
