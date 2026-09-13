import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/ui/chat_page.dart';

// 入场动画水位:算错会白屏(几千行同时动画 + 流式高频重建 → opacity 长期接近 0),
// 且数据是好的、看门狗不报错,极难定位。这里把边界钉死。
void main() {
  group('advanceAnimWatermark · 入场动画水位', () {
    test('逐条新增:只有最新那几行播动画', () {
      // 已经有 500 行,新增 1 行 → freshFrom=500 → i<1 播动画(= 就那 1 行)
      final r = advanceAnimWatermark(current: 500, rowCount: 501, loading: false);
      expect(r.freshFrom, 500);
      expect(r.watermark, 501);
    });

    test('换底暴涨:一行都不播(原 bug:6117 行同时动画 → 白屏)', () {
      final r = advanceAnimWatermark(current: 500, rowCount: 6617, loading: false);
      expect(r.freshFrom, 6617, reason: '跳变超过阈值 → 水位直接对齐,不播任何入场动画');
      expect(r.watermark, 6617);
    });

    test('历史加载中:不播(即使只多几行)', () {
      final r = advanceAnimWatermark(current: 100, rowCount: 110, loading: true);
      expect(r.freshFrom, 110);
    });

    test('恰好等于阈值仍算逐条新增(不算跳变)', () {
      final r = advanceAnimWatermark(current: 0, rowCount: kMaxFreshRows, loading: false);
      expect(r.freshFrom, 0, reason: '等于阈值不触发"跳变"分支');
    });

    test('行数没变/变少:水位不倒退,freshFrom 不越界', () {
      final same = advanceAnimWatermark(current: 500, rowCount: 500, loading: false);
      expect(same.freshFrom, 500);
      expect(same.watermark, 500);

      final shrunk = advanceAnimWatermark(current: 500, rowCount: 100, loading: false);
      expect(shrunk.freshFrom, 100, reason: 'freshFrom 必须 clamp 到行数内,否则 i<负数 恒假');
      expect(shrunk.watermark, 500, reason: '水位只进不退,免得下次增长又被当成"新行"');
    });

    test('空列表安全', () {
      final r = advanceAnimWatermark(current: 0, rowCount: 0, loading: false);
      expect(r.freshFrom, 0);
      expect(r.watermark, 0);
    });
  });
}
