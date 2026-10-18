import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Original official artwork; keep proportions and colors intact.
class ToolLogo extends StatelessWidget {
  const ToolLogo({super.key, required this.tool, this.size = 28});
  final String tool;
  final double size;
  static const tools = {
    'java',
    'node',
    'python',
    'go',
    'rust',
    'flutter',
    'dart',
  };

  @override
  Widget build(BuildContext context) {
    const localIcons = {
      'android-studio': 'android-studio.png',
      'xcode': 'xcode.png',
      'bruno': 'bruno.png',
      'reqable': 'reqable.png',
      'mitmproxy': 'mitmproxy.png',
      'vscode': 'vscode.png',
      'cursor': 'cursor.png',
      'idea': 'idea.png',
      'datagrip': 'datagrip.png',
      'hbuilderx': 'hbuilderx.png',
      'jetbrains-toolbox': 'jetbrains-toolbox.png',
      'navicat': 'navicat.png',
      'maven': 'maven.png',
      'uv': 'uv.svg',
      'gh': 'gh.svg',
      'pnpm': 'pnpm-icon.svg',
      'npm': 'npm.png',
      'devicehub': 'devicehub.png',
    };
    final local = localIcons[tool];
    if (local != null) {
      if (local.endsWith('.svg')) {
        return SvgPicture.asset(
          'assets/local_tools/$local',
          width: size,
          height: size,
          fit: BoxFit.contain,
          semanticsLabel: '$tool 官方标识',
          colorFilter: tool == 'gh'
              ? ColorFilter.mode(
                  Theme.of(context).colorScheme.onSurface,
                  BlendMode.srcIn,
                )
              : null,
        );
      }
      return Image.asset(
        'assets/local_tools/$local',
        width: size,
        height: size,
        fit: BoxFit.contain,
        semanticLabel: '$tool 官方应用图标',
      );
    }
    if (!tools.contains(tool)) {
      return Icon(Icons.extension_outlined, size: size);
    }
    final asset =
        tool == 'rust' && Theme.of(context).brightness == Brightness.dark
        ? 'rust-dark'
        : tool;
    return SvgPicture.asset(
      'assets/toolchains/$asset.svg',
      width: size,
      height: size,
      fit: BoxFit.contain,
      semanticsLabel: '$tool 官方标识',
    );
  }
}
