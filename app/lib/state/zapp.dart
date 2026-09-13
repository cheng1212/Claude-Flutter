// 应用大脑:REST + WS 组合层。页面只读这里的暴露状态,变更走方法。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api.dart';
import '../debug_log.dart';
import '../ws.dart';
import '../notify.dart';
import 'reducer.dart';
import 'slices/queue_slice.dart';

export 'slices/queue_slice.dart' show QueuedMessage;

/// 打开会话时首屏拉多少条(也是按需加载每页的大小)。
/// 用户定的:100 条足够日常看,更旧的历史平时用不到 —— 滑到最旧端再按需拉。
const int kFirstPageSize = 100;

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

  // 流式 delta 合帧缓冲:delta 按 chunk 频率(可到每秒几十条)到达,逐条 notify
  // 会让整页按 chunk 频率重建(推流卡顿根因)。缓冲 40ms 合成一条再归约;
  // 任何非 delta 事件先 flush(保顺序:终态 text 必须落在残余 delta 之后,不然丢字)。
  String _pendDeltaText = '';
  String _pendDeltaThinking = '';
  int? _pendDeltaSeq;
  Timer? _pendDeltaTimer;

  // 发送排队:会话 running 时发的消息先进队列(每会话独立),回复结束按「自动消化」
  // 开关决定要不要自动推下一条。纯 app 内存态,不持久化、不过 server。
  late final QueueSlice queue = QueueSlice(
    onChanged: notifyListeners,
    currentSessionId: () => currentSessionId,
  );

  /// openSession 后台补齐(首屏后的老消息拉取);_onEvent 顺手给它留 WS 底。
  _Backfill? _backfill;

  /// 打开会话的代际令牌:快速切换/重开时,旧打开流程的后续阶段全部作废。
  int _openToken = 0;

  List<String> models = const [];
  List<Map<String, dynamic>> modelGroups = const [];
  List<Map<String, dynamic>> sessions = const [];

  /// 首次会话列表拉取完成(成败皆置):页面据此区分「加载中」与「真空空如也」
  bool sessionsLoaded = false;
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
    _socket.onChanged = () {
      if (_socket.state != _lastWsState) {
        _lastWsState = _socket.state;
        ZLog.i('ws', 'state=${_socket.state}${_socket.failure == null ? '' : ' fail=${_socket.failure}'}');
      }
      notifyListeners();
    };
    _sub = _socket.events.listen(_onEvent);
  }

  ZSocketState? _lastWsState;
  Timer? _blankWatchdog;

  /// 白屏看门狗布防:回合在跑但 rows 为空才上 2s 定时器,持续存在则留证
  /// (「回复中列表全白」现场);无事发生不留挂起定时器(测试不炸 !timersPending)。
  void _armBlankWatchdog() {
    if (_blankWatchdog != null || _disposed) return;
    if (currentSessionId == null || !chat.running || chat.rows.isNotEmpty) return;
    _blankWatchdog = Timer(const Duration(seconds: 2), () {
      _blankWatchdog = null;
      if (_disposed) return;
      if (currentSessionId != null && chat.running && chat.rows.isEmpty) {
        ZLog.w('blank',
            'rows=0 while running! hl=$historyLoading ws=${_socket.state} lastSeq=${chat.lastSeq} backfill=${_backfill != null}',
            dedupeKey: 'blank-$currentSessionId');
        _armBlankWatchdog(); // 还白着:继续盯
      } else if (currentSessionId != null && chat.running && chat.rows.length > 50) {
        // 行数不少却看着空:多半是渲染/滚动位置问题(实测白屏时 rows 有 6617 条),
        // 记一条低频样本(60s 一次),下次能直接看出是"没数据"还是"画不出来"。
        ZLog.w('blank',
            'rows=${chat.rows.length} 但界面可能空白(渲染侧);ws=${_socket.state} lastSeq=${chat.lastSeq}',
            dedupeKey: 'blank-render');
      }
    });
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
    _pendDeltaTimer?.cancel();
    _blankWatchdog?.cancel();
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
    if (kind == 'context_compacted') {
      // 压缩边界(manual = 本端点按钮,auto = CLI 自己压的):解锁按钮并记下省了多少
      final sid = ev['sessionId'] as String?;
      compacting = false;
      if (sid != null && sid == currentSessionId) {
        lastCompact = (
          pre: (ev['preTokens'] as num?)?.toInt() ?? 0,
          post: (ev['postTokens'] as num?)?.toInt() ?? 0,
          trigger: '${ev['trigger'] ?? 'manual'}',
        );
      }
      notifyListeners();
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
    if (kind == 'stream_delta' || kind == 'thinking_delta') {
      _pendDelta(kind, ev);
      return; // 合帧:缓冲期满统一归约,不逐条 notify(整页重建跟 chunk 频率脱钩)
    }
    _flushDeltas(); // 非 delta 事件先冲掉在途 delta,保住顺序(终态 text 必须落在残余 delta 之后)
    chat = applyEvent(chat, ev);
    ZLog.i('ev', '$kind seq=${ev['seq']} rows=${chat.rows.length} lastSeq=${chat.lastSeq} running=${chat.running}');
    _backfill?.extra.add(ev); // 后台补齐窗口内的实时事件留底,换底重放不丢
    if (kind == 'complete') {
      unawaited(_loadSessions(silent: true));
      _maybeAutoConsume(); // 回合落定:自动消化队首(开关开 + 队列非空才真的推)
    }
    _armBlankWatchdog();
    notifyListeners();
  }

  // ---------------------------------------------------------------- delta 合帧

  void _pendDelta(String kind, Map<String, dynamic> ev) {
    final content = ev['content'] as String? ?? '';
    final seq = ev['seq'] as int?;
    if (seq != null) _pendDeltaSeq = seq; // 只记最大序号:合帧后中间号无意义
    if (kind == 'stream_delta') {
      _pendDeltaText += content;
    } else {
      _pendDeltaThinking += content;
    }
    _pendDeltaTimer ??= Timer(const Duration(milliseconds: 40), _flushDeltas);
  }

  /// 把缓冲的 delta 合成一条归约进 chat(有残余才 notify)。
  void _flushDeltas() {
    _pendDeltaTimer?.cancel();
    _pendDeltaTimer = null;
    if (_pendDeltaText.isEmpty && _pendDeltaThinking.isEmpty) return;
    final text = _pendDeltaText;
    final thinking = _pendDeltaThinking;
    final seq = _pendDeltaSeq;
    _pendDeltaText = '';
    _pendDeltaThinking = '';
    _pendDeltaSeq = null;
    ZLog.i('delta', 'flush text+${text.length} think+${thinking.length} seq=$seq');
    var changed = false;
    if (thinking.isNotEmpty) {
      chat = applyEvent(chat, {'kind': 'thinking_delta', 'content': thinking, 'seq': ?seq});
      changed = true;
    }
    if (text.isNotEmpty) {
      chat = applyEvent(chat, {'kind': 'stream_delta', 'content': text, 'seq': ?seq});
      changed = true;
    }
    if (changed) {
      _armBlankWatchdog();
      notifyListeners();
    }
  }

  /// 丢弃在途 delta(切会话):旧会话的瞬时流式尾巴不该落进新会话。
  void _dropDeltas() {
    _pendDeltaTimer?.cancel();
    _pendDeltaTimer = null;
    _pendDeltaText = '';
    _pendDeltaThinking = '';
    _pendDeltaSeq = null;
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
    } finally {
      sessionsLoaded = true;
    }
  }

  /// 手动刷新:把成败**报给调用方**(页面据此给可见反馈——转圈/条数/失败原因)。
  Future<({bool ok, int count, String? error})> refreshSessions() async {
    final before = error;
    await _loadSessions();
    notifyListeners();
    final failed = error != null && error != before;
    return (ok: !failed, count: sessions.length, error: failed ? error : null);
  }

  /// 打开(或重开刷新)会话:首屏只等最新一页立即上屏,老消息后台补齐后整体换底。
  /// 全量拉完才渲染是"进去转圈好久"的根源:大会话十几页串行拉完才画第一帧。
  Future<void> openSession(String id) async {
    // 同会话刷新时保留待审批卡片:审批请求不落库,REST 重建不出来;
    // 丢了卡片没人能批,服务端 runtime 会一直等(INTERACTIVE 工具无超时)→ 会话卡死。
    final switching = currentSessionId != id;
    final keepPermission = currentSessionId == id ? chat.pendingPermission : null;
    final liveBeforeLoad = currentSessionId == id ? chat : null;
    currentSessionId = id;
    if (switching) {
      chat = const ChatState(); // 切会话:先清,等首屏
    } else {
      // 同会话刷新:旧内容原地保留(stale-while-revalidate)。先清空再拉的话,
      // 网络一抖(实测:WS 掉线与 REST 超时同秒发生)拉取失败 = 列表全白,即
      // 「回复中突然卡住/白屏」的根因;保留旧内容最坏也就是旧数据+一条错误提示。
    }
    historyLoading = true;
    error = null;
    _dropDeltas(); // 旧会话的在途流式尾巴不跟进新会话
    final token = ++_openToken;
    _backfill = null;
    final bf = _Backfill(id);
    _backfill = bf; // 先挂缓冲再拉取:补齐窗口内到达的 WS 事件留底,换底重放不丢
    ZLog.i('open', 'openSession $id (token=$token, switching=$switching)');
    notifyListeners();
    try {
      // 首屏失败自动重试一次:主线程被大会话占满时,HTTP 响应回调会被排到队尾
      // 而误判超时 —— 不该因此直接落到"空态白屏",等 600ms 主线程喘过来再试。
      Future<({List<Map<String, dynamic>> messages, int total})> fetchFirst() async {
        try {
          return await _api.messages(id, limit: kFirstPageSize, offset: 0);
        } on Object catch (e) {
          ZLog.w('open', '首屏失败,600ms 后重试: $e', dedupeKey: 'first-retry-$id');
          await Future<void>.delayed(const Duration(milliseconds: 600));
          return await _api.messages(id, limit: kFirstPageSize, offset: 0);
        }
      }

      final first = await fetchFirst();
      if (token != _openToken) return;
      ZLog.i('open', 'first page rows=${first.messages.length} total=${first.total}');
      final (headEvents, maxSeq) = _histEvents(first);
      // 首屏即并入留底的实时事件:REST 读取发生在落库/回显之前时,窗口内到达的
      // 回显消息只存在于 bf.extra——不并进来就会被下面这行 `chat = st` 整体覆盖,
      // 且之后无人补回(去重指针已被抬高,订阅补发不重发 ≤N)。
      var st = _replay([...headEvents, ...bf.extra], maxSeq);
      if (keepPermission != null && st.pendingPermission == null) {
        st = _withPermission(st, keepPermission);
      }
      if (liveBeforeLoad != null) st = _keepLiveState(st, liveBeforeLoad);
      // 记住"最旧到哪"与"还有没有更旧的":用户滑到最旧端时按需再拉(见 loadOlder)。
      // 打开会话**只拉最新 kFirstPageSize 条**——按用户要求,更旧的历史平时用不到;
      // 早先的"后台一口气翻十几页"正是大会话白屏的成因(主线程被解析占满→请求超时)。
      st = copyChat(st,
          oldestSeq: _minSeqOf(headEvents) ?? 0,
          hasMoreOlder: first.total > first.messages.length);
      _backfill = null; // 首屏已并入 extra,不需要留底了
      chat = st;
      historyLoading = false;
      _armBlankWatchdog();
      notifyListeners();
      // 行号才是权威锚:meta 里的 seq 是服务器事件流编号,可能来自旧进程的
      // 天文数字(与 DB 行号分家),照抄会把去重指针毒化 → 新事件全被丢弃。
      _socket.seedLastSeq(id, maxSeq > st.lastSeq ? maxSeq : st.lastSeq);
      _socket.subscribeSession(id);
    } on Object catch (e) {
      if (token != _openToken) return;
      _backfill = null;
      historyLoading = false;
      error = '$e';
      // 同会话刷新失败:旧内容仍在(不再白屏);切换失败:留在空态+错误条
      ZLog.e('open', 'openSession $id 失败: $e(${switching ? '新会话,留空态' : '旧内容原地保留'})');
      notifyListeners();
    }
  }

  /// 重建态叠加实时态:REST/_replay 重建不推断 running,换底时以会话当前的
  /// 实时字段(subscribed/终态/上游相位)为准,只取 rows/lastSeq/用量/审批卡。
  ChatState _keepLiveState(ChatState fresh, ChatState live) {
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

  /// 是否正在加载更旧的一页(UI 显示"加载更早的消息…")。
  bool loadingOlder = false;

  /// 按需加载更旧的一页:用户滑到最旧端时调。
  ///
  /// 打开会话只拉最新 [kFirstPageSize] 条,更旧的历史平时用不到(用户要求);
  /// 早先"后台一口气翻十几页"正是大会话白屏的成因。
  /// 用 [ChatState.oldestSeq] 作锚点(比它更旧的一页),免疫新消息插入导致的漂移。
  Future<void> loadOlder() async {
    final sid = currentSessionId;
    if (sid == null || loadingOlder || !chat.hasMoreOlder || chat.oldestSeq <= 0) return;
    final token = _openToken;
    loadingOlder = true;
    notifyListeners();
    try {
      final hist = await _api.messages(sid, limit: kFirstPageSize, beforeSeq: chat.oldestSeq);
      if (token != _openToken || currentSessionId != sid) return;
      final (older, _) = _histEvents(hist);
      if (older.isEmpty) {
        chat = copyChat(chat, hasMoreOlder: false);
        return;
      }
      // ⚠️ 必须按 seq 升序归约:server 返回的是**倒序**(ORDER BY seq DESC),而
      // applyEvent 的去重是"seq ≤ lastSeq 即丢弃" —— 倒序灌进去只有第一条能活,
      // 其余全被当重复扔掉(实测:一页 100 条只接上 1 条)。
      older.sort((a, b) => ((a['seq'] as num?) ?? 0).compareTo((b['seq'] as num?) ?? 0));
      // 把这批更旧的事件归约成行(独立缓冲,不动现有 state),再整体接到最前面。
      final sink = <ChatRow>[];
      var tmp = const ChatState();
      for (final e in older) {
        tmp = applyEvent(tmp, e, sink: sink);
      }
      final minSeq = _minSeqOf(older) ?? chat.oldestSeq;
      chat = copyChat(chat,
          rows: [...sink, ...chat.rows],
          oldestSeq: minSeq,
          hasMoreOlder: hist.messages.length >= kFirstPageSize);
      ZLog.i('open', 'loadOlder +${sink.length} 条(最旧 seq=$minSeq,还有更旧=${chat.hasMoreOlder})');
    } on Object catch (e) {
      if (token != _openToken) return;
      error = '加载更早的消息失败:$e';
      ZLog.w('open', 'loadOlder 失败: $e', dedupeKey: 'load-older-$sid');
    } finally {
      loadingOlder = false;
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
    // 共用行缓冲:重建一个 8000 行的会话原来是 O(n²)(每行复制整表),打开要卡几秒
    // (实测 swap 比首屏晚 4.8 秒)。走 sink 后是 O(n)。
    final sink = <ChatRow>[];
    var st = const ChatState();
    for (final e in events) {
      st = applyEvent(st, e, sink: sink);
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
        // 这几个是瞬态/本地态,只换审批卡不该把它们丢掉
        upstreamPhase: s.upstreamPhase,
        upstreamAt: s.upstreamAt,
        liveContextTokens: s.liveContextTokens,
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
    queue.discardQueues(id); // 会话没了,排队消息一并丢弃
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
    for (final id in ids) {
      queue.discardQueues(id); // 会话没了,排队消息一并丢弃
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

  /// 让服务器自我重启:server 先回 202 再拉起新实例并退出,之后连接会断几秒,
  /// 由既有 WS 自动重连恢复。抛错 = 压根没送出去(如旧版 server 无此接口)。
  Future<void> restartServer() => _api.restartServer();

  // ---------------------------------------------------------------- 上下文压缩

  /// 压缩中(UI 按钮转圈用);完成/超时/失败都会复位。
  bool compacting = false;

  /// 最近一次压缩结果(pre → post tokens),供 UI 显示"省了多少"。
  ({int pre, int post, String trigger})? lastCompact;

  /// 手动压缩上下文:发 CLI 的 `/compact` 指令,压缩完成由 context_compacted 事件回报。
  /// 回合进行中不让压(CLI 那一刻在处理别的),先提示等这一轮结束。
  Future<void> compactContext() async {
    final sid = currentSessionId;
    if (sid == null || compacting) return;
    if (chat.running) {
      error = '正在回复中,等这一轮结束再压缩上下文';
      notifyListeners();
      return;
    }
    compacting = true;
    notifyListeners();
    try {
      _socket.sendChat(sid, '/compact');
    } on Object catch (e) {
      compacting = false;
      error = '压缩请求没发出去:$e';
      notifyListeners();
      return;
    }
    // 兜底:CLI 不认这个命令时不会有 compact_boundary,别让按钮永远转圈
    Timer(const Duration(seconds: 60), () {
      if (_disposed || !compacting) return;
      compacting = false;
      error = '压缩没有回应(CLI 可能不支持该命令)';
      notifyListeners();
    });
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
  Future<List<Map<String, dynamic>>> crons({String? sessionId, bool includePaused = false}) async {
    try {
      return await _api.crons(sessionId: sessionId, includePaused: includePaused);
    } on Object {
      return const [];
    }
  }

  /// 启用/暂停定时任务(面板开关)。抛错给调用方提示,不静默。
  Future<void> setCronActive(String id, {required bool active}) => _api.setCronActive(id, active: active);

  /// 立即运行一次(会话在跑时 server 回 409 → 抛错,由面板提示原因)。
  Future<void> runCronNow(String id) => _api.runCronNow(id);

  Future<void> restartCron(String id) => _api.restartCron(id);

  Future<List<Map<String, dynamic>>> cronRuns(String id) => _api.cronRuns(id);

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
  bool usageStatsError = false; // 拉取失败(区别于「暂无数据」的真空态)
  String usageStatsRange = '7d';

  /// 拉全局用量;失败置 null(页面空态),下次刷新再试。
  Future<void> loadUsageStats({String range = '7d'}) async {
    usageStatsLoading = true;
    usageStatsError = false;
    usageStatsRange = range;
    notifyListeners();
    try {
      usageStats = await _api.usageStats(range);
    } on Object {
      usageStats = null;
      usageStatsError = true;
    }
    usageStatsLoading = false;
    notifyListeners();
  }

  /// 上传文件到当前会话(电脑端 cwd/uploads/),返回 {显示名, 电脑路径}。
  /// [onProgress] 0.0~1.0(不传则无进度);网络错误自动重试 2 次(0.8s/1.6s 退避)。
  /// 失败抛错(调用方 toast)。
  Future<({String name, String path})> uploadFile(
      String fileName, List<int> bytes,
      {void Function(double progress)? onProgress}) async {
    final sid = currentSessionId;
    if (sid == null) throw Exception('未打开会话');
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        final path = await _api.uploadFile(sid, fileName, bytes,
            onProgress: onProgress == null
                ? null
                : (p) => onProgress(p.clamp(0.0, 1.0)));
        return (name: fileName, path: path);
      } on Object catch (e) {
        final retryable =
            e.toString().contains('超时') || e.toString().contains('网络');
        if (!retryable || attempt > 2) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 800 << (attempt - 1)));
      }
    }
  }

  /// 项目重命名:文件夹改名 + 其下会话 cwd 迁移;失败抛错(对话框提示)。
  Future<void> renameProject(String oldName, String newName) => _api.renameProject(oldName, newName);

  /// 删除项目:递归删文件夹 + 级联删其下会话;失败抛错(对话框提示)。
  Future<void> deleteProject(String name) => _api.deleteProject(name);

  /// 删除定时任务。**不吞异常**:原来这里静默,面板里"删除失败"的提示永远不会弹
  /// (调用方写了 try/catch 却永远等不到异常),用户点了没反应还以为删掉了。
  /// 返回 true = 已通知到会话的 CLI 撤销(那边才是真正在调度的)。
  Future<bool> deleteCron(String id) => _api.deleteCron(id);

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
    if (sid == null) {
      // 原来这里静默 return:用户点了没反应也查不到原因
      error = '停止失败:当前没有打开的会话';
      notifyListeners();
      return;
    }
    try {
      _socket.abort(sid);
    } on Object {
      error = '停止失败:连接未就绪(正在自动重连),请稍后再按';
      notifyListeners();
    }
  }

  // ---------------------------------------------------------------- 发送排队

  // 队列领域规则已迁入 QueueSlice(T4 试点);以下为兼容委托,UI 零改动。
  List<QueuedMessage> queueOf(String sid) => queue.queueOf(sid);

  int queueCount(String sid) => queue.queueCount(sid);

  bool autoConsumeOf(String sid) => queue.autoConsumeOf(sid);

  void setAutoConsume(String sid, {required bool on}) => queue.setAutoConsume(sid, on: on);

  String enqueue(String text, {List<String> images = const []}) => queue.enqueue(text, images: images);

  void promoteQueued(String sid, int index) => queue.promoteQueued(sid, index);

  void removeQueued(String sid, int index) => queue.removeQueued(sid, index);

  bool editQueued(String sid, int index, String text) => queue.editQueued(sid, index, text);

  /// 从队列取出第 [index] 条立即发送:打断当前回合,等落定(强裁兜底最长几秒)
  /// 后推出去;发送失败则塞回队首不丢。
  Future<bool> sendQueuedNow(String sid, int index,
      {String? model, String? permissionMode, String? thinking}) async {
    final m = queue.takeQueued(sid, index);
    if (m == null) return false;
    notifyListeners();
    final ok = await interruptAndSend(m.text,
        model: model, permissionMode: permissionMode, thinking: thinking, images: m.images);
    if (!ok && currentSessionId == sid) {
      queue.requeueFirst(sid, m);
      notifyListeners();
    }
    return ok;
  }

  /// 打断当前回合并立即发送:abort → 等回合落定(server 强裁兜底保证最长几秒)
  /// → sendChat。落定超时(12s)时返回发送结果(可能被 RUN_IN_PROGRESS 拒)。
  Future<bool> interruptAndSend(String content,
      {String? model, String? permissionMode, String? thinking, List<String> images = const []}) async {
    abort();
    final deadline = DateTime.now().add(const Duration(seconds: 12));
    while (chat.running && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    return sendChat(content, model: model, permissionMode: permissionMode, thinking: thinking, images: images);
  }

  /// 回合落定(complete)后自动消化队首:开关开 + 队列非空 + 无待审批才推。
  /// 推送前若会话已切走/又在跑,消息塞回队首不丢。
  void _maybeAutoConsume() {
    final sid = currentSessionId;
    if (sid == null || chat.running || chat.pendingPermission != null) return;
    if (queue.queueCount(sid) == 0 || !queue.autoConsumeOf(sid)) return;
    final m = queue.takeQueued(sid, 0);
    if (m == null) return;
    notifyListeners();
    Timer(const Duration(milliseconds: 400), () {
      if (_disposed) return;
      if (currentSessionId != sid) {
        queue.requeueFirst(sid, m); // 切走了:留回原会话队列
        return;
      }
      if (chat.running || chat.pendingPermission != null) {
        queue.requeueFirst(sid, m); // 又在跑/等审批:塞回队首
        notifyListeners();
        return;
      }
      final ok = sendChat(m.text, images: m.images);
      if (!ok) {
        queue.requeueFirst(sid, m); // 没发出去(如断线):不丢
        notifyListeners();
      }
    });
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
