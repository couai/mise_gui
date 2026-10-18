enum TaskStatus {
  running('执行中'),
  succeeded('已完成'),
  warning('需检查'),
  failed('失败'),
  cancelled('已停止'),
  interrupted('已中断');

  const TaskStatus(this.label);
  final String label;
}

enum TaskStepStatus { pending, running, succeeded, failed, skipped }

class TaskStep {
  const TaskStep(
    this.title, {
    this.status = TaskStepStatus.pending,
    this.exitCode,
  });
  final String title;
  final TaskStepStatus status;
  final int? exitCode;
  Map<String, dynamic> toJson() => {
    'title': title,
    'status': status.name,
    'exitCode': exitCode,
  };
  factory TaskStep.fromJson(Map<String, dynamic> json) => TaskStep(
    json['title'] as String,
    status: TaskStepStatus.values.byName(json['status'] as String),
    exitCode: json['exitCode'] as int?,
  );
}

class TaskVerification {
  const TaskVerification(this.passed, this.detail, {this.warning = false});
  final bool passed, warning;
  final String detail;
}

class WorkbenchTask {
  const WorkbenchTask({
    required this.id,
    required this.title,
    required this.manager,
    required this.startedAt,
    required this.steps,
    this.status = TaskStatus.running,
    this.output = '',
    this.verification = '等待验证',
    this.finishedAt,
  });
  final String id, title, manager, output, verification;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final List<TaskStep> steps;
  final TaskStatus status;
  bool get running => status == TaskStatus.running;
  int get completed =>
      steps.where((s) => s.status == TaskStepStatus.succeeded).length;
  double get progress => steps.isEmpty ? 0 : completed / steps.length;
  WorkbenchTask copy({
    List<TaskStep>? steps,
    TaskStatus? status,
    String? output,
    String? verification,
    DateTime? finishedAt,
  }) => WorkbenchTask(
    id: id,
    title: title,
    manager: manager,
    startedAt: startedAt,
    steps: steps ?? this.steps,
    status: status ?? this.status,
    output: output ?? this.output,
    verification: verification ?? this.verification,
    finishedAt: finishedAt ?? this.finishedAt,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'manager': manager,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'steps': steps.map((s) => s.toJson()).toList(),
    'status': status.name,
    'output': output,
    'verification': verification,
  };
  factory WorkbenchTask.fromJson(Map<String, dynamic> json) => WorkbenchTask(
    id: json['id'] as String,
    title: json['title'] as String,
    manager: json['manager'] as String,
    startedAt: DateTime.parse(json['startedAt'] as String),
    finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
    steps: (json['steps'] as List)
        .map((s) => TaskStep.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
    status: TaskStatus.values.byName(json['status'] as String),
    output: json['output'] as String,
    verification: json['verification'] as String,
  );
}
