import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/project_scan_service.dart';
import 'package:mise_gui/services/scan_directory_service.dart';

class ProjectsRepository {
  const ProjectsRepository(
    this._projectScanService,
    this._scanDirectoryService,
  );

  final ProjectScanService _projectScanService;
  final ScanDirectoryService _scanDirectoryService;

  Future<List<ProjectRecord>> loadProjects() async {
    final directories = await _scanDirectoryService.fetchDirectories();
    return _projectScanService.fetchProjects(directories);
  }

  Future<List<ScanDirectoryRecord>> loadScanDirectories() {
    return _scanDirectoryService.fetchDirectories();
  }

  Future<List<ScanDirectoryRecord>> addScanDirectory(String path) {
    return _scanDirectoryService.addDirectory(path);
  }

  Future<List<ScanDirectoryRecord>> removeScanDirectory(String path) {
    return _scanDirectoryService.removeDirectory(path);
  }

  Future<List<ScanDirectoryRecord>> setScanDirectoryEnabled(
    String path,
    bool enabled,
  ) {
    return _scanDirectoryService.setDirectoryEnabled(path, enabled);
  }

  Future<ProjectCoverageSnapshot> loadCoverageSnapshot() async {
    final directories = await _scanDirectoryService.fetchDirectories();
    final result = await _projectScanService.scan(directories);
    return ProjectCoverageSnapshot(
      scanDirectories: directories,
      projects: result.projects,
      scanRoots: result.roots,
      scanWarnings: result.warnings,
    );
  }
}
