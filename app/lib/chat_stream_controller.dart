// 流式聊天的数据层(标准工程方案 §3):delta 高频到达,按 40ms 节流 flush,
// 绝不让渲染跟随 chunk 频率。传输层只把 delta 交给这里,永远不直接触碰 UI。
//
// 用法(与 zcode reducer 对接):
//   传输层收到 stream_delta → controller.onText(delta 内容)
//   收到 thinking_delta     → controller.onThinking(delta 内容)
//   flush 回调里把缓冲内容作为一次合成的流式更新交给 reducer/notify
//   turn 结束(complete/error/abort/切会话) → finish() 或 reset()
import 'dart:async';
import 'package:flutter/foundation.dart';

/// 流式中的临时状态,turn 定稿前不属于任何持久消息。
class StreamState {
  const StreamState({required this.text, required this.thinking, required this.active});

  /// 已 flush 到 UI 的流式正文
  final String text;

  /// 已 flush 到 UI 的流式思考
  final String thinking;

  /// true = 正在流式
  final bool active;

  static const StreamState idle =
      StreamState(text: '', thinking: '', active: false);
}

/// delta 缓冲节流控制器。
///
/// - 同一个 Timer 复用:缓冲期间新 delta 只追加,不新建定时器;
/// - [finish] 必须无条件调用(正常结束/abort/出错/断线都调),
///   否则残余 delta 丢失或下游光标永闪;
/// - [reset] 切会话时清空一切在途状态,防止跨会话泄漏。
class ChatStreamController {
  ChatStreamController({
    this.interval = const Duration(milliseconds: 40),
    this.onFlush,
  });

  /// flush 周期(标准 40ms ≈ 25fps,端到端延迟 ≤56ms 人眼无感)
  final Duration interval;

  /// 每次 flush 后回调一次(页面在此把缓冲内容交给渲染/reducer)
  final void Function(StreamState state)? onFlush;

  final ValueNotifier<StreamState> state =
      ValueNotifier<StreamState>(StreamState.idle);

  String _pendingText = '';
  String _pendingThinking = '';
  Timer? _timer;
  bool _active = false;

  static const StreamState _idleState = StreamState(text: '', thinking: '', active: false);

  /// 传输层唯一入口:正文 delta。
  void onText(String delta) {
    if (delta.isEmpty) return;
    if (!_active) _beginTurn();
    _pendingText += delta;
    _timer ??= Timer(interval, _flush);
  }

  /// 传输层唯一入口:思考 delta。
  void onThinking(String delta) {
    if (delta.isEmpty) return;
    if (!_active) _beginTurn();
    _pendingThinking += delta;
    _timer ??= Timer(interval, _flush);
  }

  void _beginTurn() {
    _active = true;
    state.value = const StreamState(text: '', thinking: '', active: true);
  }

  void _flush() {
    _timer = null;
    if (_pendingText.isEmpty && _pendingThinking.isEmpty) return;
    final text = _pendingText;
    final thinking = _pendingThinking;
    _pendingText = '';
    _pendingThinking = '';
    state.value = StreamState(
        text: state.value.text + text,
        thinking: state.value.thinking + thinking,
        active: true);
    onFlush?.call(state.value);
  }

  /// 流结束/中断/出错:立刻把残余刷出去并定稿(active=false 让光标消失)。
  void finish() {
    _timer?.cancel();
    _timer = null;
    if (_pendingText.isNotEmpty || _pendingThinking.isNotEmpty) {
      state.value = StreamState(
          text: state.value.text + _pendingText,
          thinking: state.value.thinking + _pendingThinking,
          active: false);
      onFlush?.call(state.value);
    } else {
      state.value = StreamState(
          text: state.value.text,
          thinking: state.value.thinking,
          active: false);
    }
    _active = false;
  }

  /// 切会话/重置:清空一切在途状态,防止跨会话泄漏。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _pendingText = '';
    _pendingThinking = '';
    _active = false;
    state.value = _idleState;
  }

  void dispose() {
    _timer?.cancel();
    state.dispose();
  }
}
