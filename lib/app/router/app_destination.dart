import 'package:flutter/material.dart';

enum AppDestination {
  dashboard(
    label: '总览',
    description: '环境总览',
    path: '/dashboard',
    icon: Icons.space_dashboard_rounded,
    selectedIcon: Icons.dashboard_customize_rounded,
  ),
  localTools(
    label: '开发工具',
    description: '本地工具工作台',
    path: '/local-tools',
    icon: Icons.widgets_outlined,
    selectedIcon: Icons.widgets_rounded,
  ),
  toolchains(
    label: 'mise 工具链',
    description: '分类工具链',
    path: '/toolchains',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree_rounded,
  ),
  tools(
    label: '工具版本',
    description: 'mise 版本安装',
    path: '/tools',
    icon: Icons.handyman_outlined,
    selectedIcon: Icons.handyman_rounded,
  ),
  projects(
    label: '项目',
    description: '项目覆盖',
    path: '/projects',
    icon: Icons.workspaces_outline,
    selectedIcon: Icons.workspaces_rounded,
  ),
  config(
    label: '配置',
    description: '全局配置',
    path: '/config',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune_rounded,
  );

  const AppDestination({
    required this.label,
    required this.description,
    required this.path,
    required this.icon,
    required this.selectedIcon,
  });

  final String label;
  final String description;
  final String path;
  final IconData icon;
  final IconData selectedIcon;

  static AppDestination fromLocation(String location) {
    return AppDestination.values.firstWhere(
      (destination) => location.startsWith(destination.path),
      orElse: () => AppDestination.dashboard,
    );
  }
}
