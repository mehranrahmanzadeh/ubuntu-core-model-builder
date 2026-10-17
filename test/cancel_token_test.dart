import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/services/cancel_token.dart';

void main() {
  group('CancelToken', () {
    test('is not cancelled initially', () {
      final token = CancelToken();
      expect(token.isCancelled, isFalse);
    });

    test('cancel() flips isCancelled to true', () {
      final token = CancelToken();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('cancel() is idempotent', () {
      final token = CancelToken();
      token.cancel();
      token.cancel();
      expect(token.isCancelled, isTrue);
    });

    test('tokens are independent', () {
      final a = CancelToken();
      final b = CancelToken();
      a.cancel();
      expect(a.isCancelled, isTrue);
      expect(b.isCancelled, isFalse);
    });

    test('a cooperative loop stops after cancellation', () async {
      final token = CancelToken();
      var iterations = 0;

      // Simulate a long-running poll loop that checks the token.
      final done = () async {
        while (!token.isCancelled) {
          iterations++;
          if (iterations > 1000) {
            fail('loop did not stop after cancellation');
          }
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
      }();

      // Let it spin a few times, then cancel.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      token.cancel();
      await done;

      expect(iterations, greaterThan(0));
      expect(token.isCancelled, isTrue);
    });

    test('a loop that starts after cancellation never runs', () async {
      final token = CancelToken()..cancel();
      var iterations = 0;
      while (!token.isCancelled) {
        iterations++;
        if (iterations > 10) fail('loop should not run at all');
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(iterations, 0);
    });
  });
}
