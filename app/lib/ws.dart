import 'dart:async';
import 'dart:convert';

import 'package:web_socket_channel/web_socket_channel.dart';

/// WS 通道 seam:测试注入内存假件,运行时走 web_socket_channel。
abstract class ZChannel {
  Stream<Map<String, dynamic>> get messages;
  void send(Object? data);
  Future<void> close();
}

typedef ZChannelFactory = Future<ZChannel> Function(Uri uri);

enum ZSocketState { idle, connecting, open, reconnecting, closed }

class ZSocketException implements Exception {
  final String message;
  const ZSocketException(this.message);
  @override
  String toString() => message;
}

/// zcode-server WS 客户端:auth → 订阅(seq 续传) → 心跳 → 断线指数退避重连。
class ZSocket {
  ZSocket({
    required this.uri,
    required this.token,
    ZChannelFactory? factory,
    this.backoffBase = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 30),
    this.pingEvery = const Duration(seconds: 25),
    DateTime Function()? clock,
    this.onChanged,
  })  : _factory = factory ?? ioChannelFactory,
        _now = clock ?? DateTime.now;

  final Uri uri; // ws://host:5190
  final String token;
  final ZChannelFactory _factory;
  final Duration backoffBase;
  final Duration maxBackoff;
  final Duration pingEvery;
  /// 时钟 seam:测试注入假时针,判活逻辑不依赖真实时间的快慢。
  final DateTime Function() _now;
  /// 连接状态变化回调(ZApp 挂 notifyListeners;可换绑)。
  void Function()? onChanged;

  ZSocketState state = ZSocketState.idle;
  String? failure;
  int attempts = 0;

  final _events = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get events => _events.stream;

  final _wantSubs = <String>{};
  final _lastSeq = <String, int>{};
  ZChannel? _channel;
  StreamSubscription<Map<String, dynamic>>? _sub;
  Timer? _retry;
  Timer? _ping;
  DateTime _lastInbound = DateTime.now();
  bool _disposed = false;


  /// 连接并鉴权;失败抛 ZSocketException。
  Future<void> connect() async {
    _disposed = false;
    attempts = 0;
    await _dial();
  }

  Future<void> _dial() async {
    _checkDisposed();
    _setState(ZSocketState.connecting);
    final ZChannel ch;
    try {
      ch = await _factory(uri);
    } on Object catch (e) {
      failure = '$e';
      throw ZSocketException(failure!);
    }
    _channel = ch;
    final first = Completer<Map<String, dynamic>>();
    late final StreamSubscription<Map<String, dynamic>> handshaker;
    handshaker = ch.messages.listen((m) {
      if (!first.isCompleted) first.complete(m);
    }, onDone: () {
      if (!first.isCompleted) first.completeError(const ZSocketException('连接被关闭'));
    }, onError: (Object e) {
      if (!first.isCompleted) first.completeError(e);
    });
    ch.send({'type': 'auth', 'token': token});
    try {
      final reply = await first.future.timeout(const Duration(seconds: 8));
      if (reply['kind'] != 'authenticated') {
        throw ZSocketException('${reply['content'] ?? reply['kind'] ?? '鉴权失败'}');
      }
    } on Object {
      await ch.close();
      _channel = null;
      rethrow;
    } finally {
      await handshaker.cancel();
    }
    _sub = ch.messages.listen(_onData, onDone: _onDown, onError: (Object _) => _onDown());
    failure = null;
    attempts = 0;
    _setState(ZSocketState.open);
    _startPing();
    _resubscribe();
  }

  void _onData(Map<String, dynamic> m) {
    _lastInbound = _now();
    final kind = m['kind'];
    final sessionId = m['sessionId'] as String?;
    if (kind == 'replay') {
      final list = m['events'] as List? ?? const [];
      for (final e in list) {
        if (e is Map) _track(e.cast<String, dynamic>());
      }
    }
    if (sessionId is String) _track(m);
    if (!_events.isClosed) _events.add(m);
  }

  void _track(Map<String, dynamic> m) {
    final sessionId = m['sessionId'] as String?;
    final seq = m['seq'] as num?;
    if (sessionId == null || seq == null) return;
    final cur = _lastSeq[sessionId] ?? 0;
    if (seq.toInt() > cur) _lastSeq[sessionId] = seq.toInt();
  }

  void _onDown() {
    _ping?.cancel();
    _ping = null;
    _sub?.cancel();
    _sub = null;
    _channel = null;
    if (_disposed || state == ZSocketState.closed) return;
    _setState(ZSocketState.reconnecting);
    final delay = backoffBase * (1 << attempts.clamp(0, 20));
    final capped = delay > maxBackoff ? maxBackoff : delay;
    attempts++;
    _retry = Timer(capped, () {
      _dial().catchError((Object _) => _onDown());
    });
  }

  void _setState(ZSocketState s) {
    state = s;
    onChanged?.call();
  }

  void _send(Map<String, dynamic> payload) {
    final ch = _channel;
    if (state != ZSocketState.open || ch == null) {
      throw ZSocketException('未连接');
    }
    ch.send(payload);
  }

  void _startPing() {
    _ping?.cancel();
    _lastInbound = _now();
    _ping = Timer.periodic(pingEvery, (_) {
      // 假死连接:TCP 没断但对面早不在了(服务器重启/中间设备静默丢弃),
      // 本地永远等不到 onDone。两个周期没收到任何来包(含 pong)→ 主动判死重连。
      if (_now().difference(_lastInbound) > pingEvery * 2) {
        _onDown();
        return;
      }
      try {
        _channel?.send({'type': 'ping'});
      } on Object {
        // 发送失败视为断线,交给 onDone/onError 路径处理
      }
    });
  }

  void _resubscribe() {
    if (_wantSubs.isEmpty) return;
    _send({
      'type': 'chat.subscribe',
      'sessions': [
        for (final id in _wantSubs) {'sessionId': id, 'lastSeq': _lastSeq[id] ?? 0},
      ],
    });
  }

  int lastSeq(String sessionId) => _lastSeq[sessionId] ?? 0;

  /// 用 REST 历史推到的 seq 播种(只前进);重连补订从这儿续。
  void seedLastSeq(String sessionId, int seq) {
    if (seq > (_lastSeq[sessionId] ?? 0)) _lastSeq[sessionId] = seq;
  }

  /// 订阅会话;已连接时立即发送,否则等重连后统一补订。
  void subscribeSession(String sessionId) {
    _wantSubs.add(sessionId);
    if (state == ZSocketState.open) _resubscribe();
  }

  void sendChat(String sessionId, String content, {String? model, String? permissionMode, List<String> images = const []}) {
    // default 不占 options:显式发 'default' 会在服务端压掉 DB 里 PATCH 过的模式
    // (UI 列表偶发没拉到时 _mode 兜底 'default',那一轮权限就被悄悄降级),缺省让服务端读 DB。
    final options = <String, dynamic>{
      if (model != null && model.isNotEmpty && model != 'default') 'model': model,
      if (permissionMode != null && permissionMode.isNotEmpty && permissionMode != 'default')
        'permissionMode': permissionMode,
    };
    _send({
      'type': 'chat.send',
      'sessionId': sessionId,
      'content': content,
      if (images.isNotEmpty) 'images': images,
      if (options.isNotEmpty) 'options': options,
    });
  }

  void answerPermission(String sessionId, String requestId, {required bool allow, String message = ''}) {
    _send({
      'type': 'chat.permission-response',
      'sessionId': sessionId,
      'requestId': requestId,
      'allow': allow,
      'message': message,
    });
  }

  void abort(String sessionId) {
    _send({'type': 'chat.abort', 'sessionId': sessionId});
  }

  /// 断开且不再自动重连。
  Future<void> close() async {
    _disposed = true;
    _setState(ZSocketState.closed);
    _retry?.cancel();
    _ping?.cancel();
    await _sub?.cancel();
    await _channel?.close();
    _channel = null;
    if (!_events.isClosed) _events.close();
  }

  void _checkDisposed() {
    if (_disposed) throw const ZSocketException('socket 已关闭');
  }
}

/// 真实通道:WebSocketChannel 包装。
class WSChannel implements ZChannel {
  WSChannel(WebSocketChannel channel) : _channel = channel {
    messages = _channel.stream
        .map((raw) => jsonDecode(raw as String) as Map<String, dynamic>)
        .asBroadcastStream();
  }

  final WebSocketChannel _channel;
  @override
  late final Stream<Map<String, dynamic>> messages;

  @override
  void send(Object? data) => _channel.sink.add(jsonEncode(data));

  @override
  Future<void> close() => _channel.sink.close();
}

Future<ZChannel> ioChannelFactory(Uri uri) async {
  return WSChannel(WebSocketChannel.connect(uri));
}
