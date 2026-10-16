/// A brand store the account can access. `ubuntu` is the global store, for
/// which the model's `store` field should be omitted entirely.
class BrandStore {
  final String id;
  final String? name;
  final List<String> roles;
  const BrandStore({required this.id, this.name, this.roles = const []});
  bool get isGlobal => id == 'ubuntu';
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'roles': roles,
      };
  factory BrandStore.fromJson(Map<String, dynamic> j) => BrandStore(
        id: j['id'] as String,
        name: j['name'] as String?,
        roles: (j['roles'] as List<dynamic>?)
                ?.map((r) => r.toString())
                .toList() ??
            const [],
      );
}

/// A snap listed in a brand store's catalog (id + name only; type/base/
/// channels are resolved separately via the store info API).
class StoreCatalogSnap {
  final String id;
  final String name;
  const StoreCatalogSnap({required this.id, required this.name});
}

/// Shared-prefs key under which the brand-store list is cached.
/// (Top-level because it is shared between the Rust-backed surl service
/// and the pages; the former snapcraft-based implementation no longer
/// owns it.)
const String prefCachedStores = 'metadata.cachedStores';

class SurlAuthException implements Exception {
  final String message;
  SurlAuthException(this.message);
  @override
  String toString() => message;
}

class SurlUnavailableException implements Exception {
  final String message;
  SurlUnavailableException([this.message = 'surl is not available.']);
  @override
  String toString() => message;
}
