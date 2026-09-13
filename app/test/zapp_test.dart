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

// 造一页历史:beforeSeq 为空 = 最新一页(1200 起往回 limit 条);否则取比它更旧的一页
Map<String, dynamic> historyPage(String? beforeSeqRaw, int limit) {
  final beforeSeq = beforeSeqRaw == null ? null : int.tryParse(beforeSeqRaw);
  final high = beforeSeq != null ? beforeSeq - 1 : 1200;
  final msgs = <Map>[];
  for (var s = high; s > high - limit && s >= 1; s--) {
    msgs.add({'seq': s, 'role': 'user', 'meta': {'kind': 'text', 'role': 'assistant', 'seq': s, 'content': 'm$s'}});
  }
  return {'messages': msgs, 'total': 1200};
}

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

  test('openSession 首屏:只等最新一页(100 条)即上屏,不后台翻页', () async {
    await openEmpty();
    // 真实 API 语义:seq 1..1200,offset=0 返回最新 100 条(seq 1200..1101)。
    // 更旧的不再自动拉 —— 用户滑到最旧端才按需取(见 loadOlder 用例)。
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        return historyPage(Uri.parse(c.path).queryParameters['beforeSeq'], 100);
      }
      return null;
    };
    await app.openSession('s1');
    await pump();
    expect(app.historyLoading, isFalse, reason: '首屏只等最新一页');
    expect(app.chat.rows.length, 100, reason: '默认只加载 100 条(用户要求,够日常看)');
    expect((app.chat.rows.first as TextRow).content, 'm1101'); // 这一页的最小 seq
    expect((app.chat.rows.last as TextRow).content, 'm1200'); // 最新
    expect(app.chat.hasMoreOlder, isTrue, reason: '标记还有更旧的,等滑到顶再取');
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


  test('openSession 只拉首屏一页 + 标记还有更旧的(不再后台狂翻页)', () async {
    await openEmpty();
    var messageCalls = 0;
    final gate = Completer<void>();
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        messageCalls += 1;
        return gate.future.then((_) => historyPage(null, 100));
      }
      return null;
    };
    final opening = app.openSession('s1');
    await pump();
    // 首屏请求在途时,窗口内到达一条 live 事件:必须并入,不能被首屏覆盖丢掉
    channel.serverPush({'kind': 'text', 'role': 'assistant', 'seq': 1201, 'sessionId': 's1', 'content': 'live'});
    await pump();
    gate.complete();
    await opening;
    await pump();
    expect(app.historyLoading, isFalse);
    final texts = [for (final r in app.chat.rows) if (r is TextRow) r.content];
    expect(texts.last, 'live', reason: '首屏并入窗口内 WS 事件,不丢');
    expect(texts.length, 101, reason: '100 条首屏 + 1 条 live');
    expect(app.chat.hasMoreOlder, isTrue, reason: 'total 1200 > 已加载,标记还有更旧的');
    expect(app.chat.oldestSeq, 1101, reason: '记下最旧 seq 当按需加载的锚点');
    expect(messageCalls, 1, reason: '打开会话只发一次请求 —— 不再后台翻十几页(大会话白屏根因)');
  });

  test('loadOlder:滑到最旧端按需拉更旧一页,接到最前面且锚点前移', () async {
    await openEmpty();
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        final q = Uri.parse(c.path).queryParameters;
        return historyPage(q['beforeSeq'], 100);
      }
      return null;
    };
    await app.openSession('s1');
    await pump();
    final firstOldest = app.chat.oldestSeq;
    expect(app.chat.rows.length, 100);
    expect(app.chat.hasMoreOlder, isTrue);

    await app.loadOlder();
    await pump();
    expect(app.chat.rows.length, 200, reason: '又接上一页');
    expect(app.chat.oldestSeq, lessThan(firstOldest), reason: '锚点前移');
    expect((app.chat.rows.first as TextRow).content, 'm1001',
        reason: '更旧的行接在最前面(rows 旧→新;这一页最旧是 1001)');
    expect((app.chat.rows.last as TextRow).content, 'm1200', reason: '新的仍在最后');
  });

  test('bug#4 刷新丢自己消息:回显先于 REST 到达,单页也不能丢', () async {
    await openEmpty();
    // ① 发消息:本地乐观 pending 行
    app.sendChat('我刚发的');
    expect((app.chat.rows.single as UserRow).pending, isTrue);
    // ② 立刻刷新:REST 读取发生在落库之前(不含这条消息),首屏被 gate 卡住
    final gate = Completer<void>();
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        return gate.future.then((_) => {
              'messages': [
                {'seq': 1, 'meta': jsonEncode({'kind': 'text', 'role': 'user', 'content': '旧问题', 'seq': 1})},
              ],
              'total': 1, // 单页:原实现在这里 early-return,直接丢弃 _backfill.extra
            });
      }
      return null;
    };
    final opening = app.openSession('s1');
    await pump();
    expect(app.chat.rows.length, 1, reason: '刷新期间旧内容原地保留(不再清屏白屏),乐观行用户可见');
    // ③ 服务器落库 + 回显:刷新窗口内到达 → 落进 _backfill.extra
    channel.serverPush({'kind': 'text', 'role': 'user', 'content': '我刚发的', 'seq': 2, 'sessionId': 's1'});
    await pump();
    // ④ REST 首屏返回(不含回显行),原实现会把它整体覆盖且无人补回
    gate.complete();
    await opening;
    final users = app.chat.rows.whereType<UserRow>().toList();
    expect([for (final r in users) r.content], ['旧问题', '我刚发的'],
        reason: '首屏覆盖后必须由 bf.extra 归约补回,否则"刷的时候没了、过会儿又出现"');
    expect(users.last.pending, isFalse, reason: '补回的是服务器回显,不是残留的乐观行');
  });

  test('bug#4 单页会话:补齐窗口内到达的实时行不被首屏覆盖丢弃', () async {
    await openEmpty();
    final gate = Completer<void>();
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        return gate.future.then((_) => {
              'messages': [
                {'seq': 1, 'meta': jsonEncode({'kind': 'text', 'role': 'assistant', 'content': '旧回答', 'seq': 1})},
              ],
              'total': 1,
            });
      }
      return null;
    };
    final opening = app.openSession('s1');
    await pump();
    channel.serverPush({'kind': 'text', 'role': 'assistant', 'content': '窗口内的新回答', 'seq': 2, 'sessionId': 's1'});
    await pump();
    gate.complete();
    await opening;
    final texts = [for (final r in app.chat.rows) if (r is TextRow) r.content];
    expect(texts, ['旧回答', '窗口内的新回答'],
        reason: '单页路径统一走换底:extra 必须归约,实时行不能被覆盖后无人补回(且不重复)');
    expect(app.chat.lastSeq, 2);
  });

  test('按需加载期间实时开跑不被冲掉(running 只由实时事件驱动)', () async {
    await openEmpty();
    final gate = Completer<void>();
    http.responder = (c) {
      if (c.path.startsWith('/api/sessions/s1/messages')) {
        final q = Uri.parse(c.path).queryParameters;
        final page = historyPage(q['beforeSeq'], 100);
        return q['beforeSeq'] == null ? page : gate.future.then((_) => page);
      }
      return null;
    };
    await app.openSession('s1');
    await pump();
    expect(app.historyLoading, isFalse);
    channel.serverPush({'kind': 'subscribed', 'sessionId': 's1', 'isProcessing': true});
    await pump();
    expect(app.chat.running, isTrue, reason: '实时 subscribed 置运行中');
    // 加载更旧一页期间,回合开跑的实时态不能被整块替换冲掉
    final loading = app.loadOlder();
    await pump();
    gate.complete();
    await loading;
    await pump();
    expect(app.chat.rows.length, 200, reason: '更旧一页接上了');
    expect(app.chat.running, isTrue,
        reason: 'running 只由实时事件驱动,加载历史不得把它冲回 false(否则按钮从 STOP 变回发送)');
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
    await pump(const Duration(milliseconds: 60)); // 40ms 合帧窗走完才上屏
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

  test('delta 合帧:50 条 stream_delta 只 notify 一次,内容无损', () async {
    await openEmpty();
    var notifies = 0;
    void listener() => notifies++;
    app.addListener(listener);
    for (var i = 0; i < 50; i++) {
      channel.serverPush({'kind': 'stream_delta', 'content': '字$i', 'seq': 10 + i, 'sessionId': 's1'});
    }
    expect(app.chat.streamingText, isNull, reason: '缓冲期内不上屏');
    expect(notifies, 0, reason: 'delta 不逐条 notify');
    await pump(const Duration(milliseconds: 60)); // 40ms 合帧窗走完
    expect(app.chat.streamingText, [for (var i = 0; i < 50; i++) '字$i'].join());
    expect(app.chat.lastSeq, 59, reason: '合帧取最大 seq');
    expect(notifies, 1, reason: '整页重建与 chunk 频率脱钩');
    app.removeListener(listener);
  });

  test('delta 合帧:complete 先于残余 delta 到达时,flush 先落、终态后落(残字不复活)', () async {
    await openEmpty();
    channel.serverPush({'kind': 'stream_delta', 'content': '残', 'seq': 5, 'sessionId': 's1'});
    channel.serverPush({'kind': 'complete', 'seq': 6, 'sessionId': 's1'}); // 不等 40ms 窗
    await pump();
    expect(app.chat.running, isFalse);
    expect(app.chat.streamingText, isNull, reason: '残余 delta 必须在 complete 之前 flush 掉,否则定稿后又冒残字');
  });

  test('切会话丢弃旧会话在途 delta(不污染新会话)', () async {
    await openEmpty();
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => {'messages': <Map>[], 'total': 0},
        };
    channel.serverPush({'kind': 'stream_delta', 'content': '旧尾巴', 'seq': 9, 'sessionId': 's1'});
    await app.openSession('s2'); // 不等 40ms 窗就切走
    await pump(const Duration(milliseconds: 60));
    expect(app.chat.streamingText, isNull, reason: '旧会话的流式尾巴不得落进新会话');
  });

  test('发送排队:入队/去重/置顶/修改/删除', () async {
    await openEmpty();
    expect(app.enqueue('A'), 'queued');
    expect(app.enqueue('A'), 'duplicate', reason: '同文消息不重复入队');
    expect(app.enqueue('B'), 'queued');
    expect(app.enqueue('C'), 'queued');
    expect(app.queueOf('s1').map((m) => m.text), ['A', 'B', 'C']);

    app.promoteQueued('s1', 2); // C 提到队首
    expect(app.queueOf('s1').map((m) => m.text), ['C', 'A', 'B']);

    expect(app.editQueued('s1', 1, 'C'), isFalse, reason: '改成与队内其他条重复 → 拒绝');
    expect(app.editQueued('s1', 1, 'A2'), isTrue);
    expect(app.queueOf('s1').map((m) => m.text), ['C', 'A2', 'B']);

    app.removeQueued('s1', 0);
    expect(app.queueOf('s1').map((m) => m.text), ['A2', 'B']);
  });

  test('自动消化:complete 后自动推队首;开关关着就排队不动', () async {
    await openEmpty();
    app.enqueue('排队消息A');
    app.sendChat('第一轮');
    channel.serverPush({'kind': 'complete', 'seq': 2, 'sessionId': 's1'});
    await pump(const Duration(milliseconds: 600)); // 400ms 消化定时器
    final sent = channel.sent.whereType<Map>().toList();
    expect(sent.any((m) => m['type'] == 'chat.send' && m['content'] == '排队消息A'), isTrue,
        reason: '回复结束自动推下一条');
    expect(app.queueCount('s1'), 0);
    expect(app.chat.running, isTrue, reason: '推出去的消息带乐观行,回合开跑');

    // 关掉自动消化:排队不动
    app.enqueue('排队消息B');
    app.setAutoConsume('s1', on: false);
    channel.serverPush({'kind': 'complete', 'seq': 9, 'sessionId': 's1'});
    await pump(const Duration(milliseconds: 600));
    expect(app.queueCount('s1'), 1, reason: '开关关:只排队不推');
    expect(channel.sent.any((m) => m['type'] == 'chat.send' && m['content'] == '排队消息B'), isFalse);
  });

  test('interruptAndSend:先 abort,等落定后发送', () async {
    await openEmpty();
    app.sendChat('第一轮'); // running = true(乐观)
    final f = app.interruptAndSend('插队消息');
    await pump(const Duration(milliseconds: 30));
    expect(channel.sent.any((m) => m['type'] == 'chat.abort'), isTrue, reason: '先打断');
    channel.serverPush({'kind': 'complete', 'seq': 2, 'sessionId': 's1'}); // 回合落定
    final ok = await f;
    expect(ok, isTrue);
    expect(channel.sent.any((m) => m['type'] == 'chat.send' && m['content'] == '插队消息'), isTrue,
        reason: '落定后立即发送');
  });

  test('删除会话清空其队列', () async {
    await openEmpty();
    http.responder = (c) => switch (c.path) {
          '/api/sessions' => <Map>[],
          _ => null,
        };
    app.enqueue('会随会话消失');
    expect(app.queueCount('s1'), 1);
    await app.deleteSession('s1');
    expect(app.queueCount('s1'), 0);
  });

  test('同会话刷新失败:旧内容原地保留(白屏根治)', () async {
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => {
              'messages': [
                {'seq': 1, 'meta': {'kind': 'text', 'role': 'user', 'seq': 1, 'content': '历史消息'}},
              ],
              'total': 1,
            },
        };
    await app.bootstrap();
    await app.openSession('s1');
    expect(app.chat.rows.length, 1);
    // 刷新:让 messages 请求失败(模拟网络抖动/REST 超时)
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => Exception('网络抖动'),
        };
    await app.openSession('s1');
    expect(app.chat.rows.length, 1, reason: '刷新失败不清空旧内容——「回复中白屏卡住」根治');
    expect(app.error, isNotNull);
    expect(app.historyLoading, isFalse);
  });

  test('切会话失败:新会话留空态,不残留上一个会话的行', () async {
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => {
              'messages': [
                {'seq': 1, 'meta': {'kind': 'text', 'role': 'user', 'seq': 1, 'content': 's1 的消息'}},
              ],
              'total': 1,
            },
        };
    await app.bootstrap();
    await app.openSession('s1');
    expect(app.chat.rows.length, 1);
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => Exception('超时'),
        };
    await app.openSession('s2');
    expect(app.chat.rows, isEmpty, reason: '切会话不允许显示上一个会话的内容');
    expect(app.error, isNotNull);
  });

  test('同会话刷新保留 running 实时态(首屏与换底都不冲掉)', () async {
    http.responder = (c) => switch (c.path) {
          '/api/models' => ['default'],
          '/api/sessions' => <Map>[],
          _ => {
              'messages': [
                {'seq': 1, 'meta': {'kind': 'text', 'role': 'user', 'seq': 1, 'content': 'q'}},
              ],
              'total': 1,
            },
        };
    await app.bootstrap();
    await app.openSession('s1');
    app.sendChat('正在回复中');
    expect(app.chat.running, isTrue);
    await app.openSession('s1'); // 同会话刷新
    expect(app.chat.running, isTrue, reason: '刷新不得把实时 running 冲成假空闲');
    expect(app.chat.rows.length, 1, reason: 'REST 是权威:刷新后以服务器行为准,本地乐观行被替换');
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
