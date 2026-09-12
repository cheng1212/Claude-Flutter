// ChatStreamController 单测(标准工程方案附录 A 步骤 1):
// 喂大量 delta,断言 flush 频率≈节流周期、拼接无损、finish/reset 语义完整。
// Timer 依赖 fake_async 控制(与真实 40ms 周期同一代码路径)。
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/chat_stream_controller.dart';

void main() {
  group('ChatStreamController · delta 缓冲与节流', () {
    test('40ms 窗口内多个 delta 合并为一次 flush,拼接无损', () {
      fakeAsync((async) {
        var flushes = 0;
        var lastText = '';
        final c = ChatStreamController(
            interval: const Duration(milliseconds: 40),
            onFlush: (s) {
              flushes++;
              lastText = s.text;
            });
        c.onText('你');
        c.onText('好');
        async.elapse(const Duration(milliseconds: 40));
        expect(flushes, 1);
        expect(lastText, '你好');
        // 第二个窗口
        c.onText('，世界');
        async.elapse(const Duration(milliseconds: 40));
        expect(flushes, 2);
        expect(lastText, '你好，世界');
        expect(c.state.value.active, isTrue);
        c.dispose();
      });
    });

    test('finish():残余 delta 立即刷出并定稿 active=false', () {
      fakeAsync((async) {
        final c = ChatStreamController(
            interval: const Duration(milliseconds: 40), onFlush: (_) {});
        c.onText('部分内容');
        c.onText('更多');
        c.finish(); // 不 elapse:finish 必须绕过节流立即刷出
        expect(c.state.value.text, '部分内容更多');
        expect(c.state.value.active, isFalse);
        c.dispose();
      });
    });

    test('finish 后再 onText:开新 turn,active 重新为 true', () {
      fakeAsync((async) {
        final c = ChatStreamController(
            interval: const Duration(milliseconds: 40), onFlush: (_) {});
        c.onText('第一轮');
        async.elapse(const Duration(milliseconds: 40));
        c.finish();
        c.onText('第二轮');
        expect(c.state.value.active, isTrue);
        expect(c.state.value.text, '第二轮');
        c.dispose();
      });
    });

    test('reset():清空一切在途状态(切会话防跨会话泄漏)', () {
      fakeAsync((async) {
        final c = ChatStreamController(
            interval: const Duration(milliseconds: 40), onFlush: (_) {});
        c.onText('在途内容');
        c.reset();
        expect(c.state.value.text, isEmpty);
        expect(c.state.value.active, isFalse);
        c.onText('新会话内容');
        async.elapse(const Duration(milliseconds: 40));
        expect(c.state.value.text, '新会话内容');
        c.dispose();
      });
    });

    test('thinking 与 text 分缓冲互不串道', () {
      fakeAsync((async) {
        final c = ChatStreamController(
            interval: const Duration(milliseconds: 40), onFlush: (_) {});
        c.onThinking('想');
        c.onText('说');
        async.elapse(const Duration(milliseconds: 40));
        expect(c.state.value.thinking, '想');
        expect(c.state.value.text, '说');
        c.dispose();
      });
    });
  });

  group('ChatStreamController · 高频 delta 压力(标准附录 A 步骤 1)', () {
    test('100 个 delta 全部拼接无损,无内容丢失', () {
      fakeAsync((async) {
        final c = ChatStreamController(
            interval: const Duration(milliseconds: 40), onFlush: (_) {});
        final expected = List.generate(100, (i) => 'delta$i').join();
        for (final d in List.generate(100, (i) => 'delta$i')) {
          c.onText(d);
        }
        async.elapse(const Duration(milliseconds: 40));
        expect(c.state.value.text, expected);
        c.dispose();
      });
    });
  });
}
