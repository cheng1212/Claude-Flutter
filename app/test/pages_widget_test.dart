// 页面级 Widget 测试:真页面 + 假传输层(FakeHttp/FakeChannel),逐按钮 tap 断言。
// 覆盖:会话页(列表渲染/搜索/筛选chips/排序chip/批量入口-长按-全选-批量置顶-批量删除)
// 与登录页(显隐 token/连接回调)。审计矩阵阶段C产物。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/api.dart';
import 'package:zcode_app/state/zapp.dart';
import 'package:zcode_app/ui/login_page.dart';
import 'package:zcode_app/ui/sessions_page.dart';
import 'package:zcode_app/ws.dart';

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

  int count(String method, String pathPrefix) => calls
      .where((c) => c.method == method && c.path.startsWith(pathPrefix))
      .length;
}

class FakeChannel implements ZChannel {
  final _ctrl = StreamController<Map<String, dynamic>>.broadcast();

  @override
  Stream<Map<String, dynamic>> get messages => _ctrl.stream;

  @override
  void send(Object? data) {
    final m = data! as Map;
    if (m['type'] == 'auth') _ctrl.add({'kind': 'authenticated'});
  }

  @override
  Future<void> close() async => _ctrl.close();
}

Map<String, dynamic> sessionRow(String id,
        {String title = '会话', bool pinned = false, bool archived = false, String? preview}) =>
    {
      'id': id,
      'title': title,
      'is_pinned': pinned ? 1 : 0,
      'archived': archived ? 1 : 0,
      'last_preview': ?preview,
      'updated_at': '2026-09-12T10:00:00Z',
    };

ZApp makeApp(FakeHttp http, FakeChannel channel, {Object? sessions}) {
  http.responder = (c) => switch (c.path) {
        '/api/models' => ['default'],
        '/api/models/grouped' => {
            'groups': [
              {'id': 'default', 'label': '默认', 'models': []},
            ],
          },
        '/api/sessions' => sessions ?? <Map>[],
        '/api/crons' => <Map>[],
        _ => null,
      };
  final socket = ZSocket(
    uri: Uri.parse('ws://h:5190'),
    token: 'tk',
    backoffBase: const Duration(milliseconds: 5),
    factory: (_) async => channel,
  );
  return ZApp(api: ZApi(baseUrl: 'http://h:5190', token: 'tk', http: http.fn), socket: socket);
}

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  late FakeHttp http;
  late FakeChannel channel;

  setUp(() {
    http = FakeHttp();
    channel = FakeChannel();
  });

  group('SessionsPage', () {
    testWidgets('列表渲染:两条会话标题上屏', (tester) async {
      final app = makeApp(http, channel, sessions: [
        sessionRow('s1', title: '修bug'),
        sessionRow('s2', title: '写文档'),
      ]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('修bug'), findsOneWidget);
      expect(find.text('写文档'), findsOneWidget);
    });

    testWidgets('搜索框输入即过滤', (tester) async {
      final app = makeApp(http, channel, sessions: [
        sessionRow('s1', title: '修bug'),
        sessionRow('s2', title: '写文档'),
      ]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.enterText(find.widgetWithText(TextField, '搜索会话…'), 'bug');
      await tester.pump();
      expect(find.text('修bug'), findsOneWidget);
      expect(find.text('写文档'), findsNothing);
    });

    testWidgets('筛选 chip:点「置顶」只剩置顶会话', (tester) async {
      final app = makeApp(http, channel, sessions: [
        sessionRow('s1', title: '置顶的', pinned: true),
        sessionRow('s2', title: '普通的'),
      ]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('置顶'));
      await tester.pump();
      expect(find.text('置顶的'), findsOneWidget);
      expect(find.text('普通的'), findsNothing);
    });

    testWidgets('批量管理:入口→长按选中→全选→批量置顶发 PATCH', (tester) async {
      final app = makeApp(http, channel, sessions: [
        sessionRow('s1', title: '会话一'),
        sessionRow('s2', title: '会话二'),
      ]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // 长按卡片进入批量模式并选中该卡
      await tester.longPress(find.text('会话一'));
      await tester.pump();
      expect(find.text('已选 1 / 2'), findsOneWidget);

      // 点另一张卡 → 2/2
      await tester.tap(find.text('会话二'));
      await tester.pump();
      expect(find.text('已选 2 / 2'), findsOneWidget);

      // 全选按钮 → 已全选,再点取消全选 → 0,再点全选恢复
      await tester.tap(find.byIcon(Icons.deselect_rounded));
      await tester.pump();
      expect(find.text('已选 0 / 2'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.select_all_rounded));
      await tester.pump();
      expect(find.text('已选 2 / 2'), findsOneWidget);

      // 批量置顶 → 每个 id 一个 PATCH(逐个 patch,server 无批量 patch 端点)
      await tester.tap(find.text('置顶'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(http.count('PATCH', '/api/sessions/'), 2);
      expect(find.text('已更新 2 个会话'), findsOneWidget);
    });

    testWidgets('批量删除:确认弹窗→单请求 batch-delete', (tester) async {
      final app = makeApp(http, channel, sessions: [
        sessionRow('s1', title: '删我'),
        sessionRow('s2', title: '留我'),
      ]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      await tester.longPress(find.text('删我'));
      await tester.pump();
      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('删除 1 个会话'), findsOneWidget);

      http.calls.clear();
      await tester.tap(find.widgetWithText(TextButton, '删除').last);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      final batch = http.calls
          .where((c) => c.path == '/api/sessions/batch-delete')
          .toList();
      expect(batch, isNotEmpty, reason: '应走单请求批量端点');
      expect((batch.single.body as Map)['ids'], ['s1']);
      expect(find.text('已删除 1 个会话'), findsOneWidget);
    });

    testWidgets('退出批量:X 关闭并清空选择,卡片恢复正常点击', (tester) async {
      final app = makeApp(http, channel, sessions: [sessionRow('s1', title: '卡片')]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.longPress(find.text('卡片'));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(find.textContaining('已选'), findsNothing);
    });

    testWidgets('AppBar 标题点击打开项目切换弹层', (tester) async {
      final app = makeApp(http, channel, sessions: [sessionRow('s1', title: '卡片')]);
      await tester.runAsync(() => app.bootstrap());
      await tester.pumpWidget(host(SessionsPage(app: app, onLogout: () {})));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('全部会话'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('切换项目'), findsOneWidget);
    });
  });

  group('LoginPage', () {
    testWidgets('输入地址与 token 后点连接,回调带出两值', (tester) async {
      String? gotBase;
      String? gotToken;
      await tester.pumpWidget(host(LoginPage(
        initialBaseUrl: 'http://192.168.1.9:5190',
        initialToken: 'abc',
        onDone: (b, t) {
          gotBase = b;
          gotToken = t;
        },
      )));
      final tokenField = tester.widget<EditableText>(find.byType(EditableText).at(1));
      expect(tokenField.obscureText, isTrue, reason: 'token 默认密文');
      await tester.enterText(find.byType(TextField).at(1), 'xyz');
      await tester.tap(find.byType(IconButton).first); // 显隐切换
      await tester.pump();
      expect(
          tester.widget<EditableText>(find.byType(EditableText).at(1)).obscureText,
          isFalse,
          reason: '点显隐后明文');
      expect(find.text('xyz'), findsOneWidget);
      await tester.tap(find.text('连接'));
      await tester.pump();
      expect(gotToken, 'xyz');
      expect(gotBase, isNotNull);
    });
  });
}
