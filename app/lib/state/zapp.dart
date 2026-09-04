// 应用大脑:REST + WS 组合层。页面只读这里的暴露状态,变更走方法。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api.dart';
import '../ws.dart';
import 'reducer.dart';

class ZApp extends ChangeNotifier {
  ZApp({required this._api, required this._socket}) {
    _bind();
  }

  ZApi _api;
  ZSocket _socket;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retry;
  Timer? _sessionsDirtyTimer;
  bool _disposed = false;

  List<String> models = const [];
  List<Map<String, dynamic>> modelGroups = const [];
  List<Map<String, dynamic>> sessions = const [];
  String? currentSessionId;
  ChatState chat = const ChatState();
  bool historyLoading = false;

  /// 最近一次操作错误(发送失败/历史拉取失败),UI 提示用。
  String? error;

  ZSocket get socket => _socket;
  bool get linked => _socket.state == ZSocketState.open;
  String? get linkFailure => _socket.failure;
  bool get historyEmpty => !historyLoading && chat.rows.isEmpty;

  void clearError() {
    error = null;
    notifyListeners();
  }

  // ---------------------------------------------------------------- lifecycle

  /// 启动:连 WS + 拉模型/会话。WS 连不上时定时重试,REST 照拉(页面先有数据)。
  Future<void> bootstrap() async {
    _sub ??= _socket.events.listen(_onEvent);
    try {
      await _socket.connect();
    } on Object catch (e) {
      error = '连接失败: $e';
      _retry?.cancel();
      _retry = Timer(const Duration(seconds: 2), () {
        if (!_disposed) bootstrap();
      });
    }
    await _loadModels();
    await _loadSessions();
    notifyListeners();
  }

  /// 换地址/换 token:重建 api+socket,从头来。
  Future<void> relink(String baseUrl, String token) async {
    _retry?.cancel();
    await _sub?.cancel();
    _sub = null;
    final old = _socket;
    _api = ZApi(baseUrl: baseUrl, token: token);
    _socket = ZSocket(uri: wsUriOf(baseUrl), token: token);
    _unbind(old);
    currentSessionId = null;
    chat = const ChatState();
    error = null;
    _bind();
    unawaited(bootstrap());
  }

  static Uri wsUriOf(String baseUrl) {
    final u = Uri.parse(baseUrl);
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws');
  }

  void _bind() {
    _socket.onChanged = notifyListeners;
    _sub = _socket.events.listen(_onEvent);
  }

  void _unbind(ZSocket s) {
    s.onChanged = null;
    unawaited(s.close());
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _sessionsDirtyTimer?.cancel();
    _sub?.cancel();
    _socket.onChanged = null;
    unawaited(_socket.close());
    super.dispose();
  }

  // ---------------------------------------------------------------- event 路由

  void _onEvent(Map<String, dynamic> ev) {
    final kind = '${ev['kind']}';
    if (kind == 'authenticated') {
      error = null;
      notifyListeners();
      return;
    }
    if (kind == 'replay') {
      if (ev['sessionId'] == currentSessionId && ev['events'] is List) {
        final events = [
          for (final e in ev['events'] as List)
            if (e is Map) e.cast<String, dynamic>(),
        ];
        chat = applyReplay(chat, events);
        notifyListeners();
      }
      return;
    }
    if (kind == 'session_created') {
      unawaited(_loadSessions(silent: true));
      return;
    }
    if (kind == 'sessions_dirty') {
      // 任一会话开跑/跑完的服务端广播:250ms 防抖合并成一次 REST,列表徽章跟着活。
      // 控制事件,无 seq,不许进 reducer。
      _sessionsDirtyTimer?.cancel();
      _sessionsDirtyTimer = Timer(const Duration(milliseconds: 250), () async {
        if (_disposed) return;
        await _loadSessions(silent: true);
        if (!_disposed) notifyListeners();
      });
      return;
    }
    final sid = ev['sessionId'] as String?;
    if (sid == null || sid != currentSessionId) return;
    chat = applyEvent(chat, ev);
    if (kind == 'complete') unawaited(_loadSessions(silent: true));
    notifyListeners();
  }

  // ---------------------------------------------------------------- 会话

  Future<void> _loadModels() async {
    try {
      models = await _api.models();
      modelGroups = await _api.modelGroups();
    } on Object catch (e) {
      error = '$e';
    }
  }

  /// 选择器打开时的兜底重拉,成功后刷新状态。
  Future<List<Map<String, dynamic>>> apiGroups() async {
    modelGroups = await _api.modelGroups();
    notifyListeners();
    return modelGroups;
  }

  Future<void> _loadSessions({bool silent = false}) async {
    try {
      sessions = await _api.sessions();
    } on Object catch (e) {
      // 后台自动刷新(定时/事件驱动)失败保持静默:一次 REST 抖动不该在聊天页顶上弹错误条
      if (!silent) error = '$e';
    }
  }

  Future<void> refreshSessions() async {
    await _loadSessions();
    notifyListeners();
  }

  /// 打开(或重开刷新)会话:先 REST 历史(meta 是完整出站事件)重建,再带 lastSeq 订阅续传。
  Future<void> openSession(String id) async {
    // 同会话刷新时保留待审批卡片:审批请求不落库,REST 重建不出来;
    // 丢了卡片没人能批,服务端 runtime 会一直等(INTERACTIVE 工具无超时)→ 会话卡死。
    final keepPermission = currentSessionId == id ? chat.pendingPermission : null;
    currentSessionId = id;
    chat = const ChatState();
    historyLoading = true;
    error = null;
    notifyListeners();
    try {
      final hist = await _api.messages(id);
      final events = <Map<String, dynamic>>[];
      var maxSeq = 0;
      for (final row in hist.messages) {
        final ev = _rowEvent(row);
        if (ev == null) continue;
        // 行号才是权威锚:meta 里的 seq 是服务器事件流编号,可能来自旧进程的
        // 天文数字(与 DB 行号分家),照抄会把去重指针毒化 → 新事件全被丢弃。
        final sq = (row['seq'] as num?)?.toInt() ?? 0;
        ev['seq'] = sq;
        events.add(ev);
        if (sq > maxSeq) maxSeq = sq;
      }
      // REST 按 seq 倒序返回;归约要按时间正序,否则末尾事件先应用、其余全被去重。
      events.sort((a, b) =>
          ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0));
      var st = const ChatState();
      for (final e in events) {
        st = applyEvent(st, e);
      }
      if (maxSeq > st.lastSeq) {
        st = ChatState(
          rows: st.rows,
          lastSeq: maxSeq,
          running: st.running,
          streamingText: st.streamingText,
          streamingThinking: st.streamingThinking,
          usage: st.usage,
          pendingPermission: st.pendingPermission,
        );
      }
      chat = st;
      if (keepPermission != null && chat.pendingPermission == null) {
        chat = ChatState(
          rows: chat.rows,
          lastSeq: chat.lastSeq,
          running: chat.running,
          streamingText: chat.streamingText,
          streamingThinking: chat.streamingThinking,
          usage: chat.usage,
          pendingPermission: keepPermission,
        );
      }
      historyLoading = false;
      notifyListeners();
      _socket.seedLastSeq(id, maxSeq > st.lastSeq ? maxSeq : st.lastSeq);
      _socket.subscribeSession(id);
    } on Object catch (e) {
      historyLoading = false;
      error = '$e';
      notifyListeners();
    }
  }

  /// 消息行 meta → 出站事件(可能存成 JSON 字符串或已是 Map)。
  Map<String, dynamic>? _rowEvent(Map<String, dynamic> row) {
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

  /// 新建会话,建完刷新列表,返回会话行。
  Future<Map<String, dynamic>> createSession({String? title, String? cwd, String? model}) async {
    final s = await _api.createSession(title: title, cwd: cwd, model: model);
    await _loadSessions();
    notifyListeners();
    return s;
  }

  Future<void> deleteSession(String id) async {
    await _api.deleteSession(id);
    if (currentSessionId == id) {
      currentSessionId = null;
      chat = const ChatState();
    }
    await _loadSessions();
    notifyListeners();
  }

  /// 批量删除:一次请求;当前打开中的会话被删则清空聊天态。返回 {deleted, missing}。
  Future<({int deleted, List<String> missing})> deleteSessions(List<String> ids) async {
    if (ids.isEmpty) return (deleted: 0, missing: const <String>[]);
    final r = await _api.deleteSessions(ids);
    if (currentSessionId != null && ids.contains(currentSessionId)) {
      currentSessionId = null;
      chat = const ChatState();
    }
    await _loadSessions();
    notifyListeners();
    return r;
  }

  /// 会话用量聚合(累计 token/缓存 + 上下文占用 + 构成);拉不到返回 null。
  Future<Map<String, dynamic>?> sessionUsage(String id) async {
    try {
      return await _api.sessionUsage(id);
    } on Object {
      return null;
    }
  }

  Future<void> patchSession(String id, {String? title, bool? isPinned, String? model, String? permissionMode}) async {
    await _api.patchSession(id, title: title, isPinned: isPinned, model: model, permissionMode: permissionMode);
    await _loadSessions();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 对话动作

  /// 发消息:本地乐观行(pending),WS 发出;发不出去就回滚。images = data URI 列表。
  /// 返回 false = 没发出去(连接断开),调用方可把原文回填输入框。
  bool sendChat(String content, {String? model, String? permissionMode, List<String> images = const []}) {
    final sid = currentSessionId;
    final text = content.trim();
    if (sid == null || (text.isEmpty && images.isEmpty)) return false;
    chat = applyLocalUser(chat, text.isEmpty ? '[图片] ×${images.length}' : text, images: images);
    notifyListeners();
    try {
      _socket.sendChat(sid, text, model: model, permissionMode: permissionMode, images: images);
      return true;
    } on Object {
      chat = rollbackLocalUser(chat);
      error = '发送失败: 连接断开,等重连后再试';
      notifyListeners();
      return false;
    }
  }

  void answerPermission(String requestId, {required bool allow, String message = '', Map<String, dynamic>? updatedInput, bool rememberTool = false}) {
    final sid = currentSessionId;
    if (sid == null) return;
    chat = applyPermissionAnswer(chat);
    notifyListeners();
    try {
      _socket.answerPermission(sid, requestId, allow: allow, message: message, updatedInput: updatedInput, rememberTool: rememberTool);
    } on Object {
      // 断线发不出去:面板已收起;服务器侧 10 分钟超时自动 deny,
      // 或重连后 subscribed.pending 把审批卡带回来重批。
      error = '审批发送失败: 连接断开';
      notifyListeners();
    }
  }

  void abort() {
    final sid = currentSessionId;
    if (sid == null) return;
    try {
      _socket.abort(sid);
    } on Object {
      error = '停止失败: 连接断开';
      notifyListeners();
    }
  }
}
