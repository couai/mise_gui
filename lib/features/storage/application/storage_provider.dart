import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/directory_storage_service.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

final directoryStorageServiceProvider = Provider(
  (ref) => DirectoryStorageService(
    layout: ToolchainLayout.current,
    reader: const PosixDirectoryUsageReader(),
  ),
);
final directoryScanCancellationProvider = Provider((ref) {
  final token = DirectoryScanCancellation();
  ref.onDispose(token.cancel);
  return token;
});
// A scan is performed on first use or explicit refresh, never on dashboard timers.
final directoryStorageProvider = StreamProvider<StorageSnapshot>((ref) async* {
  final service = ref.watch(directoryStorageServiceProvider);
  final cancellation = ref.watch(directoryScanCancellationProvider);
  ref.onDispose(cancellation.cancel);
  final inventory = await ref.read(localToolsProvider.future);
  yield* service.scan(inventory, cancellation);
});
