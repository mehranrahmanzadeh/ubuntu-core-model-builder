import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/services/host_env.dart';

/// The six snap-bundled variables that [HostEnv.sanitizedFrom] must strip.
const List<String> kStripKeys = [
  'LD_LIBRARY_PATH',
  'GTK_PATH',
  'GIO_MODULE_DIR',
  'LIBGL_DRIVERS_PATH',
  'GDK_BACKEND',
  'LD_PRELOAD',
];

void main() {
  group('HostEnv.sanitizedFrom', () {
    test('removes every snap-bundled library-path variable', () {
      final base = <String, String>{
        for (final k in kStripKeys) k: 'poison-value-$k',
        'PATH': '/usr/bin',
        'HOME': '/root',
      };

      final sanitized = HostEnv.sanitizedFrom(base);

      for (final k in kStripKeys) {
        expect(sanitized.containsKey(k), isFalse, reason: '$k must be stripped');
      }
      // Unrelated variables are preserved.
      expect(sanitized['PATH'], '/usr/bin');
      expect(sanitized['HOME'], '/root');
    });

    test('does not modify the input map', () {
      final base = <String, String>{
        'LD_LIBRARY_PATH': '/snap/foo',
        'PATH': '/usr/bin',
      };
      final before = Map<String, String>.from(base);

      HostEnv.sanitizedFrom(base);

      // The original map is untouched (we operate on a copy).
      expect(base, before);
      expect(base.containsKey('LD_LIBRARY_PATH'), isTrue);
    });

    test('returns an empty map for an empty environment', () {
      expect(HostEnv.sanitizedFrom(const {}), isEmpty);
    });

    test('handles an environment with no strip-keys present', () {
      final base = const <String, String>{
        'PATH': '/usr/bin',
        'LANG': 'C.UTF-8',
      };
      expect(HostEnv.sanitizedFrom(base), base);
    });

    test('strips only the exact strip-keys, not near-names', () {
      // Similar-but-different names must survive.
      final base = const <String, String>{
        'LD_LIBRARY_PATH_EXTRA': 'keep',
        'GTK_PATHX': 'keep',
        'MY_LD_PRELOAD': 'keep',
        'PATH': '/usr/bin',
      };
      final sanitized = HostEnv.sanitizedFrom(base);
      expect(sanitized['LD_LIBRARY_PATH_EXTRA'], 'keep');
      expect(sanitized['GTK_PATHX'], 'keep');
      expect(sanitized['MY_LD_PRELOAD'], 'keep');
      expect(sanitized['PATH'], '/usr/bin');
    });
  });

  group('HostEnv.sanitized (getter)', () {
    test('returns a well-formed map that never contains the strip-keys',
        () {
      final sanitized = HostEnv.sanitized;
      expect(sanitized, isA<Map<String, String>>());
      for (final k in kStripKeys) {
        // The host test environment may or may not export these, but the
        // getter must guarantee they are absent regardless.
        expect(sanitized.containsKey(k), isFalse,
            reason: 'sanitized must never expose $k');
      }
    });
  });
}
