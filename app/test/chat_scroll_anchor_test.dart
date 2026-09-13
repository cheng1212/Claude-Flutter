// 滚动锚定纯函数单测(对齐 zremote composer_logic;这些数字是「闪不闪」的关键)。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/chat_scroll_anchor.dart';

void main() {
  group('AnchorThresholds 双阈值滞回', () {
    test('在底部时:距底 ≤180 都算在底(滞回带不横跳)', () {
      expect(AnchorThresholds.resolve(atBottomGap: 150, wasAtBottom: true), isTrue);
      expect(AnchorThresholds.resolve(atBottomGap: 180, wasAtBottom: true), isTrue);
      expect(AnchorThresholds.resolve(atBottomGap: 181, wasAtBottom: true), isFalse);
    });
    test('不在底部时:要 ≤100 才回到贴底(enter 比 exit 更严)', () {
      expect(AnchorThresholds.resolve(atBottomGap: 100, wasAtBottom: false), isTrue);
      expect(AnchorThresholds.resolve(atBottomGap: 120, wasAtBottom: false), isFalse);
    });
    test('未布局(maxScrollExtent 无法计算)保持原状态', () {
      expect(AnchorThresholds.resolve(atBottomGap: null, wasAtBottom: true), isTrue);
      expect(AnchorThresholds.resolve(atBottomGap: null, wasAtBottom: false), isFalse);
    });
  });

  group('ViewportAnchor 锚行补偿', () {
    final row = Object();
    test('新端长高:锚行上推 → 正值(往历史端钉回)', () {
      final d = ViewportAnchor.compensate(
          prev: AnchorSample(row, 10), next: AnchorSample(row, 4));
      expect(d, 6.0);
    });
    test('历史端长高:锚行下推 → 负值(往回钉)——旧总高增量方案在这里方向反了', () {
      final d = ViewportAnchor.compensate(
          prev: AnchorSample(row, 10), next: AnchorSample(row, 16));
      expect(d, -6.0);
    });
    test('锚行身份变了 → null(重定基线不补)', () {
      expect(
        ViewportAnchor.compensate(
            prev: AnchorSample(Object(), 10), next: AnchorSample(Object(), 4)),
        isNull,
      );
      expect(ViewportAnchor.compensate(prev: null, next: AnchorSample(row, 4)), isNull);
    });
    test('identical 行对象才算同一身份', () {
      final d = ViewportAnchor.compensate(
          prev: AnchorSample(row, 10), next: AnchorSample(row, 3));
      expect(d, 7.0);
    });
  });

  group('AnchorMath 步进规划', () {
    test('小于 minStep 不补偿', () {
      final r = AnchorMath.plan(1.0);
      expect(r.delta, 0);
      expect(r.leftover, 0);
    });
    test('单步封顶 600,剩余进 leftover', () {
      final r = AnchorMath.plan(1500);
      expect(r.delta, 600);
      expect(r.leftover, 900);
      expect(r.durationMs, AnchorMath.maxDurationMs);
    });
    test('常规增量:时长随距离缩放,落在 60~110ms', () {
      final r = AnchorMath.plan(100);
      expect(r.delta, 100);
      expect(r.durationMs, inInclusiveRange(AnchorMath.minDurationMs, AnchorMath.maxDurationMs));
    });
  });

  group('FollowLock 锁存', () {
    test('未锁 + 滚离超 exitPx → 上锁', () {
      expect(FollowLock.shouldLock(atBottomGap: 200, locked: false, maxScrollExtent: 5000), isTrue);
      expect(FollowLock.shouldLock(atBottomGap: 100, locked: false, maxScrollExtent: 5000), isFalse);
    });
    test('已锁就不重复评估', () {
      expect(FollowLock.shouldLock(atBottomGap: 200, locked: true, maxScrollExtent: 5000), isFalse);
    });
    test('解锁死区:滚回 ≤40 才解锁,100 带内不解(防临界横跳)', () {
      expect(FollowLock.shouldRelease(atBottomGap: 39, maxScrollExtent: 5000), isTrue);
      expect(FollowLock.shouldRelease(atBottomGap: 60, maxScrollExtent: 5000), isFalse);
    });
  });
}
