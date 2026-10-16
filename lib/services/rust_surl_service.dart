// Rust-backed implementation of the SurlService interface.
//
// Drop-in replacement for `SurlService` (the `surl` CLI shell-out version):
//
//   * `listStores()`    — `GET /dev/api/account` through the Rust store
//     client (same endpoint surl was hitting), replacing the surl
//     shell-out;
//   * `listStoreSnaps()` — `GET /api/v2/stores/{id}/snaps` through the
//     Rust store client;
//   * `webLogin()`      — no exported-login terminal: reuses the app's
//     in-app Rust login (email + 2FA dialogs). Pass a [BuildContext] to
//     present the dialogs; it is a no-op when already signed in.
//
// The model's `BrandStore` / `StoreCatalogSnap` classes and the
// `SurlAuthException` / `SurlUnavailableException` types come from
// `surl_service.dart` so the pages' catch clauses work unchanged.
import 'dart:isolate';

import 'package:flutter/material.dart';

import 'ffi/snapstore_auth_client.dart' hide BrandStore;
import 'rust_store_service.dart';
import 'surl_service.dart'
    show
        BrandStore,
        StoreCatalogSnap,
        SurlAuthException,
        SurlUnavailableException;

class RustSurlService {
  /// `true` when the app holds a usable store session in-process.
  Future<bool> hasCredential() async {
    final session = SnapstoreAuthSession.current;
    return session != null && session.auth.state == AuthState.succeeded;
  }

  /// Brand stores the account can access
  /// (`/dev/api/account` → `stores[].{id,name,roles}`).
  Future<List<BrandStore>> listStores() async {
    final session = _requireSession();
    final Map<String, Object?> raw;
    try {
      // Blocking FFI + HTTP — run off the UI isolate.
      raw = await Isolate.run(() => session.auth.accountInfoRaw());
    } on SnapstoreAuthError catch (e) {
      throw SurlAuthException(_authMessage(e));
    } catch (e) {
      throw SurlUnavailableException('Store lookup failed: $e');
    }
    return _parseStores(raw['stores']);
  }

  /// Snaps listed in a (brand) store's catalog
  /// (`/api/v2/stores/{id}/snaps` → `snaps[].{name,id}`).
  ///
  /// Throws [SurlAuthException] when the session is missing or the store
  /// rejects the token (401/403 — callers offer the re-login flow);
  /// [SurlUnavailableException] for other transport failures.
  Future<List<StoreCatalogSnap>> listStoreSnaps(String storeId) async {
    final session = _requireSession();
    final Map<String, Object?> raw;
    try {
      raw = await Isolate.run(() => session.auth.storeSnapsRaw(storeId));
    } on SnapstoreAuthError catch (e) {
      if (e.kind == 'http' &&
          (e.httpStatus == 401 || e.httpStatus == 403)) {
        throw SurlAuthException(_authMessage(e));
      }
      throw SurlUnavailableException(_transportMessage(e));
    } catch (e) {
      throw SurlUnavailableException('Store catalog fetch failed: $e');
    }
    final snaps = raw['snaps'];
    if (snaps is! List) return const [];
    return snaps
        .whereType<Map>()
        .map((e) {
          final m = e.cast<String, Object?>();
          return StoreCatalogSnap(
            id: m['id'] is String ? m['id'] as String : '',
            name: m['name'] is String ? m['name'] as String : '',
          );
        })
        .where((s) => s.name.isNotEmpty)
        .toList();
  }

  /// Authenticates for store queries. Unlike the old surl flow there is no
  /// exported-login terminal: this reuses the app's in-app Rust login
  /// (email + 2FA dialogs).
  ///
  /// [context] presents the login dialogs; when it is `null` the method is
  /// a no-op if already signed in and throws [SurlAuthException] otherwise.
  Future<void> webLogin({BuildContext? context}) async {
    final session = SnapstoreAuthSession.current;
    if (session != null && session.auth.state == AuthState.succeeded) {
      return;
    }
    if (context == null || !context.mounted) {
      throw SurlAuthException(
          'Store sign-in is required. Sign in on the Account step first.');
    }
    final svc = RustStoreService();
    await svc.loginInteractive(context: context);
    final s2 = SnapstoreAuthSession.current;
    if (s2 == null || s2.auth.state != AuthState.succeeded) {
      throw SurlAuthException('Store sign-in was cancelled.');
    }
  }

  // -- internals -------------------------------------------------------------

  SnapstoreAuthSession _requireSession() {
    final session = SnapstoreAuthSession.current;
    if (session == null || session.auth.state != AuthState.succeeded) {
      throw SurlAuthException(
          'Not authenticated (sign in on the Account step).');
    }
    return session;
  }

  List<BrandStore> _parseStores(Object? raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) {
          final m = e.cast<String, Object?>();
          return BrandStore(
            id: m['id'] is String ? m['id'] as String : '',
            name: m['name'] is String ? m['name'] as String : null,
            roles: m['roles'] is List
                ? (m['roles'] as List).map((r) => r.toString()).toList()
                : const <String>[],
          );
        })
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  static String _authMessage(SnapstoreAuthError e) {
    if (e.kind == 'http' && e.httpStatus != null) {
      return 'The store rejected the session (HTTP ${e.httpStatus}). '
          'Sign in again.';
    }
    final idx = e.detail.lastIndexOf(' (code: ');
    final base = idx > 0 ? e.detail.substring(0, idx) : e.detail;
    return base.trim().isEmpty ? 'Not authenticated.' : base.trim();
  }

  static String _transportMessage(SnapstoreAuthError e) {
    if (e.kind == 'network') {
      return 'Could not reach the store: ${e.detail}';
    }
    return e.detail;
  }
}
