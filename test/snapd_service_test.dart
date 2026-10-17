import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:ubuntu_core_model_builder/services/snapd_service.dart';

/// Builds an HTTP/1.1 response with a Content-Length body.
String clResponse(String body) {
  final bytes = utf8.encode(body);
  return 'HTTP/1.1 200 OK\r\n'
      'Content-Type: application/json\r\n'
      'Content-Length: ${bytes.length}\r\n'
      'Connection: close\r\n\r\n'
      '$body';
}

/// Builds an HTTP/1.1 chunked response, splitting [body] into two chunks so
/// the dechunking path is exercised.
String chunkedResponse(String body) {
  final bytes = utf8.encode(body);
  final mid = bytes.length ~/ 2;

  List<int> hexSize(int n) {
    const digits = '0123456789abcdef';
    if (n == 0) return const [48]; // '0'
    var v = n;
    var s = '';
    while (v > 0) {
      s = digits[v % 16] + s;
      v = v ~/ 16;
    }
    return s.codeUnits;
  }

  List<int> chunk(List<int> piece) =>
      <int>[...hexSize(piece.length), 13, 10, ...piece, 13, 10];

  final head = utf8.encode('HTTP/1.1 200 OK\r\n'
      'Transfer-Encoding: chunked\r\n'
      'Connection: close\r\n\r\n');
  final tail = utf8.encode('0\r\n\r\n');
  final out = <int>[
    ...head,
    ...chunk(bytes.sublist(0, mid)),
    ...chunk(bytes.sublist(mid)),
    ...tail,
  ];
  return String.fromCharCodes(out);
}

/// A mock snapd server on a temp unix socket. For each request it reads the
/// request line and hands it to [responder], which returns the raw HTTP
/// response (headers + body). The connection is closed after the response so
/// the client's byte-read loop terminates.
class _MockSnapd {
  late ServerSocket _server;
  late Directory _dir;
  final List<String> requestLines = [];
  final FutureOr<String> Function(String requestLine) _responder;

  _MockSnapd(this._responder);

  Future<void> start() async {
    _dir = Directory.systemTemp.createTempSync('snapd_mock.');
    final path = '${_dir.path}/snapd.sock';
    _server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix), 0);
    _path = path;
    _server.listen((socket) {
      final buf = BytesBuilder();
      socket.listen((data) async {
        buf.add(data);
        final text = utf8.decode(buf.toBytes(), allowMalformed: true);
        if (!text.contains('\r\n\r\n')) return; // wait for full headers
        final requestLine = text.split('\r\n').first;
        requestLines.add(requestLine);
        final response = await _responder(requestLine);
        socket.write(response);
        await socket.flush();
        socket.destroy();
      });
    });
  }

  late String _path;
  String get socketPath => _path;

  Future<void> stop() async {
    await _server.close();
    if (_dir.existsSync()) _dir.deleteSync(recursive: true);
  }
}

void main() {
  late _MockSnapd mock;
  late SnapdService svc;

  tearDown(() async {
    await mock.stop();
  });

  /// The single-snap object (as it appears inside a `result` list).
  const String singleSnap =
      '{"name":"my-snap","id":"abc123","title":"My Snap","type":"app",'
      '"channels":{"latest/stable":{},"24/stable":{},"24/edge":{},'
      '"edge/stable":{},"stable":{}}}';

  /// The full `/v2/find` response body for a single snap.
  const String findResult = '{"result":[$singleSnap]}';

  group('SnapdService.getSnapInfo', () {
    test('parses the snap and sorts its channels', () async {
      mock = _MockSnapd((req) async => clResponse(findResult));
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      final snap = await svc.getSnapInfo('my-snap');
      expect(snap.name, 'my-snap');
      expect(snap.snapId, 'abc123');
      expect(snap.title, 'My Snap');
      expect(snap.type, 'app');
      // latest first, then numeric track desc, then risk order; a bare risk
      // name is treated as the latest track.
      expect(snap.channels,
          ['latest/stable', 'stable', '24/stable', '24/edge', 'edge/stable']);
    });

    test('sends the encoded snap name on the wire', () async {
      mock = _MockSnapd((req) async => clResponse(findResult));
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      await svc.getSnapInfo('my snap');
      // Uri.encodeQueryComponent encodes a space as '+'.
      expect(mock.requestLines.single, contains('name=my+snap'));
    });

    test('throws when the snap is not found', () async {
      mock = _MockSnapd((req) async => clResponse('{"result":[]}'));
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      await expectLater(
        svc.getSnapInfo('missing'),
        throwsA(isA<Exception>().having(
            (e) => e.toString(), 'message', contains('not found'))),
      );
    });

    test('decodes a chunked-transfer response', () async {
      mock = _MockSnapd((req) async => chunkedResponse(findResult));
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      final snap = await svc.getSnapInfo('my-snap');
      expect(snap.name, 'my-snap');
      expect(snap.channels, isNotEmpty);
    });

    test('throws a FormatException on a malformed (header-less) response',
        () async {
      mock = _MockSnapd((req) async => 'no-headers-here');
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      await expectLater(
        svc.getSnapInfo('my-snap'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('SnapdService.findSnaps', () {
    test('returns [] for an empty/blank query without touching the socket',
        () async {
      mock = _MockSnapd((req) async => clResponse('{}'));
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      expect(await svc.findSnaps(''), isEmpty);
      expect(await svc.findSnaps('   '), isEmpty);
      // No request was made for the empty queries.
      expect(mock.requestLines, isEmpty);
    });

    test('merges exact-name and query results, deduplicating by name',
        () async {
      // Exact lookup (?name=) returns A and B; fuzzy (?q=) returns B and C.
      const exact =
          '{"result":[{"name":"a","id":"1"},{"name":"b","id":"2"}]}';
      const query =
          '{"result":[{"name":"b","id":"2"},{"name":"c","id":"3"}]}';
      mock = _MockSnapd((req) async {
        if (req.contains('?name=')) return clResponse(exact);
        return clResponse(query);
      });
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      final snaps = await svc.findSnaps('a b c');
      final names = snaps.map((s) => s.name).toList();
      // b appears once despite being in both responses.
      expect(names, ['a', 'b', 'c']);
    });

    test('tolerates a failing lookup and returns the other results',
        () async {
      // Exact lookup fails (malformed); fuzzy returns a result.
      const query = '{"result":[{"name":"ok","id":"1"}]}';
      mock = _MockSnapd((req) async {
        if (req.contains('?name=')) return 'malformed';
        return clResponse(query);
      });
      await mock.start();
      svc = SnapdService(socketPath: mock.socketPath);

      final snaps = await svc.findSnaps('ok');
      expect(snaps.map((s) => s.name).toList(), ['ok']);
    });
  });
}
