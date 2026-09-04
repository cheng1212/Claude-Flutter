import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/api.dart';
import 'package:zcode_app/ws.dart';

// ---------------------------------------------------------------- api 假件

class FakeHttp {
  final calls = <({String method, String path, Object? body})>[];
  Object? Function(({String method, String path, Object? body}))? responder;

  HttpFn get fn => (method, path, body) async {
        final rec = (method: method, path: path, body: body);
        calls.add(rec);
        final r = responder?.call(rec);
        if (r is Exception) throw r;
        if (r is ZApiException) throw r;
        return r;
      };
}

void main() {
  group('ZApi', () {
    test('各方法发对 method/path/Bearer,返回解析后的 JSON', () async {
      final fake = FakeHttp();
      final api = ZApi(baseUrl: 'http://h:5190', token: 'tk', http: fake.fn);

      fake.responder = (c) => c.path == '/api/models' ? ['default', 'deepseek-v4'] : null;
      expect(await api.models(), ['default', 'deepseek-v4']);

      fake.responder = (c) => [
            {'id': 's1', 'title': 'a', 'isPinned': 0},
          ];
      final sessions = await api.sessions();
      expect(sessions.single['id'], 's1');

      fake.responder = (c) => {'id': 'new1', 'title': (c.body as Map)['title']};
      final created = await api.createSession(title: 'hi');
      expect(created['id'], 'new1');

      fake.responder = (c) => {'ok': true};
      await api.patchSession('s1', title: 'x', isPinned: true);
      await api.deleteSession('s1');

      fake.responder = (c) => {
            'messages': [
              {'seq': 2, 'meta': '{"kind":"text","seq":2}'},
              {'seq': 1, 'meta': '{"kind":"text","seq":1}'},
            ],
            'total': 2,
          };
      final hist = await api.messages('s1');
      expect(hist.messages.length, 2);
      expect(hist.total, 2);

      expect(fake.calls.map((c) => c.method).toList(),
          ['GET', 'GET', 'POST', 'PATCH', 'DELETE', 'GET']);
      expect(fake.calls[2].path, '/api/sessions');
      expect(fake.calls[3].path, '/api/sessions/s1');
      expect(fake.calls[3].body, {'title': 'x', 'isPinned': true});
      expect(fake.calls[5].path, '/api/sessions/s1/messages?limit=500');
    });

    test('非 2xx 映射为 ZApiException', () async {
      final fake = FakeHttp();
      final api = ZApi(baseUrl: 'http://h:5190', token: 'tk', http: fake.fn);
      fake.responder = (c) => const ZApiException('nope', status: 401);
      await expectLater(api.sessions(), throwsA(isA<ZApiException>()));
    });
  });

  // ---------------------------------------------------------------- ws 假件

  late FakeChannel channel;
  final channels = <FakeChannel>[];
  ZSocket makeSocket({Duration backoff = const Duration(milliseconds: 5), Duration? pingEvery, DateTime Function()? clock}) {
    return ZSocket(
      uri: Uri.parse('ws://h:5190'),
      token: 'tk',
      backoffBase: backoff,
      pingEvery: pingEvery ?? const Duration(seconds: 25),
      clock: clock,
      factory: (uri) async {
        channel = FakeChannel();
        channels.add(channel);
        return channel;
      },
    );
  }

  test('connect 发 auth,收到 authenticated 后 open;subscribe 带重连后 lastSeq', () async {
    final s = makeSocket();
    final seen = <Map<String, dynamic>>[];
    final sub = s.events.listen(seen.add);

    await s.connect();
    expect(s.state, ZSocketState.open);
    expect(channel.sent.first, {'type': 'auth', 'token': 'tk'});

    s.subscribeSession('s1');
    await pump();
    expect(channel.sent.last['type'], 'chat.subscribe');
    expect((channel.sent.last['sessions'] as List).first,
        {'sessionId': 's1', 'lastSeq': 0});

    // 服务器推事件 → events 流可见,lastSeq 前进
    channel.serverPush({'kind': 'text', 'role': 'assistant', 'content': 'a', 'seq': 3, 'sessionId': 's1'});
    await pump();
    expect(seen.last['content'], 'a');
    expect(s.lastSeq('s1'), 3);

    // 断线 → 自动重连 → 重新 auth + 带 lastSeq=3 补订
    channel.serverClose();
    await pump();
    expect(s.state, ZSocketState.reconnecting);
    await pump(const Duration(milliseconds: 30));
    expect(s.state, ZSocketState.open);
    expect(channels.length, 2);
    expect(channels[1].sent.first, {'type': 'auth', 'token': 'tk'});
    final resub = channels[1].sent.last;
    expect(resub['type'], 'chat.subscribe');
    expect((resub['sessions'] as List).first, {'sessionId': 's1', 'lastSeq': 3});
    await sub.cancel();
    await s.close();
  });

  test('replay 事件批量推进 lastSeq;sendChat/abort/permission 载荷正确', () async {
    final s = makeSocket();
    await s.connect();
    s.subscribeSession('s1');
    await pump();
    channel.serverPush({
      'kind': 'replay',
      'sessionId': 's1',
      'events': [
        {'kind': 'text', 'seq': 1, 'sessionId': 's1', 'content': 'x'},
        {'kind': 'complete', 'seq': 2, 'sessionId': 's1'},
      ],
    });
    await pump();
    expect(s.lastSeq('s1'), 2);

    s.sendChat('s1', '你好', model: 'default', permissionMode: 'acceptEdits');
    expect(channel.sent.last, {
      'type': 'chat.send',
      'sessionId': 's1',
      'content': '你好',
      'options': {'permissionMode': 'acceptEdits'}, // default 不占 options.model
    });

    // default 权限模式也不占 options:显式发 'default' 会在服务端压掉 DB 里 PATCH 过的模式
    s.sendChat('s1', '再问', model: 'glm-x', permissionMode: 'default');
    expect(channel.sent.last, {
      'type': 'chat.send',
      'sessionId': 's1',
      'content': '再问',
      'options': {'model': 'glm-x'},
    });

    s.answerPermission('s1', 'r9', allow: true);
    expect(channel.sent.last, {
      'type': 'chat.permission-response',
      'sessionId': 's1',
      'requestId': 'r9',
      'allow': true,
      'message': '',
    });

    s.abort('s1');
    expect(channel.sent.last, {'type': 'chat.abort', 'sessionId': 's1'});
    await s.close();
    expect(s.state, ZSocketState.closed);
  });

  test('鉴权被拒 → 抛 ZSocketException', () async {
    final denyCh = FakeChannel()..deny = true;
    final s = ZSocket(
      uri: Uri.parse('ws://h:5190'),
      token: 'tk',
      factory: (_) async => denyCh,
    );
    await expectLater(s.connect(), throwsA(isA<ZSocketException>()));
  });

  test('假死连接判活:周期性来包保活;静默超两个周期主动判死重连', () async {
    // 假时针驱动:判活只看"来包间隔",与真实定时器快慢解耦,不抖
    var now = DateTime.now();
    final s = makeSocket(
      pingEvery: const Duration(milliseconds: 10),
      clock: () => now,
    );
    final sub = s.events.listen((_) {});
    final baseChannels = channels.length; // channels 跨测试共享,用差值断言
    await s.connect();
    expect(s.state, ZSocketState.open);
    expect(channels.length, baseChannels + 1);

    // 有来包(pong/事件都算入站):时针小步走(间隔 < 2×周期),永不判死
    for (var i = 0; i < 6; i++) {
      now = now.add(const Duration(milliseconds: 4));
      channel.serverPush(const {'kind': 'pong'});
    }
    await pump(const Duration(milliseconds: 25)); // 让真实 ping 周期跑几拍做检查
    expect(channels.length, baseChannels + 1, reason: '来包正常时不应判死重连');

    // 来包停了:时针跳过两个周期(>20ms)无任何入站(本地 onDone 不会来)→ 判死重连
    now = now.add(const Duration(milliseconds: 100));
    await pump(const Duration(milliseconds: 25)); // 周期拍检查 → _onDown → 退避 5ms 重连
    await pump(const Duration(milliseconds: 10));
    expect(channels.length, baseChannels + 2, reason: '静默超两个周期应判死并重连');
    expect(s.state, ZSocketState.open);
    await sub.cancel();
    await s.close();
  });
}

Future<void> pump([Duration d = const Duration(milliseconds: 2)]) => Future.delayed(d);

class FakeChannel implements ZChannel {
  bool deny = false;
  final sent = <Map>[];
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();
  bool _closed = false;

  @override
  Stream<Map<String, dynamic>> get messages => _ctrl.stream;

  @override
  void send(Object? data) {
    final m = data! as Map;
    sent.add(m);
    if (m['type'] == 'auth') {
      _ctrl.add(deny ? {'kind': 'error', 'content': 'unauthorized'} : {'kind': 'authenticated'});
    }
  }

  void serverPush(Map<String, dynamic> m) => _ctrl.add(m);

  void serverClose() {
    if (!_closed) {
      _closed = true;
      _ctrl.close();
    }
  }

  @override
  Future<void> close() async {
    serverClose();
  }
}
