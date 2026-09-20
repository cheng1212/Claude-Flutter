// 会话列表状态切片(优化方案 T4 第三刀):从 ZApp 拆出的领域切片。
// 纯状态 + 拉取/防抖规则;跨域依赖由 ZApp 注入,依赖方向:slice 不可反向引用 ZApp。
// - [onChanged]:数据变化后由 ZApp 传入 notifyListeners(UI 仍只监听 ZApp,零改动)
// - [onError]:非静默拉取失败写 ZApp.error(聊天页顶部错误条数据源)
// - [fetchSessions]:REST 拉取器(ZApp._api.sessions 包装)

import 'dart:async';

class SessionsSlice {
  SessionsSlice({
    required this.onChanged,
    required this.onError,
    required this.fetchSessions,
  });

  final void Function() onChanged;
  final void Function(String message) onError;
  final Future<List<Map<String, dynamic>>> Function() fetchSessions;

  List<Map<String, dynamic>> sessions = const [];

  /// 首次会话列表拉取完成(成败皆置):页面据此区分「加载中」与「真空空如也」。
  bool sessionsLoaded = false;

  Timer? _dirtyTimer;
  bool _disposed = false;

  /// 拉取会话列表。[silent] = 后台自动刷新(定时/事件驱动),失败保持静默:
  /// 一次 REST 抖动不该在聊天页顶上弹错误条。
  Future<void> load({bool silent = false}) async {
    try {
      sessions = await fetchSessions();
      sessionsLoaded = true;
      onChanged();
    } on Object catch (e) {
      sessionsLoaded = true;
      if (!silent) onError('$e');
      onChanged();
    }
  }

  /// 手动刷新:把成败**报给调用方**(页面据此给可见反馈——转圈/条数/失败原因)。
  Future<({bool ok, int count, String? error})> refresh() async {
    try {
      sessions = await fetchSessions();
      sessionsLoaded = true;
      onChanged();
      return (ok: true, count: sessions.length, error: null);
    } on Object catch (e) {
      final msg = '$e';
      onError(msg);
      onChanged();
      return (ok: false, count: 0, error: msg);
    }
  }

  /// 任一会话开跑/跑完的服务端广播:250ms 防抖合并成一次 REST,列表徽章跟着活。
  /// 控制事件,无 seq,不进归约。
  void scheduleDirtyReload({required bool Function() isAlive}) {
    _dirtyTimer?.cancel();
    _dirtyTimer = Timer(const Duration(milliseconds: 250), () async {
      if (_disposed || !isAlive()) return;
      await load(silent: true);
    });
  }

  void dispose() {
    _disposed = true;
    _dirtyTimer?.cancel();
  }
}
