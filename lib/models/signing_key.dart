/// A signing key the app can use for model assertions.
///
/// [name] is the key name in the host GPG keyring (`snap keys`), [sha3384]
/// is the SHA3-384 fingerprint of the public key (as `sign-key-sha3-384`),
/// and [registered] indicates whether the key is known to the Snap Store
/// account (it was registered via the app's key registration flow).
class SigningKey {
  final String name;
  final String sha3384;
  final bool registered;

  SigningKey({
    required this.name,
    required this.sha3384,
    this.registered = false,
  });

  SigningKey copyWith({bool? registered}) => SigningKey(
        name: name,
        sha3384: sha3384,
        registered: registered ?? this.registered,
      );
}
