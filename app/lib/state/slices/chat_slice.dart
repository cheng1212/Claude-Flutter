// 聊天域切片(T4 最后一块)——第一步:纯函数先行。
// 历史重建/事件转换/审批叠加/实时态叠加:输入输出明确、不碰 ZApp 字段,
// 先期从 zapp.dart 迁入;字段(chat/currentSessionId/historyLoading/_openToken/
// _backfill)与动作(openSession/sendChat/abort)按绞杀者节奏后续迁入本类。
// 语义 1:1 移植自 zapp.dart,除可见性(_ 前缀去除)外零改动。

import 'dart:convert';

import '../reducer.dart';

class ChatSlice {
  ChatSlice._();

  /// 消息页(rows)→ 出站事件列表 + 最大 seq。
  static ({List<Map<String, dynamic>> events, int maxSeq}) histEvents(
      ({List<Map<String, dynamic>> messages, int total}) hist) {
    final events = <Map<String, dynamic>>[];
    var maxSeq = 0;
    for (final row in hist.messages) {
      final ev = rowEvent(row);
      if (ev == null) continue;
      final sq = (row['seq'] as num?)?.toInt() ?? 0;
      ev['seq'] = sq;
      events.add(ev);
      if (sq > maxSeq) maxSeq = sq;
    }
    return (events: events, maxSeq: maxSeq);
  }

  /// 事件列表里的最小 seq(锚点翻页的「更旧」边界);空列表返回 null。
  static int? minSeqOf(List<Map<String, dynamic>> events) {
    int? min;
    for (final e in events) {
      final s = (e['seq'] as num?)?.toInt();
      if (s == null) continue;
      if (min == null || s < min) min = s;
    }
    return min;
  }

  /// 消息行 meta → 出站事件(可能存成 JSON 字符串或已是 Map)。
  static Map<String, dynamic>? rowEvent(Map<String, dynamic> row) {
    final meta = row['meta'];
    if (meta is Map) return meta.cast<String, dynamic>();
    if (meta is String && meta.isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        if (decoded is Map) return decoded.cast<String, dynamic>();
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  /// 排序重放一段事件(REST 按 seq 倒序返回,归约要按时间正序),水位抬到 maxSeq。
  /// 不推断 running:重建的历史最后一条是 text/tool 不代表「正在跑」,
  /// running 只该由 subscribed.isProcessing + 实时终态/开始事件驱动,否则
  /// 重放后若缺 complete(如 reload 重建)会冻结成假「运行中」、按钮卡 STOP。
  static ChatState replay(List<Map<String, dynamic>> events, int maxSeq) {
    events.sort((a, b) =>
        ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0));
    // 共用行缓冲:重建一个 8000 行的会话原来是 O(n²)(每行复制整表),打开要卡几秒
    // (实测 swap 比首屏晚 4.8 秒)。走 sink 后是 O(n)。
    final sink = <ChatRow>[];
    var st = const ChatState();
    for (final e in events) {
      st = applyEvent(st, e, sink: sink);
    }
    // 重建一律从「空闲」起步;真实 running 由随后到达的 subscribed/实时事件设定。
    return ChatState(
      rows: st.rows,
      lastSeq: st.lastSeq > maxSeq ? st.lastSeq : maxSeq,
      streamingText: st.streamingText,
      streamingThinking: st.streamingThinking,
      usage: st.usage,
      pendingPermission: st.pendingPermission,
      upstreamPhase: st.upstreamPhase,
      upstreamAt: st.upstreamAt,
      running: false,
    );
  }

  /// 只换审批卡,不丢瞬态/本地态。
  static ChatState withPermission(ChatState s, PermissionReq req) => ChatState(
        rows: s.rows,
        lastSeq: s.lastSeq,
        running: s.running,
        streamingText: s.streamingText,
        streamingThinking: s.streamingThinking,
        usage: s.usage,
        pendingPermission: req,
        upstreamPhase: s.upstreamPhase,
        upstreamAt: s.upstreamAt,
        liveContextTokens: s.liveContextTokens,
      );

  /// 重建态叠加实时态:REST/replay 重建不推断 running,换底时以会话当前的
  /// 实时字段(subscribed/终态/上游相位)为准,只取 rows/lastSeq/用量/审批卡。
  static ChatState keepLiveState(ChatState fresh, ChatState live) {
    return ChatState(
      rows: fresh.rows,
      lastSeq: fresh.lastSeq,
      running: live.running,
      streamingText: fresh.streamingText,
      streamingThinking: fresh.streamingThinking,
      usage: fresh.usage,
      pendingPermission: fresh.pendingPermission,
      upstreamPhase: fresh.upstreamPhase,
      upstreamAt: fresh.upstreamAt,
      // 实时上下文占用来自瞬态事件(不落库),重建拿不到 → 保留会话当前值
      liveContextTokens: live.liveContextTokens,
      // 分页锚点/是否还有更旧:首屏算出来的,别被实时态冲掉
      oldestSeq: fresh.oldestSeq > 0 ? fresh.oldestSeq : live.oldestSeq,
      hasMoreOlder: fresh.hasMoreOlder,
    );
  }
}
