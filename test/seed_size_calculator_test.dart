import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ubuntu_core_model_builder/models/model_assertion.dart';
import 'package:ubuntu_core_model_builder/models/snap_entry.dart';
import 'package:ubuntu_core_model_builder/services/seed_size_calculator.dart';
import 'package:ubuntu_core_model_builder/services/store_api_service.dart';

const _ct = {'content-type': 'application/json'};

/// A StoreApiService backed by a MockClient. [size] is the download size for
/// a channel named `24/stable` / amd64; [components] are the component
/// resources for that channel. Other channels/architectures resolve to null.
StoreApiService seedStore({
  int? size,
  List<Map<String, dynamic>>? components,
}) {
  final downloadBody = {
    'channel-map': [
      {
        'channel': {
          'architecture': 'amd64',
          'track': '24',
          'risk': 'stable',
          'name': '24/stable',
        },
        'download': {'size': size},
      },
    ],
  };
  final resourcesBody = {
    'channel-map': [
      {
        'channel': {
          'architecture': 'amd64',
          'track': '24',
          'risk': 'stable',
          'name': '24/stable',
        },
        'resources': components ?? const [],
      },
    ],
  };
  return StoreApiService(
    client: MockClient((req) async {
      final fields = req.url.queryParameters['fields'] ?? '';
      if (fields.contains('download')) {
        return http.Response(jsonEncode(downloadBody), 200, headers: _ct);
      }
      if (fields.contains('resources')) {
        return http.Response(jsonEncode(resourcesBody), 200, headers: _ct);
      }
      return http.Response('{}', 404);
    }),
  );
}

ModelAssertion modelWith(List<SnapEntry> snaps) => ModelAssertion()
  ..architecture = ModelArchitecture.amd64
  ..snaps = snaps;

SnapEntry app(String name,
        {String channel = '24/stable', Map<String, String> components = const {}}) =>
    SnapEntry(
        name: name,
        id: 'x' * 32,
        type: SnapType.app,
        defaultChannel: channel,
        components: components);

void main() {
  group('SeedSizeCalculator.formatBytes', () {
    const mib = 1024 * 1024;
    const gib = 1024 * 1024 * 1024;

    test('formats below 1 MiB as MiB', () {
      expect(SeedSizeCalculator.formatBytes(512 * 1024), '0.5 MiB');
    });

    test('formats the MiB range with one decimal', () {
      expect(SeedSizeCalculator.formatBytes(150 * mib), '150.0 MiB');
      expect(SeedSizeCalculator.formatBytes(2 * mib + 512 * 1024), '2.5 MiB');
    });

    test('switches to GiB at 1 GiB with two decimals', () {
      expect(SeedSizeCalculator.formatBytes(gib), '1.00 GiB');
      expect(SeedSizeCalculator.formatBytes(2560 * mib), '2.50 GiB');
      expect(SeedSizeCalculator.formatBytes(3 * gib + 512 * mib), '3.50 GiB');
    });
  });

  group('SeedSizeCalculator.calculate', () {
    test('sums resolved snap sizes in model order with no warnings', () async {
      final store = seedStore(size: 1000);
      final calc = SeedSizeCalculator(store: store);
      final m = modelWith([
        app('a'),
        app('b'),
      ]);
      final result = await calc.calculate(m);
      expect(result.totalBytes, 2000);
      expect(result.lines.map((l) => l.label).toList(), ['a', 'b']);
      expect(result.warnings, isEmpty);
    });

    test('adds resolved component sizes as "snap / component" lines',
        () async {
      final store = seedStore(
        size: 1000,
        components: [
          {
            'name': 'comp-a',
            'type': 'component/kernel-modules',
            'download': {'size': 500},
          },
        ],
      );
      final calc = SeedSizeCalculator(store: store);
      final m = modelWith([
        app('b', components: {'comp-a': 'required'}),
      ]);
      final result = await calc.calculate(m);
      // Snap line (1000) then component line (500); total 1500.
      expect(result.totalBytes, 1500);
      expect(result.lines.map((l) => l.label).toList(), ['b', 'b / comp-a']);
      expect(result.warnings, isEmpty);
    });

    test('warns and zero-fills a snap whose size cannot be resolved',
        () async {
      final store = seedStore(size: 1000);
      final calc = SeedSizeCalculator(store: store);
      final m = modelWith([
        app('known'), // 24/stable -> resolves
        app('unknown', channel: 'edge/stable'), // no match -> null
      ]);
      final result = await calc.calculate(m);
      expect(result.totalBytes, 1000);
      expect(result.lines.map((l) => l.label).toList(),
          ['known', 'unknown (size unknown)']);
      expect(result.warnings, contains('unknown'));
    });

    test('warns about an unresolvable component but keeps the snap size',
        () async {
      final store = seedStore(size: 1000); // no components offered
      final calc = SeedSizeCalculator(store: store);
      final m = modelWith([
        app('b', components: {'missing-comp': 'required'}),
      ]);
      final result = await calc.calculate(m);
      expect(result.totalBytes, 1000); // only the snap size
      expect(result.lines.map((l) => l.label).toList(),
          ['b', 'b / missing-comp (size unknown)']);
      expect(result.warnings, contains('missing-comp (component of b)'));
    });

    test('scopes a brand store to the lookups', () async {
      final store = seedStore(size: 777);
      final calc = SeedSizeCalculator(store: store);
      final m = modelWith([app('a')])..store = 'my-brand';
      final result = await calc.calculate(m);
      expect(result.totalBytes, 777);
    });
  });
}
