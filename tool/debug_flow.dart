// Debug: exercise the full flow and print actual errors.
import 'dart:isolate';
import 'package:ubuntu_core_model_builder/services/ffi/snapstore_auth_client.dart';
import 'package:ubuntu_core_model_builder/services/rust_store_service.dart';

Future<void> main() async {
  print('available: ${SnapstoreAuthSession.isAvailable()}');
  final session = await SnapstoreAuthSession.init(
    storeUrl: 'http://127.0.0.1:8471',
    loginUrl: 'http://127.0.0.1:8471',
    permissions: RustStoreService.loginAcls.join(','),
  );
  final s = await session.login(
    promptCredentials: () async {
      session.auth.submitCredentials('user@example.com', 's3cret');
      await _wait(session, const {AuthState.needs2faCode, AuthState.idle});
      return session.auth.state != AuthState.idle;
    },
    promptTwoFactor: () async {
      session.auth.submit2faCode('654321');
      await _wait(session, const {AuthState.succeeded, AuthState.idle});
      return session.auth.state == AuthState.succeeded;
    },
  );
  print('login result: $s');

  // whoami on UI isolate
  try {
    final a = session.auth.whoami();
    print('whoami (UI): $a');
  } catch (e) {
    print('whoami (UI) FAILED: $e');
  }

  // whoami on new isolate
  try {
    final a = await Isolate.run(() => session.auth.whoami());
    print('whoami (Isolate): $a');
  } catch (e, st) {
    print('whoami (Isolate) FAILED: $e');
    print(st);
  }

  // accountInfoRaw on UI isolate
  try {
    final raw = session.auth.accountInfoRaw();
    print('accountInfo (UI): keys=${raw.keys.toList()}');
  } catch (e) {
    print('accountInfo (UI) FAILED: $e');
  }
}

Future<AuthState> _wait(SnapstoreAuthSession session, Set<AuthState> t) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    final s = session.auth.state;
    if (t.contains(s)) return s;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  return session.auth.state;
}
