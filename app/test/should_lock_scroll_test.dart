import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/ui/chat_page.dart';

// 锁位补偿判定:这块区域反复出问题(内容被推走 / 回到底部卡住),逐条锁行为。
void main() {
  bool ok({
    double offset = 200,
    double delta = 30,
    bool dragging = false,
    bool animating = false,
    bool running = true,
  }) =>
      shouldLockScroll(
        offset: offset,
        delta: delta,
        dragging: dragging,
        animatingToBottom: animating,
        running: running,
      );

  test('常规场景:看历史 + 回合在跑 + 内容增长 → 补偿', () {
    expect(ok(), isTrue);
  });

  test('只滚了一点点也要补(阈值 60px 会漏掉这种,内容就被一点点推走)', () {
    expect(ok(offset: 6), isTrue); // 超过 4px 容差
    expect(ok(offset: 30), isTrue); // 远小于旧的 60px 阈值
  });

  test('在底部(≤ 容差)不补:让内容自然跟随', () {
    expect(ok(offset: 0), isFalse);
    expect(ok(offset: 4), isFalse);
    expect(ok(offset: 4.1), isTrue);
  });

  test('回到底部动画进行中不补(否则 jumpTo 打断动画 → 永远到不了 0,卡住)', () {
    expect(ok(animating: true), isFalse);
  });

  test('手指拖动中不补(jumpTo 会 goIdle 掉手势)', () {
    expect(ok(dragging: true), isFalse);
  });

  test('回合没在跑不补(没有新增内容)', () {
    expect(ok(running: false), isFalse);
  });

  test('内容没长(delta ≤ 1)不补;面板收起变小也不回拉', () {
    expect(ok(delta: 0), isFalse);
    expect(ok(delta: 1), isFalse);
    expect(ok(delta: -50), isFalse); // 缩小:让视口自然扩大
    expect(ok(delta: 2), isTrue);
  });
}
