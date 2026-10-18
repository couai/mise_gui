import 'package:flutter/material.dart';
import 'package:mise_gui/features/local_tools/presentation/local_tools_page.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/app/router/app_destination.dart';
import 'package:mise_gui/app/shell/app_shell.dart';
import 'package:mise_gui/features/config/presentation/config_page.dart';
import 'package:mise_gui/features/dashboard/presentation/dashboard_page.dart';
import 'package:mise_gui/features/projects/presentation/projects_page.dart';
import 'package:mise_gui/features/tools/presentation/tools_page.dart';

final rootNavigatorKeyProvider = Provider<GlobalKey<NavigatorState>>(
  (ref) => GlobalKey<NavigatorState>(),
);

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: ref.watch(rootNavigatorKeyProvider),
    initialLocation: AppDestination.dashboard.path,
    routes: [
      GoRoute(
        path: '/toolchains',
        redirect: (context, state) => Uri(
          path: AppDestination.tools.path,
          queryParameters: state.uri.queryParameters.isEmpty
              ? null
              : state.uri.queryParameters,
        ).toString(),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppDestination.dashboard.path,
                builder: (context, state) => const DashboardPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppDestination.localTools.path,
                builder: (context, state) => LocalToolsPage(
                  initialTool: state.uri.queryParameters['tool'],
                  initialCategory: state.uri.queryParameters['category'],
                  initialStatus: state.uri.queryParameters['status'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppDestination.tools.path,
                builder: (context, state) => ToolsPage(
                  initialTool: state.uri.queryParameters['tool'],
                  initialTab: state.uri.queryParameters['tab'],
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppDestination.projects.path,
                builder: (context, state) => const ProjectsPage(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: AppDestination.config.path,
                builder: (context, state) => const ConfigPage(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
});
