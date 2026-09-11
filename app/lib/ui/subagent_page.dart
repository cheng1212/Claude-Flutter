// 子代理只读转录页:虚拟会话视图——像会话一样打开,但不能发消息
// (host 没有给运行中子代理注入消息的口子,只有模型能 SendMessage 找它)。
import 'package:flutter/material.dart';

import '../state/zapp.dart';
import '../theme.dart';

class SubagentTranscriptPage extends StatefulWidget {
  final ZApp app;
  final String sessionId;
  final String agentId;
  final String title;

  const SubagentTranscriptPage({
    super.key,
    required this.app,
    required this.sessionId,
    required this.agentId,
    required this.title,
  });

  @override
  State<SubagentTranscriptPage> createState() => _SubagentTranscriptPageState();
}

class _SubagentTranscriptPageState extends State<SubagentTranscriptPage> {
  late final Future<List<Map<String, dynamic>>> _future =
      widget.app.subagentMessages(widget.sessionId, widget.agentId);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: Row(children: [
          Icon(Icons.hub_rounded, size: 17, color: ZT.grape),
          const SizedBox(width: 8),
          Expanded(
            child: Text(widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: '子代理视图只读:消息由父会话派发,不能在这里输入',
            child: Icon(Icons.visibility_outlined, size: 16, color: ZT.inkSoft),
          ),
        ]),
      ),
      body: SafeArea(
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _future,
          builder: (ctx, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            }
            if (snap.hasError) {
              // 拉取失败不能和"转录为空"混同:一个是没数据,一个是网络/服务出错
              return Padding(
                padding: EdgeInsets.all(24),
                child: Text('转录拉取失败: ${snap.error}',
                    style: TextStyle(fontSize: 12.5, color: ZT.rose, height: 1.6)),
              );
            }
            final events = snap.data ?? const <Map<String, dynamic>>[];
            if (events.isEmpty) {
              return Padding(
                padding: EdgeInsets.all(24),
                child: Text('转录为空(子代理尚未产出内容,或转录已被清理)。',
                    style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6)),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 20),
              itemCount: events.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _bubble(events[i]),
            );
          },
        ),
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> ev) {
    final kind = '${ev['kind']}';
    if (kind == 'thinking') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 7),
          decoration: ShapeDecoration(
            color: ZT.grape.withValues(alpha: 0.07),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: Text('${ev['content'] ?? ''}',
              style: TextStyle(fontSize: 11.5, fontStyle: FontStyle.italic, color: ZT.grape, height: 1.5)),
        ),
      );
    }
    if (kind == 'tool_use') {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: ShapeDecoration(
            color: ZT.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8), side: ZT.inkSide(w: 1, color: ZT.edge)),
          ),
          child: Text('⚙ ${ev['toolName'] ?? ''}',
              style: TextStyle(fontSize: 11, fontFamily: ZT.mono, color: ZT.inkSoft)),
        ),
      );
    }
    if (kind == 'text') {
      final isUser = '${ev['role'] ?? ''}' == 'user';
      return Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.86),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: const EdgeInsets.fromLTRB(11, 8, 11, 9),
          decoration: ShapeDecoration(
            color: isUser ? ZT.primary.withValues(alpha: 0.1) : ZT.surface,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: ZT.inkSide(w: isUser ? 1.2 : 1, color: isUser ? ZT.primary.withValues(alpha: 0.5) : ZT.edge)),
          ),
          child: SelectableText('${ev['content'] ?? ''}',
              style: TextStyle(fontSize: 13, height: 1.55, color: ZT.ink)),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}
