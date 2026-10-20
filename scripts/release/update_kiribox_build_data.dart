import 'dart:convert';
import 'dart:io';

import 'package:fl_build/cfg/config.dart';
import 'package:fl_build/utils.dart';

/// Uses the owning generator rather than editing BuildData by hand.
Future<void> main() async {
  makeCfg = const MakeCfg(appName: 'KiriBox');
  final version = RegExp(r'^version: [^+]+\+(\d+)$', multiLine: true)
      .firstMatch(await File('pubspec.yaml').readAsString());
  if (version == null) throw StateError('pubspec.yaml needs a build number');
  final override = File('more_build_data.json');
  final previous = await override.exists() ? await override.readAsString() : null;
  if (previous != null) throw StateError('Move the local more_build_data.json override before generating fork branding');
  try {
    await override.writeAsString(jsonEncode({'build': int.parse(version.group(1)!)}));
    await updateBuildData();
  } finally { await override.delete(); }
}
