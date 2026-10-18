import 'dart:io';

/// One directory policy for UI, persistence and command planning.
class ToolchainLayout {
  ToolchainLayout({
    required this.home,
    Map<String, String> environment = const {},
  }) : environment = Map.unmodifiable(environment);

  static ToolchainLayout current = ToolchainLayout(
    home: Platform.environment['HOME'] ?? Directory.current.path,
    environment: Platform.environment,
  );

  final String home;
  final Map<String, String> environment;
  String get root =>
      environment['MISE_GUI_TOOLCHAINS_ROOT'] ?? '$home/Developer/toolchains';
  String get configDir =>
      environment['MISE_CONFIG_DIR'] ??
      (environment['XDG_CONFIG_HOME'] == null
          ? '$root/mise/config'
          : '${environment['XDG_CONFIG_HOME']}/mise');
  String get globalConfigPath => '$configDir/config.toml';
  String get dataDir =>
      environment['MISE_DATA_DIR'] ??
      (environment['XDG_DATA_HOME'] == null
          ? '$root/mise/data'
          : '${environment['XDG_DATA_HOME']}/mise');
  String get cacheDir =>
      environment['MISE_CACHE_DIR'] ??
      (environment['XDG_CACHE_HOME'] == null
          ? '$root/mise/cache'
          : '${environment['XDG_CACHE_HOME']}/mise');
  String get stateDir =>
      environment['MISE_STATE_DIR'] ??
      (environment['XDG_STATE_HOME'] == null
          ? '$root/mise/state'
          : '${environment['XDG_STATE_HOME']}/mise');
  String get appDir => '$root/mise-gui';
  String get cargoHome => environment['CARGO_HOME'] ?? '$root/rust/cargo';
  String get rustupHome => environment['RUSTUP_HOME'] ?? '$root/rust/rustup';

  static const categories = {
    'java': 'jdk',
    'node': 'nodejs',
    'python': 'python',
    'go': 'go',
    'rust': 'rust',
    'flutter': 'flutter',
  };

  String categoryRoot(String tool) {
    final category = categories[tool];
    if (category == null) {
      throw ArgumentError('首期仅支持 Java、Node.js、Python、Go、Rust、Flutter。');
    }
    return '$root/$category';
  }

  String installTarget(String tool, String version) {
    validateVersion(version);
    return tool == 'rust'
        ? '$cargoHome/bin'
        : '${categoryRoot(tool)}/versions/$version';
  }

  static void validateVersion(String version) {
    // mise link requires an exact version; reject paths, aliases and channels.
    if (!RegExp(
          r'^(?:[a-zA-Z][a-zA-Z0-9]*-)?[0-9]+\.[0-9]+\.[0-9]+[a-zA-Z0-9.+_-]*$',
        ).hasMatch(version) ||
        version.contains('..') ||
        version.toLowerCase().contains('latest')) {
      throw ArgumentError('请选择精确版本，不能使用 latest、主版本别名或路径。');
    }
  }

  Future<bool> isClassified(String tool, String path) async {
    try {
      final actual = await Directory(path).resolveSymbolicLinks();
      final category = await Directory(
        categoryRoot(tool),
      ).resolveSymbolicLinks();
      return actual == category || actual.startsWith('$category/');
    } on FileSystemException {
      return false;
    }
  }

  Future<void> checkNewTarget(String tool, String version) async {
    if (tool == 'rust') return;
    final target = installTarget(tool, version);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('目标已存在，保留原内容：$target');
    }
    // Resolve every existing ancestor to catch redirects outside the category.
    var ancestor = Directory(target).parent;
    while (!await ancestor.exists()) {
      ancestor = ancestor.parent;
    }
    final actual = await ancestor.resolveSymbolicLinks();
    var rootAncestor = Directory(root);
    while (!await rootAncestor.exists()) {
      rootAncestor = rootAncestor.parent;
    }
    final rootActual = await rootAncestor.resolveSymbolicLinks();
    final expectedAncestor =
        rootActual + ancestor.path.substring(rootAncestor.path.length);
    if (actual != expectedAncestor) {
      throw StateError('安装目录的软链接指向分类目录以外：$actual');
    }
  }
}

String quoteArgument(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

/// Argument parsing only: shell substitutions, pipes and redirects never execute.
List<String> parseCommandArguments(String source) {
  final words = <String>[];
  var word = StringBuffer();
  String? quote;
  var escaped = false;
  var started = false;
  for (final rune in source.runes) {
    final ch = String.fromCharCode(rune);
    if (escaped) {
      word.write(ch);
      escaped = false;
      started = true;
      continue;
    }
    if (ch == '\\' && quote != "'") {
      escaped = true;
      started = true;
      continue;
    }
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        word.write(ch);
      }
      started = true;
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      started = true;
      continue;
    }
    if (ch.trim().isEmpty) {
      if (started) {
        words.add(word.toString());
        word = StringBuffer();
        started = false;
      }
    } else {
      word.write(ch);
      started = true;
    }
  }
  if (escaped || quote != null) throw const FormatException('命令引号未闭合。');
  if (started) words.add(word.toString());
  return words;
}
