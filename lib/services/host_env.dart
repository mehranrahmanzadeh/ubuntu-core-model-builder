import 'dart:io';

/// Provides a "host-safe" environment for spawning host binaries from within
/// a classically-confined snap.
///
/// The snap sets LD_LIBRARY_PATH, GTK_PATH, GIO_MODULE_DIR, LIBGL_DRIVERS_PATH
/// and GDK_BACKEND so its own bundled (patchelf'd) libraries are used by the
/// Flutter app. But when we spawn HOST tools (snap, gpg, pinentry,
/// gnome-terminal), those variables poison the child: it tries to load our
/// bundled libraries instead of the host's, causing launch failures or
/// missing pinentry dialogs. We strip them so host binaries use host
/// libraries.
class HostEnv {
  HostEnv._();

  /// The single source of truth for which environment variables are stripped
  /// so host tools load their own libraries rather than the snap's bundled
  /// (patchelf'd) ones.
  ///
  /// TEST CONTRACT (see `test/host_env_test.dart`): that file asserts exactly
  /// this set of keys is removed and that unrelated keys survive. If you add
  /// or remove an entry here, update `kStripKeys` in the test to match, or
  /// the suite will fail.
  static const _stripKeys = <String>[
    'LD_LIBRARY_PATH',
    'GTK_PATH',
    'GIO_MODULE_DIR',
    'LIBGL_DRIVERS_PATH',
    'GDK_BACKEND',
    // Flutter/engine and snap-injected paths that could also interfere:
    'LD_PRELOAD',
  ];

  /// A copy of [base] with the snap-bundled library-path variables removed.
  ///
  /// Factored out of [sanitized] so the stripping behaviour can be tested
  /// hermetically against a controlled environment (Platform.environment
  /// itself cannot be overridden in tests).
  ///
  /// TEST CONTRACT (see `test/host_env_test.dart`): this method must
  ///   * remove every key in [_stripKeys] from the returned copy;
  ///   * preserve every other key (exact-name match only — `GTK_PATHX` and
  ///     `LD_LIBRARY_PATH_EXTRA` must NOT be stripped); and
  ///   * NOT mutate [base] (it operates on a copy).
  /// Keep [sanitized] delegating here so the real-environment path is the
  /// same code under test.
  static Map<String, String> sanitizedFrom(Map<String, String> base) {
    final env = Map<String, String>.from(base);
    for (final k in _stripKeys) {
      env.remove(k);
    }
    return env;
  }

  /// A copy of the current environment with snap-bundled library paths
  /// removed, suitable for `Process.start`/`Process.run` `environment:`.
  static Map<String, String> get sanitized =>
      sanitizedFrom(Platform.environment);
}
