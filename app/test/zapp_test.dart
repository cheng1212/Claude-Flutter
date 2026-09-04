import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/api.dart';
import 'package:zcode_app/state/reducer.dart';
import 'package:zcode_app/state/zapp.dart';
import 'package:zcode_app/ws.dart';

// ---------------------------------------------------------------- 假件

class FakeHttp {
  final calls = <({String method, String path, Object? body})>[];
  Object? Function(({String method, String path, Object? body}))? responder;

  HttpFn get fn => (method, path, body) async {
        final rec = (method: method, path: path, body: body);
        calls.add(rec);
        final r = responder?.call(rec);
        if (r is Exception) throw r;
        return r;
      };
}

class FakeChannel implements ZChannel {
  final sent = <Map>[];
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get messages => _ctrl.stream;

  @override
  void send(Object? data) {
    final m = data! as Map;
    sent.add(m);
    if (m['type'] == 'auth') _ctrl.add({'kind': 'authenticated'});
  }

  void serverPush(Map<String, dynamic> m) => _ctrl.add(m);

  @override
  Future<void> close() async => _ctrl.close();
}

Future<void> pump([Duration d = const Duration(milliseconds: 2)]) => Future.delayed(d);

void main() {
  late FakeHttp http;
  late FakeChannel channel;
  late ZSocket socket;
  late ZApp app;

  setUp(() {
    http = FakeHttp();
    socket = ZSocket(
      uri: Uri.parse('ws://h:5190'),
      token: 'tk',
      backoffBase: const Duration(milliseconds: 5),
      factory: (_) async => channel = FakeChannel(),
    );
    app = ZApp(api: ZApi(baseUrl: 'http://h:5190', token: 'tk', http: http.fn), socket: socket);
  });

  Future<void> openEmpty() async {
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => {'messages': <Map>[], 'total': 0},
        };
    await app.bootstrap();
    await app.openSession('s1');
    http.calls.clear();
  }

  test('bootstrap:连 WS + 拉模型和会话列表', () async {
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default', 'deepseek-v4'],
          '/api/sessions' => [
              {'id': 's1', 'title': '修bug'},
            ],
          _ => null,
        };
    await app.bootstrap();
    expect(app.linked, isTrue);
    expect(app.models, ['default', 'deepseek-v4']);
    expect(app.sessions.single['id'], 's1');
  });

  test('openSession:REST meta 重建历史,lastSeq 续传订阅', () async {
    await openEmpty();
    final events = [
      {'kind': 'text', 'role': 'user', 'content': '问题', 'seq': 1},
      {'kind': 'text', 'role': 'assistant', 'content': '回答', 'seq': 2},
      {'kind': 'complete', 'seq': 3},
    ];
    // REST 按 seq 倒序返回,meta 是完整出站事件
    http.responder = (c) => {
          'messages': [
            for (final e in events.reversed) {'seq': e['seq'], 'meta': jsonEncode(e)},
          ],
          'total': 3,
        };
    await app.openSession('s1');
    expect(app.currentSessionId, 's1');
    expect(app.chat.rows[0], isA<UserRow>());
    expect((app.chat.rows[0] as UserRow).content, '问题');
    expect((app.chat.rows[1] as TextRow).content, '回答');
    expect(app.chat.lastSeq, 3);
    expect(app.chat.running, isFalse); // 末尾 complete 落定
    final sub = channel.sent.last;
    expect(sub['type'], 'chat.subscribe');
    expect((sub['sessions'] as List).first, {'sessionId': 's1', 'lastSeq': 3});
  });

  test('实时事件归约进 chat;complete 后刷新会话列表', () async {
    await openEmpty();
    channel.serverPush({'kind': 'stream_delta', 'seq': 1, 'sessionId': 's1', 'content': 'he'});
    await pump();
    expect(app.chat.streamingText, 'he');
    channel.serverPush(
        {'kind': 'text', 'role': 'assistant', 'content': 'hello', 'seq': 2, 'sessionId': 's1'});
    await pump();
    final row = app.chat.rows.single;
    expect(row, isA<TextRow>());
    expect((row as TextRow).content, 'hello');
    // complete → 会话列表刷新(排序/状态变了)
    channel.serverPush({'kind': 'complete', 'seq': 3, 'sessionId': 's1'});
    await pump();
    expect(app.chat.running, isFalse);
    expect(http.calls.any((c) => c.path == '/api/sessions'), isTrue);
  });

  test('sendChat:乐观行 pending,服务器回显就地确认', () async {
    await openEmpty();
    app.sendChat('你好');
    final u = app.chat.rows.single as UserRow;
    expect(u.content, '你好');
    expect(u.pending, isTrue);
    expect(app.chat.running, isTrue);
    expect(channel.sent.last['type'], 'chat.send');
    expect(channel.sent.last['content'], '你好');
    channel.serverPush({'kind': 'text', 'role': 'user', 'content': '你好', 'seq': 1, 'sessionId': 's1'});
    await pump();
    final rows = app.chat.rows.whereType<UserRow>().toList();
    expect(rows.length, 1); // 合并,没有双气泡
    expect(rows.single.pending, isFalse);
  });

  test('未连接时 sendChat 报错并回滚乐观行', () async {
    // 跳过 bootstrap:socket 一直没连
    http.responder = (c) => {'messages': <Map>[], 'total': 0};
    await app.openSession('s1');
    app.sendChat('hi');
    expect(app.chat.rows, isEmpty); // 回滚
    expect(app.error, isNotNull);
  });

  test('answerPermission/abort 透传;应答后立即清 pendingPermission', () async {
    await openEmpty();
    channel.serverPush(
        {'kind': 'permission_request', 'requestId': 'r1', 'toolName': 'Bash', 'input': {}, 'sessionId': 's1'});
    await pump();
    expect(app.chat.pendingPermission?.requestId, 'r1');
    app.answerPermission('r1', allow: true, message: 'ok');
    expect(channel.sent.last, {
      'type': 'chat.permission-response',
      'sessionId': 's1',
      'requestId': 'r1',
      'allow': true,
      'message': 'ok',
    });
    expect(app.chat.pendingPermission, isNull);
    app.abort();
    expect(channel.sent.last, {'type': 'chat.abort', 'sessionId': 's1'});
  });

  test('replay 事件灌入当前会话', () async {
    await openEmpty();
    channel.serverPush({
      'kind': 'replay',
      'sessionId': 's1',
      'events': [
        {'kind': 'text', 'role': 'user', 'content': 'q', 'seq': 1, 'sessionId': 's1'},
        {'kind': 'complete', 'seq': 2, 'sessionId': 's1'},
      ],
    });
    await pump();
    expect((app.chat.rows.single as UserRow).content, 'q');
    expect(app.chat.lastSeq, 2);
  });

  test('createSession 建完拉列表并返回会话行', () async {
    http.responder = (c) => switch (c.path) {
          '/api/sessions' when c.method == 'POST' => {'id': 'new1', 'title': 'hi'},
          '/api/sessions' => <Map>[],
          _ => null,
        };
    final s = await app.createSession(title: 'hi');
    expect(s['id'], 'new1');
    expect(http.calls.last.path, '/api/sessions'); // 刷新列表
  });

  test('deleteSession:清当前会话状态并刷新列表', () async {
    await openEmpty();
    http.responder = (c) => <Map>[];
    await app.deleteSession('s1');
    expect(app.currentSessionId, isNull);
    expect(app.chat.rows, isEmpty);
    expect(http.calls.last.path, '/api/sessions');
  });
}
