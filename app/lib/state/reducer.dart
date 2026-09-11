// 纯函数状态归约:WS 事件 → ChatState。UI 只读,所有变更走这里(可单测)。
import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart';

@immutable
sealed class ChatRow {
  const ChatRow();
}

@immutable
class UserRow extends ChatRow {
  final String content;

  /// 随消息发的图(data URI):乐观行本地就有,历史重建时 meta 里有,零网络成本回显。
  final List<String> images;

  /// ISO 时间:气泡显示 HH:mm 用(本地发送时刻或服务器发射时刻)
  final String? createdAt;

  /// true = 本地乐观插入还没收到服务器回显;发送失败会被回滚。
  final bool pending;
  const UserRow(this.content, {this.pending = false, this.images = const [], this.createdAt});
}

@immutable
class TextRow extends ChatRow {
  final String content;

  /// ISO 时间:助手气泡显示 HH:mm 用
  final String? createdAt;
  const TextRow(this.content, {this.createdAt});
}

@immutable
class ThinkingRow extends ChatRow {
  final String content;
  const ThinkingRow(this.content);
}

@immutable
class ToolResult {
  final String content;
  final bool isError;
  const ToolResult({required this.content, required this.isError});
}

@immutable
class ToolRow extends ChatRow {
  final String toolId;
  final String toolName;
  final Map<String, dynamic> toolInput;
  final ToolResult? result;

  /// 工具开跑时刻(本机时钟):运行中卡片靠它走秒,证明命令活着而非卡死。
  /// 重放重建时取重建时刻,走秒会重计——纯显示用途,可接受。
  final DateTime? startedAt;

  /// 非空 = 该工具由子代理(Task/Agent)发起,值为发起者的 toolId(子代理面板分组用)。
  final String? parentToolUseId;
  const ToolRow({required this.toolId, required this.toolName, required this.toolInput, this.result, this.startedAt, this.parentToolUseId});
}

@immutable
class ErrorRow extends ChatRow {
  final String content;

  /// 已知可恢复的中断类提示(服务重启打断/看门狗自动中断):中性琥珀,别和真错误一样红。
  final bool neutral;
  const ErrorRow(this.content, {this.neutral = false});
}

@immutable
class UsageInfo {
  final int inputTokens;
  final int outputTokens;
  final int cacheReadInputTokens;
  final int cacheCreationInputTokens;
  final double totalCostUsd;
  final int durationMs;
  final int numTurns;
  final int contextWindow;
  final int maxOutputTokens;
  const UsageInfo({
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    required this.totalCostUsd,
    required this.durationMs,
    this.numTurns = 0,
    this.contextWindow = 0,
    this.maxOutputTokens = 0,
  });

  /// 上一轮的上下文占用 ≈ 输入 + 缓存读 + 缓存写(result 时的 prompt 就是全部历史)。
  int get contextTokens => inputTokens + cacheReadInputTokens + cacheCreationInputTokens;

  /// 缓存命中率:缓存读 / (输入 + 缓存读 + 缓存写)。
  double get cacheHitRate {
    final total = contextTokens;
    return total == 0 ? 0 : cacheReadInputTokens / total;
  }
}

@immutable
class PermissionReq {
  final String requestId;
  final String toolName;
  final Map<String, dynamic> input;
  const PermissionReq({required this.requestId, required this.toolName, required this.input});
}

@immutable
class ChatState {
  final List<ChatRow> rows;
  final int lastSeq;
  final bool running;
  final String? streamingText;
  final String? streamingThinking;
  final UsageInfo? usage;
  final PermissionReq? pendingPermission;
  /// 上游中转代理的瞬态状态('request'/'first_byte'):静默期显示真实"已转发上游",
  /// 没有(旧 server/非中转模型没等到事件)就退回客户端自己猜。null = 无信息。
  final String? upstreamPhase;
  final DateTime? upstreamAt; // 事件到达的本地时刻,骨架行据此走秒

  const ChatState({
    this.rows = const [],
    this.lastSeq = 0,
    this.running = false,
    this.streamingText,
    this.streamingThinking,
    this.usage,
    this.pendingPermission,
    this.upstreamPhase,
    this.upstreamAt,
  });
}

ChatState _with(ChatState s, {List<ChatRow>? rows, int? lastSeq, bool? running, String? streamingText, String? streamingThinking, bool clearStreamText = false, bool clearStreamThinking = false, UsageInfo? usage, PermissionReq? pendingPermission, bool clearPermission = false, String? upstreamPhase, bool clearUpstream = false}) {
  return ChatState(
    rows: rows ?? s.rows,
    lastSeq: lastSeq ?? s.lastSeq,
    running: running ?? s.running,
    streamingText: clearStreamText ? null : (streamingText ?? s.streamingText),
    streamingThinking: clearStreamThinking ? null : (streamingThinking ?? s.streamingThinking),
    usage: usage ?? s.usage,
    pendingPermission: clearPermission ? null : (pendingPermission ?? s.pendingPermission),
    upstreamPhase: clearUpstream ? null : (upstreamPhase ?? s.upstreamPhase),
    upstreamAt: clearUpstream || upstreamPhase == null ? (clearUpstream ? null : s.upstreamAt) : DateTime.now(),
  );
}

/// 上游中转代理的瞬态广播(upstream_status,无 seq 控制事件)落地。
/// 只认 'request'/'first_byte' 两个有展示意义的相位;done/error 由回合终态统一收。
ChatState setUpstreamPhase(ChatState s, String phase) {
  if (phase != 'request' && phase != 'first_byte') return s;
  return _with(s, upstreamPhase: phase);
}

/// 被打断工具卡的占位结果:可辨识,迟到的真 tool_result 会覆盖它(见 tool_result 匹配)。
const kInterruptedToolMark = '[中断] 命令被打断或服务重启,没有回传输出';

/// 还没拿到结果的工具卡就地落定:中断的输出回不来了,别让卡片永远转圈。
List<ChatRow> _closeDanglingTools(List<ChatRow> rows) {
  var changed = false;
  final next = rows.map<ChatRow>((r) {
    if (r is ToolRow && r.result == null) {
      changed = true;
      return ToolRow(
        toolId: r.toolId,
        toolName: r.toolName,
        toolInput: r.toolInput,
        startedAt: r.startedAt,
        result: const ToolResult(content: kInterruptedToolMark, isError: true),
      );
    }
    return r;
  }).toList();
  return changed ? next : rows;
}

/// 单事件归约;seq <= lastSeq 的事件丢弃(重连去重)。
ChatState applyEvent(ChatState s, Map<String, dynamic> ev) {
  final kind = ev['kind'] as String? ?? '';
  final seq = ev['seq'] as int?;
  if (seq != null && seq <= s.lastSeq && kind != 'permission_request') return s;
  final nextSeq = seq != null && seq > s.lastSeq ? seq : s.lastSeq;

  switch (kind) {
    case 'stream_delta':
      return _with(s, lastSeq: nextSeq, running: true, streamingText: (s.streamingText ?? '') + (ev['content'] as String? ?? ''));
    case 'thinking_delta':
      return _with(s, lastSeq: nextSeq, running: true, streamingThinking: (s.streamingThinking ?? '') + (ev['content'] as String? ?? ''));
    case 'text':
      final isUser = (ev['role'] as String? ?? 'assistant') == 'user';
      if (isUser) {
        // 服务器回显用户消息:就地转正第一条同内容的 pending 行,不追加(防双气泡)。
        // 实时线上图片被剥成 imageCount(瘦身);纯图消息 content 为空,用占位文案对上;
        // 历史重建(REST meta)带完整 images 列表,直接随行回显。
        var content = ev['content'] as String? ?? '';
        final imageCount = (ev['imageCount'] as num?)?.toInt() ?? 0;
        final historyImages = (ev['images'] as List?)?.whereType<String>().toList();
        if (content.isEmpty && imageCount > 0) content = '[图片] ×$imageCount';
        final rows = [...s.rows];
        final idx = rows.indexWhere((r) => r is UserRow && r.pending && r.content == content);
        if (idx >= 0) {
          final pendingRow = rows[idx] as UserRow;
          rows[idx] = UserRow(content, images: historyImages ?? pendingRow.images, createdAt: pendingRow.createdAt ?? (ev['createdAt'] as String?));
        } else {
          rows.add(UserRow(content, images: historyImages ?? const <String>[], createdAt: ev['createdAt'] as String? ?? DateTime.now().toIso8601String()));
        }
        return _with(s, lastSeq: nextSeq, running: true, rows: rows);
      }
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, TextRow(ev['content'] as String? ?? '', createdAt: ev['createdAt'] as String? ?? DateTime.now().toIso8601String())], clearStreamText: true);
    case 'thinking':
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, ThinkingRow(ev['content'] as String? ?? '')], clearStreamThinking: true);
    case 'tool_use':
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, ToolRow(
        toolId: ev['toolId'] as String? ?? '',
        toolName: ev['toolName'] as String? ?? '',
        toolInput: (ev['toolInput'] as Map?)?.cast<String, dynamic>() ?? const {},
        startedAt: DateTime.now(),
        parentToolUseId: ev['parentToolUseId'] as String?,
      )]);
    case 'tool_result':
      final toolId = ev['toolId'] as String? ?? '';
      final result = ToolResult(content: ev['content'] as String? ?? '', isError: ev['isError'] as bool? ?? false);
      final rows = [...s.rows];
      // 也匹配被中断标记收尾的卡:重连时 subscribed(false) 先到、replay 后到,
      // 卡已被收尾;放宽匹配,迟到的真结果才能覆盖占位标记。
      final idx = rows.lastIndexWhere((r) =>
          r is ToolRow && r.toolId == toolId && (r.result == null || r.result?.content == kInterruptedToolMark));
      if (idx >= 0) {
        final tool = rows[idx] as ToolRow;
        rows[idx] = ToolRow(toolId: tool.toolId, toolName: tool.toolName, toolInput: tool.toolInput, result: result, startedAt: tool.startedAt);
        return _with(s, lastSeq: nextSeq, running: true, rows: rows);
      }
      return _with(s, lastSeq: nextSeq, running: true, rows: rows);
    case 'permission_resolved':
      // 多端同步:另一端已应答该审批,本地同 requestId 的卡片收起(不匹配则忽略)
      final resolvedId = ev['requestId'] as String? ?? '';
      if (s.pendingPermission?.requestId == resolvedId) {
        return _with(s, clearPermission: true);
      }
      return s;
    case 'permission_request':
      return _with(s, pendingPermission: PermissionReq(
        requestId: ev['requestId'] as String? ?? '',
        toolName: ev['toolName'] as String? ?? '',
        input: (ev['input'] as Map?)?.cast<String, dynamic>() ?? const {},
      ));
    case 'task_started':
      // 后台任务/子代理:复用工具卡渲染(走秒计时直接继承),complete 后收尾
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, ToolRow(
        toolId: ev['taskId'] as String? ?? '',
        toolName: ev['taskType'] == 'local_agent' ? '子任务' : '后台任务',
        toolInput: {'description': ev['description'] as String? ?? ''},
        startedAt: DateTime.now(),
      )]);
    case 'task_complete':
      final taskId = ev['taskId'] as String? ?? '';
      final status = ev['status'] as String? ?? 'completed';
      final summary = ev['summary'] as String? ?? '';
      final result = ToolResult(
        content: summary.isEmpty ? '[后台任务 $status]' : summary,
        isError: status != 'completed',
      );
      final rows = [...s.rows];
      // 放宽匹配:后台任务跑得比回合久时,complete 已把卡片收尾成中断占位,迟到的真结果要盖回来
      final idx = rows.lastIndexWhere((r) =>
          r is ToolRow && r.toolId == taskId && (r.result == null || r.result?.content == kInterruptedToolMark));
      if (idx < 0) return _with(s, lastSeq: nextSeq);
      final tool = rows[idx] as ToolRow;
      rows[idx] = ToolRow(
        toolId: tool.toolId,
        toolName: tool.toolName,
        toolInput: tool.toolInput,
        startedAt: tool.startedAt,
        result: result,
      );
      return _with(s, lastSeq: nextSeq, running: true, rows: rows);
    case 'usage':
      return _with(s, lastSeq: nextSeq, usage: UsageInfo(
        inputTokens: (ev['inputTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (ev['outputTokens'] as num?)?.toInt() ?? 0,
        cacheReadInputTokens: (ev['cacheReadInputTokens'] as num?)?.toInt() ?? 0,
        cacheCreationInputTokens: (ev['cacheCreationInputTokens'] as num?)?.toInt() ?? 0,
        totalCostUsd: (ev['totalCostUsd'] as num?)?.toDouble() ?? 0,
        durationMs: (ev['durationMs'] as num?)?.toInt() ?? 0,
        numTurns: (ev['numTurns'] as num?)?.toInt() ?? 0,
        contextWindow: (ev['contextWindow'] as num?)?.toInt() ?? 0,
        maxOutputTokens: (ev['maxOutputTokens'] as num?)?.toInt() ?? 0,
      ));
    case 'complete':
      // 收尾:还没拿到 tool_result 的工具卡就地落定(命令被打断,结果永远不会来)。
      // 不收尾的话卡片永久转圈、走秒不停,看起来就是"卡住了"。
      return _with(s, lastSeq: nextSeq, running: false, clearStreamText: true, clearStreamThinking: true, clearPermission: true, clearUpstream: true, rows: _closeDanglingTools(s.rows));
    case 'error':
      final content = ev['content'] as String? ?? '';
      if (content == 'RUN_IN_PROGRESS') {
        // 服务器上一轮仍在跑(可能已卡死):本轮被拒,消息没落库。
        // 撤回乐观行(否则刷新前一直挂着假气泡)、恢复 running 让停止按钮出现,并提示怎么解。
        final rolled = rollbackLocalUser(s);
        return _with(rolled, lastSeq: nextSeq, running: true, rows: [
          ...rolled.rows,
          const ErrorRow('上一轮仍在运行(可能已卡住):点输入框旁的停止按钮 ■,然后再重发', neutral: true),
        ]);
      }
      // 已知可恢复的中断提示(服务重启打断/看门狗自动中断)视觉降噪:中性而非红
      final neutral = content.contains('打断了上一轮') || content.startsWith('回合超过');
      return _with(s, lastSeq: nextSeq, running: false, clearUpstream: true, rows: [...s.rows, ErrorRow(content, neutral: neutral)]);
    case 'subscribed':
      // 只取运行态,不抬 lastSeq:服务器指针先于 replay 到达,若先抬去重门槛,
      // 紧跟的 replay(全部 ≤ 指针)会被 seq 去重整批丢弃,界面冻结在旧内容。
      // isProcessing=false(如服务重启后重连):上一世的悬空工具卡已成孤儿,一并收尾;
      // 迟到的真结果靠 tool_result 的放宽匹配覆盖回来。
      // pending:服务器带回的待审批清单(重连/App 重启后确定性重建审批卡);
      // 显式空数组 = 没有在等的审批,清掉本地旧卡;无该字段(旧服务器)保持原状。
      final isProcessing = ev['isProcessing'] as bool? ?? false;
      final pendingList = ev['pending'] as List?;
      final rows = isProcessing ? s.rows : _closeDanglingTools(s.rows);
      if (pendingList == null) {
        return _with(s, running: isProcessing, rows: rows);
      }
      Map? lastPending;
      for (final item in pendingList) {
        if (item is Map) lastPending = item;
      }
      if (lastPending == null) {
        return _with(s, running: isProcessing, clearPermission: true, rows: rows);
      }
      return _with(s, running: isProcessing, rows: rows, pendingPermission: PermissionReq(
        requestId: '${lastPending['requestId'] ?? ''}',
        toolName: '${lastPending['toolName'] ?? ''}',
        input: (lastPending['input'] as Map?)?.cast<String, dynamic>() ?? const {},
      ));
    default:
      return seq != null ? _with(s, lastSeq: nextSeq) : s;
  }
}

/// 聊天内搜索:按关键词过滤消息行(大小写不敏感;空查询返回空)。
/// 命中范围:用户/助手/思考的文本,工具行匹配工具名+入参 JSON。
/// 返回 (行, 在 rows 中的下标, 角色标签, 参与匹配的全文) 供面板展示与引用发送。
List<({ChatRow row, int index, String roleLabel, String content})> searchChatRows(
    List<ChatRow> rows, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return const [];
  final hits = <({ChatRow row, int index, String roleLabel, String content})>[];
  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    String? role;
    String? content;
    if (r is UserRow) {
      role = '用户';
      content = r.content;
    } else if (r is TextRow) {
      role = '助手';
      content = r.content;
    } else if (r is ThinkingRow) {
      role = '思考';
      content = r.content;
    } else if (r is ToolRow) {
      role = '工具';
      content = '${r.toolName} ${jsonEncode(r.toolInput)}';
    }
    if (content == null || !content.toLowerCase().contains(q)) continue;
    hits.add((row: r, index: i, roleLabel: role!, content: content));
  }
  return hits;
}

/// 重连补发:一批事件按序灌入(applyEvent 自带 seq 去重)。
ChatState applyReplay(ChatState s, List<Map<String, dynamic>> events) {
  var cur = s;
  for (final ev in events) {
    cur = applyEvent(cur, ev);
  }
  return cur;
}

/// 本地乐观插入用户消息(不占 seq)。images 随行带:气泡里直接回显缩略图(本地就有 base64)。
ChatState applyLocalUser(ChatState s, String content, {List<String> images = const []}) {
  // 新回合从零开始等:上一回合的上游相位不能再带到这一回合的静默期里
  return _with(s, running: true, clearUpstream: true, rows: [...s.rows, UserRow(content, pending: true, images: images, createdAt: DateTime.now().toIso8601String())]);
}

/// 应答权限后立即收起面板(complete 也会清,这里只为即时反馈)。
ChatState applyPermissionAnswer(ChatState s) {
  return _with(s, clearPermission: true);
}

/// 回滚末尾的乐观用户行(WS 未连上、发送失败时)。
/// 乐观置位的 running 一并清掉:这条消息根本没在服务端开跑,不清会让
/// 发送/停止按钮冻结在"运行中"(明明没在跑却显示停止、发不出去)。
ChatState rollbackLocalUser(ChatState s) {
  final idx = s.rows.lastIndexWhere((r) => r is UserRow && r.pending);
  if (idx < 0) return s;
  final rows = [...s.rows]..removeAt(idx);
  return _with(s, rows: rows, running: false);
}
