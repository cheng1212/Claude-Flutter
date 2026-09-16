// 长按菜单的动作层:纯函数,不碰 widget。
//
// 「哪一行能复制什么、复制出来是什么」全库只有这一个出处 —— 长按菜单、剪贴板
// 内容、多选导出、「选择文字」二级页都从这里取。单测直接打这几个函数,不用起 UI。
import 'dart:convert';

import '../core/markdown_plain.dart';
import '../state/reducer.dart';

/// 长按菜单动作。跨行类型通用,具体给哪些由 [rowMenuFor] 决定。
enum RowAction {
  copyAll('复制'),
  copyPlain('复制为纯文本'),
  selectText('选择文字'),
  quote('引用发送'),
  multiSelect('多选'),
  copyToolInput('复制调用'),
  copyToolOutput('复制输出');

  final String label;
  const RowAction(this.label);
}

/// 一个菜单项:动作 + 展示文案。
///
/// 文案默认取 [RowAction.label],个别行类型会覆盖 —— 助手消息存的是 markdown
/// 源码,泛泛一个「复制」会让人以为拿到的是渲染后的文字,那里写明「Markdown 原文」。
class RowMenuItem {
  final RowAction action;
  final String label;
  const RowMenuItem(this.action, this.label);
}

/// 该行长按后弹哪些项(顺序 = 展示顺序;多选是模式入口,每种行都给)。
List<RowMenuItem> rowMenuFor(ChatRow row) => switch (row) {
      UserRow() => const [
          RowMenuItem(RowAction.copyAll, '复制'),
          RowMenuItem(RowAction.selectText, '选择文字'),
          RowMenuItem(RowAction.quote, '引用发送'),
          RowMenuItem(RowAction.multiSelect, '多选'),
        ],
      TextRow() => const [
          RowMenuItem(RowAction.copyAll, '复制 Markdown 原文'),
          RowMenuItem(RowAction.copyPlain, '复制为纯文本'),
          RowMenuItem(RowAction.selectText, '选择文字'),
          RowMenuItem(RowAction.quote, '引用发送'),
          RowMenuItem(RowAction.multiSelect, '多选'),
        ],
      ThinkingRow() => const [
          RowMenuItem(RowAction.copyAll, '复制思考'),
          RowMenuItem(RowAction.selectText, '选择文字'),
          RowMenuItem(RowAction.multiSelect, '多选'),
        ],
      ToolRow() => const [
          RowMenuItem(RowAction.copyToolInput, '复制调用'),
          RowMenuItem(RowAction.copyToolOutput, '复制输出'),
          RowMenuItem(RowAction.selectText, '选择文字'),
          RowMenuItem(RowAction.multiSelect, '多选'),
        ],
      ErrorRow() => const [
          RowMenuItem(RowAction.copyAll, '复制'),
          RowMenuItem(RowAction.selectText, '选择文字'),
          RowMenuItem(RowAction.multiSelect, '多选'),
        ],
    };

/// 角色标签:多选导出做前缀、引用发送写进正文。
String rowRoleLabel(ChatRow row) => switch (row) {
      UserRow() => '我',
      TextRow() => '助手',
      ThinkingRow() => '思考',
      ToolRow() => '工具',
      ErrorRow() => '错误',
    };

/// 该动作要复制的内容;null = 这个动作不产出文本([RowAction.selectText] /
/// [RowAction.quote] / [RowAction.multiSelect] 由 UI 自己处理)。
///
/// 与菜单无关:[ToolRow] 菜单里没有 [RowAction.copyPlain],但这里照样能取到
/// 纯文本口径(「选择文字」二级页要用)。
String? copyPayloadFor(ChatRow row, RowAction action) => switch (action) {
      RowAction.copyToolInput => row is ToolRow ? toolCallText(row) : null,
      RowAction.copyToolOutput => row is ToolRow ? (row.result?.content ?? '') : null,
      RowAction.copyAll => rowCopyText(row),
      RowAction.copyPlain => rowCopyText(row, plain: true),
      RowAction.selectText ||
      RowAction.quote ||
      RowAction.multiSelect =>
        null,
    };

/// 「选择文字」二级页里的文本:一律纯文本口径 ——
/// 用户在那个页面里挑出来的东西,贴出去不该还带着 markdown 标记。
String selectableTextFor(ChatRow row) => rowCopyText(row, plain: true);

/// 一行「可复制的正文」:单选复制与多选导出共用同一口径。
/// [plain] = true 时把 markdown 剥成纯文本(只有 [TextRow] 有区别)。
String rowCopyText(ChatRow row, {bool plain = false}) => switch (row) {
      UserRow(:final content) => content,
      TextRow(:final content) => plain ? markdownToPlain(content) : content,
      ThinkingRow(:final content) => content,
      ErrorRow(:final content) => content,
      ToolRow() => toolCallText(row),
    };

/// 工具行的「调用」文本:工具名 + 入参,和卡片上显示的口径一致。
String toolCallText(ToolRow row) {
  final input = prettyToolInput(row.toolInput);
  return input.isEmpty ? row.toolName : '${row.toolName}\n$input';
}

/// 工具入参 → 展示文本:单键命令类(命令/路径/模式/提示词)只给值,
/// 其余按缩进 JSON。从 rows.dart 的卡片里提出来共用,免得两处各写一份。
String prettyToolInput(Map<String, dynamic> input) {
  if (input.isEmpty) return '';
  final one = input['command'] ??
      input['file_path'] ??
      input['path'] ??
      input['pattern'] ??
      input['prompt'];
  if (one is String && one.isNotEmpty) return one;
  try {
    return const JsonEncoder.withIndent('  ').convert(input);
  } on Object {
    return '$input';
  }
}

/// 多选导出:按传入顺序(时间正序)拼接,带角色前缀。
/// 空内容行跳过 —— 导出整段会话时不该留一串空壳。
String composeSelection(List<ChatRow> rows, {bool withRole = true}) {
  final parts = <String>[];
  for (final row in rows) {
    final body = rowCopyText(row, plain: true).trim();
    if (body.isEmpty) continue;
    parts.add(withRole ? '【${rowRoleLabel(row)}】$body' : body);
  }
  return parts.join('\n\n');
}
