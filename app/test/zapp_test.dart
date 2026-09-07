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

  test('openSession 首屏:最新一页到齐即上屏,不等全量分页', () async {
    await openEmpty();
    final gate = Completer<void>();
    // 真实 API 语义:seq 1..1200,offset=0 返回最新 500(seq 1200..701),
    // beforeSeq 返回"比它更旧"的一页。首屏只等第一页,老消息后台按锚点补齐。
    Map<String, dynamic> pageFor({int? beforeSeq, int? offset}) {
      final high = beforeSeq != null ? beforeSeq - 1 : 1200 - (offset ?? 0);
      final msgs = <Map>[];
      for (var s = high; s > high - 500 && s >= 1; s--) {
        msgs.add({'seq': s, 'role': 'user', 'meta': {'kind': 'text', 'role': 'assistant', 'seq': s, 'content': 'm$s'}});
      }
      return {'messages': msgs, 'total': 1200};
    }

    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        final q = Uri.parse(c.path).queryParameters;
        final beforeSeq = q['beforeSeq'] == null ? null : int.parse(q['beforeSeq']!);
        final offset = q['offset'] == null ? null : int.parse(q['offset']!);
        final page = pageFor(beforeSeq: beforeSeq, offset: offset);
        final isFirst = beforeSeq == null;
        return isFirst ? page : gate.future.then((_) => page);
      }
      return null;
    };
    final opening = app.openSession('s1');
    await pump(const Duration(milliseconds: 20));
    expect(app.historyLoading, isFalse, reason: '首屏只等最新一页,老消息后台补');
    expect(app.chat.rows.length, 500);
    expect((app.chat.rows.first as TextRow).content, 'm701'); // 最新一页的最小 seq
    gate.complete();
    await opening;
    expect(app.chat.rows.length, 1200, reason: '补齐换底后全量在列');
  });

  test('backgrounds:server 统一任务列表透传;失败返回空', () async {
    await openEmpty();
    http.responder = (c) {
      if (c.path == '/api/sessions/s1/backgrounds') {
        return {
          'backgrounds': [
            {'id': 'tool9', 'command': 'npm run build', 'status': 'running', 'outputTail': 'l3'},
          ],
        };
      }
      return null;
    };
    final rows = await app.backgrounds('s1');
    expect(rows.single['command'], 'npm run build');
    expect(rows.single['outputTail'], 'l3');
    http.responder = (c) => throw Exception('boom');
    expect(await app.backgrounds('s1'), isEmpty);
  });

  test('openSession 补齐窗口内到达的 WS 事件,换底不吞', () async {
    await openEmpty();
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        final q = Uri.parse(c.path).queryParameters;
        final beforeSeq = q['beforeSeq'] == null ? null : int.parse(q['beforeSeq']!);
        final offset = q['offset'] == null ? null : int.parse(q['offset']!);
        final high = beforeSeq != null ? beforeSeq - 1 : 1200 - (offset ?? 0);
        // 首轮补齐(比最新页更旧)时,窗口内到达一条 live 事件,换底必须不吞
        if (beforeSeq == 701) {
          channel.serverPush({'kind': 'text', 'role': 'assistant', 'seq': 1201, 'sessionId': 's1', 'content': 'live'});
        }
        final msgs = <Map>[];
        for (var s = high; s > high - 500 && s >= 1; s--) {
          msgs.add({'seq': s, 'role': 'user', 'meta': {'kind': 'text', 'role': 'assistant', 'seq': s, 'content': 'm$s'}});
        }
        return {'messages': msgs, 'total': 1200};
      }
      return null;
    };
    await app.openSession('s1');
    await pump();
    expect(app.historyLoading, isFalse);
    final texts = [for (final r in app.chat.rows) if (r is TextRow) r.content];
    expect(texts.length, 1201, reason: '1200 条 REST + 1 条补齐窗口内 WS 到达的 live 消息,换底不能丢');
    expect(texts.last, 'live');
  });

  test('sessions_dirty:250ms 防抖合并成一次列表刷新;控制帧不进 reducer', () async {
    await openEmpty();
    var sessionFetches = 0;
    http.responder = (c) {
      if (c.path == '/api/sessions') {
        sessionFetches++;
        return <Map>[
          {'id': 's1', 'title': 'x', 'isRunning': true},
        ];
      }
      return {'messages': <Map>[], 'total': 0};
    };
    // 开跑/跑完连发三拍(不同会话混着)→ 只该合并成一次 REST
    channel.serverPush({'kind': 'sessions_dirty', 'sessionId': 's1'});
    channel.serverPush({'kind': 'sessions_dirty', 'sessionId': 's1'});
    channel.serverPush({'kind': 'sessions_dirty', 'sessionId': 'other'});
    await pump(const Duration(milliseconds: 400));
    expect(sessionFetches, 1);
    expect(app.sessions.single['isRunning'], isTrue);
    // 控制帧不进聊天流:当前会话行数不变
    expect(app.chat.rows, isEmpty);
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

  test('openSession 锚 DB 行号:meta 里旧服务器的天文数字 seq 不得毒化去重指针', () async {
    await openEmpty();
    // 服务器重启前 delta 把事件 seq 灌到天文数字;DB 行号才是连续权威
    http.responder = (c) => {
          'messages': [
            {'seq': 3, 'meta': jsonEncode({'kind': 'complete', 'seq': 17203})},
            {'seq': 2, 'meta': jsonEncode({'kind': 'text', 'role': 'assistant', 'content': '回答', 'seq': 17102})},
            {'seq': 1, 'meta': jsonEncode({'kind': 'text', 'role': 'user', 'content': '问题', 'seq': 17101})},
          ],
          'total': 3,
        };
    await app.openSession('s1');
    expect(app.chat.lastSeq, 3); // 用行号,不是 meta 的 17203
    expect(app.chat.rows.first, isA<UserRow>());
    final sub = channel.sent.last;
    expect((sub['sessions'] as List).first, {'sessionId': 's1', 'lastSeq': 3});
  });

  test('openSession 历史末尾无 complete(reload 重建):running 不冻结成假运行中', () async {
    await openEmpty();
    // 末尾是 text 没有 complete:重建历史推断 running 会把按钮卡成 STOP
    http.responder = (c) => {
          'messages': [
            {'seq': 2, 'meta': jsonEncode({'kind': 'text', 'role': 'assistant', 'content': '回答', 'seq': 2})},
            {'seq': 1, 'meta': jsonEncode({'kind': 'text', 'role': 'user', 'content': '问题', 'seq': 1})},
          ],
          'total': 2,
        };
    await app.openSession('s1');
    expect(app.chat.rows.length, 2);
    // running 不能被历史推断;真实态由 subscribed.isProcessing 驱动
    expect(app.chat.running, isFalse, reason: '末条 text 不代表正在跑,不能冻结成运行中');
    // 服务器说没在跑:subscribed isProcessing=false 到齐后也保持 idle
    channel.serverPush({'kind': 'subscribed', 'sessionId': 's1', 'isProcessing': false});
    await pump();
    expect(app.chat.running, isFalse);
  });

  test('openSession 同会话刷新保留待审批卡片(审批不落库,丢了没人能批)', () async {
    await openEmpty();
    channel.serverPush({
      'kind': 'permission_request', 'requestId': 'r9', 'toolName': 'Bash', 'input': {}, 'sessionId': 's1',
    });
    await pump();
    expect(app.chat.pendingPermission?.requestId, 'r9');
    // 刷新:REST 历史里没有审批事件
    http.responder = (c) => {'messages': <Map>[], 'total': 0};
    await app.openSession('s1');
    expect(app.chat.pendingPermission?.requestId, 'r9'); // 保留,审批卡不丢
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

    // 「本会话总是允许」:rememberTool 透传上服务器
    channel.serverPush(
        {'kind': 'permission_request', 'requestId': 'r2', 'toolName': 'Write', 'input': {}, 'sessionId': 's1'});
    await pump();
    app.answerPermission('r2', allow: true, rememberTool: true);
    expect(channel.sent.last, {
      'type': 'chat.permission-response',
      'sessionId': 's1',
      'requestId': 'r2',
      'allow': true,
      'message': '',
      'rememberTool': true,
    });
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
