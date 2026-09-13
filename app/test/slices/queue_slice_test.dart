// QueueSlice 单测(优化方案 T4 试点:队列领域切片)。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/state/slices/queue_slice.dart';

void main() {
  late QueueSlice slice;
  var changes = 0;
  String? sessionId = 's1';

  setUp(() {
    changes = 0;
    sessionId = 's1';
    slice = QueueSlice(onChanged: () => changes++, currentSessionId: () => sessionId);
  });

  group('QueueSlice', () {
    test('enqueue 落到当前会话并通知;同文去重不重复入队', () {
      expect(slice.enqueue('A'), 'queued');
      expect(slice.enqueue('A'), 'duplicate');
      expect(slice.enqueue('B'), 'queued');
      expect(changes, 2); // duplicate 不通知
      expect(slice.queueOf('s1').map((m) => m.text), ['A', 'B']);
    });

    test('currentSessionId 为 null 时入队返回 queued 但不落盘', () {
      sessionId = null;
      expect(slice.enqueue('漂浮消息'), 'queued');
      expect(slice.queueOf('s1'), isEmpty);
      expect(changes, 0);
    });

    test('takeQueued 取出后队列空则清 key;越界返回 null', () {
      slice.enqueue('A');
      final m = slice.takeQueued('s1', 0);
      expect(m?.text, 'A');
      expect(slice.queueCount('s1'), 0);
      expect(slice.takeQueued('s1', 0), isNull);
    });

    test('requeueFirst 塞回队首不丢', () {
      slice.enqueue('A');
      slice.enqueue('B');
      final m = slice.takeQueued('s1', 0);
      slice.requeueFirst('s1', m!);
      expect(slice.queueOf('s1').map((m) => m.text), ['A', 'B']);
    });

    test('editQueued 同文判重返回 false 且不生效', () {
      slice.enqueue('A');
      slice.enqueue('B');
      expect(slice.editQueued('s1', 1, 'A'), isFalse);
      expect(slice.queueOf('s1').map((m) => m.text), ['A', 'B']);
      expect(slice.editQueued('s1', 1, 'C'), isTrue);
      expect(slice.queueOf('s1').map((m) => m.text), ['A', 'C']);
    });

    test('discardQueues 清队列并保留开关语义', () {
      slice.enqueue('A');
      slice.setAutoConsume('s1', on: false);
      expect(slice.autoConsumeOf('s1'), isFalse);
      slice.discardQueues('s1');
      expect(slice.queueOf('s1'), isEmpty);
    });
  });
}
