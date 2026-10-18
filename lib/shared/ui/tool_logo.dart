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
