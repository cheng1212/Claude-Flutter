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
  bool _disposed = false;

  List<String> models = const [];
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
      unawaited(_loadSessions());
      return;
    }
    final sid = ev['sessionId'] as String?;
    if (sid == null || sid != currentSessionId) return;
    chat = applyEvent(chat, ev);
    if (kind == 'complete') unawaited(_loadSessions());
    notifyListeners();
  }

  // ---------------------------------------------------------------- 会话

  Future<void> _loadModels() async {
    try {
      models = await _api.models();
    } on Object catch (e) {
      error = '$e';
    }
  }

  Future<void> _loadSessions() async {
    try {
      sessions = await _api.sessions();
    } on Object catch (e) {
      error = '$e';
    }
  }

  Future<void> refreshSessions() async {
    await _loadSessions();
    notifyListeners();
  }

  /// 打开(或重开刷新)会话:先 REST 历史(meta 是完整出站事件)重建,再带 lastSeq 订阅续传。
  Future<void> openSession(String id) async {
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
        events.add(ev);
        final sq = (ev['seq'] as num?)?.toInt() ?? (row['seq'] as num?)?.toInt() ?? 0;
        ev['seq'] ??= sq;
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

  Future<void> patchSession(String id, {String? title, bool? isPinned, String? model, String? permissionMode}) async {
    await _api.patchSession(id, title: title, isPinned: isPinned, model: model, permissionMode: permissionMode);
    await _loadSessions();
    notifyListeners();
  }

  // ---------------------------------------------------------------- 对话动作

  /// 发消息:本地乐观行(pending),WS 发出;发不出去就回滚。
  void sendChat(String content, {String? model, String? permissionMode}) {
    final sid = currentSessionId;
    final text = content.trim();
    if (sid == null || text.isEmpty) return;
    chat = applyLocalUser(chat, text);
    notifyListeners();
    try {
      _socket.sendChat(sid, text, model: model, permissionMode: permissionMode);
    } on Object {
      chat = rollbackLocalUser(chat);
      error = '发送失败: 连接断开,等重连后再试';
      notifyListeners();
    }
  }

  void answerPermission(String requestId, {required bool allow, String message = ''}) {
    final sid = currentSessionId;
    if (sid == null) return;
    chat = applyPermissionAnswer(chat);
    notifyListeners();
    _socket.answerPermission(sid, requestId, allow: allow, message: message);
  }

  void abort() {
    final sid = currentSessionId;
    if (sid == null) return;
    _socket.abort(sid);
  }
}
