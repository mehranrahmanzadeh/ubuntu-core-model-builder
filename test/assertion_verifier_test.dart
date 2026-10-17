import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/services/assertion_verifier.dart';

/// A long, base64-ish signature block (>= 32 chars) so the signature-length
/// check passes.
const String kSig =
    'MEUCIQDx3Jp2oQnL5k9mR7vT1wZ4yU6aB8cE0fGhIjKlMnOpQIgF0e1r2t3u4v5w6';

/// Builds a signed-model-assertion text with overridable headers.
String signedAssertion({
  String type = 'model',
  String model = 'my-device',
  String authority = 'abc123',
  String brand = 'abc123',
  String? signKey,
  String signature = kSig,
}) {
  final lines = <String>[
    'type: $type',
    'authority-id: $authority',
    'brand-id: $brand',
    'model: $model',
  ];
  if (signKey != null) {
    lines.add('sign-key-sha3-384: $signKey');
  }
  return '${lines.join('\n')}\n\n$signature';
}

ModelAssertion originalModel({
  String model = 'my-device',
  String authority = 'abc123',
  String brand = 'abc123',
}) =>
    ModelAssertion()
      ..model = model
      ..authorityId = authority
      ..brandId = brand;

VerificationCheck? check(
        VerificationReport report, String label) =>
    report.checks.where((c) => c.label == label).firstOrNull;

void main() {
  group('VerificationReport', () {
    test('allPassed is true when there are no fails (warns allowed)', () {
      final r = VerificationReport([
        VerificationCheck('a', CheckStatus.pass, ''),
        VerificationCheck('b', CheckStatus.warn, ''),
      ]);
      expect(r.allPassed, isTrue);
      expect(r.hasWarnings, isTrue);
    });

    test('allPassed is false when any check fails', () {
      final r = VerificationReport([
        VerificationCheck('a', CheckStatus.pass, ''),
        VerificationCheck('b', CheckStatus.fail, ''),
      ]);
      expect(r.allPassed, isFalse);
    });

    test('hasWarnings is false when there are only pass/fail', () {
      final r = VerificationReport([
        VerificationCheck('a', CheckStatus.pass, ''),
        VerificationCheck('b', CheckStatus.fail, ''),
      ]);
      expect(r.hasWarnings, isFalse);
    });
  });

  group('AssertionVerifier.verify', () {
    // A key name that will not exist in the local keyring, so the signing-key
    // check deterministically warns ("no local key") rather than failing.
    const absentKey = 'no-such-key-xyz';

    test('passes the deterministic checks on a matching assertion',
        () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(signKey: 'a1b2c3d4e5f6'),
        originalModel: originalModel(),
        signingKeyName: absentKey,
      );

      expect(check(report, 'Structure')!.status, CheckStatus.pass);
      expect(check(report, 'Type')!.status, CheckStatus.pass);
      expect(check(report, 'Model name')!.status, CheckStatus.pass);
      expect(check(report, 'Authority ID')!.status, CheckStatus.pass);
      expect(check(report, 'Brand ID')!.status, CheckStatus.pass);
      expect(check(report, 'Signature')!.status, CheckStatus.pass);
      // No fails at all (the signing-key check only warns).
      expect(report.allPassed, isTrue);
      // The absent key yields a signing-key warning.
      expect(check(report, 'Signing key')!.status, CheckStatus.warn);
    });

    test('fails structure and returns early on an unparseable assertion',
        () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: 'this is not an assertion at all',
        originalModel: originalModel(),
        signingKeyName: absentKey,
      );
      // Early return: the report contains only the failed Structure check.
      expect(report.checks, hasLength(1));
      expect(check(report, 'Structure')!.status, CheckStatus.fail);
      expect(report.allPassed, isFalse);
    });

    test('fails the Type check when the assertion is not a model', () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(type: 'serial'),
        originalModel: originalModel(),
        signingKeyName: absentKey,
      );
      expect(check(report, 'Type')!.status, CheckStatus.fail);
      expect(check(report, 'Type')!.detail, contains('serial'));
      expect(report.allPassed, isFalse);
    });

    test('fails the Model name check on a mismatch', () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(model: 'other-model'),
        originalModel: originalModel(model: 'my-device'),
        signingKeyName: absentKey,
      );
      expect(check(report, 'Model name')!.status, CheckStatus.fail);
      expect(report.allPassed, isFalse);
    });

    test('fails the Authority ID check on a mismatch', () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(authority: 'someone-else'),
        originalModel: originalModel(authority: 'abc123'),
        signingKeyName: absentKey,
      );
      expect(check(report, 'Authority ID')!.status, CheckStatus.fail);
    });

    test('fails the Brand ID check on a mismatch', () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(brand: 'someone-else'),
        originalModel: originalModel(brand: 'abc123'),
        signingKeyName: absentKey,
      );
      expect(check(report, 'Brand ID')!.status, CheckStatus.fail);
    });

    test('warns when the assertion has no sign-key header', () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(signKey: null),
        originalModel: originalModel(),
        signingKeyName: absentKey,
      );
      expect(check(report, 'Signing key')!.status, CheckStatus.warn);
      expect(check(report, 'Signing key')!.detail,
          contains('no sign-key-sha3-384'));
      // Still no fails: allPassed is true.
      expect(report.allPassed, isTrue);
    });

    test('fails the Signature check when the block is too short', () async {
      final report = await AssertionVerifier().verify(
        signedAssertion: signedAssertion(
            signature: 'short-signature-block'),
        originalModel: originalModel(),
        signingKeyName: absentKey,
      );
      expect(check(report, 'Signature')!.status, CheckStatus.fail);
      expect(report.allPassed, isFalse);
    });
  });

  group('AssertionVerifier.verifyViaSnapAck', () {
    test('returns a snapd-acknowledgement check (env-agnostic)', () async {
      // The exact pass/fail outcome depends on the host's snapd and whether
      // it accepts the file; the contract we lock in is that it completes and
      // reports a check labelled "snapd acknowledgement".
      final check =
          await AssertionVerifier().verifyViaSnapAck('/nonexistent/model');
      expect(check.label, 'snapd acknowledgement');
      // It must report a definitive status (pass or fail), never warn.
      expect(
          check.status == CheckStatus.pass || check.status == CheckStatus.fail,
          isTrue);
    });
  });
}
