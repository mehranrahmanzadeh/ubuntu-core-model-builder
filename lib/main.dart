import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:yaru/yaru.dart';

import 'pages/home_page.dart';
import 'services/rust_key_service.dart';
import 'services/rust_store_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installShutdownHandlers();
  // Restore a persisted Snap Store session from the Rust auth backend
  // (no-op when the native library is missing or there is no saved pair).
  await RustStoreService.bootstrap();
  runApp(const ModelBuilderApp());
}

bool _cleanedUp = false;

Future<void> _cleanup() async {
  if (_cleanedUp) return;
  _cleanedUp = true;
  try {
    await RustKeyService.stopSnapGpgAgent().timeout(const Duration(seconds: 3));
  } catch (_) {
    // Never block on cleanup failure.
  }
}

void _installShutdownHandlers() {
  // Termination signals: window-close on Linux often delivers SIGTERM;
  // Ctrl-C in a launching terminal delivers SIGINT.
  for (final sig in [ProcessSignal.sigterm, ProcessSignal.sigint]) {
    try {
      sig.watch().listen((_) async {
        await _cleanup();
        exit(0);
      });
    } catch (_) {
      // Some signals may not be watchable in all environments; ignore.
    }
  }
}

class ModelBuilderApp extends StatefulWidget {
  const ModelBuilderApp({super.key});

  @override
  State<ModelBuilderApp> createState() => _ModelBuilderAppState();
}

class _ModelBuilderAppState extends State<ModelBuilderApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On desktop, "detached" fires as the app is tearing down.
    if (state == AppLifecycleState.detached) {
      // Best-effort synchronous kick-off; the process may exit before this
      // completes, so signals above are the primary mechanism.
      _cleanup();
    }
  }

  @override
  Widget build(BuildContext context) {
    return YaruTheme(
      builder: (context, yaru, child) {
        return MaterialApp(
          title: 'Model Builder',
          theme: yaru.theme,
          darkTheme: yaru.darkTheme,
          debugShowCheckedModeBanner: false,
          home: const HomePage(),
        );
      },
    );
  }
}
