// 应用大脑:REST + WS 组合层。页面只读这里的暴露状态,变更走方法。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api.dart';
import '../ws.dart';
import '../notify.dart';
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

  /// openSession 后台补齐(首屏后的老消息拉取);_onEvent 顺手给它留 WS 底。
  _Backfill? _backfill;

  /// 打开会话的代际令牌:快速切换/重开时,旧打开流程的后续阶段全部作废。
  int _openToken = 0;

  List<String> models = const [];
  List<Map<String, dynamic>> modelGroups = const [];
  List<Map<String, dynamic>> sessions = const [];
  String? currentSessionId;
  ChatState chat = const ChatState();
  bool historyLoading = false;

  /// App 前后台状态(main 的观察者回写):后台才允许弹通知。默认前台。
  String appLifecycle = 'resumed';

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
    if (kind == 'upstream_status') {
      // 上游中转代理的计时广播:同样是控制事件,只落到当前会话的瞬态相位上,
      // 供静默期骨架行显示"已转发上游"真状态;无 seq、不补发,断了就退回本地猜。
      final sid = ev['sessionId'] as String?;
      if (sid != null && sid == currentSessionId) {
        chat = setUpstreamPhase(chat, '${ev['phase'] ?? ''}');
        notifyListeners();
      }
      return;
    }
    final sid = ev['sessionId'] as String?;
    final decision = notifyDecision(
        lifecycleState: appLifecycle,
        kind: kind,
        forCurrentSession: sid == currentSessionId,
      );
      if (decision != null) Notify.show(decision, _notifyBody(kind, ev));
      if (sid == null || sid != currentSessionId) return;
    chat = applyEvent(chat, ev);
    _backfill?.extra.add(ev); // 后台补齐窗口内的实时事件留底,换底重放不丢
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

  /// 打开(或重开刷新)会话:首屏只等最新一页立即上屏,老消息后台补齐后整体换底。
  /// 全量拉完才渲染是"进去转圈好久"的根源:大会话十几页串行拉完才画第一帧。
  Future<void> openSession(String id) async {
    // 同会话刷新时保留待审批卡片:审批请求不落库,REST 重建不出来;
    // 丢了卡片没人能批,服务端 runtime 会一直等(INTERACTIVE 工具无超时)→ 会话卡死。
    final keepPermission = currentSessionId == id ? chat.pendingPermission : null;
    currentSessionId = id;
    chat = const ChatState();
    historyLoading = true;
    error = null;
    final token = ++_openToken;
    _backfill = null;
    final bf = _Backfill(id);
    _backfill = bf; // 先挂缓冲再拉取:补齐窗口内到达的 WS 事件留底,换底重放不丢
    notifyListeners();
    try {
      final first = await _api.messages(id, limit: 500, offset: 0);
      if (token != _openToken) return;
      final (headEvents, maxSeq) = _histEvents(first);
      var st = _replay(headEvents, maxSeq);
      if (keepPermission != null && st.pendingPermission == null) {
        st = _withPermission(st, keepPermission);
      }
      chat = st;
      historyLoading = false;
      notifyListeners();
      // 行号才是权威锚:meta 里的 seq 是服务器事件流编号,可能来自旧进程的
      // 天文数字(与 DB 行号分家),照抄会把去重指针毒化 → 新事件全被丢弃。
      _socket.seedLastSeq(id, maxSeq > st.lastSeq ? maxSeq : st.lastSeq);
      _socket.subscribeSession(id);
      if (first.total <= first.messages.length) {
        _backfill = null;
        return;
      }
      // 后台补齐老消息:按 seq 锚点翻更旧页——offset 分页期间若新消息插入(更高 seq),
      // 窗口会整体上移、整段漏掉;锚点(比当前最小 seq 更旧)免疫漂移,翻到底为止。
      var beforeSeq = _minSeqOf(headEvents);
      while (beforeSeq != null) {
        final hist = await _api.messages(id, limit: 500, beforeSeq: beforeSeq);
        if (token != _openToken || _backfill != bf) return;
        final (older, _) = _histEvents(hist);
        if (older.isEmpty) break;
        bf.older.addAll(older);
        beforeSeq = _minSeqOf(older);
        if (hist.messages.length < 500) break; // 不足一页 = 已翻到最旧
      }
      var full = _replay([...headEvents, ...bf.older, ...bf.extra], maxSeq);
      final livePermission = currentSessionId == id ? chat.pendingPermission : null;
      if (livePermission != null && full.pendingPermission == null) {
        full = _withPermission(full, livePermission);
      }
      if (token != _openToken || _backfill != bf) return;
      _backfill = null;
      if (currentSessionId == id) {
        // 换底不能把 subscribed/实时事件已设定的 running 冲掉:保留它,
        // 重建本身不推断 running(_replay 已归零),实时态只由 subscribed/终态事件驱动。
        full = ChatState(
          rows: full.rows,
          lastSeq: full.lastSeq,
          running: chat.running,
          streamingText: full.streamingText,
          streamingThinking: full.streamingThinking,
          usage: full.usage,
          pendingPermission: full.pendingPermission,
          upstreamPhase: full.upstreamPhase,
          upstreamAt: full.upstreamAt,
        );
        chat = full;
        notifyListeners();
      }
    } on Object catch (e) {
      if (token != _openToken) return;
      _backfill = null;
      historyLoading = false;
      error = '$e';
      notifyListeners();
    }
  }

  /// 消息页(rows)→ 出站事件列表 + 最大 seq。
  (List<Map<String, dynamic>>, int) _histEvents(
      ({List<Map<String, dynamic>> messages, int total}) hist) {
    final events = <Map<String, dynamic>>[];
    var maxSeq = 0;
    for (final row in hist.messages) {
      final ev = _rowEvent(row);
      if (ev == null) continue;
      final sq = (row['seq'] as num?)?.toInt() ?? 0;
      ev['seq'] = sq;
      events.add(ev);
      if (sq > maxSeq) maxSeq = sq;
    }
    return (events, maxSeq);
  }

  /// 事件列表里的最小 seq(锚点翻页的"更旧"边界);空列表返回 null。
  int? _minSeqOf(List<Map<String, dynamic>> events) {
    int? min;
    for (final e in events) {
      final s = (e['seq'] as num?)?.toInt();
      if (s == null) continue;
      if (min == null || s < min) min = s;
    }
    return min;
  }

  /// 排序重放一段事件(REST 按 seq 倒序返回,归约要按时间正序),水位抬到 maxSeq。
  /// 不推断 running:重建的历史最后一条是 text/tool 不代表"正在跑",
  /// running 只该由 subscribed.isProcessing + 实时终态/开始事件驱动,否则
  /// 重放后若缺 complete(如 reload 重建)会冻结成假"运行中"、按钮卡 STOP。
  ChatState _replay(List<Map<String, dynamic>> events, int maxSeq) {
    events.sort((a, b) =>
        ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0));
    var st = const ChatState();
    for (final e in events) {
      st = applyEvent(st, e);
    }
    // 重建一律从"空闲"起步;真实 running 由随后到达的 subscribed/实时事件设定。
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

  ChatState _withPermission(ChatState s, PermissionReq req) => ChatState(
        rows: s.rows,
        lastSeq: s.lastSeq,
        running: s.running,
        streamingText: s.streamingText,
        streamingThinking: s.streamingThinking,
        usage: s.usage,
        pendingPermission: req,
      );

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

  Future<void> patchSession(String id, {String? title, bool? isPinned, String? model, String? permissionMode, bool? archived, List<String>? tags, String? cwd}) async {
    await _api.patchSession(id, title: title, isPinned: isPinned, model: model, permissionMode: permissionMode, archived: archived, tags: tags, cwd: cwd);
    await _loadSessions();
    notifyListeners();
  }

  /// 复制会话(fork):服务端拷贝消息与配置;完成后刷新列表,返回新会话行。
  Future<Map<String, dynamic>> forkSession(String id) async {
    final row = await _api.forkSession(id);
    await _loadSessions();
    notifyListeners();
    return row;
  }

  /// 完整重载:先让 server 从 CLI 磁盘转录补回丢失事件,再重建会话(含分页全量)。
  /// 返回补回条数;失败返回 -1(仍会走 openSession 重建)。
  Future<int> fullReload(String id) async {
    var merged = -1;
    try {
      merged = await _api.reloadSession(id);
    } on Object {
      merged = -1;
    }
    await openSession(id);
    return merged;
  }

  /// 定时任务列表;失败返回空。
  Future<List<Map<String, dynamic>>> crons({String? sessionId}) async {
    try {
      return await _api.crons(sessionId: sessionId);
    } on Object {
      return const [];
    }
  }

  /// 后台任务(server 统一登记视图);失败返回空。
  Future<List<Map<String, dynamic>>> backgrounds(String sessionId) async {
    try {
      return await _api.backgrounds(sessionId);
    } on Object {
      return const [];
    }
  }

  /// 子代理列表(磁盘转录元数据);失败返回空。
  Future<List<Map<String, dynamic>>> subagents(String sessionId) async {
    try {
      return await _api.subagents(sessionId);
    } on Object {
      return const [];
    }
  }

  /// 子代理转录消息(只读);失败返回空。
  Future<List<Map<String, dynamic>>> subagentMessages(String sessionId, String agentId) async {
    try {
      return await _api.subagentMessages(sessionId, agentId);
    } on Object {
      return const [];
    }
  }

  /// 项目文件夹(总目录 + 名字列表);失败给空。
  Future<({String root, List<String> names})> projects() async {
    try {
      return await _api.projects();
    } on Object {
      return (root: '', names: const <String>[]);
    }
  }

  /// 新建项目文件夹,返回其 cwd;失败抛错(对话框提示)。
  Future<String> createProject(String name) => _api.createProject(name);

  // ---- 用量总览(/api/usage) ----
  Map<String, dynamic>? usageStats; // 原始快照,页面经 parseUsageStats 解析
  bool usageStatsLoading = false;
  String usageStatsRange = '7d';

  /// 拉全局用量;失败置 null(页面空态),下次刷新再试。
  Future<void> loadUsageStats({String range = '7d'}) async {
    usageStatsLoading = true;
    usageStatsRange = range;
    notifyListeners();
    try {
      usageStats = await _api.usageStats(range);
    } on Object {
      usageStats = null;
    }
    usageStatsLoading = false;
    notifyListeners();
  }

  /// 项目重命名:文件夹改名 + 其下会话 cwd 迁移;失败抛错(对话框提示)。
  Future<void> renameProject(String oldName, String newName) => _api.renameProject(oldName, newName);

  /// 删除项目:递归删文件夹 + 级联删其下会话;失败抛错(对话框提示)。
  Future<void> deleteProject(String name) => _api.deleteProject(name);

  Future<void> deleteCron(String id) async {
    try {
      await _api.deleteCron(id);
    } on Object {
      // 静默
    }
  }

  /// 导出会话 markdown;失败返回 null(调用方提示即可)。
  Future<({String filename, String markdown})?> exportSession(String id) async {
    try {
      return await _api.exportSession(id);
    } on Object {
      return null;
    }
  }

  String _notifyBody(String kind, Map<String, dynamic> ev) {
    if (kind == 'error') {
      final c = '${ev['content'] ?? ''}';
      return c.length > 60 ? c.substring(0, 60) : c;
    }
    return '有任务在后台结束了';
  }

  // ---------------------------------------------------------------- 对话动作

  /// 发消息:本地乐观行(pending),WS 发出;发不出去就回滚。images = data URI 列表。
  /// 返回 false = 没发出去(连接断开),调用方可把原文回填输入框。
  bool sendChat(String content, {String? model, String? permissionMode, String? thinking, List<String> images = const []}) {
    final sid = currentSessionId;
    final text = content.trim();
    if (sid == null || (text.isEmpty && images.isEmpty)) return false;
    chat = applyLocalUser(chat, text.isEmpty ? '[图片] ×${images.length}' : text, images: images);
    notifyListeners();
    try {
      _socket.sendChat(sid, text, model: model, permissionMode: permissionMode, thinking: thinking, images: images);
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

/// openSession 后台补齐的暂存:老页面事件 + 补齐窗口内到达的 WS 事件,
/// 拉齐后合并整体重放换底。重开会话/切会话时整个实例被丢弃(代际令牌兜底)。
class _Backfill {
  final String id;
  final List<Map<String, dynamic>> older = [];
  final List<Map<String, dynamic>> extra = [];
  _Backfill(this.id);
}
