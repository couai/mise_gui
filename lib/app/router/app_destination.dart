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
  tools(
    label: 'mise 版本管理',
    description: '已安装与可安装版本',
    path: '/tools',
    icon: Icons.handyman_outlined,
    selectedIcon: Icons.handyman_rounded,
  ),
  storage(
    label: '目录与缓存',
    description: '空间与路径检查',
    path: '/storage',
    icon: Icons.storage_outlined,
    selectedIcon: Icons.storage_rounded,
  ),
  projects(
    label: '项目',
    description: '项目覆盖',
    path: '/projects',
    icon: Icons.workspaces_outline,
    selectedIcon: Icons.workspaces_rounded,
  ),
  tasks(
    label: '任务中心',
    description: '步骤、输出与验证',
    path: '/tasks',
    icon: Icons.task_alt_outlined,
    selectedIcon: Icons.task_alt_rounded,
  ),
  managers(
    label: '管理器设置',
    description: '路径与执行选项',
    path: '/managers',
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings_rounded,
  ),
  config(
    label: 'mise 配置',
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
