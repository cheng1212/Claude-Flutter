// 诊断日志:环形缓冲最近 N 条,只记事件元数据(种类/序号/行数/状态),不记消息内容。
// 出现「卡死/白屏/丢消息」时,设置里一键复制贴回来即可定位;每条同步 debugPrint,
// 手机插 USB 时 `adb logcat -s flutter` 能实时看到。
import 'dart:async';

import 'package:flutter/foundation.dart';

class ZLog {
  static final List<String> _lines = <String>[];
  static const int kMax = 800;
  static final Map<String, int> _dedupeAt = <String, int>{};
  static bool _installed = false;

  /// 主线程看门狗:正常每秒一跳;两次执行间隔超过阈值 = 主线程被卡住
  /// (「回复时卡死」这类现场,自动留证)。公有便于测试里取消防泄漏。
  static Timer? stallTimer;
  static DateTime _lastTick = DateTime.now();
  static const int _stallThresholdMs = 3000;

  static void _put(String line) {
    _lines.add(line);
    if (_lines.length > kMax) _lines.removeRange(0, _lines.length - kMax);
    // debugPrint 在 release 也可用(自带限速);adb logcat -s flutter 实时可看
    debugPrint(line);
  }

  static String _ts() {
    final now = DateTime.now();
    String p2(int v) => v.toString().padLeft(2, '0');
    return '${p2(now.hour)}:${p2(now.minute)}:${p2(now.second)}.${now.millisecond.toString().padLeft(3, '0')}';
  }

  static void i(String tag, String msg) => _put('${_ts()} [$tag] $msg');

  static void e(String tag, String msg) => _put('${_ts()} [$tag][ERR] $msg');

  /// 同一 [dedupeKey] 10 秒内只记一条(防告警刷屏)。
  static void w(String tag, String msg, {String? dedupeKey}) {
    if (dedupeKey != null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final last = _dedupeAt[dedupeKey];
      if (last != null && now - last < 10000) return;
      _dedupeAt[dedupeKey] = now;
    }
    _put('${_ts()} [$tag][!] $msg');
  }

  static String dump() => _lines.join('\n');

  static void clear() {
    _lines.clear();
    _dedupeAt.clear();
  }

  /// 在 main() 最早处调用:接管框架异常 + 启动主线程看门狗(自续跳,非周期定时器)。
  static void install() {
    if (_installed) return;
    _installed = true;
    FlutterError.onError = (details) {
      e('flutter', details.exceptionAsString());
      final stack = details.stack?.toString().split('\n').take(5).join(' | ') ?? '';
      if (stack.isNotEmpty) i('flutter', 'at $stack');
      FlutterError.presentError(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      e('uncaught', '$error');
      i('uncaught', 'at ${stack.toString().split('\n').take(5).join(' | ')}');
      return false;
    };
    _stallCheck();
  }

  static void _stallCheck() {
    final now = DateTime.now();
    final gap = now.difference(_lastTick).inMilliseconds;
    _lastTick = now;
    if (gap > _stallThresholdMs) {
      _put('${_ts()} [main][!] 主线程卡顿约 ${(gap / 1000).toStringAsFixed(1)}s(定时器未能按时执行)');
    }
    stallTimer = Timer(const Duration(seconds: 1), _stallCheck);
  }
}
