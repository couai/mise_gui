import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';

final classifiedVersionsProvider = FutureProvider<List<ClassifiedVersion>>((
  ref,
) {
  return ref.watch(classifiedToolchainServiceProvider).inventory();
});
