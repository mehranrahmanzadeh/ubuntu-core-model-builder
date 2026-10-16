import 'package:flutter_test/flutter_test.dart';
import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/services/assertion_builder.dart';

void main() {
  ModelAssertion validModel() {
    return ModelAssertion()
      ..authorityId = 'abc123'
      ..brandId = 'abc123'
      ..model = 'my-device'
      ..base = 'core24'
      ..snaps = [
        SnapEntry(
          name: 'my-app',
          id: 'x' * 32,
          type: SnapType.app,
          defaultChannel: 'stable',
        ),
        SnapEntry(
          name: 'pc-kernel',
          id: 'y' * 32,
          type: SnapType.kernel,
          defaultChannel: '24/stable',
        ),
        SnapEntry(
          name: 'pc',
          id: 'z' * 32,
          type: SnapType.gadget,
          defaultChannel: '24/stable',
        ),
      ];
  }

  test('builds valid header with ordered snaps', () {
    final header = AssertionBuilder.buildHeader(validModel());
    final snaps = header['snaps'] as List;

    expect(header['type'], 'model');
    expect(header['series'], '16');
    expect(header['grade'], 'signed');
    expect(header['base'], 'core24');
    // kernel & gadget ordered before app
    expect(snaps.first['name'], 'pc-kernel');
    expect(snaps.last['name'], 'my-app');
    expect(header['timestamp'], matches(r'Z$'));
  });

  test('throws when snap ID unresolved', () {
    final model = validModel();
    model.snaps = [
      SnapEntry(
        name: 'pc-kernel',
        id: '',
        type: SnapType.kernel,
        defaultChannel: 'stable',
      ),
      SnapEntry(
        name: 'pc',
        id: 'z' * 32,
        type: SnapType.gadget,
        defaultChannel: 'stable',
      ),
    ];

    expect(
      () => AssertionBuilder.buildHeader(model),
      throwsA(isA<AssertionBuildException>()),
    );
  });

  test('throws when kernel missing', () {
    final model = validModel();
    model.snaps = [
      SnapEntry(
        name: 'pc',
        id: 'z' * 32,
        type: SnapType.gadget,
        defaultChannel: 'stable',
      ),
    ];

    expect(
      () => AssertionBuilder.buildHeader(model),
      throwsA(isA<AssertionBuildException>()),
    );
  });

  test('throws when authority-id differs from brand-id', () {
    final model = validModel()..authorityId = 'different';
    expect(
      () => AssertionBuilder.buildHeader(model),
      throwsA(isA<AssertionBuildException>()),
    );
  });

  test('buildJson produces valid indented JSON', () {
    final json = AssertionBuilder.buildJson(validModel());
    expect(json, contains('"type": "model"'));
    expect(json, contains('"brand-id": "abc123"'));
  });

  group('validation', () {
    test('blank authority-id is reported', () {
      final m = validModel()..authorityId = '   ';
      expect(
          () => AssertionBuilder.buildHeader(m),
          throwsA(isA<AssertionBuildException>()
              .having((e) => e.errors.join(' '), 'errors',
                  contains('authority-id'))));
    });

    test('bad model name is rejected', () {
      for (final bad in ['My-Device', 'my device', '-lead', 'trail-', '']) {
        final m = validModel()..model = bad;
        expect(
            () => AssertionBuilder.buildHeader(m),
            throwsA(isA<AssertionBuildException>()
                .having((e) => e.errors.join(' '), 'errors',
                    contains('model name'))),
            reason: 'model name "$bad" must be rejected');
      }
    });

    test('missing base is reported', () {
      final m = validModel()..base = null;
      expect(
          () => AssertionBuilder.buildHeader(m),
          throwsA(isA<AssertionBuildException>()
              .having((e) => e.errors.join(' '), 'errors', contains('base'))));
    });

    test('missing gadget is reported', () {
      final m = validModel();
      m.snaps.removeWhere((s) => s.type == SnapType.gadget);
      expect(
          () => AssertionBuilder.buildHeader(m),
          throwsA(isA<AssertionBuildException>()
              .having((e) => e.errors.join(' '), 'errors', contains('gadget'))));
    });

    test('all validation errors are aggregated in one exception', () {
      final m = validModel()
        ..authorityId = null
        ..model = 'Bad Model'
        ..base = null;
      m.snaps.removeWhere((s) => s.type == SnapType.gadget);

      Object? caught;
      try {
        AssertionBuilder.buildHeader(m);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<AssertionBuildException>());
      expect((caught as AssertionBuildException).errors.length,
          greaterThanOrEqualTo(4));
    });

    test('exception message lists each error', () {
      final m = validModel()..model = null;
      try {
        AssertionBuilder.buildHeader(m);
        fail('expected AssertionBuildException');
      } on AssertionBuildException catch (e) {
        expect(e.toString(), contains('  - model name is required.'));
      }
    });
  });

  group('optional header fields', () {
    test('store omitted when blank, present when set', () {
      expect(AssertionBuilder.buildHeader(validModel())['store'], isNull);
      final m = validModel()..store = '  my-brand  ';
      expect(AssertionBuilder.buildHeader(m)['store'], 'my-brand');
    });

    test('custom series is honoured', () {
      final m = validModel()..series = '20';
      expect(AssertionBuilder.buildHeader(m)['series'], '20');
    });

    test('grade name is emitted', () {
      final m = validModel()..grade = ModelGrade.secured;
      expect(AssertionBuilder.buildHeader(m)['grade'], 'secured');
    });
  });

  group('system-user-authority', () {
    test('brandOnly omits the field', () {
      expect(
          AssertionBuilder.buildHeader(validModel())['system-user-authority'],
          isNull);
    });

    test('anyone emits the literal star', () {
      final m = validModel()
        ..systemUserAuthorityMode = SystemUserAuthorityMode.anyone;
      expect(AssertionBuilder.buildHeader(m)['system-user-authority'], '*');
    });

    test('specificIds emits a trimmed non-empty list', () {
      final m = validModel()
        ..systemUserAuthorityMode = SystemUserAuthorityMode.specificIds
        ..systemUserAuthorityIds = ['  acct-a ', '', 'acct-b', '   '];
      expect(
          AssertionBuilder.buildHeader(m)['system-user-authority'],
          ['acct-a', 'acct-b']);
    });

    test('specificIds with only blank ids omits the field', () {
      final m = validModel()
        ..systemUserAuthorityMode = SystemUserAuthorityMode.specificIds
        ..systemUserAuthorityIds = [' ', '  '];
      expect(
          AssertionBuilder.buildHeader(m)['system-user-authority'], isNull);
    });
  });

  group('validation-sets', () {
    test('omitted when none', () {
      expect(
          AssertionBuilder.buildHeader(validModel())['validation-sets'],
          isNull);
    });

    test('emits entries, omitting account-id equal to brand-id', () {
      final m = validModel();
      m.validationSets = [
        ValidationSetRef(accountId: 'abc123', name: 'brand-vset'),
        ValidationSetRef(
            accountId: 'other',
            name: 'core24-vset',
            mode: 'prefer-enforce',
            sequence: 7),
      ];
      final sets = AssertionBuilder.buildHeader(m)['validation-sets'] as List;
      expect(sets, hasLength(2));
      // Brand-owned: account-id omitted.
      expect(sets[0], {'name': 'brand-vset', 'mode': 'enforce'});
      // Foreign: account-id kept, sequence stringified.
      expect(sets[1], {
        'account-id': 'other',
        'name': 'core24-vset',
        'mode': 'prefer-enforce',
        'sequence': '7',
      });
    });

    test('blank names are filtered out', () {
      final m = validModel();
      m.validationSets = [
        ValidationSetRef(accountId: 'abc123', name: '   '),
      ];
      expect(AssertionBuilder.buildHeader(m)['validation-sets'], isNull);
    });
  });

  group('storage-safety', () {
    test('unset omits the field', () {
      expect(
          AssertionBuilder.buildHeader(validModel())['storage-safety'],
          isNull);
    });

    test('encrypted', () {
      final m = validModel()..storageSafety = StorageSafety.encrypted;
      expect(
          AssertionBuilder.buildHeader(m)['storage-safety'], 'encrypted');
    });

    test('preferEncrypted', () {
      final m = validModel()..storageSafety = StorageSafety.preferEncrypted;
      expect(
          AssertionBuilder.buildHeader(m)['storage-safety'],
          'prefer-encrypted');
    });

    test('preferUnencrypted', () {
      final m = validModel()..storageSafety = StorageSafety.preferUnencrypted;
      expect(
          AssertionBuilder.buildHeader(m)['storage-safety'],
          'prefer-unencrypted');
    });
  });

  group('serial-authority', () {
    test('omitted when empty', () {
      expect(
          AssertionBuilder.buildHeader(validModel())['serial-authority'],
          isNull);
    });

    test('emits trimmed ids, dropping blanks', () {
      final m = validModel()..serialAuthorityIds = ['acct-a', '  acct-b  ', ''];
      expect(
          AssertionBuilder.buildHeader(m)['serial-authority'],
          ['acct-a', 'acct-b']);
    });
  });

  group('snap maps', () {
    test('presence omitted for infrastructure snaps', () {
      final snaps =
          AssertionBuilder.buildHeader(validModel())['snaps'] as List;
      for (final raw in snaps) {
        final map = raw as Map;
        if (map['type'] != 'app') {
          expect(map['presence'], isNull);
        }
      }
    });

    test('presence emitted for app snaps', () {
      final m = validModel();
      final app = m.snaps.firstWhere((s) => s.type == SnapType.app);
      m.snaps = [
        ...m.snaps.where((s) => s != app),
        SnapEntry(
            name: app.name,
            id: app.id,
            type: app.type,
            defaultChannel: app.defaultChannel,
            presence: SnapPresence.optional),
      ];
      final snaps = AssertionBuilder.buildHeader(m)['snaps'] as List;
      final a = snaps.firstWhere((s) => (s as Map)['type'] == 'app') as Map;
      expect(a['presence'], 'optional');
    });

    test('components are emitted nested', () {
      final m = validModel();
      final kernel = m.snaps.firstWhere((s) => s.type == SnapType.kernel);
      m.snaps = [
        ...m.snaps.where((s) => s != kernel),
        kernel.copyWith(components: {
          'pc-kernel-generic': 'required',
          'extra': 'optional',
        }),
      ];
      final snaps = AssertionBuilder.buildHeader(m)['snaps'] as List;
      final k = snaps.firstWhere((s) => (s as Map)['name'] == 'pc-kernel')
          as Map;
      expect(k['components'], {
        'pc-kernel-generic': {'presence': 'required'},
        'extra': {'presence': 'optional'},
      });
    });

    test('empty channel is dropped from the map', () {
      final m = validModel();
      final app = m.snaps.firstWhere((s) => s.type == SnapType.app);
      m.snaps = [
        ...m.snaps.where((s) => s != app),
        SnapEntry(
            name: app.name,
            id: app.id,
            type: app.type,
            defaultChannel: ''),
      ];
      final snaps = AssertionBuilder.buildHeader(m)['snaps'] as List;
      final a = snaps.firstWhere((s) => (s as Map)['name'] == app.name) as Map;
      expect(a.containsKey('default-channel'), isFalse);
    });
  });

  group('orderedSnaps', () {
    test('infrastructure ranked snapd < base < kernel < gadget', () {
      final ordered = AssertionBuilder.orderedSnaps([
        SnapEntry(
            name: 'zz-gadget',
            id: 'g',
            type: SnapType.gadget,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'aa-kernel',
            id: 'k',
            type: SnapType.kernel,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'snapd',
            id: 's',
            type: SnapType.snapd,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'core24',
            id: 'b',
            type: SnapType.base,
            defaultChannel: 'stable'),
      ]);
      expect(ordered.map((s) => s.name).toList(),
          ['snapd', 'core24', 'aa-kernel', 'zz-gadget']);
    });

    test('app order is preserved (no alphabetical sort)', () {
      final ordered = AssertionBuilder.orderedSnaps([
        SnapEntry(
            name: 'zeta-app',
            id: 'z',
            type: SnapType.app,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'alpha-app',
            id: 'a',
            type: SnapType.app,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'pc-kernel',
            id: 'k',
            type: SnapType.kernel,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'pc',
            id: 'g',
            type: SnapType.gadget,
            defaultChannel: 'stable'),
      ]);
      expect(ordered.map((s) => s.name).toList(),
          ['pc-kernel', 'pc', 'zeta-app', 'alpha-app']);
    });

    test('same-type infrastructure snaps sort alphabetically', () {
      final ordered = AssertionBuilder.orderedSnaps([
        SnapEntry(
            name: 'core24',
            id: 'b2',
            type: SnapType.base,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'core22',
            id: 'b1',
            type: SnapType.base,
            defaultChannel: 'stable'),
        SnapEntry(
            name: 'pc',
            id: 'g',
            type: SnapType.gadget,
            defaultChannel: 'stable'),
      ]);
      expect(ordered.map((s) => s.name).toList(), ['core22', 'core24', 'pc']);
    });
  });

  group('timestamp', () {
    test('is RFC3339 UTC with Z suffix and no fractional seconds', () {
      final ts = AssertionBuilder.buildHeader(validModel())['timestamp']
          as String;
      expect(ts, endsWith('Z'));
      expect(ts, isNot(contains('.')));
      expect(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(ts),
          isTrue,
          reason: 'unexpected timestamp format: $ts');
    });
  });
}
