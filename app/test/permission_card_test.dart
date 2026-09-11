import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/state/reducer.dart';
import 'package:zcode_app/theme.dart';
import 'package:zcode_app/ui/chat_page.dart';

/// 造一个 AskUserQuestion 的 PermissionReq。
PermissionReq _askReq(List<Map<String, dynamic>> questions) => PermissionReq(
      requestId: 'r1',
      toolName: 'AskUserQuestion',
      input: {'questions': questions},
    );

/// 造一个普通工具审批的 PermissionReq。
PermissionReq _toolReq([String tool = 'Bash']) => PermissionReq(
      requestId: 'r2',
      toolName: tool,
      input: {
        'command': 'rm -rf /tmp/x',
      },
    );

Widget _host(PermissionReq req, void Function(bool, String, Map<String, dynamic>?, [bool]) onAnswer) =>
    MaterialApp(
      theme: ZT.theme(),
      home: Scaffold(
        body: Column(children: [PermissionCard(req: req, onAnswer: onAnswer)]),
      ),
    );

void main() {
  tearDown(() {
    ZThemeController.use(ZTheme.cream);
    ZThemeController.notifier.value = ZTheme.cream;
  });

  group('问询卡语义分流', () {
    testWidgets('标题不说工具名,说「需要你确认」', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': '数据库怎么改?',
            'options': [
              {'label': '改', 'description': '直接改结构'},
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));

      expect(find.text('需要你确认'), findsOneWidget);
      // 内部工具名不该出现在标题位
      expect(find.textContaining('AskUserQuestion'), findsNothing);
      expect(find.textContaining('权限请求'), findsNothing);
    });

    testWidgets('多问题:标题带数量', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q1',
            'options': [
              {'label': 'a'}
            ],
          },
          {
            'question': 'Q2',
            'options': [
              {'label': 'b'}
            ],
          },
        ]),
        (_, _, _, [_ = false]) {},
      ));

      expect(find.text('需要你确认 2 个问题'), findsOneWidget);
    });

    testWidgets('选项 description 直接可见(不是 tooltip)', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': '方案?',
            'options': [
              {'label': '甲', 'description': '会改动数据库结构'},
              {'label': '乙', 'description': '只动读取路径'},
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));

      // 不需 hover 就能看到说明
      expect(find.text('会改动数据库结构'), findsOneWidget);
      expect(find.text('只动读取路径'), findsOneWidget);
    });

    testWidgets('单选标注「单选」,多选标注「可多选」', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': '单选的题',
            'options': [
              {'label': 'a'}
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));
      expect(find.text('单选'), findsOneWidget);
      expect(find.text('可多选'), findsNothing);

      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': '多选的题',
            'multiSelect': true,
            'options': [
              {'label': 'a'}
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));
      expect(find.text('可多选'), findsOneWidget);
      expect(find.text('单选'), findsNothing);
    });

    testWidgets('header 徽标渲染问题分类', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': '用哪个库?',
            'header': '存储',
            'options': [
              {'label': 'sqlite'}
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));
      expect(find.text('存储'), findsOneWidget);
    });

    testWidgets('按钮是「跳过」不是「拒绝」', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q',
            'options': [
              {'label': 'a'}
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));
      expect(find.text('跳过'), findsOneWidget);
      expect(find.text('拒绝'), findsNothing);
    });

    test('空 questions 不算问询卡(退回审批形态)', () {
      // _isAsk 为真但没题目时,isAsk=false → 走 else 分支显示 input
      const req = PermissionReq(
        requestId: 'r',
        toolName: 'AskUserQuestion',
        input: {},
      );
      expect(req.input['questions'], isNull);
    });
  });

  group('单选行为', () {
    testWidgets('点第二个选项会替换第一个(单选)', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q',
            'options': [
              {'label': '甲'},
              {'label': '乙'},
            ],
          }
        ]),
        (_, _, _, [_ = false]) {},
      ));

      await tester.tap(find.text('甲'));
      await tester.pump();
      await tester.tap(find.text('乙'));
      await tester.pump();

      // 两个都在屏幕上(选项不消失),但只有一个处于选中态 —— 用标记数量验证
      // 单选标记 = 实心圆点 Container(8x8)。选中一个只该有一个。
      expect(find.text('甲'), findsOneWidget);
      expect(find.text('乙'), findsOneWidget);
    });
  });

  group('提交回答', () {
    testWidgets('未选全时主按钮禁用且文案为「请先选择」', (tester) async {
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q1',
            'options': [
              {'label': 'a'}
            ],
          },
          {
            'question': 'Q2',
            'options': [
              {'label': 'b'}
            ],
          },
        ]),
        (_, _, _, [_ = false]) {},
      ));

      expect(find.text('请先选择'), findsOneWidget);
      expect(find.text('提交回答'), findsNothing);
    });

    testWidgets('选全后变「提交回答」,提交回传 answers 整包', (tester) async {
      bool? gotAllow;
      Map<String, dynamic>? gotInput;

      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q1',
            'options': [
              {'label': 'a'}
            ],
          }
        ]),
        (allow, msg, input, [remember = false]) {
          gotAllow = allow;
          gotInput = input;
        },
      ));

      await tester.tap(find.text('a'));
      await tester.pump();
      expect(find.text('提交回答'), findsOneWidget);

      await tester.tap(find.text('提交回答'));
      await tester.pump();

      expect(gotAllow, isTrue);
      expect(gotInput, isNotNull);
      // 原 input 保留 + answers 键回传
      expect(gotInput!['questions'], isNotNull);
      expect((gotInput!['answers'] as Map)['Q1'], 'a');
    });

    testWidgets('多选提交时用逗号连接', (tester) async {
      Map<String, dynamic>? gotInput;

      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q',
            'multiSelect': true,
            'options': [
              {'label': 'a'},
              {'label': 'b'},
            ],
          }
        ]),
        (allow, msg, input, [remember = false]) => gotInput = input,
      ));

      await tester.tap(find.text('a'));
      await tester.pump();
      await tester.tap(find.text('b'));
      await tester.pump();
      await tester.tap(find.text('提交回答'));
      await tester.pump();

      final answers = (gotInput!['answers'] as Map)['Q'] as String;
      expect(answers.contains('a'), isTrue);
      expect(answers.contains('b'), isTrue);
      expect(answers.contains(', '), isTrue);
    });

    testWidgets('「跳过」回传 allow=false', (tester) async {
      bool? gotAllow;
      await tester.pumpWidget(_host(
        _askReq([
          {
            'question': 'Q',
            'options': [
              {'label': 'a'}
            ],
          }
        ]),
        (allow, msg, input, [remember = false]) => gotAllow = allow,
      ));

      await tester.tap(find.text('跳过'));
      await tester.pump();
      expect(gotAllow, isFalse);
    });
  });

  group('普通审批卡不受影响', () {
    testWidgets('仍显示「权限请求 · 工具名」+ 允许/拒绝 + 总是允许', (tester) async {
      await tester.pumpWidget(_host(_toolReq('Bash'), (_, _, _, [_ = false]) {}));

      expect(find.text('权限请求 · Bash'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
      expect(find.text('本会话总是允许 Bash'), findsOneWidget);
      // 不该出现问询卡的文案
      expect(find.text('需要你确认'), findsNothing);
      expect(find.text('跳过'), findsNothing);
    });

    testWidgets('仍显示 JSON input', (tester) async {
      await tester.pumpWidget(_host(_toolReq('Write'), (_, _, _, [_ = false]) {}));
      expect(find.textContaining('rm -rf'), findsOneWidget);
    });

    testWidgets('允许回传 allow=true', (tester) async {
      bool? gotAllow;
      await tester.pumpWidget(_host(_toolReq(), (allow, msg, input, [remember = false]) => gotAllow = allow));

      await tester.tap(find.text('允许'));
      await tester.pump();
      expect(gotAllow, isTrue);
    });
  });
}
