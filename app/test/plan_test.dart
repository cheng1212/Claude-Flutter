import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/state/reducer.dart';
import 'package:zcode_app/ui/rows.dart';

ToolRow _tool(String name, Map<String, dynamic> input, {String? result}) => ToolRow(
      toolId: 't-$name-${input.hashCode}',
      toolName: name,
      toolInput: input,
      result: result == null ? null : ToolResult(content: result, isError: false),
    );

void main() {
  test('TaskCreate/TaskUpdate 增量折叠:建单、推进、完成,面板实时反映', () {
    final rows = <ChatRow>[
      _tool('TaskCreate', {'subject': '搭代理模块'}, result: '{"id":"36"}'),
      _tool('TaskCreate', {'subject': '接模型条目'}, result: '{"id":"37"}'),
      _tool('TaskUpdate', {'taskId': '36', 'status': 'in_progress'}),
      _tool('TaskCreate', {'subject': '收尾构建'}, result: '{"id":"41"}'),
      _tool('TaskUpdate', {'taskId': '36', 'status': 'completed'}),
      _tool('TaskUpdate', {'taskId': '41', 'status': 'in_progress'}),
    ];
    final steps = derivePlanSteps(rows)!;
    expect(steps.length, 3);
    expect(steps[0].content, '搭代理模块');
    expect(steps[0].completed, isTrue); // TaskUpdate completed 覆盖创建时的 pending
    expect(steps[1].status, 'pending'); // 没动过:保持 pending
    expect(steps[2].inProgress, isTrue);
  });

  test('TaskCreate 结果解析不出 id → 按创建序占位,后续 TaskUpdate 按号对上', () {
    final rows = <ChatRow>[
      _tool('TaskCreate', {'subject': '第一件事'}),
      _tool('TaskCreate', {'subject': '第二件事'}),
      _tool('TaskUpdate', {'taskId': '2', 'status': 'completed'}),
    ];
    final steps = derivePlanSteps(rows)!;
    expect(steps.length, 2);
    expect(steps[1].completed, isTrue);
    expect(steps[0].completed, isFalse);
    expect(steps[0].inProgress, isFalse);
  });

  test('TaskList 快照整体校正折叠状态', () {
    final rows = <ChatRow>[
      _tool('TaskCreate', {'subject': '旧标题'}, result: '{"id":"1"}'),
      _tool('TaskList', {}),
    ];
    // 快照解析失败(非 JSON)→ 保留折叠
    expect(derivePlanSteps(rows)!.single.content, '旧标题');
    rows[1] = _tool('TaskList', {}, result: '{"tasks":[{"id":"1","subject":"新标题","status":"completed"}]}');
    final corrected = derivePlanSteps(rows)!;
    expect(corrected.single.content, '新标题');
    expect(corrected.single.completed, isTrue);
  });

  test('没有任务工具 → 退回 TodoWrite 快照;两者皆无 → null', () {
    final todo = <ChatRow>[
      _tool('TodoWrite', {
        'todos': [
          {'content': '甲', 'status': 'completed'},
          {'content': '乙', 'status': 'in_progress'},
        ],
      }),
    ];
    final steps = derivePlanSteps(todo)!;
    expect(steps.length, 2);
    expect(steps[0].completed, isTrue);

    expect(derivePlanSteps(<ChatRow>[const TextRow('普通聊天')]), isNull);
  });
}
