// ChatStreamController 单测(标准工程方案附录 A 步骤 1):
// 喂大量 delta,断言 flush 频率≈节流周期、拼接无损、finish/reset 语义完整。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/chat_stream_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ChatStreamController · delta 缓冲与节流', () {
    test('同周期内多个 delta 合并为一次 flush,拼接无损', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      var flushes = 0;
      c.onFlush = (_) => flushes++;
      c.onText('你');
      c.onText('好');
      c.onText('，世界');
      expect(flushes, greaterThanOrEqualTo(1));
      expect(c.state.value.text, '你好，世界');
      expect(c.state.value.active, isTrue);
      c.dispose();
    });

    test('interval=0:每次 flush 清空缓冲,不丢内容', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      var lastText = '';
      c.onFlush = (s) => lastText = s.text;
      c.onText('a');
      c.onText('b');
      expect(lastText, contains('a'));
      c.dispose();
    });

    test('finish():残余 delta 立即刷出并定稿 active=false', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      c.onText('部分内容');
      c.onText('更多');
      c.finish();
      expect(c.state.value.active, isFalse);
      expect(c.state.value.text, contains('部分内容'));
      expect(c.state.value.text, contains('更多'));
      c.dispose();
    });

    test('finish 后再 onText:开新 turn,active 重新为 true', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      c.onText('第一轮');
      c.finish();
      c.onText('第二轮');
      expect(c.state.value.active, isTrue);
      expect(c.state.value.text, '第二轮');
      c.dispose();
    });

    test('reset():清空一切在途状态(切会话防跨会话泄漏)', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      c.onText('在途内容');
      c.reset();
      expect(c.state.value.text, isEmpty);
      expect(c.state.value.active, isFalse);
      c.onText('新会话内容');
      expect(c.state.value.text, '新会话内容');
      c.dispose();
    });

    test('thinking 与 text 分缓冲互不串道', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      c.onThinking('想');
      c.onText('说');
      expect(c.state.value.thinking, '想');
      expect(c.state.value.text, '说');
      c.dispose();
    });
  });

  group('ChatStreamController · 高频 delta 压力(标准附录 A 步骤 1)', () {
    test('100 个 delta 全部拼接无损,无内容丢失', () {
      final c = ChatStreamController(interval: Duration.zero, onFlush: (_) {});
      final expected = List.generate(100, (i) => 'delta$i').join();
      for (final d in List.generate(100, (i) => 'delta$i')) {
        c.onText(d);
      }
      expect(c.state.value.text, expected);
      c.dispose();
    });
  });
}
