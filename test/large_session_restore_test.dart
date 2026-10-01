import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voice_composer_adapter.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  testWidgets(
    'remote chat remains usable while bounded history hydration is pending',
    (tester) async {
      final httpClient = _DelayedMessagesHttpClient();
      addTearDown(httpClient.release);
      final apiClient = ApiClient(
        baseUrl: 'http://large-session.fixture',
        apiKey: 'fixture-key',
        httpClient: httpClient,
      );
      var submitted = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: ChatScreen(
            connection: SavedConnection(
              id: 'large-session-fixture',
              label: 'Large session fixture',
              host: 'large-session.fixture',
              port: 8642,
              apiKey: 'fixture-key',
            ),
            session: const Session(
              id: 'stored-large-session',
              title: 'Large chat',
              model: 'fixture-model',
              source: 'api_server',
              messageCount: 4261,
              isActive: true,
              preview: '',
              startedAt: 1,
            ),
            testApiClient: apiClient,
            testRemotePromptSubmit:
                ({
                  required sessionId,
                  required text,
                  required onEvent,
                  required onSent,
                }) async {
                  submitted += 1;
                  onSent();
                },
            testVoiceComposerAdapter: FakeVoiceComposerAdapter(),
          ),
        ),
      );
      await tester.pump();

      final messagesUri = await httpClient.messagesUri.future;
      expect(messagesUri.queryParameters, {'limit': '50', 'order': 'latest'});
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat-message-composer')))
            .enabled,
        isTrue,
      );
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.attach_file),
            )
            .onPressed,
        isNotNull,
      );

      await tester.enterText(
        find.byKey(const Key('chat-message-composer')),
        'Prompt while history is loading',
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await tester.pump();

      expect(submitted, 1);
      expect(find.text('Prompt while history is loading'), findsOneWidget);

      httpClient.release();
      await tester.pumpAndSettle();

      expect(find.text('Stale transcript row'), findsNothing);
      expect(find.text('Prompt while history is loading'), findsOneWidget);
    },
  );
}

class _DelayedMessagesHttpClient extends http.BaseClient {
  final Completer<Uri> messagesUri = Completer<Uri>();
  final Completer<void> _released = Completer<void>();

  void release() {
    if (!_released.isCompleted) _released.complete();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      if (!messagesUri.isCompleted) messagesUri.complete(request.url);
      await _released.future;
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode({
              'data': [
                {'role': 'assistant', 'content': 'Stale transcript row'},
              ],
            }),
          ),
        ),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode({'error': 'unexpected request'}))),
      404,
      headers: {'content-type': 'application/json'},
    );
  }
}
