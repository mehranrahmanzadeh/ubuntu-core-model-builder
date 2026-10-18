// Rust-backed implementation of the StoreService interface.
//
// Drop-in replacement for `StoreService` (the snapcraft shell-out version):
// same public API — `StoreAccount`, `LoginSession`, `getCurrentAccount()`,
// `isLoggedIn()`, `loginInteractive()`, `waitForLogin()`, `logout()`,
// `importCredentials()` — but the login itself runs entirely in-app via the
// Rust auth state machine (Ubuntu One SSO + 2FA dialogs), with no terminal
// and no snapcraft dependency.
//
// Credentials persist across app launches through Secure Storage (key
// `snapstore-credentials`); [RustStoreService.bootstrap] restores them at
// startup.
import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'cancel_token.dart';
import 'ffi/snapstore_auth_client.dart';

/// The account the app is signed in as.
class StoreAccount {
  final String email;
  final String accountId;
  final String? username;

  StoreAccount({
    required this.email,
    required this.accountId,
    this.username,
  });
}

/// Handle for an in-progress login. The Rust flow needs no sentinel file;
/// cancel/dispose are no-ops (the login dialogs handle their own
/// cancellation).
class LoginSession {
  LoginSession();
  Future<void> cancel() async {}
  Future<void> dispose() async {}
}

class CredentialImportException implements Exception {
  final String message;
  CredentialImportException(this.message);
  @override
  String toString() => message;
}

class RustStoreService {
  /// Set when a login flow has finished (success/cancel/failure),
  /// so [waitForLogin] can settle immediately instead of polling to timeout.
  bool _loginSettled = false;

  /// Secure-Storage key for the persisted credential pair.
  static const String secureStorageKey = 'snapstore-credentials';

  /// Platform-native secure storage (Keychain / Keystore / libsecret) for
  /// the macaroon credential pair. [FlutterSecureStorage] is the standard
  /// cross-platform choice; on desktop Linux it uses libsecret.
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static Future<String?> _readCreds() => _secure.read(key: secureStorageKey);
  static Future<void> _writeCreds(String json) =>
      _secure.write(key: secureStorageKey, value: json);
  static Future<void> _deleteCreds() => _secure.delete(key: secureStorageKey);

  /// ACLs requested for the standard in-app login — the set `snapcraft login`
  /// requests from the store's `/dev/api/acl/` endpoint, **plus**
  /// `store_admin`.
  ///
  /// `store_admin` is required to read a brand store's catalog
  /// (`GET /api/v2/stores/{id}/snaps` — the Snaps page). It is the same scope
  /// the old `surl` flow obtained via
  /// `snapcraft export-login --acls package_access,store_admin`. Requesting it
  /// in the single in-app login means one sign-in covers BOTH the account/keys
  /// endpoints and the brand-store catalog, so [RustSurlService.webLogin] can
  /// safely no-op when a session already exists.
  ///
  /// `modify_account_key` is required to register signing keys
  /// (`POST /dev/api/account/account-key` — the Keys page). snapcraft itself
  /// does NOT request it in a normal login (its `register-key` command logs in
  /// with a short-lived token scoped to exactly this ACL), so without it the
  /// store rejects key registration with
  /// `permission modify_account_key is required`.
  ///
  /// NOTE: the store rejects other spellings (e.g. `package-view` /
  /// `account-view-packages` -> 403 `macaroon-permission-invalid`). The
  /// `package_access`/`package_manage` meta-ACLs grant the read access the
  /// app needs for account/store listings, so no extra view ACLs are
  /// requested.
  static const List<String> loginAcls = [
    'package_access',
    'package_manage',
    'package_metrics',
    'package_push',
    'package_register',
    'package_release',
    'package_update',
    'store_admin',
    'modify_account_key',
  ];

  static String get _loginPermissions => loginAcls.join(',');

  /// Initialize the Rust runtime and restore the persisted credentials
  /// (if any). Call once from `main()` before `runApp`.
  ///
  /// Never throws: when the native library is missing the app simply runs
  /// unsigned (the account step stays "Not signed in").
  static Future<void> bootstrap() async {
    if (!SnapstoreAuthSession.isAvailable()) return;
    try {
      final session =
          await SnapstoreAuthSession.init(permissions: _loginPermissions);
      final saved = await _readCreds();
      if (saved == null || saved.isEmpty) return;
      // No network needed: the Rust side validates the macaroon pair
      // locally (parse + bind) before flipping the machine to `succeeded`.
      await session.restore(saved);
    } catch (_) {
      // Best-effort: an unreadable/invalid pair just means "signed out".
    }
  }

  Future<StoreAccount?> getCurrentAccount() async {
    final session = SnapstoreAuthSession.current;
    if (session == null) return null;
    if (session.auth.state != AuthState.succeeded) return null;
    try {
      // `whoami` blocks the isolate for one HTTP request — run it off the
      // UI thread (FFI objects are sendable).
      final info = await Isolate.run(() => session.auth.whoami());
      return _toAccount(info);
    } catch (_) {
      // Fall back to the UI isolate (bounded by the Rust-side timeout).
      try {
        return _toAccount(session.auth.whoami());
      } catch (_) {
        return null;
      }
    }
  }

  StoreAccount? _toAccount(AccountInfo info) {
    if (info.email.isEmpty) return null;
    return StoreAccount(
      email: info.email,
      accountId: info.id,
      username: info.username.isEmpty ? null : info.username,
    );
  }

  Future<bool> isLoggedIn() async => (await getCurrentAccount()) != null;

  /// Starts the in-app interactive login (email + password + 2FA dialogs).
  ///
  /// [context] is used to present the dialogs; pass the page's context.
  Future<LoginSession> loginInteractive({BuildContext? context}) async {
    if (context == null || !context.mounted) {
      throw StateError(
          'loginInteractive() requires a mounted BuildContext to show dialogs.');
    }
    final session = await _ensureSession();
    final s = await session.login(
      promptCredentials: () => _showCredentialsDialog(context, session),
      promptTwoFactor: () => _showTwoFactorDialog(context, session),
    );
    if (s == AuthState.succeeded) {
      await _persistLatestCredentials();
    }
    _loginSettled = true;
    return LoginSession();
  }

  /// Resolves once the login flow has settled: returns the signed-in
  /// account, or `null` when it was cancelled/failed/timed out.
  Future<StoreAccount?> waitForLogin({
    Duration interval = const Duration(seconds: 2),
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancelToken,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (cancelToken?.isCancelled ?? false) return null;
      // The dialog-driven flow has already ended (cancel/failure): no need
      // to poll to the timeout.
      if (_loginSettled) {
        final session = SnapstoreAuthSession.current;
        if (session == null || session.auth.state != AuthState.succeeded) {
          return null;
        }
      }
      final acct = await _settleAccount();
      if (acct != null) return acct;
      await Future<void>.delayed(interval);
    }
    return null;
  }

  Future<void> logout() async {
    final session = SnapstoreAuthSession.current;
    if (session != null) {
      try {
        await session.logout();
      } catch (_) {
        // The in-process session is best-effort; always clear storage.
      }
    }
    try {
      await _deleteCreds();
    } catch (_) {}
  }

  /// Imports a `snapcraft export-login` credential payload (the pasted
  /// text). The Rust side validates the macaroon pair and re-keys the
  /// session; the fresh pair is persisted to Secure Storage.
  Future<StoreAccount?> importCredentials(String credentials) async {
    final trimmed = credentials.trim();
    if (trimmed.isEmpty) {
      throw CredentialImportException('No credentials provided.');
    }
    final session = await _ensureSession();
    try {
      session.auth.importExportedLogin(trimmed);
    } on SnapstoreAuthError catch (e) {
      throw CredentialImportException(_humanError(e));
    }
    // Wait for the machine to process the import (validate + persist).
    final s = await _waitForState(
        session, const {AuthState.succeeded, AuthState.idle},
        const Duration(seconds: 10));
    if (s != AuthState.succeeded) {
      final events = session.auth.drainEvents();
      final detail = events
          .whereType<FailedEvent>()
          .map((e) => _humanError(e.error))
          .join('; ');
      throw CredentialImportException(
          detail.isEmpty ? 'Credentials could not be validated.' : detail);
    }
    await _persistLatestCredentials();
    return getCurrentAccount();
  }

  // -- internals -------------------------------------------------------------

  Future<SnapstoreAuthSession> _ensureSession() async {
    final existing = SnapstoreAuthSession.current;
    if (existing != null) return existing;
    if (!SnapstoreAuthSession.isAvailable()) {
      throw StateError('The Rust auth backend is not available.');
    }
    return SnapstoreAuthSession.init(permissions: _loginPermissions);
  }

  /// Resolves the account when the machine has settled on `succeeded`
  /// (persisting the fresh credential pair first); `null` otherwise.
  Future<StoreAccount?> _settleAccount() async {
    final session = SnapstoreAuthSession.current;
    if (session == null) return null;
    if (session.auth.state != AuthState.succeeded) return null;
    await _persistLatestCredentials();
    return getCurrentAccount();
  }

  /// Drains a `succeeded` event and stores its credentials in Secure
  /// Storage (best-effort). Retries briefly because the event is emitted a
  /// few microseconds after the state transition.
  Future<void> _persistLatestCredentials() async {
    final session = SnapstoreAuthSession.current;
    if (session == null) return;
    for (var i = 0; i < 5; i++) {
      for (final e in session.auth.drainEvents()) {
        if (e is SucceededEvent) {
          try {
            await _writeCreds(e.credentialsJson);
          } catch (_) {}
          return;
        }
      }
      if (session.auth.state != AuthState.succeeded) return;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<AuthState> _waitForState(SnapstoreAuthSession session,
      Set<AuthState> targets, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final s = session.auth.state;
      if (targets.contains(s)) return s;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return session.auth.state;
  }

  static String _humanError(SnapstoreAuthError e) {
    if (e.kind == 'http' && e.httpStatus != null) {
      return '${SnapstoreServiceErrors.cleanDetail(e.detail)} '
          '(HTTP ${e.httpStatus})';
    }
    return SnapstoreServiceErrors.cleanDetail(e.detail);
  }
}

// ---------------------------------------------------------------------------
// Login dialogs (the "terminal" replaced by in-app UI)
//
// Each dialog is *self-contained* for its phase: after the user submits, the
// dialog performs the FFI submit and polls the machine until the phase
// settles. Wrong credentials / a wrong 2FA code surface as inline errors
// with in-place retry. The dialog's future resolves `true` when the phase
// settled (hand-off / success) and `false` when the user cancelled the
// whole login.
//
// Event-buffer discipline: a dialog only drains machine events in *terminal*
// states (idle / succeeded). While the machine is in-flight the events stay
// buffered, so the login loop never observes a stale state.
// ---------------------------------------------------------------------------

const _pollInterval = Duration(milliseconds: 150);

/// Polls the machine until the phase the dialog just submitted has settled.
///
/// Terminal detection is state-based; the "input rejected, try again" case
/// is detected from *fresh machine events* (a `failed` event, or a re-
/// emitted `needs_2fa_code` for the code phase).
class _PhaseWatcher {
  _PhaseWatcher(this._session, this._isCredentialsPhase) {
    _tick();
    _timer = Timer.periodic(_pollInterval, (_) => _tick());
  }

  final SnapstoreAuthSession _session;
  final bool _isCredentialsPhase;
  late final Timer _timer;
  final Completer<bool> result = Completer<bool>();

  void Function(String)? _onFailure;

  void start(void Function(String message) onFailure) {
    _onFailure = onFailure;
  }

  void cancel() {
    _timer.cancel();
    if (!result.isCompleted) result.complete(false);
  }

  void _done(bool ok) {
    _timer.cancel();
    if (!result.isCompleted) result.complete(ok);
  }

  void _tick() {
    if (result.isCompleted) {
      _timer.cancel();
      return;
    }
    final s = _session.auth.state;

    if (s == AuthState.succeeded) {
      _done(true);
      return;
    }
    if (_isCredentialsPhase && s == AuthState.needs2faCode) {
      // Credentials accepted; the 2FA dialog takes over. Do NOT drain the
      // buffered `needs_2fa_code` event — the 2FA phase owns it.
      _done(true);
      return;
    }
    if (s == AuthState.idle) {
      // Flow ended without success: report (retryable) or give up.
      var handled = false;
      for (final e in _session.auth.drainEvents()) {
        if (e is FailedEvent && !handled) {
          handled = true;
          final fn = _onFailure;
          if (fn != null) {
            fn(SnapstoreServiceErrors.human(e.error));
            // The dialog stays open for an in-place retry. Stop the poller:
            // the next tick would see idle + an EMPTY event buffer and
            // misread that as "flow ended", auto-closing the dialog.
            _timer.cancel();
            return;
          }
        }
        if (e is CancelledEvent) {
          _done(false);
          return;
        }
      }
      if (!handled) _done(false);
      return;
    }
    // While the code phase is in flight, a *fresh* re-emitted
    // `needs_2fa_code` event means the code we just sent was rejected —
    // surface it inline instead of looping.
    if (!_isCredentialsPhase && s == AuthState.needs2faCode) {
      for (final e in _session.auth.drainEvents()) {
        if (e is Needs2faCodeEvent) {
          final fn = _onFailure;
          if (fn != null) {
            fn('The code was not accepted. Check it and try again.');
            return;
          }
        }
      }
    }
    // Still in flight (working / home state); keep waiting.
  }
}

/// Email + password prompt with inline error feedback.
Future<bool> _showCredentialsDialog(
    BuildContext context, SnapstoreAuthSession session) {
  // Consume the `needs_credentials` event that triggered this dialog (and
  // any stale events), so events buffered later are unambiguously new.
  session.auth.drainEvents();
  final email = TextEditingController();
  final password = TextEditingController();
  final formKey = GlobalKey<FormState>();
  String? error;
  bool submitting = false;
  _PhaseWatcher? watcher;
  bool completed = false;

  final Future<bool?> future = showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          void submit() {
            if (!formKey.currentState!.validate()) return;
            setState(() {
              submitting = true;
              error = null;
            });
            try {
              final state = session.auth.state;
              if (state == AuthState.idle) {
                // Previous attempt failed (machine reset to idle): restart
                // the flow before submitting again.
                session.auth.startLogin();
              }
              session.auth.submitCredentials(email.text.trim(), password.text);
              watcher?.cancel();
              final w = _PhaseWatcher(session, true);
              watcher = w;
              w.start((msg) {
                setState(() {
                  submitting = false;
                  error = msg;
                });
              });
              w.result.future.then((ok) {
                // A newer submit superseded this watcher (retry after an
                // inline error): its cancel() completes the future with
                // `false` — that must not pop the dialog.
                if (w != watcher) return;
                completed = true;
                if (dialogContext.mounted &&
                    Navigator.of(dialogContext).canPop()) {
                  Navigator.of(dialogContext).pop(ok);
                }
              });
            } on SnapstoreAuthError catch (e) {
              setState(() {
                submitting = false;
                error = SnapstoreServiceErrors.human(e);
              });
            }
          }

          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (completed || didPop) return;
              // Explicit cancel: abort the whole login flow.
              watcher?.cancel();
              session.auth.cancel();
              Navigator.of(dialogContext).pop(false);
            },
            child: AlertDialog(
              title: const Text('Sign in to the Snap Store'),
              content: SizedBox(
                width: 420,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (error != null) ...[
                        Text(error!,
                            style: TextStyle(
                                color: Theme.of(ctx).colorScheme.error)),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: email,
                        enabled: !submitting,
                        decoration:
                            const InputDecoration(labelText: 'Ubuntu One email'),
                        autofillHints: const [AutofillHints.email],
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        validator: (v) =>
                            (v == null || v.trim().isEmpty)
                                ? 'Email is required.'
                                : null,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: password,
                        enabled: !submitting,
                        decoration:
                            const InputDecoration(labelText: 'Password'),
                        autofillHints: const [AutofillHints.password],
                        obscureText: true,
                        onFieldSubmitted: (_) => submit(),
                        validator: (v) =>
                            (v == null || v.isEmpty)
                                ? 'Password is required.'
                                : null,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting || completed
                      ? null
                      : () =>
                          Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  onPressed: submitting ? null : submit,
                  icon: submitting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.login, size: 16),
                  label: Text(submitting ? 'Signing in…' : 'Sign in'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
  return future.then((v) => v ?? false);
}

/// TOTP / SMS one-time-code prompt with inline error feedback.
Future<bool> _showTwoFactorDialog(
    BuildContext context, SnapstoreAuthSession session) {
  // Consume the `needs_2fa_code` event that triggered this dialog; any
  // re-emitted event later means the code we sent was rejected.
  session.auth.drainEvents();
  final code = TextEditingController();
  final formKey = GlobalKey<FormState>();
  String? error;
  bool submitting = false;
  bool completed = false;
  _PhaseWatcher? watcher;

  final Future<bool?> future = showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (ctx, setState) {
          void submit() {
            if (!formKey.currentState!.validate()) return;
            setState(() {
              submitting = true;
              error = null;
            });
            try {
              session.auth.submit2faCode(code.text.trim());
              watcher?.cancel();
              final w = _PhaseWatcher(session, false);
              watcher = w;
              w.start((msg) {
                setState(() {
                  submitting = false;
                  error = msg;
                  code.clear();
                });
              });
              w.result.future.then((ok) {
                // A newer submit superseded this watcher (retry after an
                // inline error): its cancel() completes the future with
                // `false` — that must not pop the dialog.
                if (w != watcher) return;
                completed = true;
                if (dialogContext.mounted &&
                    Navigator.of(dialogContext).canPop()) {
                  Navigator.of(dialogContext).pop(ok);
                }
              });
            } on SnapstoreAuthError catch (e) {
              setState(() {
                submitting = false;
                error = SnapstoreServiceErrors.human(e);
              });
            }
          }

          return PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, result) {
              if (completed || didPop) return;
              watcher?.cancel();
              session.auth.cancel();
              Navigator.of(dialogContext).pop(false);
            },
            child: AlertDialog(
              title: const Text('Two-factor authentication'),
              content: SizedBox(
                width: 420,
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Enter the 6-digit code from your authenticator app '
                        '(or the SMS code you received).',
                      ),
                      const SizedBox(height: 16),
                      if (error != null) ...[
                        Text(error!,
                            style: TextStyle(
                                color: Theme.of(ctx).colorScheme.error)),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: code,
                        enabled: !submitting,
                        autofocus: true,
                        keyboardType: TextInputType.number,
                        maxLength: 8,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 22,
                            letterSpacing: 8),
                        decoration:
                            const InputDecoration(labelText: 'Code'),
                        onFieldSubmitted: (_) => submit(),
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Enter the code.'
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: submitting || completed
                      ? null
                      : () =>
                          Navigator.of(dialogContext).pop(false),
                  child: const Text('Cancel'),
                ),
                ElevatedButton.icon(
                  onPressed: submitting ? null : submit,
                  icon: submitting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.lock, size: 16),
                  label: Text(submitting ? 'Verifying…' : 'Verify'),
                ),
              ],
            ),
          );
        },
      );
    },
  );
  return future.then((v) => v ?? false);
}

/// Maps a Rust `SnapstoreAuthError` to a user-friendly message.
class SnapstoreServiceErrors {
  static String human(SnapstoreAuthError e) {
    switch (e.kind) {
      case 'credentials_rejected':
        return 'The store rejected your credentials. Check your email and '
            'password, then try again.';
      case 'two_factor_required':
        return 'This account requires a two-factor code.';
      case 'http':
        final status = e.httpStatus;
        if (status == 401 || status == 403) {
          return 'Authentication failed. '
              'Check your credentials and try again.';
        }
        final base = cleanDetail(e.detail);
        return base.isEmpty
            ? 'The store request failed (HTTP $status).'
            : 'The store request failed (HTTP $status): $base';
      case 'network':
        return 'Network error: ${cleanDetail(e.detail)}';
      case 'no_active_session':
        return 'Not signed in (session is inactive).';
      default:
        final base = cleanDetail(e.detail);
        return base.isEmpty ? 'Login failed.' : base;
    }
  }

  /// Strips the trailing ` (code: …)` the Rust side appends to store error
  /// bodies, keeping the human-readable message part.
  static String cleanDetail(String detail) {
    final idx = detail.lastIndexOf(' (code: ');
    if (idx > 0) return detail.substring(0, idx).trim();
    return detail.trim();
  }
}
