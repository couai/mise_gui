import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_version_service.dart';
import 'package:mise_gui/services/project_launcher.dart';

final projectProfileServiceProvider = Provider(
  (ref) => const ProjectProfileService(),
);
final projectEnvironmentServiceProvider = Provider(
  (ref) => ProjectEnvironmentService(
    ref.watch(projectProfileServiceProvider),
    ref.watch(projectMiseQueryServiceProvider),
  ),
);
final projectEnvironmentProvider = FutureProvider.autoDispose
    .family<ProjectEnvironment, String>((ref, path) async {
      final service = ref.watch(projectEnvironmentServiceProvider);
      final local = await ref.watch(localToolsProvider.future);
      return service.inspect(path, local);
    });
final projectVersionServiceProvider = Provider(
  (ref) => ProjectVersionService(
    ref.watch(classifiedToolchainServiceProvider),
    ref.watch(miseActionServiceProvider),
  ),
);
final projectLauncherProvider = Provider(
  (ref) => ProjectLauncher(ref.watch(localToolProcessProvider)),
);

final projectsProvider = FutureProvider<List<ProjectRecord>>((ref) {
  return ref.watch(projectsRepositoryProvider).loadProjects();
});

final projectCoverageProvider = FutureProvider<ProjectCoverageSnapshot>((ref) {
  return ref.watch(projectsRepositoryProvider).loadCoverageSnapshot();
});
