import 'dart:convert';
import 'dart:io';
import 'package:toml/toml.dart';
import 'package:xml/xml.dart';
import 'package:yaml/yaml.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Reads a bounded allowlist of metadata. Never sources scripts or reads .env.
class ProjectProfileService {
  const ProjectProfileService();
  static const manifestNames = [
    'package.json',
    'pom.xml',
    'build.gradle',
    'build.gradle.kts',
    'pyproject.toml',
    'go.mod',
    'Cargo.toml',
    'pubspec.yaml',
  ];
  static const versionNames = [
    'mise.toml',
    '.mise.toml',
    'mise.local.toml',
    '.mise.local.toml',
    '.tool-versions',
    '.node-version',
    '.nvmrc',
    '.python-version',
    '.java-version',
    '.go-version',
    'rust-toolchain',
    'rust-toolchain.toml',
  ];
  static const auxiliaryNames = [
    'pnpm-lock.yaml',
    'yarn.lock',
    'package-lock.json',
    'uv.lock',
    'mvnw',
    'gradlew',
    'api/bruno/bruno.json',
    'api/bruno/opencollection.yml',
  ];
  static const maxBytes = 256 * 1024;

  /// Shared TOML semantics for coverage and project profiles; no evaluation.
  static Map<String, dynamic> miseVersions(String content) {
    final table = TomlDocument.parse(content).toMap()['tools'];
    if (table == null) return {};
    if (table is! Map) throw const FormatException('tools 必须是 TOML 表');
    return {
      for (final entry in table.entries)
        switch (entry.key) {
          'nodejs' => 'node',
          'golang' => 'go',
          _ => entry.key.toString(),
        }: entry.value is Map
            ? entry.value['version']
            : entry.value,
    };
  }

  static Future<String?> readMetadata(String root, String name) async {
    final file = File('$root/$name');
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.absolute.path) {
      throw const FormatException('软链接或非普通文件，未读取');
    }
    if ((await file.stat()).size > maxBytes) {
      throw const FormatException('元数据超过 256 KiB，未读取');
    }
    // Cap the stream too, in case a file grows after stat.
    final bytes = <int>[];
    await for (final chunk in file.openRead()) {
      bytes.addAll(chunk);
      if (bytes.length > maxBytes) {
        throw const FormatException('元数据超过 256 KiB，未读取');
      }
    }
    return utf8.decode(bytes);
  }

  Future<ProjectProfile> inspect(String path) async {
    if (!File(path).isAbsolute) throw ArgumentError('项目必须是绝对路径');
    final root = await Directory(path).resolveSymbolicLinks();
    final contents = <String, String>{};
    final warnings = <String>[];
    for (final name in [...manifestNames, ...versionNames]) {
      try {
        final text = await readMetadata(root, name);
        if (text != null) contents[name] = text;
      } catch (_) {
        warnings.add('$name 无法安全读取（文件类型、大小或权限），请手动检查。');
      }
    }
    final present = <String>{};
    for (final name in auxiliaryNames) {
      final file = File('$root/$name');
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
                FileSystemEntityType.file &&
            await file.resolveSymbolicLinks() == file.absolute.path) {
          present.add(name);
        }
      } on FileSystemException {
        warnings.add('$name 无法检查。');
      }
    }
    return parse(root, contents, present: present, warnings: warnings);
  }

  /// Parser seam keeps fixtures independent of user files and external commands.
  ProjectProfile parse(
    String root,
    Map<String, String> files, {
    Set<String> present = const {},
    List<String> warnings = const [],
  }) {
    final issues = [...warnings];
    final stacks = <String>{}, tools = <String>{}, provided = <String>{};
    final requirements = <ProjectRequirement>[];
    final scripts = <ProjectScript>[];
    void require(
      String tool,
      Object? value,
      String source, [
      ProjectRequirementKind kind = ProjectRequirementKind.prefix,
    ]) {
      tools.add(tool);
      if (value is String && value.trim().isNotEmpty) {
        requirements.add(
          ProjectRequirement(tool, value.trim(), source, kind: kind),
        );
      } else if (value != null) {
        issues.add('$source · $tool 版本声明为空或类型不受支持，请手动核对。');
      }
    }

    for (final entry in files.entries) {
      final name = entry.key, text = entry.value;
      try {
        if (name == 'package.json') {
          stacks.add('Node.js');
          tools.add('node');
          final data = jsonDecode(text) as Map;
          final dependencies = {
            ...?data['dependencies'] as Map?,
            ...?data['devDependencies'] as Map?,
          };
          for (final (key, label) in [
            ('vue', 'Vue'),
            ('typescript', 'TypeScript'),
            ('react', 'React'),
            ('next', 'Next.js'),
            ('nuxt', 'Nuxt'),
          ]) {
            if (dependencies.containsKey(key)) stacks.add(label);
          }
          final engines = data['engines'];
          if (engines is Map) {
            for (final tool in ['node', 'npm', 'pnpm', 'yarn']) {
              if (engines.containsKey(tool)) {
                require(
                  tool,
                  engines[tool],
                  '$name · engines',
                  ProjectRequirementKind.constraint,
                );
              }
            }
          }
          var manager = 'npm';
          final pm = data['packageManager'];
          if (pm is String) {
            final match = RegExp(r'^(npm|pnpm|yarn)@([^+]+)').firstMatch(pm);
            if (match != null) {
              manager = match[1]!;
              require(
                manager,
                match[2],
                '$name · packageManager',
                ProjectRequirementKind.exact,
              );
            } else {
              issues.add('packageManager 无法识别，请核对项目包管理器。');
            }
          } else if (present.contains('pnpm-lock.yaml')) {
            manager = 'pnpm';
          } else if (present.contains('yarn.lock')) {
            manager = 'yarn';
          }
          tools.add(manager);
          if (present.intersection({
                'pnpm-lock.yaml',
                'yarn.lock',
                'package-lock.json',
              }).length >
              1) {
            issues.add('存在多个 Node 锁文件，请核对包管理器后再安装依赖。');
          }
          final declaredScripts = data['scripts'];
          if (declaredScripts is Map) {
            for (final key in declaredScripts.keys.whereType<String>().take(
              40,
            )) {
              scripts.add(
                ProjectScript(
                  key,
                  'cd ${quoteArgument(root)} && $manager run ${quoteArgument(key)}',
                ),
              );
            }
          }
        } else if (name == 'pyproject.toml') {
          stacks.add('Python');
          tools.add('python');
          final data = TomlDocument.parse(text).toMap();
          final project = data['project'];
          if (project is Map) {
            require(
              'python',
              project['requires-python'],
              '$name · requires-python',
              ProjectRequirementKind.constraint,
            );
            if ((project['dependencies'] as List? ?? []).any(
              (v) => v.toString().toLowerCase().startsWith('fastapi'),
            )) {
              stacks.add('FastAPI');
            }
          }
          if (present.contains('uv.lock')) tools.add('uv');
        } else if (name == 'Cargo.toml') {
          stacks.add('Rust');
          tools.add('rust');
          final data = TomlDocument.parse(text).toMap();
          final package = data['package'];
          if (package is Map) {
            require(
              'rust',
              package['rust-version'],
              '$name · rust-version',
              ProjectRequirementKind.minimum,
            );
          }
        } else if (name == 'pubspec.yaml') {
          final data = loadYaml(text) as Map;
          final deps = data['dependencies'];
          final flutter =
              (deps is Map && deps.containsKey('flutter')) ||
              data.containsKey('flutter');
          stacks.add(flutter ? 'Flutter' : 'Dart');
          tools.add(flutter ? 'flutter' : 'dart');
          final env = data['environment'];
          if (env is Map) {
            require(
              'dart',
              env['sdk'],
              '$name · environment.sdk',
              ProjectRequirementKind.constraint,
            );
            if (env['flutter'] != null) {
              require(
                'flutter',
                env['flutter'],
                '$name · environment.flutter',
                ProjectRequirementKind.constraint,
              );
            }
          }
        } else if (name == 'pom.xml') {
          stacks.add('Java / Maven');
          tools.addAll(['java', 'maven']);
          if (text.contains('<!DOCTYPE')) throw const FormatException('DTD');
          final xml = XmlDocument.parse(text);
          final properties = xml.rootElement
              .findElements('properties')
              .firstOrNull;
          for (final key in [
            'maven.compiler.release',
            'java.version',
            'maven.compiler.target',
          ]) {
            final value = properties?.findElements(key).firstOrNull?.innerText;
            if (value != null) {
              require('java', value, '$name · $key');
              break;
            }
          }
          if (text.contains('spring-boot')) stacks.add('Spring Boot');
          if (present.contains('mvnw')) provided.add('maven');
        } else if (name == 'build.gradle' || name == 'build.gradle.kts') {
          stacks.add('Java / Gradle');
          tools.addAll(['java', 'gradle']);
          final match = RegExp(
            r'JavaLanguageVersion\.of\(\s*(\d+)\s*\)',
          ).firstMatch(text);
          if (match != null) {
            require('java', match[1], '$name · java.toolchain');
          }
          if (text.contains('com.android.')) {
            stacks.add('Android');
            tools.add('android-sdk');
          }
          if (present.contains('gradlew')) provided.add('gradle');
          issues.add('$name 仅识别静态声明；插件、变量和完整构建环境需由项目构建验证。');
        } else if (name == 'go.mod') {
          stacks.add('Go');
          tools.add('go');
          final go = RegExp(
            r'^go\s+(\d[\d.]+)\s*$',
            multiLine: true,
          ).firstMatch(text);
          if (go != null) {
            require('go', go[1], '$name · go', ProjectRequirementKind.minimum);
          }
          final toolchain = RegExp(
            r'^toolchain\s+go(\S+)',
            multiLine: true,
          ).firstMatch(text);
          if (toolchain != null) {
            require(
              'go',
              toolchain[1],
              '$name · toolchain',
              ProjectRequirementKind.minimum,
            );
          }
        } else if ([
          'mise.toml',
          '.mise.toml',
          'mise.local.toml',
          '.mise.local.toml',
        ].contains(name)) {
          final table = miseVersions(text);
          for (final entry in table.entries) {
            final tool = entry.key;
            final value = entry.value;
            if (value is String) {
              require(tool, value, name);
            } else {
              tools.add(tool);
              issues.add('$name · $tool 使用复杂版本声明，请在 mise 版本管理中核对。');
            }
          }
        } else if (name == '.tool-versions') {
          for (final line in const LineSplitter().convert(text)) {
            final parts = line.split('#').first.trim().split(RegExp(r'\s+'));
            if (parts.length >= 2) {
              final tool = switch (parts.first) {
                'nodejs' => 'node',
                'golang' => 'go',
                _ => parts.first,
              };
              require(tool, parts[1], name);
              if (parts.length > 2) {
                issues.add('$name · $tool 声明了多个版本，需核对选择顺序。');
              }
            }
          }
        } else if (name == 'rust-toolchain.toml') {
          final table = TomlDocument.parse(text).toMap()['toolchain'];
          if (table is Map) require('rust', table['channel'], name);
        } else {
          const names = {
            '.node-version': 'node',
            '.nvmrc': 'node',
            '.python-version': 'python',
            '.java-version': 'java',
            '.go-version': 'go',
            'rust-toolchain': 'rust',
          };
          final tool = names[name];
          final value = const LineSplitter()
              .convert(text)
              .map((l) => l.split('#').first.trim())
              .where((l) => l.isNotEmpty)
              .firstOrNull;
          if (tool != null) require(tool, value, name);
        }
      } catch (_) {
        issues.add('$name 解析失败；未将其声明判定为已满足。');
      }
    }
    return ProjectProfile(
      path: root,
      name: root.split('/').last,
      stacks: stacks.toList(),
      evidence: files.keys.toList(),
      requirements: requirements,
      toolIds: tools.toList()..sort(),
      providedTools: provided.toList(),
      scripts: scripts,
      warnings: issues,
      brunoPath: present.any((n) => n.startsWith('api/bruno/'))
          ? '$root/api/bruno'
          : null,
    );
  }
}
