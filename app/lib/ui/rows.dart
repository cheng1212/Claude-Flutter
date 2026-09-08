// 聊天行渲染:typed ChatRow → widget。流式 append 只重排本行(MemoMarkdown)。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../state/reducer.dart';
import '../theme.dart';

/// 统一入口:按行类型分发。
Widget buildChatRow(ChatRow row) {
  return switch (row) {
    UserRow() => UserBubble(row: row),
    TextRow() => AssistantBlock(text: row.content),
    ThinkingRow() => ReasoningCard(text: row.content),
    ToolRow() => ToolCallCard(row: row),
    ErrorRow() => ErrorBlock(content: row.content, neutral: row.neutral),
  };
}

/// data URI 缩略图:data: scheme 移动端 Image.network 拉不到,解 base64 走内存。
/// 解不开(坏图)给占位图标,不让气泡崩。聊天页预览条与用户气泡共用。
Widget chatImageThumb(String uri, {double size = 64}) {
  final Uint8List? bytes = _tryDecodeDataUri(uri);
  if (bytes == null) {
    return Container(
      width: size,
      height: size,
      color: ZT.line,
      alignment: Alignment.center,
      child: Icon(Icons.broken_image_rounded, size: 20, color: ZT.inkSoft),
    );
  }
  return Image.memory(bytes, width: size, height: size, fit: BoxFit.cover, gaplessPlayback: true);
}

Uint8List? _tryDecodeDataUri(String uri) {
  final match = RegExp(r'^data:image/[^;]+;base64,(.+)$').firstMatch(uri);
  if (match == null) return null;
  try {
    return base64Decode(match.group(1)!);
  } on FormatException {
    return null;
  }
}

// ------------------------------------------------------------- memoized md

/// 流式预览用:未闭合的代码围栏自动补上闭合行,只作用于渲染文本、不改动原文本。
/// 没有这步,流式中途 ``` 刚输出还没等到闭合行的几十秒里,后续正文会被
/// markdown 包整体当成代码块渲染,视觉上像整条回复"糊"了。
/// 规则:逐行识别 ```/~~~ 围栏标记(同字符、不少于开栏长度才闭合),
/// 结束时若仍在栏内,补一行与开栏同字符的闭合标记。
String balanceFences(String src) {
  final lines = src.split('\n');
  String? open; // 开栏字符(``` 或 ~~~)
  int openLen = 0;
  for (final line in lines) {
    final m = RegExp(r'^\s{0,3}(`{3,}|~{3,})').firstMatch(line);
    if (m == null) continue;
    final marker = m.group(1)!;
    final ch = marker[0];
    if (open == null) {
      open = ch;
      openLen = marker.length;
    } else if (ch == open && marker.length >= openLen) {
      open = null; // 同字符且够长 → 闭合
    }
  }
  if (open == null) return src;
  return '$src\n${open * 3}';
}

/// MarkdownBody 的记忆化包装:文本没变就不重排(流式 append 只重排本行)。
/// [streaming] 为 true 时(回复还在吐字)重排节流到 200ms 一帧——长回复尾部
/// 全量 parse 是 O(n),每个 delta 都重排会打满 UI 线程;流式结束翻 false 时
/// 绕过节流立即终渲染,不丢尾字。
class MemoMarkdown extends StatefulWidget {
  final String text;
  final TextStyle? baseStyle;
  final bool streaming;

  const MemoMarkdown({super.key, required this.text, this.baseStyle, this.streaming = false});

  /// 测试 seam:可注入假时钟(ws.dart clock 同款手法),单测里推动节流窗口。
  static int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// 测试观察点:真实发生 Markdown parse 的次数(缓存命中不计数)。
  static int parseCount = 0;

  @override
  State<MemoMarkdown> createState() => _MemoMarkdownState();
}

class _MemoMarkdownState extends State<MemoMarkdown> {
  String? _built;
  Widget? _cached;
  int _lastBuildAtMs = 0;
  static const _throttleMs = 200;

  @override
  void didUpdateWidget(covariant MemoMarkdown old) {
    super.didUpdateWidget(old);
    if (_built != null && _built == widget.text && old.streaming == widget.streaming) return;
    if (widget.streaming &&
        _built != null &&
        MemoMarkdown.nowMs() - _lastBuildAtMs < _throttleMs) {
      return; // 节流窗口内沿用旧缓存,下一批 delta 到达时再重排
    }
    _built = null;
    _cached = null;
  }

  @override
  Widget build(BuildContext context) {
    if (_cached != null) return _cached!;
    _built = widget.text;
    _lastBuildAtMs = MemoMarkdown.nowMs();
    MemoMarkdown.parseCount++;
    _cached = MarkdownBody(
      data: widget.streaming ? balanceFences(widget.text) : widget.text,
      selectable: true,
      softLineBreak: true,
      builders: {'pre': _CodeBlockBuilder()},
      styleSheet: MarkdownStyleSheet(
        p: widget.baseStyle ??
            TextStyle(fontSize: 14, height: 1.5, color: ZT.ink, fontFamily: ZT.mono),
        h1: TextStyle(
            fontSize: 19, fontWeight: FontWeight.w800, color: ZT.ink, fontFamily: ZT.mono),
        h2: TextStyle(
            fontSize: 17, fontWeight: FontWeight.w800, color: ZT.ink, fontFamily: ZT.mono),
        h3: TextStyle(
            fontSize: 15.5, fontWeight: FontWeight.w700, color: ZT.ink, fontFamily: ZT.mono),
        code: TextStyle(
          fontSize: 12.5,
          fontFamily: ZT.mono,
          backgroundColor: ZT.bg,
          color: ZT.primaryDeep,
        ),
        codeblockDecoration: BoxDecoration(
          color: ZT.bg,
          borderRadius: BorderRadius.circular(ZT.radius),
          border: Border.all(width: 1.2, color: ZT.edge),
        ),
        codeblockPadding: const EdgeInsets.all(10),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(width: 3, color: ZT.primary)),
          color: ZT.surface,
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
        listBullet: TextStyle(
            fontSize: 14, height: 1.5, color: ZT.ink, fontFamily: ZT.mono),
        tableBorder: TableBorder.all(width: 1, color: ZT.line),
        a: TextStyle(color: ZT.primaryDeep, fontWeight: FontWeight.w700),
      ),
    );
    return _cached!;
  }
}

/// 代码块 builder,挂在 'pre' 标签上:顶部语言标签 + 复制按钮,正文横向滚动。
/// visitText 返回 null 避免默认路径重复渲染正文。
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) => null;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final classValue = element.attributes['class'] ?? '';
    final lang = RegExp(r'language-([\w+#.-]+)').firstMatch(classValue)?.group(1) ?? '';
    final code = element.textContent.replaceFirst(RegExp(r'\n$'), '');
    return _CodeBlock(code: code, language: lang);
  }
}

class _CodeBlock extends StatefulWidget {
  final String code;
  final String language;

  const _CodeBlock({required this.code, required this.language});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;
  Timer? _resetTimer;

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(width: 1, color: ZT.line)),
          ),
          padding: const EdgeInsets.fromLTRB(4, 0, 2, 0),
          child: Row(children: [
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.language.isEmpty ? '代码' : widget.language,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                  color: ZT.inkFaint,
                ),
              ),
            ),
            InkWell(
              borderRadius: BorderRadius.circular(3),
              onTap: _copy,
              child: Padding(
                padding: const EdgeInsets.all(6),
                child: Icon(
                  _copied ? Icons.check_rounded : Icons.content_copy_rounded,
                  size: 15,
                  color: _copied ? ZT.aqua : ZT.inkFaint,
                ),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.all(10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              widget.code,
              style: TextStyle(
                  fontSize: 12, height: 1.55, fontFamily: ZT.mono, color: ZT.ink),
            ),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------------- rows

/// 用户消息:右侧亮绿气泡;pending 是还没被服务器确认的乐观行。
class UserBubble extends StatelessWidget {
  final UserRow row;

  const UserBubble({super.key, required this.row});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Opacity(
        opacity: row.pending ? 0.72 : 1,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82),
          margin: const EdgeInsets.only(top: 8, left: 44),
          padding: const EdgeInsets.fromLTRB(13, 9, 13, 10),
          decoration: ShapeDecoration(
            color: ZT.ink,
            shadows: ZT.hard(dx: 2.5, dy: 2.5, color: ZT.ink.withValues(alpha: 0.28)),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.only(
                topLeft: Radius.circular(ZT.radius),
                topRight: Radius.circular(4),
                bottomLeft: Radius.circular(ZT.radius),
                bottomRight: Radius.circular(ZT.radius),
              ),
              side: BorderSide(width: 1.4, color: ZT.primary),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (row.images.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final uri in row.images)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: chatImageThumb(uri),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              if (row.content.isNotEmpty)
                SelectableText(
                  row.content,
                  style: TextStyle(
                      fontSize: 14, height: 1.45, color: ZT.onInk, fontFamily: ZT.mono),
                ),
              if (row.pending) ...[
                const SizedBox(height: 4),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                        strokeWidth: 1.6, color: ZT.onInk),
                  ),
                  const SizedBox(width: 5),
                  Text('发送中',
                      style: TextStyle(
                          fontSize: 10, color: ZT.onInk.withValues(alpha: 0.8))),
                ]),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 助手回复:Markdown;空文本不占位。
class AssistantBlock extends StatelessWidget {
  final String text;

  const AssistantBlock({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 10),
      child: MemoMarkdown(text: text),
    );
  }
}

/// 思考过程:紫色折叠卡。
class ReasoningCard extends StatefulWidget {
  final String text;

  const ReasoningCard({super.key, required this.text});

  @override
  State<ReasoningCard> createState() => _ReasoningCardState();
}

class _ReasoningCardState extends State<ReasoningCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final text = widget.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8, right: 24),
      decoration: BoxDecoration(
        color: ZT.surface,
        borderRadius: BorderRadius.circular(ZT.radius),
        border: Border.all(width: 1.2, color: ZT.grape.withValues(alpha: 0.5)),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  PulseDot(color: ZT.grape, size: 5),
                  const SizedBox(width: 6),
                  Text('思考过程',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: ZT.grape,
                        letterSpacing: 0.4,
                      )),
                  const Spacer(),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 16, color: ZT.inkFaint),
                ]),
                if (_open)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      text,
                      style: TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: ZT.inkSoft,
                          fontStyle: FontStyle.italic,
                          fontFamily: ZT.mono),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11.5,
                          color: ZT.inkFaint,
                          fontStyle: FontStyle.italic,
                          fontFamily: ZT.mono),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 工具调用:折叠卡;运行中转圈,失败红勾,完成青勾。
class ToolCallCard extends StatefulWidget {
  final ToolRow row;

  const ToolCallCard({super.key, required this.row});

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final streaming = row.result == null;
    final failed = row.result?.isError ?? false;
    final input = _prettyInput(row.toolInput);
    final output = row.result?.content ?? '';
    final accent = failed ? ZT.rose : (streaming ? ZT.primary : ZT.aqua);

    return Container(
      margin: const EdgeInsets.only(top: 8, right: 20),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shadows: ZT.hard(dx: 2, dy: 2, color: ZT.ink.withValues(alpha: 0.16)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.3, color: accent),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  if (streaming)
                    SizedBox(
                      width: 11,
                      height: 11,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: ZT.primary),
                    )
                  else
                    Icon(
                      failed ? Icons.close_rounded : Icons.check_rounded,
                      size: 13,
                      color: accent,
                      weight: 3,
                    ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      row.toolName.isEmpty ? '工具' : row.toolName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                        color: accent == ZT.aqua ? ZT.ink : accent,
                        fontFamily: ZT.mono,
                      ),
                    ),
                  ),
                  if (streaming) ...[
                    _ElapsedTicker(row.startedAt),
                    const SizedBox(width: 6),
                  ],
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 15, color: ZT.inkFaint),
                ]),
                if (!_open && input.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: Text(
                      input.trim().split('\n').first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11,
                          fontFamily: ZT.mono,
                          color: ZT.inkFaint),
                    ),
                  ),
                if (_open) ...[
                  if (input.trim().isNotEmpty) _MonoSection(title: '输入', body: input),
                  if (output.trim().isNotEmpty)
                    _MonoSection(title: '输出', body: output),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _prettyInput(Map<String, dynamic> input) {
    if (input.isEmpty) return '';
    final one = input['command'] ?? input['file_path'] ?? input['path'] ?? input['pattern'] ?? input['prompt'];
    if (one is String && one.isNotEmpty) return one;
    try {
      return const JsonEncoder.withIndent('  ').convert(input);
    } on Object {
      return '$input';
    }
  }
}

/// 运行中工具卡的走秒:数字在跳 = 命令还活着。长命令(如 flutter build)静默几分钟,
/// 没有它看起来就像卡死了。每秒 setState 一次,仅 streaming 期间挂载。
class _ElapsedTicker extends StatefulWidget {
  final DateTime? startedAt;
  const _ElapsedTicker(this.startedAt);

  @override
  State<_ElapsedTicker> createState() => _ElapsedTickerState();
}

class _ElapsedTickerState extends State<_ElapsedTicker> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.startedAt;
    if (start == null) return const SizedBox.shrink();
    final d = DateTime.now().difference(start);
    String two(int n) => n.toString().padLeft(2, '0');
    final text = d.inHours > 0
        ? '${d.inHours}:${two(d.inMinutes.remainder(60))}:${two(d.inSeconds.remainder(60))}'
        : '${two(d.inMinutes)}:${two(d.inSeconds.remainder(60))}';
    return Text('已运行 $text',
        style: TextStyle(
            fontSize: 10.5, fontFamily: ZT.mono, color: ZT.primary));
  }
}

class _MonoSection extends StatelessWidget {
  final String title;
  final String body;

  const _MonoSection({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                  color: ZT.inkFaint)),
          const SizedBox(height: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: SelectableText(
                body,
                style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    fontFamily: ZT.mono,
                    color: ZT.inkSoft),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 错误行:红字块;已知可恢复的中断提示(neutral)用琥珀降噪,不和真错误一个观感。
class ErrorBlock extends StatelessWidget {
  final String content;
  final bool neutral;

  const ErrorBlock({super.key, required this.content, this.neutral = false});

  @override
  Widget build(BuildContext context) {
    final color = neutral ? ZT.lemon : ZT.rose;
    return Container(
      margin: const EdgeInsets.only(top: 8, right: 20),
      padding: const EdgeInsets.all(10),
      decoration: ShapeDecoration(
        color: color.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.3, color: color),
        ),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(neutral ? Icons.info_outline_rounded : Icons.error_outline_rounded,
            size: 14, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: SelectableText(
            content,
            style: TextStyle(
                fontSize: 12.5, height: 1.45, color: color, fontFamily: ZT.mono),
          ),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------- plan

class PlanStep {
  final String content;
  final String status;
  PlanStep({required this.content, this.status = 'pending'});
  bool get completed => status == 'completed' || status == 'done';
  bool get inProgress => status == 'in_progress' || status == 'active';
}

/// 从工具行推导计划步骤:优先折叠任务工具(TaskCreate/TaskUpdate/TaskList,
/// 增量状态,面板实时反映 agent 干到哪一步);没有任务工具时退回 TodoWrite 类
/// 一次性快照(update_plan / TodoWrite / ExitPlanMode),取最近一次调用。
List<PlanStep>? derivePlanSteps(List<ChatRow> rows) {
  return deriveTaskSteps(rows) ?? _todoSnapshotSteps(rows);
}

List<PlanStep>? _todoSnapshotSteps(List<ChatRow> rows) {
  // 显式列举计划类工具:contains('plan') 这类模糊匹配会把 ExitPlanMode 等
  // 名字带 plan 的无关工具误认进来。
  const planTools = {'todowrite', 'updateplan', 'exitplanmode'};
  for (final row in rows.reversed) {
    if (row is! ToolRow) continue;
    final name = row.toolName.toLowerCase().replaceAll('_', '');
    if (!planTools.contains(name)) continue;
    final parsed = _parsePlanValue(row.toolInput);
    if (parsed != null && parsed.isNotEmpty) return parsed;
  }
  return null;
}

class _TaskItem {
  String subject;
  String status;
  _TaskItem(this.subject, this.status);
}

/// 折叠任务工具行 → 实时任务清单。id 只在 tool_result 里(TaskCreate 返回分配的
/// id),解析不出就按创建序号占位——进度面板不追求台账级精确,够看进度就行。
List<PlanStep>? deriveTaskSteps(List<ChatRow> rows) {
  final order = <String>[];
  final byId = <String, _TaskItem>{};
  void put(String id, String subject, String status) {
    final existing = byId[id];
    if (existing == null) {
      order.add(id);
      byId[id] = _TaskItem(subject, status);
    } else {
      if (subject.isNotEmpty) existing.subject = subject;
      if (status.isNotEmpty) existing.status = status;
    }
  }

  for (final row in rows) {
    if (row is! ToolRow) continue;
    final name = row.toolName.toLowerCase().replaceAll('_', '');
    if (name == 'taskcreate') {
      final subject = '${row.toolInput['subject'] ?? ''}'.trim();
      if (subject.isEmpty) continue;
      put(_idFromResult(row.result?.content) ?? '${order.length + 1}', subject, 'pending');
    } else if (name == 'taskupdate') {
      final id = '${row.toolInput['taskId'] ?? row.toolInput['id'] ?? ''}'.trim();
      if (id.isEmpty) continue;
      put(id, '${row.toolInput['subject'] ?? ''}'.trim(), '${row.toolInput['status'] ?? ''}'.trim());
    } else if (name == 'tasklist') {
      // TaskList 回全量快照:解析得动就整体校正一遍,解析不动保留已有折叠
      final items = _tasksFromResult(row.result?.content);
      if (items == null) continue;
      order.clear();
      byId.clear();
      for (final it in items) {
        put(it.$1, it.$2, it.$3);
      }
    }
  }
  if (order.isEmpty) return null;
  return [for (final id in order) PlanStep(content: byId[id]!.subject, status: byId[id]!.status)];
}

/// 从 TaskCreate 的 tool_result 里抠分配的 id:先按 JSON(本 harness 返回 {"id":..}),
/// 退化到第一个数字。解析不出 → null(调用方用序号占位)。
String? _idFromResult(String? content) {
  if (content == null || content.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException {
    decoded = null;
  }
  if (decoded is Map) {
    final id = decoded['id'] ?? decoded['taskId'];
    if (id != null) return '$id';
    final task = decoded['task'];
    if (task is Map && task['id'] != null) return '${task['id']}';
  }
  return RegExp(r'(\d+)').firstMatch(content)?.group(1);
}

/// 从 TaskList 的 tool_result 解析全量 (id, subject, status);解析不动返回 null。
List<(String, String, String)>? _tasksFromResult(String? content) {
  if (content == null || content.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(content);
  } on FormatException {
    return null;
  }
  if (decoded is Map && decoded['tasks'] is List) decoded = decoded['tasks'];
  if (decoded is! List) return null;
  final out = <(String, String, String)>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final id = '${item['id'] ?? ''}'.trim();
    final subject = '${item['subject'] ?? item['content'] ?? item['title'] ?? ''}'.trim();
    if (id.isEmpty || subject.isEmpty) continue;
    out.add((id, subject, '${item['status'] ?? 'pending'}'));
  }
  return out.isEmpty ? null : out;
}

List<PlanStep>? _parsePlanValue(Object? value) {
  Object? decoded = value;
  if (decoded is String) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return null;
    }
  }
  if (decoded is Map) {
    for (final key in const ['todos', 'plan', 'plans', 'steps', 'items']) {
      final result = _parsePlanValue(decoded[key]);
      if (result != null) return result;
    }
    return null;
  }
  if (decoded is! List) return null;
  final steps = <PlanStep>[];
  for (final item in decoded) {
    if (item is String && item.trim().isNotEmpty) {
      steps.add(PlanStep(content: item.trim()));
    } else if (item is Map) {
      final content =
          '${item['content'] ?? item['step'] ?? item['title'] ?? item['text'] ?? item['activeForm'] ?? item['label'] ?? ''}'
              .trim();
      if (content.isEmpty) continue;
      final status =
          '${item['status'] ?? (item['completed'] == true || item['done'] == true ? 'completed' : 'pending')}';
      steps.add(PlanStep(content: content, status: status));
    }
  }
  return steps.isEmpty ? null : steps;
}

/// 执行计划面板(可折叠):进度条 + 步骤清单。
class PlanPanel extends StatefulWidget {
  final List<PlanStep> steps;

  const PlanPanel({super.key, required this.steps});

  @override
  State<PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<PlanPanel> {
  bool _open = true;

  @override
  Widget build(BuildContext context) {
    final completed = widget.steps.where((s) => s.completed).length;
    final progress =
        widget.steps.isEmpty ? 0.0 : completed / widget.steps.length;
    final current = widget.steps.where((s) => s.inProgress).toList();
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shadows: ZT.hard(dx: 3, dy: 3, color: ZT.ink.withValues(alpha: 0.2)),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.6),
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.account_tree_rounded, size: 16, color: ZT.primary),
                  const SizedBox(width: 7),
                  Text('执行计划 · $completed/${widget.steps.length}',
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          fontFamily: ZT.mono)),
                  const Spacer(),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      size: 17, color: ZT.inkFaint),
                ]),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 5,
                    backgroundColor: ZT.line,
                    color: ZT.primary,
                  ),
                ),
                if (!_open && current.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text('▶ ${current.first.content}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: ZT.primary)),
                  ),
                if (_open)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Column(
                      children: [
                        for (final step in widget.steps)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 18,
                                  child: step.completed
                                      ? Icon(Icons.check_box_rounded,
                                          size: 15, color: ZT.primary)
                                      : step.inProgress
                                          ? Icon(
                                              Icons.indeterminate_check_box_rounded,
                                              size: 15,
                                              color: ZT.lemon)
                                          : Icon(Icons.check_box_outline_blank_rounded,
                                              size: 15,
                                              color:
                                                  ZT.inkFaint.withValues(alpha: 0.6)),
                                ),
                                const SizedBox(width: 7),
                                Expanded(
                                  child: Text(
                                    step.content,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      height: 1.4,
                                      fontFamily: ZT.mono,
                                      color: step.completed
                                          ? ZT.inkFaint
                                          : ZT.ink,
                                      decoration: step.completed
                                          ? TextDecoration.lineThrough
                                          : null,
                                      fontWeight: step.inProgress
                                          ? FontWeight.w700
                                          : FontWeight.w400,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
