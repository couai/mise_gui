import 'dart:io';
import 'package:xml/xml.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/project_profile_service.dart';

/// Bounded static module graph. Build scripts and wrappers are never executed.
class ProjectJavaMetadata {
  static const maxModules = 40, maxDepth = 8;
  static const rootNames = [
    'settings.gradle',
    'settings.gradle.kts',
    'gradle.properties',
    'gradle/wrapper/gradle-wrapper.properties',
  ];

  static String? inside(String root, String base, String relative) {
    if (relative.contains('\\') || relative.contains('\u0000')) return null;
    final raw = Directory(
      '$base/$relative',
    ).absolute.uri.normalizePath().toFilePath();
    final path = raw.length > 1 && raw.endsWith('/')
        ? raw.substring(0, raw.length - 1)
        : raw;
    return path == root || path.startsWith('$root/') ? path : null;
  }

  static Future<void> collect(
    String root,
    Map<String, String> files,
    List<String> warnings,
  ) async {
    final visited = <String>{};
    Future<void> read(String directory, String name) async {
      final relative = directory == root
          ? name
          : '${directory.substring(root.length + 1)}/$name';
      if (files.containsKey(relative)) return;
      try {
        final text = await ProjectProfileService.readMetadata(root, relative);
        if (text != null) files[relative] = text;
      } catch (_) {
        warnings.add('$relative 无法安全读取，模块信息不完整。');
      }
    }

    Future<void> visit(String directory, int depth) async {
      if (visited.contains(directory)) return;
      if (depth > maxDepth || visited.length >= maxModules) {
        warnings.add('Java 模块扫描达到上限（$maxModules 个、深度 $maxDepth），结果不完整。');
        return;
      }
      visited.add(directory);
      for (final name in [
        'pom.xml',
        'build.gradle',
        'build.gradle.kts',
        ...rootNames,
      ]) {
        await read(directory, name);
      }
      String? content(String name) =>
          files[directory == root
              ? name
              : '${directory.substring(root.length + 1)}/$name'];
      final pom = content('pom.xml');
      if (pom != null) {
        try {
          final xml = _pom(pom);
          final properties = _properties(xml);
          for (final module
              in xml
                  .findElements('modules')
                  .expand((e) => e.findElements('module'))) {
            final path = _expand(module.innerText.trim(), properties);
            final child = inside(root, directory, path);
            if (child == null || path.contains(r'${')) {
              warnings.add('Maven 模块路径越界或为动态值，未读取。');
            } else {
              await visit(child, depth + 1);
            }
          }
          final parent = xml.findElements('parent').firstOrNull;
          if (parent != null) {
            final relative = parent.findElements('relativePath').firstOrNull;
            final path = relative?.innerText.trim() ?? '../pom.xml';
            if (path.isNotEmpty) {
              final target = inside(root, directory, path);
              if (target != null && target.endsWith('/pom.xml')) {
                await visit(File(target).parent.path, depth + 1);
              }
            }
          }
        } catch (_) {
          warnings.add('Maven 模块声明解析失败。');
        }
      }
      for (final name in ['settings.gradle', 'settings.gradle.kts']) {
        final settings = content(name);
        if (settings == null) continue;
        for (final entry in _gradlePaths(settings, warnings).entries) {
          final child = inside(root, directory, entry.value);
          if (child == null) {
            warnings.add('Gradle 模块 ${entry.key} 路径越界，未读取。');
          } else {
            await visit(child, depth + 1);
          }
        }
      }
    }

    if (files.keys.any(
      (k) => const [
        'pom.xml',
        'build.gradle',
        'build.gradle.kts',
        'settings.gradle',
        'settings.gradle.kts',
      ].contains(k),
    )) {
      await visit(root, 0);
    }
  }

  static List<ProjectJavaModule> parse(String root, Map<String, String> files) {
    final modules = <ProjectJavaModule>[];
    final seen = <String>{};
    String key(String dir, String name) =>
        dir == root ? name : '${dir.substring(root.length + 1)}/$name';
    String? text(String dir, String name) => files[key(dir, name)];
    String? wrapper(String dir) {
      final data =
          text(dir, 'gradle/wrapper/gradle-wrapper.properties') ??
          text(root, 'gradle/wrapper/gradle-wrapper.properties');
      return data == null
          ? null
          : RegExp(
              r'gradle-(\d+(?:\.\d+)+)-(?:bin|all)\.zip',
            ).firstMatch(data)?[1];
    }

    Map<String, String> mavenProperties(
      String dir,
      Set<String> chain,
      List<String> issues,
    ) {
      if (!chain.add(dir)) {
        issues.add('Maven parent 存在循环。');
        return {};
      }
      final source = text(dir, 'pom.xml');
      if (source == null) return {};
      final xml = _pom(source);
      final parent = xml.findElements('parent').firstOrNull;
      final inherited = <String, String>{};
      if (parent != null) {
        final relative =
            parent.findElements('relativePath').firstOrNull?.innerText.trim() ??
            '../pom.xml';
        final target = relative.isEmpty ? null : inside(root, dir, relative);
        if (target != null &&
            target.endsWith('/pom.xml') &&
            text(File(target).parent.path, 'pom.xml') != null) {
          final parentXml = _pom(text(File(target).parent.path, 'pom.xml')!);
          String? value(XmlElement e, String name) =>
              e.findElements(name).firstOrNull?.innerText.trim();
          final matches = [
            'groupId',
            'artifactId',
            'version',
          ].every((n) => value(parent, n) == value(parentXml, n));
          if (matches) {
            inherited.addAll(
              mavenProperties(File(target).parent.path, {...chain}, issues),
            );
          } else {
            issues.add('本地 parent 坐标不匹配，未继承属性。');
          }
        } else {
          issues.add('外部或远端 parent 未解析，继承信息可能不完整。');
        }
      }
      final compiler = _compilerTarget(xml);
      return {
        ...inherited,
        ..._properties(xml),
        if (compiler != null) 'maven-compiler-plugin': compiler,
      };
    }

    void visit(
      String dir,
      int depth, {
      List<ProjectRequirement> gradleInherited = const [],
    }) {
      if (seen.contains(dir)) return;
      if (depth > maxDepth || seen.length >= maxModules) return;
      seen.add(dir);
      final pom = text(dir, 'pom.xml');
      if (pom != null) {
        final issues = <String>[];
        final reqs = <ProjectRequirement>[];
        try {
          final xml = _pom(pom);
          final props = mavenProperties(dir, {}, issues);
          for (final name in [
            'maven-compiler-plugin',
            'maven.compiler.release',
            'java.version',
            'maven.compiler.target',
            'maven.compiler.source',
          ]) {
            if (props[name] != null) {
              reqs.add(
                ProjectRequirement(
                  'java',
                  _expand(props[name]!, props),
                  '${key(dir, 'pom.xml')} · $name',
                  kind: ProjectRequirementKind.minimum,
                ),
              );
              break;
            }
          }
          modules.add(
            ProjectJavaModule(
              path: dir,
              name: dir == root ? '.' : dir.substring(root.length + 1),
              manager: 'Maven',
              buildFile: key(dir, 'pom.xml'),
              requirements: reqs,
              warnings: issues,
            ),
          );
          for (final node
              in xml
                  .findElements('modules')
                  .expand((e) => e.findElements('module'))) {
            if (modules.length >= maxModules) {
              issues.add('模块扫描达到上限，结果不完整。');
              break;
            }
            final value = _expand(node.innerText.trim(), props);
            final child = value.contains(r'${')
                ? null
                : inside(root, dir, value);
            if (child != null) {
              if (text(child, 'pom.xml') == null) {
                modules.add(
                  ProjectJavaModule(
                    path: child,
                    name: value,
                    manager: 'Maven',
                    buildFile: key(child, 'pom.xml'),
                    warnings: ['声明的模块缺少可读取的 pom.xml。'],
                  ),
                );
              } else {
                visit(child, depth + 1);
              }
            } else {
              issues.add('模块路径越界或包含未解析属性。');
            }
          }
        } catch (_) {
          modules.add(
            ProjectJavaModule(
              path: dir,
              name: dir == root ? '.' : dir.substring(root.length + 1),
              manager: 'Maven',
              buildFile: key(dir, 'pom.xml'),
              warnings: ['pom.xml 解析失败。'],
            ),
          );
        }
      }
      final buildName = text(dir, 'build.gradle.kts') != null
          ? 'build.gradle.kts'
          : 'build.gradle';
      final build = text(dir, buildName);
      final settings =
          text(dir, 'settings.gradle.kts') ?? text(dir, 'settings.gradle');
      if (build != null || settings != null || gradleInherited.isNotEmpty) {
        final issues = <String>[];
        final props = <String, String>{
          ..._javaProperties(text(root, 'gradle.properties') ?? ''),
          ..._javaProperties(text(dir, 'gradle.properties') ?? ''),
        };
        final code = _withoutComments(build ?? '');
        final scopes = _gradleScopes(code);
        final own = _gradleRequirements(scopes.$1, props, key(dir, buildName));
        final shared = _gradleRequirements(
          scopes.$2,
          props,
          '${key(dir, buildName)} · subprojects/allprojects',
        );
        final reqs = _mergeGradle(gradleInherited, own);
        final children = settings == null
            ? <String, String>{}
            : _gradlePaths(settings, issues);
        if (build == null && dir != root) issues.add('模块没有可读取的构建文件，约定插件配置待核对。');
        if (build != null && reqs.isEmpty) {
          issues.add('未识别静态 Java 编译级别或工具链，动态构建配置待核对。');
        }
        modules.add(
          ProjectJavaModule(
            path: dir,
            name: dir == root ? '.' : dir.substring(root.length + 1),
            manager: 'Gradle',
            buildFile: key(
              dir,
              build != null
                  ? buildName
                  : 'settings.gradle${text(dir, 'settings.gradle.kts') != null ? '.kts' : ''}',
            ),
            requirements: reqs,
            warnings: issues,
            wrapperVersion: wrapper(dir),
          ),
        );
        for (final entry in children.entries) {
          final child = inside(root, dir, entry.value);
          if (child == null) {
            issues.add('模块 ${entry.key} 路径越界。');
            continue;
          }
          if (seen.length >= maxModules ||
              modules.length >= maxModules ||
              depth >= maxDepth) {
            issues.add('模块扫描达到上限，结果不完整。');
            break;
          }
          if (text(child, 'build.gradle') == null &&
              text(child, 'build.gradle.kts') == null &&
              reqs.isEmpty) {
            modules.add(
              ProjectJavaModule(
                path: child,
                name: entry.key,
                manager: 'Gradle',
                buildFile: key(child, 'build.gradle'),
                warnings: ['模块没有可读取的构建文件，约定插件配置待核对。'],
                wrapperVersion: wrapper(dir),
              ),
            );
          } else {
            visit(
              child,
              depth + 1,
              gradleInherited: _mergeGradle(gradleInherited, shared),
            );
          }
        }
      }
    }

    visit(root, 0);
    return modules;
  }

  // A root Java plugin does not configure child projects. Only literal
  // subprojects/allprojects blocks supply shared static compilation evidence.
  static (String, String) _gradleScopes(String code) {
    final own = StringBuffer(), shared = StringBuffer();
    var offset = 0;
    for (final match in RegExp(
      r'\b(?:subprojects|allprojects)\s*\{',
    ).allMatches(code)) {
      if (match.start < offset) continue;
      var level = 1, end = match.end;
      String? quote;
      var escaped = false;
      for (; end < code.length && level > 0; end++) {
        final c = code[end];
        if (quote != null) {
          if (c == quote && !escaped) quote = null;
          escaped = !escaped && c == '\\';
        } else if (c == "'" || c == '"') {
          quote = c;
        } else if (c == '{') {
          level++;
        } else if (c == '}') {
          level--;
        }
      }
      own.write(code.substring(offset, match.start));
      shared.write(code.substring(match.end, end));
      if (code.substring(match.start, match.end).startsWith('allprojects')) {
        own.write(code.substring(match.end, end));
      }
      offset = end;
    }
    own.write(code.substring(offset));
    return (own.toString(), shared.toString());
  }

  static List<ProjectRequirement> _gradleRequirements(
    String code,
    Map<String, String> props,
    String source,
  ) {
    final declarations = <String, ProjectRequirement>{};
    void add(String value, String field, ProjectRequirementKind kind) {
      value = value.replaceAll(RegExp('["\' ]'), '');
      final version =
          props[value] ??
          value.replaceFirst('JavaVersion.VERSION_', '').replaceAll('_', '.');
      declarations[field] = ProjectRequirement(
        'java',
        version,
        '$source · $field',
        kind: kind,
      );
    }

    for (final match in RegExp(
      r'JavaLanguageVersion\.of\(\s*([^\n;]+?)\s*\)',
    ).allMatches(code)) {
      add(match[1]!, 'java.toolchain', ProjectRequirementKind.prefix);
    }
    for (final match in RegExp(
      r'''(sourceCompatibility|targetCompatibility)\s*=\s*([\w.]+|["'][\d.]+["'])''',
    ).allMatches(code)) {
      add(match[2]!, match[1]!, ProjectRequirementKind.minimum);
    }
    for (final match in RegExp(
      r'options\.release(?:\.set\(\s*|\s*=\s*)(\d+)',
    ).allMatches(code)) {
      add(match[1]!, 'options.release', ProjectRequirementKind.minimum);
    }
    return declarations.values.toList();
  }

  static List<ProjectRequirement> _mergeGradle(
    List<ProjectRequirement> inherited,
    List<ProjectRequirement> own,
  ) => {
    for (final req in [...inherited, ...own]) req.source.split(' · ').last: req,
  }.values.toList();

  static String? _compilerTarget(XmlElement project) {
    final build = project.findElements('build').firstOrNull;
    if (build == null) return null;
    final containers = [
      ...build
          .findElements('pluginManagement')
          .expand((e) => e.findElements('plugins')),
      ...build.findElements('plugins'),
    ];
    String? value;
    for (final plugin in containers.expand((e) => e.findElements('plugin'))) {
      if (plugin.findElements('artifactId').firstOrNull?.innerText.trim() !=
          'maven-compiler-plugin') {
        continue;
      }
      final cfg = plugin.findElements('configuration').firstOrNull;
      value =
          cfg?.findElements('release').firstOrNull?.innerText.trim() ??
          cfg?.findElements('target').firstOrNull?.innerText.trim() ??
          value;
    }
    return value;
  }

  static XmlElement _pom(String text) {
    if (text.toUpperCase().contains('<!DOCTYPE')) {
      throw const FormatException('DTD');
    }
    return XmlDocument.parse(text).rootElement;
  }

  static Map<String, String> _properties(XmlElement root) => {
    for (final e
        in root.findElements('properties').expand((p) => p.childElements))
      e.name.local: e.innerText.trim(),
  };
  static String _expand(String value, Map<String, String> props) {
    for (var i = 0; i < 12; i++) {
      final next = value.replaceAllMapped(
        RegExp(r'\$\{([^}]+)\}'),
        (m) => props[m[1]] ?? m[0]!,
      );
      if (next == value) break;
      value = next;
    }
    return value;
  }

  static Map<String, String> _javaProperties(String text) => {
    for (final line in text.split('\n'))
      if (RegExp(
        r'^\s*(?:javaVersion|jdkVersion|java\.version)\s*=',
      ).hasMatch(line))
        line.split('=').first.trim(): line
            .substring(line.indexOf('=') + 1)
            .trim(),
  };
  static Map<String, String> _gradlePaths(String source, List<String> issues) {
    final text = _withoutComments(source), paths = <String, String>{};
    for (final m in RegExp(
      r'\binclude(?!Build)\s*(?:\(([\s\S]*?)\)|([^\n;]+))',
    ).allMatches(text)) {
      final args = m[1] ?? m[2]!;
      final pieces = args
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final piece in pieces) {
        final literal = RegExp(
          r'''^["'](:?[\w.-]+(?::[\w.-]+)*)["']$''',
        ).firstMatch(piece);
        if (literal == null) {
          issues.add('动态 Gradle include 未展开，模块列表可能不完整。');
          continue;
        }
        final id = literal[1]!.replaceFirst(RegExp(r'^:'), '');
        paths[id] = id.replaceAll(':', '/');
      }
    }
    for (final m in RegExp(
      r'''project\(\s*["']:([^"']+)["']\s*\)\.projectDir\s*=\s*(?:file\(|File\(\s*rootDir\s*,)\s*["']([^"']+)["']\s*\)''',
    ).allMatches(text)) {
      if (paths.containsKey(m[1])) paths[m[1]!] = m[2]!;
    }
    if (text.contains('includeBuild') ||
        RegExp(r'\bprojectDir\b').allMatches(text).length >
            RegExp(
              r'''\.projectDir\s*=\s*(?:file\(|File\(\s*rootDir\s*,)\s*["'][^"']+["']\s*\)''',
            ).allMatches(text).length) {
      issues.add('复合构建或动态 projectDir 未展开，模块列表可能不完整。');
    }
    return paths;
  }

  static String _withoutComments(String input) {
    final out = StringBuffer();
    String? quote;
    var block = false, line = false, escape = false;
    for (var i = 0; i < input.length; i++) {
      final c = input[i], next = i + 1 < input.length ? input[i + 1] : '';
      if (line) {
        if (c == '\n') {
          line = false;
          out.write(c);
        }
        continue;
      }
      if (block) {
        if (c == '*' && next == '/') {
          block = false;
          i++;
        } else if (c == '\n') {
          out.write(c);
        }
        continue;
      }
      if (quote != null) {
        out.write(c);
        if (!escape && c == quote) quote = null;
        escape = !escape && c == '\\';
        continue;
      }
      if (c == '/' && next == '/') {
        line = true;
        i++;
        continue;
      }
      if (c == '/' && next == '*') {
        block = true;
        i++;
        continue;
      }
      if (c == '"' || c == "'") quote = c;
      out.write(c);
    }
    return out.toString();
  }
}
