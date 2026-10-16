import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/services/assertion_parser.dart';

void main() {
  const sig =
      'MEUCIQDBx3Jp2oQnL5k9mR7vT1wZ4yU6aB8cE0fGhIjKlMnOpQIgF0e1r2t3u4v5w6x7';
  const multiSig =
      'MEUCIQDBx3Jp2oQnL5k9mR7vT1wZ4yU6aB8cE0fGhIjKlMnOpQIgF0e1r2t3\nu4v5w6x7y8z9a0b1c2d3e4f5g6h7i8j9k0l1m2n3o4p5';

  /// A syntactically complete signed model assertion. [extraHeaders] are
  /// inserted just before the timestamp line so nested blocks (snaps:,
  /// validation-sets:, ...) land inside the header block.
  String assertion({
    List<String> extraHeaders = const [],
    String signature = sig,
    String? typeOverride,
  }) {
    return [
      'type: ${typeOverride ?? 'model'}',
      'authority-id: canonical',
      'series: 16',
      'brand-id: canonical',
      'model: my-device',
      'architecture: amd64',
      'base: core24',
      'grade: signed',
      'sign-key-sha3-384: a1b2c3d4e5f6a1b2c3d4e5f6',
      ...extraHeaders,
      'timestamp: 2026-01-02T03:04:05Z',
      '',
      signature,
    ].join('\n');
  }

  const List<String> snapsBlock = [
    'snaps:',
    '  -',
    '    name: pc-kernel',
    '    id: yyyyyyyyyyyyyyyyyyyyyyyyyyyy',
    '    type: kernel',
    '    default-channel: 24/stable',
    '    components:',
    '      pc-kernel-generic:',
    '        presence: required',
    '      pc-kernel-lowlatency:',
    '        presence: optional',
    '  -',
    '    name: pc',
    '    id: zzzzzzzzzzzzzzzzzzzzzzzzzzzz',
    '    type: gadget',
    '    default-channel: 24/stable',
  ];

  group('AssertionParser.parse', () {
    test('extracts top-level headers and accessors', () {
      final parsed = AssertionParser.parse(assertion());
      expect(parsed.type, 'model');
      expect(parsed.authorityId, 'canonical');
      expect(parsed.brandId, 'canonical');
      expect(parsed.model, 'my-device');
      expect(parsed.signKeySha3384, 'a1b2c3d4e5f6a1b2c3d4e5f6');
      expect(parsed.headers['series'], '16');
      expect(parsed.headers['grade'], 'signed');
      // Indented snaps lines must not leak into top-level headers.
      expect(parsed.headers.containsKey('name'), isFalse);
    });

    test('keeps the raw text', () {
      final text = assertion();
      expect(AssertionParser.parse(text).raw, text);
    });

    test('preserves a multi-line signature block', () {
      final parsed =
          AssertionParser.parse(assertion(signature: multiSig));
      expect(parsed.signature, multiSig);
    });

    test('normalises CRLF line endings', () {
      final crlf = assertion().replaceAll('\n', '\r\n');
      final parsed = AssertionParser.parse(crlf);
      expect(parsed.authorityId, 'canonical');
      expect(parsed.headers['model'], 'my-device');
    });

    test('throws when there is no signature block', () {
      expect(
        () => AssertionParser.parse('type: model\nauthority-id: canonical'),
        throwsA(isA<AssertionParseException>()),
      );
    });

    test('throws when the signature block is empty', () {
      expect(
        () => AssertionParser.parse('type: model\n\n   \n'),
        throwsA(isA<AssertionParseException>()),
      );
    });

    test('throws when the type header is missing', () {
      expect(
        () => AssertionParser.parse(
            'authority-id: canonical\nbrand-id: canonical\n\n$sig'),
        throwsA(isA<AssertionParseException>()),
      );
    });
  });

  group('AssertionParser.parseSnaps', () {
    test('parses entry fields in order', () {
      final snaps =
          AssertionParser.parseSnaps(assertion(extraHeaders: snapsBlock));
      expect(snaps, hasLength(2));

      expect(snaps[0].fields['name'], 'pc-kernel');
      expect(snaps[0].fields['id'], 'yyyyyyyyyyyyyyyyyyyyyyyyyyyy');
      expect(snaps[0].fields['type'], 'kernel');
      expect(snaps[0].fields['default-channel'], '24/stable');

      expect(snaps[1].fields['name'], 'pc');
      expect(snaps[1].fields['type'], 'gadget');
    });

    test('parses nested components with presence', () {
      final snaps =
          AssertionParser.parseSnaps(assertion(extraHeaders: snapsBlock));
      expect(snaps[0].components, {
        'pc-kernel-generic': 'required',
        'pc-kernel-lowlatency': 'optional',
      });
      expect(snaps[1].components, isEmpty);
    });

    test('returns empty list when there is no snaps block', () {
      expect(AssertionParser.parseSnaps(assertion()), isEmpty);
    });

    test('stops at the next top-level header', () {
      // The snaps block must not swallow the trailing timestamp header.
      final text = assertion(extraHeaders: snapsBlock);
      final snaps = AssertionParser.parseSnaps(text);
      expect(snaps.last.fields['name'], 'pc');
      expect(snaps.last.fields['timestamp'], isNull);
    });

    test('skips orphan fields before the first entry marker', () {
      final text = [
        'snaps:',
        '    name: orphan',
        '  -',
        '    name: pc',
        '    type: gadget',
      ].join('\n');
      final snaps = AssertionParser.parseSnaps(text);
      expect(snaps, hasLength(1));
      expect(snaps.single.fields['name'], 'pc');
    });

    test('normalises CRLF line endings', () {
      final crlf =
          assertion(extraHeaders: snapsBlock).replaceAll('\n', '\r\n');
      final snaps = AssertionParser.parseSnaps(crlf);
      expect(snaps, hasLength(2));
      expect(snaps[0].components['pc-kernel-generic'], 'required');
    });
  });

  group('AssertionParser.parseValidationSets', () {
    const vsetHeaders = [
      'validation-sets:',
      '  -',
      '    account-id: other-acct',
      '    name: core24-vset',
      '    mode: enforce',
      '    sequence: 3',
      '  -',
      '    name: brand-vset',
      '    mode: prefer-enforce',
    ];

    test('parses a list of maps', () {
      final vsets = AssertionParser.parseValidationSets(
          assertion(extraHeaders: vsetHeaders));
      expect(vsets, hasLength(2));
      expect(vsets[0], {
        'account-id': 'other-acct',
        'name': 'core24-vset',
        'mode': 'enforce',
        'sequence': '3',
      });
      // Second entry legitimately omits account-id.
      expect(vsets[1], {'name': 'brand-vset', 'mode': 'prefer-enforce'});
    });

    test('returns empty list when absent', () {
      expect(AssertionParser.parseValidationSets(assertion()), isEmpty);
    });
  });

  group('AssertionParser.parseStringList', () {
    test('parses an inline single value', () {
      final ids = AssertionParser.parseStringList(
          assertion(extraHeaders: const ['serial-authority: acct-only']),
          'serial-authority');
      expect(ids, ['acct-only']);
    });

    test('parses a multi-line list', () {
      final ids = AssertionParser.parseStringList(
        assertion(
          extraHeaders: const [
            'serial-authority:',
            '  - acct-a',
            '  - acct-b',
          ],
        ),
        'serial-authority',
      );
      expect(ids, ['acct-a', 'acct-b']);
    });

    test('returns empty list when absent', () {
      expect(AssertionParser.parseStringList(assertion(), 'serial-authority'),
          isEmpty);
    });
  });

  group('AssertionParser.parseSystemUserAuthority', () {
    test('absent field parses as brand-only', () {
      final r = AssertionParser.parseSystemUserAuthority(assertion());
      expect(r.anyone, isFalse);
      expect(r.ids, isEmpty);
      expect(r.isPresent, isFalse);
    });

    test('inline star means anyone', () {
      final r = AssertionParser.parseSystemUserAuthority(
          assertion(extraHeaders: const ['system-user-authority: *']));
      expect(r.anyone, isTrue);
      expect(r.ids, isEmpty);
      expect(r.isPresent, isTrue);
    });

    test('inline single id', () {
      final r = AssertionParser.parseSystemUserAuthority(
          assertion(extraHeaders: const ['system-user-authority: acct-x']));
      expect(r.anyone, isFalse);
      expect(r.ids, ['acct-x']);
    });

    test('multi-line id list', () {
      final r = AssertionParser.parseSystemUserAuthority(
        assertion(
          extraHeaders: const [
            'system-user-authority:',
            '  - acct-a',
            '  - acct-b',
          ],
        ),
      );
      expect(r.anyone, isFalse);
      expect(r.ids, ['acct-a', 'acct-b']);
    });

    test('star inside the list means anyone', () {
      final r = AssertionParser.parseSystemUserAuthority(
        assertion(
          extraHeaders: const [
            'system-user-authority:',
            '  - *',
          ],
        ),
      );
      expect(r.anyone, isTrue);
      expect(r.ids, isEmpty);
    });
  });
}
