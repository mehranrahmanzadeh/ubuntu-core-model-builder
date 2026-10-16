import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:ubuntu_core_model_builder/models/store_snap.dart';
import 'package:ubuntu_core_model_builder/services/store_api_service.dart';

/// Builds a [StoreApiService] backed by a [MockClient] that returns
/// [body] (JSON) with [status], and records the last request in [last].
StoreApiService mockService(
  Map<String, dynamic> body,
  void Function() capture, {
  int status = 200,
  void Function(http.Request)? inspect,
}) {
  return StoreApiService(
    client: MockClient((request) async {
      capture();
      inspect?.call(request);
      if (status != 200) {
        return http.Response('error body', status);
      }
      return http.Response(jsonEncode(body), 200,
            headers: {'content-type': 'application/json'});
    }),
  );
}

void main() {
  group('StoreSnap.fromSnapdJson', () {
    test('reads name, id, title, summary, type, base', () {
      final s = StoreSnap.fromSnapdJson({
        'name': 'my-snap',
        'id': 'abc123',
        'title': 'My Snap',
        'summary': 'A summary',
        'type': 'base',
        'base': 'core24',
      });
      expect(s.name, 'my-snap');
      expect(s.snapId, 'abc123');
      expect(s.title, 'My Snap');
      expect(s.summary, 'A summary');
      expect(s.type, 'base');
      expect(s.base, 'core24');
    });

    test('falls back to snap-id when id is missing', () {
      final s = StoreSnap.fromSnapdJson({
        'name': 'my-snap',
        'snap-id': 'snapId42',
        'title': 'T',
      });
      expect(s.snapId, 'snapId42');
    });

    test('tolerates missing optional fields', () {
      final s = StoreSnap.fromSnapdJson({'name': 'x', 'id': 'y'});
      expect(s.title, isNull);
      expect(s.summary, isNull);
      expect(s.type, isNull);
      expect(s.base, isNull);
      expect(s.channels, isEmpty);
    });
  });

  group('sortChannels', () {
    test('orders latest first, then numeric tracks descending, then risk',
        () {
      final sorted = StoreApiService.sortChannels([
        '24/candidate',
        'latest/stable',
        '24/stable',
        'edge/stable',
        'latest/edge',
        '2/stable',
      ]);
      expect(sorted, [
        'latest/stable',
        'latest/edge',
        '24/stable',
        '24/candidate',
        '2/stable',
        'edge/stable',
      ]);
    });

    test('treats a bare risk name as the latest track', () {
      expect(StoreApiService.sortChannels(['candidate', 'stable']),
          ['stable', 'candidate']);
    });

    test('does not mutate the input list', () {
      final input = ['2/stable', 'latest/stable'];
      final copy = List.of(input);
      StoreApiService.sortChannels(input);
      expect(input, copy);
    });
  });

  group('headers', () {
    test('always sets the device architecture and series', () async {
      http.Request? last;
      final svc = mockService({'results': []}, () {},
          inspect: (r) => last = r);
      await svc.findSnaps('q', 'amd64');
      expect(last!.headers['Snap-Device-Architecture'], 'amd64');
      expect(last!.headers['Snap-Device-Series'], '16');
    });

    test('sets Snap-Device-Store only for a non-global brand store',
        () async {
      final captured = <http.Request>[];
      final rec = StoreApiService(
        client: MockClient((r) async {
          captured.add(r);
          return http.Response(jsonEncode({'results': []}), 200,
            headers: {'content-type': 'application/json'});
        }),
      );

      await rec.findSnaps('q', 'amd64', storeId: 'my-brand');
      await rec.findSnaps('q', 'amd64'); // no store
      await rec.findSnaps('q', 'amd64', storeId: 'ubuntu'); // global

      expect(captured[0].headers['Snap-Device-Store'], 'my-brand');
      expect(captured[1].headers['Snap-Device-Store'], isNull);
      expect(captured[2].headers['Snap-Device-Store'], isNull);
    });
  });

  group('findSnaps', () {
    test('parses results and resolves fields from snap/revision', () async {
      final svc = mockService({
        'results': [
          {
            'name': 'my-snap',
            'snap-id': 'id1',
            'snap': {
              'title': 'My Snap',
              'summary': 'A snap',
              'type': 'app',
              'snap-id': 'id1',
            },
            'revision': {'type': 'app'},
          },
          {
            'name': 'other',
            'snap-id': 'id2',
            'snap': {'title': 'Other'},
            'revision': {'type': 'base'},
          },
          {
            'snap': {
              'name': 'noTopName',
              'snap-id': 'id3',
              'title': 'FromSnap',
            },
            'revision': {},
          },
        ],
      }, () {});

      final out = await svc.findSnaps('my-snap', 'amd64');
      expect(out, hasLength(3));

      expect(out[0].name, 'my-snap');
      expect(out[0].snapId, 'id1');
      expect(out[0].title, 'My Snap');
      expect(out[0].type, 'app');

      expect(out[1].name, 'other');
      expect(out[1].type, 'base');

      // Name resolved from the nested snap object.
      expect(out[2].name, 'noTopName');
      expect(out[2].snapId, 'id3');
      expect(out[2].title, 'FromSnap');
      expect(out[2].type, isNull);
    });

    test('skips entries with an empty name', () async {
      final svc = mockService({
        'results': [
          {'name': '', 'snap-id': 'x'},
          {'name': 'kept', 'snap-id': 'y'},
        ],
      }, () {});
      final out = await svc.findSnaps('q', 'amd64');
      expect(out, hasLength(1));
      expect(out.single.name, 'kept');
    });

    test('encodes the query in the URL', () async {
      http.Request? last;
      final svc = mockService({'results': []}, () {},
          inspect: (r) => last = r);
      await svc.findSnaps('my query', 'amd64');
      expect(last!.url.queryParameters['q'], 'my query');
      expect(last!.url.path, endsWith('/snaps/find'));
    });

    test('throws on a non-200 response', () async {
      final svc = mockService({}, () {}, status: 500);
      await expectLater(
        svc.findSnaps('q', 'amd64'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('500'))),
      );
    });
  });

  group('getSnapInfo', () {
    Map<String, dynamic> info({
      String? type,
      List<Map<String, dynamic>>? channelMap,
    }) {
      return {
        'name': 'my-snap',
        'snap': {
          'snap-id': 'id1',
          'title': 'My Snap',
          'summary': 'sum',
          if (type != null) 'type': type,
        },
        'channel-map': channelMap ??
            [
              {
                'channel': {
                  'architecture': 'amd64',
                  'track': 'latest',
                  'risk': 'stable',
                  'name': 'latest/stable',
                },
                'base': 'core24',
                'type': 'base',
              },
            ],
      };
    }

    test('resolves base, type and sorted channels', () async {
      final svc = mockService(info(
        type: 'base',
        channelMap: [
          {
            'channel': {
              'architecture': 'amd64',
              'track': 'latest',
              'risk': 'stable',
              'name': 'latest/stable',
            },
            'base': 'core24',
            'type': 'base',
          },
          {
            'channel': {
              'architecture': 'amd64',
              'track': '24',
              'risk': 'stable',
              'name': '24/stable',
            },
            'base': 'core24',
          },
          {
            'channel': {
              'architecture': 'arm64',
              'track': 'latest',
              'risk': 'stable',
              'name': 'latest/stable',
            },
            'base': 'core24',
            'type': 'base',
          },
        ],
      ), () {});

      final s = await svc.getSnapInfo('my-snap', 'amd64');
      expect(s.name, 'my-snap');
      expect(s.snapId, 'id1');
      expect(s.title, 'My Snap');
      expect(s.type, 'base');
      expect(s.base, 'core24');
      // Only amd64 channels, sorted: latest first then numeric track.
      expect(s.channels, ['latest/stable', '24/stable']);
    });

    test('ignores channels for other architectures', () async {
      final svc = mockService(info(
        channelMap: [
          {
            'channel': {
              'architecture': 'amd64',
              'track': 'latest',
              'risk': 'stable',
              'name': 'latest/stable',
            },
            'base': 'core24',
          },
          {
            'channel': {
              'architecture': 'arm64',
              'track': '22',
              'risk': 'stable',
              'name': '22/stable',
            },
            'base': 'core22',
          },
        ],
      ), () {});
      final s = await svc.getSnapInfo('my-snap', 'amd64');
      expect(s.channels, ['latest/stable']);
    });

    test('defaults base to core for an app snap with no base', () async {
      final svc = mockService(info(
        type: 'app',
        channelMap: [
          {
            'channel': {
              'architecture': 'amd64',
              'track': 'latest',
              'risk': 'stable',
              'name': 'latest/stable',
            },
          },
        ],
      ), () {});
      final s = await svc.getSnapInfo('my-snap', 'amd64');
      expect(s.type, 'app');
      // No base in the channel-map for an app snap -> default 'core'.
      expect(s.base, 'core');
    });

    test('resolves type from the channel-map when snap.type is absent',
        () async {
      final svc = mockService(info(
        channelMap: [
          {
            'channel': {
              'architecture': 'amd64',
              'track': 'latest',
              'risk': 'stable',
              'name': 'latest/stable',
            },
            'type': 'kernel',
          },
        ],
      ), () {});
      final s = await svc.getSnapInfo('my-snap', 'amd64');
      expect(s.type, 'kernel');
      // kernel snap with no base -> base stays null (no 'core' default).
      expect(s.base, isNull);
    });

    test('throws on a non-200 response', () async {
      final svc = mockService({}, () {}, status: 404);
      await expectLater(
        svc.getSnapInfo('missing', 'amd64'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('404'))),
      );
    });
  });

  group('getChannelsWithBases', () {
    const body = {
      'channel-map': [
        {
          'channel': {
            'architecture': 'amd64',
            'track': '24',
            'risk': 'stable',
            'name': '24/stable',
          },
          'base': 'core24',
        },
        {
          'channel': {
            'architecture': 'amd64',
            'track': 'latest',
            'risk': 'stable',
          },
          'base': 'core24',
        },
        {
          'channel': {
            'architecture': 'arm64',
            'track': 'latest',
            'risk': 'stable',
            'name': 'latest/stable',
          },
          'base': 'core22',
        },
      ],
    };

    test('returns canonical channels with bases, sorted', () async {
      final svc = mockService(body, () {});
      final result =
          await svc.getChannelsWithBases('my-snap', 'amd64');
      expect(result, [
        (channel: 'latest/stable', base: 'core24'),
        (channel: '24/stable', base: 'core24'),
      ]);
    });

    test('returns empty on a non-200 response', () async {
      final svc = mockService({}, () {}, status: 500);
      final result = await svc.getChannelsWithBases('my-snap', 'amd64');
      expect(result, isEmpty);
    });
  });

  group('getBaseForChannel', () {
    const body = {
      'channel-map': [
        {
          'channel': {
            'architecture': 'amd64',
            'track': 'latest',
            'risk': 'stable',
            'name': 'latest/stable',
          },
          'base': 'core24',
        },
        {
          'channel': {
            'architecture': 'amd64',
            'track': '24',
            'risk': 'stable',
            'name': '24/stable',
          },
          'base': 'core24',
        },
        {
          'channel': {
            'architecture': 'arm64',
            'track': 'latest',
            'risk': 'stable',
            'name': 'latest/stable',
          },
          'base': 'core22',
        },
      ],
    };

    test('matches the canonical track/risk form', () async {
      final svc = mockService(body, () {});
      expect(await svc.getBaseForChannel('s', 'amd64', 'latest/stable'),
          'core24');
      expect(await svc.getBaseForChannel('s', 'amd64', '24/stable'),
          'core24');
    });

    test('matches a bare risk name against the latest track', () async {
      final svc = mockService(body, () {});
      // 'stable' is the bare risk of latest/stable.
      expect(await svc.getBaseForChannel('s', 'amd64', 'stable'), 'core24');
    });

    test('respects the requested architecture', () async {
      final svc = mockService(body, () {});
      expect(await svc.getBaseForChannel('s', 'arm64', 'latest/stable'),
          'core22');
      // amd64 has no 'edge' channel.
      expect(await svc.getBaseForChannel('s', 'amd64', 'edge'), isNull);
    });

    test('returns null when the channel is unknown', () async {
      final svc = mockService(body, () {});
      expect(await svc.getBaseForChannel('s', 'amd64', 'no/such'), isNull);
    });
  });

  group('getComponentsForChannel', () {
    const body = {
      'channel-map': [
        {
          'channel': {
            'architecture': 'amd64',
            'track': 'latest',
            'risk': 'stable',
            'name': 'latest/stable',
          },
          'resources': [
            {
              'name': 'kernel-modules',
              'type': 'component/kernel-modules',
              'description': 'K mods',
            },
            {'name': 'standard', 'type': 'component/standard'},
            {'name': 'not-a-component', 'type': 'base'},
            {'name': 'dup', 'type': 'component/x'},
            {'name': 'dup', 'type': 'component/y'},
          ],
        },
      ],
    };

    test('returns only component/ resources, deduped and sorted', () async {
      final svc = mockService(body, () {});
      final comps =
          await svc.getComponentsForChannel('s', 'amd64', 'latest/stable');
      expect(comps.map((c) => c.name).toList(),
          ['dup', 'kernel-modules', 'standard']);
      final km = comps.firstWhere((c) => c.name == 'kernel-modules');
      expect(km.type, 'component/kernel-modules');
      expect(km.description, 'K mods');
    });

    test('returns empty when the channel does not match', () async {
      final svc = mockService(body, () {});
      final comps = await svc.getComponentsForChannel('s', 'amd64', 'edge');
      expect(comps, isEmpty);
    });

    test('returns empty on a non-200 response', () async {
      final svc = mockService({}, () {}, status: 500);
      final comps = await svc.getComponentsForChannel('s', 'amd64',
          'latest/stable');
      expect(comps, isEmpty);
    });
  });

  group('getDownloadSize', () {
    const body = {
      'channel-map': [
        {
          'channel': {
            'architecture': 'amd64',
            'track': 'latest',
            'risk': 'stable',
            'name': 'latest/stable',
          },
          'download': {'size': 12345},
        },
      ],
    };

    test('returns the size for a matching channel', () async {
      final svc = mockService(body, () {});
      expect(
          await svc.getDownloadSize('s', 'amd64', 'latest/stable'), 12345);
    });

    test('returns null when the channel does not match', () async {
      final svc = mockService(body, () {});
      expect(await svc.getDownloadSize('s', 'amd64', 'edge'), isNull);
    });

    test('returns null on a non-200 response', () async {
      final svc = mockService({}, () {}, status: 500);
      expect(
          await svc.getDownloadSize('s', 'amd64', 'latest/stable'), isNull);
    });
  });

  group('getComponentSizes', () {
    const body = {
      'channel-map': [
        {
          'channel': {
            'architecture': 'amd64',
            'track': 'latest',
            'risk': 'stable',
            'name': 'latest/stable',
          },
          'resources': [
            {
              'name': 'kernel-modules',
              'type': 'component/kernel-modules',
              'download': {'size': 100},
            },
            {
              'name': 'standard',
              'type': 'component/standard',
              'download': {'size': 200},
            },
            {
              'name': 'base-res',
              'type': 'base',
              'download': {'size': 999},
            },
            {'name': 'nosize', 'type': 'component/nosize'},
          ],
        },
      ],
    };

    test('maps component name to size, skipping non-components and missing',
        () async {
      final svc = mockService(body, () {});
      final sizes =
          await svc.getComponentSizes('s', 'amd64', 'latest/stable');
      expect(sizes, {
        'kernel-modules': 100,
        'standard': 200,
      });
    });

    test('returns empty on a non-200 response', () async {
      final svc = mockService({}, () {}, status: 500);
      final sizes =
          await svc.getComponentSizes('s', 'amd64', 'latest/stable');
      expect(sizes, isEmpty);
    });
  });
}

