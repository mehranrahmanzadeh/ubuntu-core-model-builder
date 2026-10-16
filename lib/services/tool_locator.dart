import 'package:process_run/process_run.dart';

import 'host_env.dart';

/// Status of the host tools the app depends on.
///
/// Only `snap` (snapd) is required: store login runs in-app via the Rust
/// auth bridge, and model signing goes through `snap sign`. [hasPinentry]
/// is informational — a graphical passphrase prompt is recommended but not
/// required (passphrase-less keys work without it).
class ToolStatus {
  final bool hasSnap;
  final bool hasPinentry;
  final String? snapPath;

  ToolStatus({
    required this.hasSnap,
    required this.hasPinentry,
    this.snapPath,
  });

  bool get ready => hasSnap;
}

class ToolLocator {
  static Future<ToolStatus> check() async {
    final shell = Shell(
        throwOnError: false,
        environment: HostEnv.sanitized,
        includeParentEnvironment: false);

    Future<String?> which(String tool) async {
      final r = await shell.run('which $tool');
      if (r.first.exitCode != 0) return null;
      final out = r.outText.trim();
      return out.isEmpty ? null : out;
    }

    final snapPath = await which('snap');
    final pinentry = await which('pinentry-gnome3') ??
        await which('pinentry-gtk-2') ??
        await which('pinentry');

    return ToolStatus(
      hasSnap: snapPath != null,
      hasPinentry: pinentry != null,
      snapPath: snapPath,
    );
  }
}
