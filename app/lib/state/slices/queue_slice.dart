// 发送排队状态切片(优化方案 T4 试点):从 ZApp 拆出的第一个领域切片。
// 纯状态 + 领域规则;跨域依赖由 ZApp 注入,依赖方向:slice 不可反向引用 ZApp。
// - [onChanged]:数据变化后由 ZApp 传入 notifyListeners(UI 仍只监听 ZApp,零改动)
// - [currentSessionId]:当前会话读取器(enqueue 落到哪个会话)
// QueuedMessage 在本文件定义,zapp.dart 转出保持下游 import 不变。

import 'package:flutter/foundation.dart';

/// 排队中的消息(会话 running 时发的、等上一轮结束后再推的消息)。
@immutable
class QueuedMessage {
  const QueuedMessage({required this.id, required this.text, this.images = const []});
  final String id;
  final String text;
  final List<String> images;
}

class QueueSlice {
  QueueSlice({required this.onChanged, required this.currentSessionId});

  final void Function() onChanged;
  final String? Function() currentSessionId;

  final Map<String, List<QueuedMessage>> _queues = {};
  final Set<String> _autoConsumeOff = {}; // 默认开;关掉的会话记在这里
  int _queuedSeq = 0;

  List<QueuedMessage> queueOf(String sid) => _queues[sid] ?? const [];

  int queueCount(String sid) => _queues[sid]?.length ?? 0;

  bool autoConsumeOf(String sid) => !_autoConsumeOff.contains(sid);

  void setAutoConsume(String sid, {required bool on}) {
    if (on) {
      _autoConsumeOff.remove(sid);
    } else {
      _autoConsumeOff.add(sid);
    }
    onChanged();
  }

  /// 入队。返回 'queued' 成功 / 'duplicate' 队内已有同文消息(去重不入)。
  String enqueue(String text, {List<String> images = const []}) {
    final sid = currentSessionId();
    if (sid == null) return 'queued';
    final norm = text.trim();
    final q = _queues.putIfAbsent(sid, () => <QueuedMessage>[]);
    for (final m in q) {
      if (m.text.trim() == norm && m.images.length == images.length) return 'duplicate';
    }
    q.add(QueuedMessage(
      id: 'q${DateTime.now().microsecondsSinceEpoch}_${_queuedSeq++}',
      text: text,
      images: List<String>.of(images),
    ));
    onChanged();
    return 'queued';
  }

  /// 置顶:把第 [index] 条提到队首(下一次优先推它)。
  void promoteQueued(String sid, int index) {
    final q = _queues[sid];
    if (q == null || index <= 0 || index >= q.length) return;
    q.insert(0, q.removeAt(index));
    onChanged();
  }

  void removeQueued(String sid, int index) {
    final q = _queues[sid];
    if (q == null || index < 0 || index >= q.length) return;
    q.removeAt(index);
    if (q.isEmpty) _queues.remove(sid);
    onChanged();
  }

  /// 修改排队文案;返回 false = 改成了与队内其他条重复,未生效。
  bool editQueued(String sid, int index, String text) {
    final q = _queues[sid];
    if (q == null || index < 0 || index >= q.length) return true;
    final norm = text.trim();
    for (var i = 0; i < q.length; i++) {
      if (i != index && q[i].text.trim() == norm) return false;
    }
    final old = q[index];
    q[index] = QueuedMessage(id: old.id, text: text, images: old.images);
    onChanged();
    return true;
  }

  /// 取出第 [index] 条(立即发送/自动消化共用的底层);队列空则清 key。
  /// 越界返回 null。
  QueuedMessage? takeQueued(String sid, int index) {
    final q = _queues[sid];
    if (q == null || index < 0 || index >= q.length) return null;
    final m = q.removeAt(index);
    if (q.isEmpty) _queues.remove(sid);
    return m;
  }

  /// 发送失败/条件不满足:塞回队首不丢。
  void requeueFirst(String sid, QueuedMessage m) {
    _queues.putIfAbsent(sid, () => <QueuedMessage>[]).insert(0, m);
  }

  /// 会话删除:排队消息一并丢弃。
  void discardQueues(String sid) {
    _queues.remove(sid);
    onChanged();
  }
}
