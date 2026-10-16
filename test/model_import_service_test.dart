import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/services/model_import_service.dart';
import 'package:ubuntu_core_model_builder/services/store_api_service.dart';

const _ct = {'content-type': 'application/json'};

/// A StoreApiService that resolves an app's base for a given channel and
/// returns snap info with the given base. Used to exercise reResolveAppBase.
StoreApiService importStore({
  Map<String, String>? baseForChannel,
  String? infoBase,
}) {
  return StoreApiService(
    client: MockClient((req) async {
      final fields = req.url.queryParameters['fields'] ?? '';
      if (fields.contains('base') && fields.contains('revision')) {
        // getBaseForChannel / getChannelsWithBases shape.
        final cm = <Map<String, dynamic>>[
          for (final e in (baseForChannel ?? const {}).entries)
            {
              'channel': {
                'architecture': 'amd64',
                'track': e.key.split('/')[0],
                'risk': e.key.split('/')[1],
                'name': e.key,
              },
              'base': e.value,
            },
        ];
        return http.Response(
            jsonEncode({'channel-map': cm}), 200, headers: _ct);
      }
      // getSnapInfo fallback.
      return http.Response(
          jsonEncode({'name': 'x', 'snap': {}, 'channel-map': [], 'base': infoBase}),
          200,
          headers: _ct);
    }),
  );
}

Map<String, dynamic> validJsonModel() => {
      'type': 'model',
      'authority-id': 'abc123',
      'brand-id': 'abc123',
      'series': '16',
      'model': 'my-device',
      'architecture': 'amd64',
      'base': 'core24',
      'grade': 'signed',
      'snaps': [
        {
          'name': 'snapd',
          'id': 's' * 32,
          'type': 'snapd',
          'default-channel': 'stable',
        },
        {
          'name': 'core24',
          'id': 'b' * 32,
          'type': 'base',
          'default-channel': 'stable',
        },
        {
          'name': 'pc-kernel',
          'id': 'k' * 32,
          'type': 'kernel',
          'default-channel': '24/stable',
          'components': {
            'pc-kernel-generic': {'presence': 'required'},
          },
        },
        {
          'name': 'pc',
          'id': 'g' * 32,
          'type': 'gadget',
          'default-channel': '24/stable',
        },
        {
          'name': 'my-app',
          'id': 'a' * 32,
          'type': 'app',
          'default-channel': '24/stable',
          'presence': 'required',
        },
      ],
    };

/// A minimal signed .model assertion text (flat header + signature).
String validModelFile() => [
      'type: model',
      'authority-id: abc123',
      'brand-id: abc123',
      'series: 16',
      'model: my-device',
      'architecture: amd64',
      'base: core24',
      'grade: signed',
      'sign-key-sha3-384: a1b2c3d4',
      'snaps:',
      '  -',
      '    name: snapd',
      '    id: s${'s' * 31}',
      '    type: snapd',
      '    default-channel: stable',
      '  -',
      '    name: core24',
      '    id: ${'b' * 32}',
      '    type: base',
      '    default-channel: stable',
      '  -',
      '    name: pc-kernel',
      '    id: ${'k' * 32}',
      '    type: kernel',
      '    default-channel: 24/stable',
      '    components:',
      '      pc-kernel-generic:',
      '        presence: required',
      '  -',
      '    name: pc',
      '    id: ${'g' * 32}',
      '    type: gadget',
      '    default-channel: 24/stable',
      '  -',
      '    name: my-app',
      '    id: ${'a' * 32}',
      '    type: app',
      '    default-channel: 24/stable',
      '    presence: required',
      '',
      'MEUCIQDx3Jp2oQnL5k9mR7vT1wZ4yU6aB8cE0fGhIjKlMnOpQIg',
    ].join('\n');

void main() {
  late Directory tmp;
  late File file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('import_test.');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<ImportResult> importText(String content,
      {bool reResolve = true, StoreApiService? store}) async {
    file = File('${tmp.path}/model.json')
      ..writeAsStringSync(content);
    return ModelImportService(
        store: store ?? importStore())
        .importFromFile(file.path, reResolveAppBase: reResolve);
  }

  group('ModelImportException', () {
    test('toString returns the message', () {
      expect(ModelImportException('bad').toString(), 'bad');
    });
  });

  group('JSON import', () {
    test('parses headers and snaps', () async {
      final r = await importText(jsonEncode(validJsonModel()), reResolve: false);
      final m = r.model;
      expect(m.type, 'model');
      expect(m.authorityId, 'abc123');
      expect(m.brandId, 'abc123');
      expect(m.series, '16');
      expect(m.model, 'my-device');
      expect(m.architecture, ModelArchitecture.amd64);
      expect(m.base, 'core24');
      expect(m.grade, ModelGrade.signed);
      expect(r.importedBrandId, 'abc123');
      expect(m.snaps, hasLength(5));
    });

    test('maps snap types and presence', () async {
      final r =
          await importText(jsonEncode(validJsonModel()), reResolve: false);
      final byName = {for (final s in r.model.snaps) s.name: s};
      expect(byName['snapd']!.type, SnapType.snapd);
      expect(byName['core24']!.type, SnapType.base);
      expect(byName['pc-kernel']!.type, SnapType.kernel);
      expect(byName['pc']!.type, SnapType.gadget);
      expect(byName['my-app']!.type, SnapType.app);
      expect(byName['my-app']!.presence, SnapPresence.required_);
      // default-channel preserved.
      expect(byName['pc-kernel']!.defaultChannel, '24/stable');
    });

    test('parses nested components into the snap entry', () async {
      final r =
          await importText(jsonEncode(validJsonModel()), reResolve: false);
      final kernel =
          r.model.snaps.firstWhere((s) => s.name == 'pc-kernel');
      expect(kernel.components, {'pc-kernel-generic': 'required'});
    });

    test('marks a non-primary base snap as dependent (autoAdded)', () async {
      final json = validJsonModel();
      json['snaps'].add({
        'name': 'core22',
        'id': 'c' * 32,
        'type': 'base',
        'default-channel': 'stable',
      });
      final r = await importText(jsonEncode(json), reResolve: false);
      final core22 = r.model.snaps.firstWhere((s) => s.name == 'core22');
      expect(core22.autoAdded, isTrue);
      // The primary base (core24 == model.base) is not auto-added.
      final core24 = r.model.snaps.firstWhere((s) => s.name == 'core24');
      expect(core24.autoAdded, isFalse);
    });

    test('throws on a classic model', () async {
      final json = validJsonModel()..['classic'] = 'true';
      await expectLater(
        importText(jsonEncode(json), reResolve: false),
        throwsA(isA<ModelImportException>().having(
            (e) => e.message, 'message', contains('classic'))),
      );
    });

    test('throws on a legacy top-level kernel/gadget model', () async {
      final json = validJsonModel()
        ..['kernel'] = 'pc-kernel'
        ..['gadget'] = 'pc';
      await expectLater(
        importText(jsonEncode(json), reResolve: false),
        throwsA(isA<ModelImportException>().having(
            (e) => e.message, 'message', contains('legacy'))),
      );
    });

    test('throws when there is no grade and no base', () async {
      final json = validJsonModel()
        ..remove('grade')
        ..remove('base');
      await expectLater(
        importText(jsonEncode(json), reResolve: false),
        throwsA(isA<ModelImportException>().having(
            (e) => e.message,
            'message',
            contains('not a grade-based'))),
      );
    });

    test('throws when the JSON is not a model object', () async {
      // A JSON object that has no model structure: the `is! Map` guard does
      // not fire (it IS a map) but it has no grade/base -> rejected.
      // Use an array to hit the actual "not a model object" guard by
      // wrapping it so the content starts with '{'.
      await expectLater(
        importText(jsonEncode({'snaps': []}), reResolve: false),
        throwsA(isA<ModelImportException>().having(
            (e) => e.message, 'message', contains('not a grade-based'))),
      );
      // A genuine non-object JSON body (a bare array) is routed to the
      // .model parser and rejected there.
      await expectLater(
        importText('[1, 2, 3]', reResolve: false),
        throwsA(isA<ModelImportException>()
            .having((e) => e.message, 'message', contains('Not a valid model'))),
      );
    });

    test('warns and defaults an unknown architecture', () async {
      final json = validJsonModel()..['architecture'] = 'mips64';
      final r = await importText(jsonEncode(json), reResolve: false);
      expect(r.model.architecture, ModelArchitecture.amd64);
      expect(r.warnings, anyElement(contains('mips64')));
    });

    test('warns and defaults an unknown grade', () async {
      final json = validJsonModel()..['grade'] = 'weird';
      final r = await importText(jsonEncode(json), reResolve: false);
      expect(r.model.grade, ModelGrade.signed);
      expect(r.warnings, anyElement(contains('weird')));
    });

    test('applies system-user-authority from JSON (list)', () async {
      final json = validJsonModel()
        ..['system-user-authority'] = ['acct-a', 'acct-b'];
      final r = await importText(jsonEncode(json), reResolve: false);
      expect(
          r.model.systemUserAuthorityMode, SystemUserAuthorityMode.specificIds);
      expect(r.model.systemUserAuthorityIds, ['acct-a', 'acct-b']);
    });

    test('applies system-user-authority from JSON (star means anyone)',
        () async {
      final json = validJsonModel()..['system-user-authority'] = '*';
      final r = await importText(jsonEncode(json), reResolve: false);
      expect(r.model.systemUserAuthorityMode, SystemUserAuthorityMode.anyone);
    });

    test('applies validation-sets and serial-authority from JSON', () async {
      final json = validJsonModel()
        ..['validation-sets'] = [
          {
            'account-id': 'other',
            'name': 'vset-1',
            'mode': 'prefer-enforce',
            'sequence': 3,
          },
          {
            'name': 'vset-2',
            'mode': 'enforce',
          },
        ]
        ..['serial-authority'] = ['serial-acct'];
      final r = await importText(jsonEncode(json), reResolve: false);
      expect(r.model.validationSets, hasLength(2));
      // account-id omitted -> filled from brand-id.
      expect(r.model.validationSets[1].accountId, 'abc123');
      expect(r.model.validationSets[0].sequence, 3);
      expect(r.model.serialAuthorityIds, ['serial-acct']);
    });

    test('applies storage-safety from JSON', () async {
      final json = validJsonModel()..['storage-safety'] = 'encrypted';
      final r = await importText(jsonEncode(json), reResolve: false);
      expect(r.model.storageSafety, StorageSafety.encrypted);
    });

    test('resolves app base when reResolveAppBase is true', () async {
      final store = importStore(baseForChannel: {'24/stable': 'core24'});
      final r = await importText(jsonEncode(validJsonModel()),
          reResolve: true, store: store);
      final app = r.model.snaps.firstWhere((s) => s.name == 'my-app');
      expect(app.appBase, 'core24');
      expect(r.warnings, isEmpty);
    });

    test('does not resolve app base when reResolveAppBase is false',
        () async {
      final r =
          await importText(jsonEncode(validJsonModel()), reResolve: false);
      final app = r.model.snaps.firstWhere((s) => s.name == 'my-app');
      expect(app.appBase, isNull);
    });
  });

  group('.model import', () {
    test('parses a signed model file', () async {
      final r = await importText(validModelFile(), reResolve: false);
      final m = r.model;
      expect(m.model, 'my-device');
      expect(m.base, 'core24');
      expect(m.grade, ModelGrade.signed);
      expect(r.importedBrandId, 'abc123');
      expect(m.snaps, hasLength(5));
    });

    test('parses nested components from a signed model', () async {
      final r = await importText(validModelFile(), reResolve: false);
      final kernel = r.model.snaps.firstWhere((s) => s.name == 'pc-kernel');
      expect(kernel.components, {'pc-kernel-generic': 'required'});
    });

    test('parses system-user-authority from a signed model', () async {
      final text = validModelFile().replaceFirst(
          'sign-key-sha3-384: a1b2c3d4',
          'system-user-authority:\n  - acct-a\n  - acct-b\nsign-key-sha3-384: a1b2c3d4');
      final r = await importText(text, reResolve: false);
      expect(
          r.model.systemUserAuthorityMode, SystemUserAuthorityMode.specificIds);
      expect(r.model.systemUserAuthorityIds, ['acct-a', 'acct-b']);
    });

    test('throws when the file is a non-model assertion', () async {
      final text = [
        'type: serial',
        'authority-id: abc123',
        '',
        'MEUCIQDx3Jp2oQnL5k9mR7vT1wZ4yU6aB8cE0fGhIjKlMnOpQIg',
      ].join('\n');
      await expectLater(
        importText(text, reResolve: false),
        throwsA(isA<ModelImportException>().having(
            (e) => e.message, 'message', contains('not a model'))),
      );
    });

    test('throws when the file is not a valid assertion', () async {
      // No signature block -> parser throws, wrapped by ModelImportException.
      await expectLater(
        importText('this is not an assertion at all', reResolve: false),
        throwsA(isA<ModelImportException>().having(
            (e) => e.message,
            'message',
            allOf(
                contains('Not a valid model file'),
                contains('no signature block')))),
      );
    });
  });
}
