import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/connection.dart';
import 'package:hermes_android/core/services/desktop_gateway_client.dart';
import 'package:hermes_android/core/services/ws_client.dart';

void main() {
  test('WsClient advertises and answers server initiated requests', () async {
    final gateway = await _ServerRequestGateway.start();
    addTearDown(gateway.stop);
    final requests = <GatewayServerRequest>[];
    final client = WsClient(
      'http://127.0.0.1:${gateway.port}',
      token: 'fixture-key',
      profile: 'work',
      heartbeatInterval: const Duration(hours: 1),
      heartbeatDeadline: const Duration(hours: 2),
    );
    client.onServerRequest = (request) {
      requests.add(request);
      request.respond({'value': 'answered'});
      return true;
    };
    addTearDown(client.close);

    await client.connect().timeout(const Duration(seconds: 5));
    await _waitFor(() => gateway.capabilityFrames.isNotEmpty);
    expect(gateway.capabilityFrames.single['params'], {
      'server_requests': true,
    });

    gateway.sendServerRequest(
      id: 'srq-live',
      method: 'secret',
      params: {
        'session_id': 'runtime-1',
        'env_var': 'TOKEN',
        'prompt': 'Token',
      },
    );
    await _waitFor(() => gateway.serverResponses.containsKey('srq-live'));

    expect(requests, hasLength(1));
    expect(requests.single.method, 'secret');
    expect(requests.single.replayed, isFalse);
    expect(gateway.serverResponses['srq-live'], {
      'jsonrpc': '2.0',
      'id': 'srq-live',
      'result': {'value': 'answered'},
    });
  });

  test(
    'WsClient rejects unhandled methods and can replay open requests',
    () async {
      final gateway = await _ServerRequestGateway.start();
      addTearDown(gateway.stop);
      final client = WsClient(
        'http://127.0.0.1:${gateway.port}',
        token: 'fixture-key',
        heartbeatInterval: const Duration(hours: 1),
        heartbeatDeadline: const Duration(hours: 2),
      );
      addTearDown(client.close);
      await client.connect().timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gateway.capabilityFrames, isEmpty);

      gateway.sendServerRequest(
        id: 'srq-unknown',
        method: 'preview.read',
        params: {'session_id': 'runtime-1'},
      );
      await _waitFor(() => gateway.serverResponses.containsKey('srq-unknown'));
      expect(
        gateway.serverResponses['srq-unknown']?['error'],
        containsPair('code', -32601),
      );

      GatewayServerRequest? replayed;
      client.onServerRequest = (request) {
        replayed = request;
        request.respond({'choice': 'deny'});
        return true;
      };
      client.deliverOpenRequests([
        {
          'id': 'srq-replayed',
          'method': 'approval',
          'params': {
            'session_id': 'runtime-1',
            'request_id': 'approval-1',
            'command': 'rm file',
          },
        },
      ]);
      await _waitFor(() => gateway.serverResponses.containsKey('srq-replayed'));
      expect(replayed?.replayed, isTrue);
      expect(gateway.serverResponses['srq-replayed']?['result'], {
        'choice': 'deny',
      });
    },
  );

  test(
    'Desktop bridge routes approval, secret and clarify responses',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
      );
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'server-request-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      final events = <StreamEvent>[];
      client.setAsyncEventListener((_, event) => events.add(event));
      await client.ensureSession('mobile-1');

      gateway.sendServerRequest(
        id: 'srq-approval',
        method: 'approval',
        params: {
          'session_id': 'runtime-1',
          'request_id': 'approval-queue-1',
          'command': 'rm file',
          'description': 'Delete a file',
          'choices': ['once', 'deny'],
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'approval.request'),
      );
      expect(
        events
            .lastWhere((event) => event.type == 'approval.request')
            .data['server_request_id'],
        'srq-approval',
      );
      await client.respondToApproval(sessionId: 'mobile-1', choice: 'deny');
      await _waitFor(() => gateway.serverResponses.containsKey('srq-approval'));
      expect(gateway.serverResponses['srq-approval']?['result'], {
        'choice': 'deny',
      });

      gateway.sendServerRequest(
        id: 'srq-secret',
        method: 'secret',
        params: {
          'session_id': 'runtime-1',
          'env_var': 'TOKEN',
          'prompt': 'Enter token',
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'secret.request'),
      );
      expect(
        events
            .lastWhere((event) => event.type == 'secret.request')
            .data['request_id'],
        'srq-secret',
      );
      await client.respondToSecret(requestId: 'srq-secret', value: 'value');
      await _waitFor(() => gateway.serverResponses.containsKey('srq-secret'));
      expect(gateway.serverResponses['srq-secret']?['result'], {
        'value': 'value',
      });

      gateway.sendServerRequest(
        id: 'srq-clarify',
        method: 'clarify',
        params: {
          'session_id': 'runtime-1',
          'questions': [
            {'qid': 'q1', 'question': 'Proceed?'},
          ],
        },
      );
      await _waitFor(
        () => events.any((event) => event.type == 'clarify.request'),
      );
      await client.respondToClarify(
        requestId: 'srq-clarify',
        questionId: 'q1',
        answer: 'Yes',
      );
      await _waitFor(() => gateway.clarifyLocks.isNotEmpty);
      expect(gateway.clarifyLocks.single, {
        'request_id': 'srq-clarify',
        'question_id': 'q1',
        'answer': 'Yes',
      });
    },
  );

  test(
    'Desktop bridge re-delivers open requests after session resume',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
        openRequestsOnResume: [
          {
            'id': 'srq-resumed-secret',
            'method': 'secret',
            'params': {
              'session_id': 'runtime-1',
              'env_var': 'TOKEN',
              'prompt': 'Enter token',
            },
          },
        ],
      );
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'server-request-replay-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      final events = <StreamEvent>[];
      client.setAsyncEventListener((_, event) => events.add(event));

      await client.ensureSession('stored-1');
      await _waitFor(
        () => events.any(
          (event) =>
              event.type == 'secret.request' &&
              event.data['request_id'] == 'srq-resumed-secret',
        ),
      );
      await client.respondToSecret(
        requestId: 'srq-resumed-secret',
        value: 'value',
      );
      await _waitFor(
        () => gateway.serverResponses.containsKey('srq-resumed-secret'),
      );
      expect(gateway.serverResponses['srq-resumed-secret']?['result'], {
        'value': 'value',
      });
    },
  );

  test(
    'Desktop bridge does not replay already locked clarify answers',
    () async {
      final gateway = await _ServerRequestGateway.start(
        withDashboardAuth: true,
        openRequestsOnResume: [
          {
            'id': 'srq-resumed-clarify',
            'method': 'clarify',
            'params': {
              'session_id': 'runtime-1',
              'questions': [
                {'qid': 'q1', 'question': 'Already answered?'},
                {'qid': 'q2', 'question': 'Still pending?'},
              ],
              'answers': {'q1': 'Yes'},
            },
          },
        ],
      );
      addTearDown(gateway.stop);
      final client = DesktopGatewayClient.fromConnection(
        SavedConnection(
          id: 'server-request-clarify-replay-test',
          label: 'Local fixture',
          host: 'localhost',
          port: gateway.port,
          apiKey: 'fixture-key',
          useHttps: false,
          desktopGatewayUrl: 'http://127.0.0.1:${gateway.port}',
          dashboardUsername: 'user',
          dashboardPassword: 'pass',
        ),
      );
      addTearDown(client.close);
      final events = <StreamEvent>[];
      client.setAsyncEventListener((_, event) => events.add(event));

      await client.ensureSession('stored-1');
      await _waitFor(
        () => events.any((event) => event.type == 'clarify.request'),
      );
      final event = events.lastWhere(
        (candidate) => candidate.type == 'clarify.request',
      );
      expect(event.data['questions'], [
        {'qid': 'q2', 'question': 'Still pending?'},
      ]);

      await client.respondToClarify(
        requestId: 'srq-resumed-clarify',
        questionId: 'q2',
        answer: 'No',
      );
      await _waitFor(() => gateway.clarifyLocks.isNotEmpty);
      expect(gateway.clarifyLocks.single, {
        'request_id': 'srq-resumed-clarify',
        'question_id': 'q2',
        'answer': 'No',
      });
    },
  );
}

Future<void> _waitFor(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _ServerRequestGateway {
  _ServerRequestGateway(
    this._server,
    this.withDashboardAuth,
    this.openRequestsOnResume,
  );

  final HttpServer _server;
  final bool withDashboardAuth;
  final List<Map<String, dynamic>>? openRequestsOnResume;
  final List<WebSocket> _sockets = [];
  final List<Map<String, dynamic>> capabilityFrames = [];
  final Map<String, Map<String, dynamic>> serverResponses = {};
  final List<Map<String, dynamic>> clarifyLocks = [];

  int get port => _server.port;

  static Future<_ServerRequestGateway> start({
    bool withDashboardAuth = false,
    List<Map<String, dynamic>>? openRequestsOnResume,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final gateway = _ServerRequestGateway(
      server,
      withDashboardAuth,
      openRequestsOnResume,
    );
    server.listen(gateway._handleHttp);
    return gateway;
  }

  Future<void> _handleHttp(HttpRequest request) async {
    if (withDashboardAuth &&
        request.method == 'POST' &&
        request.uri.path == '/auth/password-login') {
      request.response
        ..statusCode = 200
        ..headers.set('set-cookie', 'hermes_session_at=fixture; Path=/')
        ..write('{"ok":true}');
      await request.response.close();
      return;
    }
    if (withDashboardAuth &&
        request.method == 'POST' &&
        request.uri.path == '/api/auth/ws-ticket') {
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write('{"ticket":"fixture-ticket"}');
      await request.response.close();
      return;
    }
    if (request.uri.path != '/api/ws') {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    _sockets.add(socket);
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': {'type': 'gateway.ready', 'payload': {}},
      }),
    );
    socket.listen((raw) => _handleSocketFrame(socket, raw));
  }

  void _handleSocketFrame(WebSocket socket, dynamic raw) {
    final frame = Map<String, dynamic>.from(jsonDecode(raw as String) as Map);
    final method = frame['method'];
    final id = frame['id'];
    if (method == null && id is String) {
      serverResponses[id] = frame;
      return;
    }
    if (method == 'client.capabilities') {
      capabilityFrames.add(frame);
      _respond(socket, id, {
        'server_requests': ['clarify', 'approval', 'sudo', 'secret'],
      });
      return;
    }
    if (method == 'session.resume') {
      if (openRequestsOnResume != null) {
        _respond(socket, id, {
          'session_id': 'runtime-1',
          'open_requests': openRequestsOnResume,
        });
        return;
      }
      _error(socket, id, 4007, 'session not found');
      return;
    }
    if (method == 'session.create') {
      _respond(socket, id, {
        'session_id': 'runtime-1',
        'stored_session_id': 'stored-1',
      });
      return;
    }
    if (method == 'clarify.lock') {
      clarifyLocks.add(Map<String, dynamic>.from(frame['params'] as Map));
      _respond(socket, id, {'status': 'ok', 'remaining': <String>[]});
      return;
    }
    if (method == 'gateway.ping') {
      _respond(socket, id, {'ok': true});
      return;
    }
    _error(socket, id, -32601, 'unknown method');
  }

  void sendServerRequest({
    required String id,
    required String method,
    required Map<String, dynamic> params,
  }) {
    final socket = _sockets.single;
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
  }

  void _respond(WebSocket socket, dynamic id, Map<String, dynamic> result) {
    socket.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }

  void _error(WebSocket socket, dynamic id, int code, String message) {
    socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': code, 'message': message},
      }),
    );
  }

  Future<void> stop() async {
    for (final socket in _sockets) {
      await socket.close();
    }
    _sockets.clear();
    await _server.close(force: true);
  }
}
