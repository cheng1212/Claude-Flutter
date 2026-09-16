// 复制动作层(纯函数)测试:菜单项裁剪、复制内容口径、markdown 剥离、多选拼接。
// 这一层不碰 widget,所以断言可以直接打在字符串上,不用起 UI。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/core/markdown_plain.dart';
import 'package:zcode_app/state/reducer.dart';
import 'package:zcode_app/ui/row_actions.dart';

void main() {
  group('markdownToPlain', () {
    test('剥标题/加粗/行内码/链接,留正文与原意', () {
      const src = '# 标题\n\n这是**粗体**和`代码`,见[文档](https://x/y)。';
      final out = markdownToPlain(src);
      expect(out, '标题\n\n这是粗体和代码,见文档。');
    });

    test('图片只留 alt、删除线去掉、引用去 >、无序列表转 •', () {
      const src = '![示意图](img.png)\n\n> 引用一句\n\n- 甲\n- 乙\n\n~~划掉~~';
      final out = markdownToPlain(src);
      expect(out, contains('示意图'));
      expect(out, contains('引用一句'));
      expect(out, contains('• 甲'));
      expect(out, contains('划掉'));
      expect(out, isNot(contains('img.png')));
      expect(out, isNot(contains('~~')));
      expect(out, isNot(contains('>')));
    });

    test('围栏代码块原样保留标记与会话内容(核心约束)', () {
      const src = '看这段:\n\n```bash\n# 这是注释,不是标题\n'
          'echo "**不是加粗**"\n```\n\n完。';
      final out = markdownToPlain(src);
      // 代码正文里的 # 和 ** 一个都不能动
      expect(out, contains('# 这是注释,不是标题'));
      expect(out, contains('echo "**不是加粗**"'));
      // 但围栏标记本身和语言标签要去掉
      expect(out, isNot(contains('```')));
      expect(out, isNot(contains('bash')));
      expect(out, contains('看这段:'));
      expect(out, contains('完。'));
    });

    test('不剥单星号/单下划线:乘号与 snake_case 不能被改坏', () {
      expect(markdownToPlain('算一下 2 * 3 * 4 和 some_var_name'),
          '算一下 2 * 3 * 4 和 some_var_name');
    });

    test('分割线整行丢弃、连续空行折叠', () {
      const src = '甲\n\n\n\n---\n\n乙';
      expect(markdownToPlain(src), '甲\n\n乙');
    });

    test('待办项与有序列表编号保留可读性', () {
      expect(markdownToPlain('1. 第一步\n2. 第二步'), '1. 第一步\n2. 第二步');
    });
  });

  group('rowMenuFor:菜单项按行类型裁剪', () {
    test('用户消息:复制/选择文字/引用发送/多选,没有纯文本项', () {
      final actions = rowMenuFor(const UserRow('你好')).map((m) => m.action).toList();
      expect(actions, [
        RowAction.copyAll,
        RowAction.selectText,
        RowAction.quote,
        RowAction.multiSelect,
      ]);
      expect(actions, isNot(contains(RowAction.copyPlain)));
    });

    test('助手消息:多一项「复制为纯文本」,且复制项写明 Markdown 原文', () {
      final menu = rowMenuFor(const TextRow('**粗**'));
      expect(menu.map((m) => m.action), contains(RowAction.copyPlain));
      expect(menu.firstWhere((m) => m.action == RowAction.copyAll).label,
          '复制 Markdown 原文');
    });

    test('工具行:复制调用/复制输出,没有整条「复制」', () {
      final actions = rowMenuFor(ToolRow(toolId: 't1', toolName: 'Bash', toolInput: const {}))
          .map((m) => m.action)
          .toList();
      expect(actions, contains(RowAction.copyToolInput));
      expect(actions, contains(RowAction.copyToolOutput));
      expect(actions, isNot(contains(RowAction.copyAll)));
    });

    test('思考行与错误行都能复制', () {
      for (final row in <ChatRow>[const ThinkingRow('想了想'), const ErrorRow('炸了')]) {
        expect(rowMenuFor(row).map((m) => m.action), contains(RowAction.copyAll));
      }
    });

    test('每种行都能进多选', () {
      final rows = <ChatRow>[
        const UserRow('u'),
        const TextRow('t'),
        const ThinkingRow('k'),
        ToolRow(toolId: 't1', toolName: 'Bash', toolInput: const {}),
        const ErrorRow('e'),
      ];
      for (final row in rows) {
        expect(rowMenuFor(row).map((m) => m.action), contains(RowAction.multiSelect),
            reason: '${row.runtimeType} 应有「多选」');
      }
    });
  });

  group('copyPayloadFor:复制内容口径', () {
    test('助手消息 复制原文给 markdown,复制为纯文本给剥离后的', () {
      const row = TextRow('# 标题\n**粗**');
      expect(copyPayloadFor(row, RowAction.copyAll), '# 标题\n**粗**');
      expect(copyPayloadFor(row, RowAction.copyPlain), '标题\n粗');
    });

    test('用户消息两种口径都是原文(用户输入本来就没有 markdown 标记)', () {
      const row = UserRow('看下这个');
      expect(copyPayloadFor(row, RowAction.copyAll), '看下这个');
      expect(copyPayloadFor(row, RowAction.copyPlain), '看下这个');
    });

    test('工具行:复制调用给「工具名+入参」,复制输出给结果正文', () {
      final row = ToolRow(
        toolId: 't1',
        toolName: 'Bash',
        toolInput: const {'command': 'ls -la'},
        result: const ToolResult(content: 'file_a\nfile_b', isError: false),
      );
      expect(copyPayloadFor(row, RowAction.copyToolInput), 'Bash\nls -la');
      expect(copyPayloadFor(row, RowAction.copyToolOutput), 'file_a\nfile_b');
    });

    test('工具还没跑完时复制输出给空串(不是 null,调用方按空白拦截)', () {
      final row = ToolRow(toolId: 't1', toolName: 'Bash', toolInput: const {});
      expect(copyPayloadFor(row, RowAction.copyToolOutput), '');
    });

    test('非复制类动作返回 null', () {
      const row = TextRow('x');
      for (final a in [RowAction.selectText, RowAction.quote, RowAction.multiSelect]) {
        expect(copyPayloadFor(row, a), isNull);
      }
    });

    test('选择文字页拿到的是一律纯文本口径', () {
      expect(selectableTextFor(const TextRow('**粗**')), '粗');
      expect(selectableTextFor(const UserRow('原文**保留**')), '原文**保留**');
    });

    test('多参数工具入参按 JSON 缩进(单键命令类只给值)', () {
      expect(prettyToolInput(const {'command': 'ls'}), 'ls');
      expect(prettyToolInput(const {'a': 1, 'b': 2}), contains('"a": 1'));
      expect(prettyToolInput(const {}), '');
    });
  });

  group('composeSelection:多选导出', () {
    test('按传入顺序拼接并带角色前缀', () {
      final out = composeSelection(const [UserRow('问题'), TextRow('回答')]);
      expect(out, '【我】问题\n\n【助手】回答');
    });

    test('助手内容走纯文本口径,贴出去不带 markdown 标记', () {
      final out = composeSelection(const [TextRow('**重点**')]);
      expect(out, '【助手】重点');
    });

    test('空内容行跳过,不留空壳', () {
      final out = composeSelection(const [UserRow('甲'), TextRow('   '), ErrorRow('炸了')]);
      expect(out, '【我】甲\n\n【错误】炸了');
    });

    test('withRole=false 时只拼正文', () {
      expect(composeSelection(const [UserRow('甲'), TextRow('乙')], withRole: false),
          '甲\n\n乙');
    });

    test('工具行连调用一起导出', () {
      final row = ToolRow(toolId: 't1', toolName: 'Read', toolInput: const {'file_path': '/a/b'});
      expect(composeSelection([row]), '【工具】Read\n/a/b');
    });

    test('全空输入返回空串', () {
      expect(composeSelection(const [TextRow('')]), '');
    });
  });
}
