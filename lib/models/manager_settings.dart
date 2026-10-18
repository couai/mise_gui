import 'dart:io';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Only declared options are executable; no free-form flags or shell fragments.
class ManagerSettings {
  const ManagerSettings({
    this.miseExecutable = '',
    this.brewExecutable = '/opt/homebrew/bin/brew',
    this.homebrewPrefix = '/opt/homebrew',
    required this.androidSdk,
    this.xcodeDeveloper = '/Applications/Xcode.app/Contents/Developer',
    this.miseOffline = false,
    this.actionTimeoutMinutes = 30,
    this.probeTimeoutSeconds = 5,
    this.storageTimeoutSeconds = 30,
  });
  factory ManagerSettings.defaults(ToolchainLayout layout) => ManagerSettings(
    androidSdk:
        layout.environment['ANDROID_HOME'] ?? '${layout.root}/android/sdk',
    xcodeDeveloper:
        layout.environment['DEVELOPER_DIR'] ??
        '/Applications/Xcode.app/Contents/Developer',
  );
  final String miseExecutable,
      brewExecutable,
      homebrewPrefix,
      androidSdk,
      xcodeDeveloper;
  final bool miseOffline;
  final int actionTimeoutMinutes, probeTimeoutSeconds, storageTimeoutSeconds;
  Map<String, String> get environment => {
    'ANDROID_HOME': androidSdk,
    'ANDROID_SDK_ROOT': androidSdk,
    'DEVELOPER_DIR': xcodeDeveloper,
    if (miseOffline) 'MISE_OFFLINE': '1',
    'HOMEBREW_NO_AUTO_UPDATE': '1',
    'HOMEBREW_NO_ANALYTICS': '1',
  };
  Map<String, dynamic> toJson() => {
    'schema': 1,
    'miseExecutable': miseExecutable,
    'brewExecutable': brewExecutable,
    'homebrewPrefix': homebrewPrefix,
    'androidSdk': androidSdk,
    'xcodeDeveloper': xcodeDeveloper,
    'miseOffline': miseOffline,
    'actionTimeoutMinutes': actionTimeoutMinutes,
    'probeTimeoutSeconds': probeTimeoutSeconds,
    'storageTimeoutSeconds': storageTimeoutSeconds,
  };
  factory ManagerSettings.fromJson(Map<String, dynamic> j) => ManagerSettings(
    miseExecutable: j['miseExecutable'] as String,
    brewExecutable: j['brewExecutable'] as String,
    homebrewPrefix: j['homebrewPrefix'] as String,
    androidSdk: j['androidSdk'] as String,
    xcodeDeveloper: j['xcodeDeveloper'] as String,
    miseOffline: j['miseOffline'] as bool,
    actionTimeoutMinutes: j['actionTimeoutMinutes'] as int,
    probeTimeoutSeconds: j['probeTimeoutSeconds'] as int,
    storageTimeoutSeconds: j['storageTimeoutSeconds'] as int,
  );
  void validate() {
    for (final value in [
      miseExecutable,
      brewExecutable,
      homebrewPrefix,
      androidSdk,
      xcodeDeveloper,
    ]) {
      if (value.isEmpty && value == miseExecutable) continue;
      if (!value.startsWith('/') ||
          value.contains(RegExp(r'[\x00-\x1f]')) ||
          value.split('/').contains('..')) {
        throw ArgumentError('路径必须是绝对路径，不能含控制符或 ..');
      }
    }
    if (brewExecutable.isEmpty ||
        homebrewPrefix.isEmpty ||
        androidSdk.isEmpty ||
        xcodeDeveloper.isEmpty) {
      throw ArgumentError('仅 mise 程序路径允许留空以自动查找');
    }
    if (actionTimeoutMinutes < 1 ||
        actionTimeoutMinutes > 120 ||
        probeTimeoutSeconds < 1 ||
        probeTimeoutSeconds > 30 ||
        storageTimeoutSeconds < 1 ||
        storageTimeoutSeconds > 300) {
      throw ArgumentError('操作超时范围 1–120 分钟；检查 1–30 秒；目录测量 1–300 秒');
    }
  }

  Future<void> validatePaths() async {
    validate();
    for (final path in [miseExecutable, brewExecutable]) {
      if (path.isNotEmpty &&
          (!await File(path).exists() ||
              (await File(path).stat()).mode & 0x49 == 0)) {
        throw ArgumentError('程序不存在或不可执行：$path');
      }
    }
    for (final path in [homebrewPrefix, androidSdk, xcodeDeveloper]) {
      if (!await Directory(path).exists()) throw ArgumentError('目录不存在：$path');
    }
  }
}
