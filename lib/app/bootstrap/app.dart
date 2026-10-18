import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/app/router/app_router.dart';
import 'package:mise_gui/app/theme/app_theme.dart';

class MiseGuiApp extends ConsumerStatefulWidget {
  const MiseGuiApp({super.key});

  @override
  ConsumerState<MiseGuiApp> createState() => _MiseGuiAppState();
}

class _MiseGuiAppState extends ConsumerState<MiseGuiApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncThemeWithSystem();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    _syncThemeWithSystem();
    super.didChangePlatformBrightness();
  }

  void _syncThemeWithSystem() {
    ref.read(systemThemeModeProvider.notifier).state = resolveSystemThemeMode();
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);
    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp.router(
      title: 'mise_gui',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      routerConfig: router,
    );
  }
}
