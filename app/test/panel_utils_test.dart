import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/state/reducer.dart';
import 'package:zcode_app/panel_utils.dart';

ChatRow tool(String id, String name, Map<String, dynamic> input, {String? parent, String? resultContent, bool resultError = false}) =>
    ToolRow(
      toolId: id,
      toolName: name,
      toolInput: input,
      parentToolUseId: parent,
      result: resultContent == null ? null : ToolResult(content: resultContent, isError: resultError),
    );

void main() {
  group('trimRecent · 列表收口', () {
    test('已完成的超过 keep → 只留最近 keep 条,运行中的全留', () {
      final items = <({String id, bool running})>[
        (id: 'a', running: true), // 运行中,永远留
        for (var i = 0; i < 20; i++) (id: 'd$i', running: false), // 时间倒序:d0 最新
      ];
      final r = trimRecent(items, isRunning: (x) => x.running, keep: 15);
      expect(r.hidden, 5);
      expect(r.shown.length, 16); // 1 运行中 + 15 完成
      expect(r.shown.first.id, 'a');
      expect(r.shown[1].id, 'd0'); // 最近的在最前
      expect(r.shown.any((x) => x.id == 'd19'), isFalse); // 最旧的被折叠
    });

    test('未超上限 → 原样全显示,不折叠', () {
      final items = <({String id, bool running})>[
        for (var i = 0; i < 10; i++) (id: 'd$i', running: false),
      ];
      final r = trimRecent(items, isRunning: (x) => x.running, keep: 15);
      expect(r.shown.length, 10);
      expect(r.hidden, 0);
    });

    test('全是运行中 → 一条不折(哪怕超过 keep)', () {
      final items = <({String id, bool running})>[
        for (var i = 0; i < 30; i++) (id: 'r$i', running: true),
      ];
      final r = trimRecent(items, isRunning: (x) => x.running, keep: 15);
      expect(r.shown.length, 30);
      expect(r.hidden, 0);
    });

    test('边界:刚好等于 keep 不折叠;空列表安全', () {
      final exact = <({String id, bool running})>[
        for (var i = 0; i < 15; i++) (id: 'd$i', running: false),
      ];
      expect(trimRecent(exact, isRunning: (x) => x.running, keep: 15).hidden, 0);
      expect(trimRecent(<({String id, bool running})>[], isRunning: (x) => x.running).hidden, 0);
    });
  });

  group('deriveSubagents', () {
    test('Task 工具行即子代理;嵌套活动按 parentToolUseId 计数', () {
      final rows = <ChatRow>[
        tool('t0', 'Bash', {'command': 'ls'}),
        tool('task-1', 'Task', {'description': '查文档', 'prompt': '查一下'}),
        tool('n1', 'Read', {'path': '/a'}, parent: 'task-1'),
        tool('n2', 'Grep', {'pattern': 'x'}, parent: 'task-1'),
      ];
      final subs = deriveSubagents(rows);
      expect(subs, hasLength(1));
      expect(subs[0].description, '查文档');
      expect(subs[0].activityCount, 2);
      expect(subs[0].done, isFalse);
    });

    test('带出模型与子代理类型(用户要盯"子代理用了哪个模型")', () {
      final rows = <ChatRow>[
        tool('task-1', 'Task', {
          'description': '查文档',
          'prompt': '查一下',
          'model': 'opus-5',
          'subagent_type': 'general-purpose',
        }),
      ];
      final subs = deriveSubagents(rows);
      expect(subs.single.requestedModel, 'opus-5');
      expect(subs.single.agentType, 'general-purpose');
    });

    test('未指定 model → 空串(表示继承主模型,面板显示「跟随本会话」)', () {
      final rows = <ChatRow>[
        tool('task-1', 'Task', {'description': '查一下', 'prompt': 'x'}),
      ];
      expect(deriveSubagents(rows).single.requestedModel, '');
      expect(deriveSubagents(rows).single.agentType, '');
    });
    test('子代理结果到达即 done', () {
      final rows = <ChatRow>[
        tool('task-1', 'Task', {'description': '查文档'}),
        tool('n1', 'Read', {'path': '/a'}, parent: 'task-1'),
      ];
      final withResult = <ChatRow>[
        ...rows,
        tool('task-1', 'Task', {'description': '查文档'}, resultContent: '结论'),
      ];
      expect(deriveSubagents(rows)[0].done, isFalse);
      expect(deriveSubagents(withResult)[0].done, isTrue);
    });
    test('非 Task 工具不算子代理;空列表为空', () {
      expect(deriveSubagents([tool('t', 'Bash', {'command': 'x'})]), isEmpty);
      expect(deriveSubagents(const []), isEmpty);
    });
  });

  group('deriveBackgrounds', () {
    test('run_in_background 的 Bash 登记;结果到达即完成并带输出', () {
      final rows = <ChatRow>[
        tool('bg1', 'Bash', {'command': 'flutter build', 'run_in_background': true}),
      ];
      final b = deriveBackgrounds(rows);
      expect(b, hasLength(1));
      expect(b[0].command, 'flutter build');
      expect(b[0].running, isTrue);
      // reducer 语义:tool_result 就地替换同 toolId 的行(不是追加)
      final withResult = <ChatRow>[
        tool('bg1', 'Bash', {'command': 'flutter build', 'run_in_background': true}, resultContent: 'Done in 60s'),
      ];
      final b2 = deriveBackgrounds(withResult);
      expect(b2[0].running, isFalse);
      expect(b2[0].outputTail, contains('Done in 60s'));
    });
    test('前台 Bash 不进后台面板', () {
      expect(deriveBackgrounds([tool('f', 'Bash', {'command': 'ls'})]), isEmpty);
    });
  });

  group('buildReferenceMessage', () {
    test('短内容原样引用', () {
      final m = buildReferenceMessage(fromTitle: '旧会话', markdown: '上下文内容', head: 4000, tail: 8000);
      expect(m, contains('旧会话'));
      expect(m, contains('上下文内容'));
    });
    test('超长内容截头留尾', () {
      final long = 'H' * 5000 + 'MIDDLE' * 3000 + 'T' * 9000;
      final m = buildReferenceMessage(fromTitle: 'x', markdown: long, head: 4000, tail: 8000);
      expect(m.contains('H' * 100), isTrue);
      expect(m.contains('T' * 100), isTrue);
      expect(m.contains('MIDDLE'), isFalse);
      expect(m.length, lessThan(long.length));
    });
  });
}
