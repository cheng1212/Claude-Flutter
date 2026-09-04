// 纯函数状态归约:WS 事件 → ChatState。UI 只读,所有变更走这里(可单测)。
import 'package:flutter/foundation.dart';

@immutable
sealed class ChatRow {
  const ChatRow();
}

@immutable
class UserRow extends ChatRow {
  final String content;

  /// true = 本地乐观插入还没收到服务器回显;发送失败会被回滚。
  final bool pending;
  const UserRow(this.content, {this.pending = false});
}

@immutable
class TextRow extends ChatRow {
  final String content;
  const TextRow(this.content);
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
  const ToolRow({required this.toolId, required this.toolName, required this.toolInput, this.result});
}

@immutable
class ErrorRow extends ChatRow {
  final String content;
  const ErrorRow(this.content);
}

@immutable
class UsageInfo {
  final int inputTokens;
  final int outputTokens;
  final double totalCostUsd;
  final int durationMs;
  const UsageInfo({required this.inputTokens, required this.outputTokens, required this.totalCostUsd, required this.durationMs});
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

  const ChatState({
    this.rows = const [],
    this.lastSeq = 0,
    this.running = false,
    this.streamingText,
    this.streamingThinking,
    this.usage,
    this.pendingPermission,
  });
}

ChatState _with(ChatState s, {List<ChatRow>? rows, int? lastSeq, bool? running, String? streamingText, String? streamingThinking, bool clearStreamText = false, bool clearStreamThinking = false, UsageInfo? usage, PermissionReq? pendingPermission, bool clearPermission = false}) {
  return ChatState(
    rows: rows ?? s.rows,
    lastSeq: lastSeq ?? s.lastSeq,
    running: running ?? s.running,
    streamingText: clearStreamText ? null : (streamingText ?? s.streamingText),
    streamingThinking: clearStreamThinking ? null : (streamingThinking ?? s.streamingThinking),
    usage: usage ?? s.usage,
    pendingPermission: clearPermission ? null : (pendingPermission ?? s.pendingPermission),
  );
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
        final content = ev['content'] as String? ?? '';
        final rows = [...s.rows];
        final idx = rows.indexWhere((r) => r is UserRow && r.pending && r.content == content);
        if (idx >= 0) {
          rows[idx] = UserRow(content);
        } else {
          rows.add(UserRow(content));
        }
        return _with(s, lastSeq: nextSeq, running: true, rows: rows);
      }
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, TextRow(ev['content'] as String? ?? '')], clearStreamText: true);
    case 'thinking':
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, ThinkingRow(ev['content'] as String? ?? '')], clearStreamThinking: true);
    case 'tool_use':
      return _with(s, lastSeq: nextSeq, running: true, rows: [...s.rows, ToolRow(
        toolId: ev['toolId'] as String? ?? '',
        toolName: ev['toolName'] as String? ?? '',
        toolInput: (ev['toolInput'] as Map?)?.cast<String, dynamic>() ?? const {},
      )]);
    case 'tool_result':
      final toolId = ev['toolId'] as String? ?? '';
      final result = ToolResult(content: ev['content'] as String? ?? '', isError: ev['isError'] as bool? ?? false);
      final rows = [...s.rows];
      final idx = rows.lastIndexWhere((r) => r is ToolRow && r.toolId == toolId && r.result == null);
      if (idx >= 0) {
        final tool = rows[idx] as ToolRow;
        rows[idx] = ToolRow(toolId: tool.toolId, toolName: tool.toolName, toolInput: tool.toolInput, result: result);
        return _with(s, lastSeq: nextSeq, running: true, rows: rows);
      }
      return _with(s, lastSeq: nextSeq, running: true, rows: rows);
    case 'permission_request':
      return _with(s, pendingPermission: PermissionReq(
        requestId: ev['requestId'] as String? ?? '',
        toolName: ev['toolName'] as String? ?? '',
        input: (ev['input'] as Map?)?.cast<String, dynamic>() ?? const {},
      ));
    case 'usage':
      return _with(s, lastSeq: nextSeq, usage: UsageInfo(
        inputTokens: (ev['inputTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (ev['outputTokens'] as num?)?.toInt() ?? 0,
        totalCostUsd: (ev['totalCostUsd'] as num?)?.toDouble() ?? 0,
        durationMs: (ev['durationMs'] as num?)?.toInt() ?? 0,
      ));
    case 'complete':
      return _with(s, lastSeq: nextSeq, running: false, clearStreamText: true, clearStreamThinking: true, clearPermission: true);
    case 'error':
      return _with(s, lastSeq: nextSeq, running: false, rows: [...s.rows, ErrorRow(ev['content'] as String? ?? '')]);
    case 'subscribed':
      final isProcessing = ev['isProcessing'] as bool? ?? false;
      final serverLastSeq = ev['lastSeq'] as int?;
      return _with(s, running: isProcessing, lastSeq: serverLastSeq != null && serverLastSeq > s.lastSeq ? serverLastSeq : s.lastSeq);
    default:
      return seq != null ? _with(s, lastSeq: nextSeq) : s;
  }
}

/// 重连补发:一批事件按序灌入(applyEvent 自带 seq 去重)。
ChatState applyReplay(ChatState s, List<Map<String, dynamic>> events) {
  var cur = s;
  for (final ev in events) {
    cur = applyEvent(cur, ev);
  }
  return cur;
}

/// 本地乐观插入用户消息(不占 seq)。
ChatState applyLocalUser(ChatState s, String content) {
  return _with(s, running: true, rows: [...s.rows, UserRow(content, pending: true)]);
}

/// 应答权限后立即收起面板(complete 也会清,这里只为即时反馈)。
ChatState applyPermissionAnswer(ChatState s) {
  return _with(s, clearPermission: true);
}

/// 回滚末尾的乐观用户行(WS 未连上、发送失败时)。
ChatState rollbackLocalUser(ChatState s) {
  final idx = s.rows.lastIndexWhere((r) => r is UserRow && r.pending);
  if (idx < 0) return s;
  final rows = [...s.rows]..removeAt(idx);
  return _with(s, rows: rows);
}
