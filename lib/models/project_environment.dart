enum ProjectRequirementKind { prefix, exact, minimum, constraint }

class ProjectRequirement {
  const ProjectRequirement(
    this.tool,
    this.value,
    this.source, {
    this.kind = ProjectRequirementKind.prefix,
  });
  final String tool, value, source;
  final ProjectRequirementKind kind;
}

class ProjectScript {
  const ProjectScript(this.name, this.command);
  final String name, command;
}

class ProjectProfile {
  const ProjectProfile({
    required this.path,
    required this.name,
    this.stacks = const [],
    this.evidence = const [],
    this.requirements = const [],
    this.toolIds = const [],
    this.providedTools = const [],
    this.scripts = const [],
    this.warnings = const [],
    this.brunoPath,
  });
  final String path, name;
  final List<String> stacks, evidence, toolIds, providedTools, warnings;
  final List<ProjectRequirement> requirements;
  final List<ProjectScript> scripts;
  final String? brunoPath;
}

enum ProjectToolState {
  satisfied('符合声明'),
  available('工具可用'),
  mismatch('版本不符'),
  missing('缺少工具'),
  review('待核对'),
  projectProvided('项目提供');

  const ProjectToolState(this.label);
  final String label;
}

class ProjectToolCheck {
  const ProjectToolCheck({
    required this.tool,
    required this.requirements,
    required this.installed,
    required this.state,
    this.effective,
    this.source,
    this.detail = '',
  });
  final String tool, detail;
  final List<ProjectRequirement> requirements;
  final List<String> installed;
  final String? effective, source;
  final ProjectToolState state;
}

class ProjectEnvironment {
  const ProjectEnvironment(
    this.profile,
    this.checks,
    this.checkedAt, {
    this.queryIssue,
  });
  final ProjectProfile profile;
  final List<ProjectToolCheck> checks;
  final DateTime checkedAt;
  final String? queryIssue;
  int get issueCount => checks
      .where(
        (c) =>
            c.state == ProjectToolState.mismatch ||
            c.state == ProjectToolState.missing ||
            c.state == ProjectToolState.review,
      )
      .length;
}
