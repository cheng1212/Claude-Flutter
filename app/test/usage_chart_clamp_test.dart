import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/ui/usage_page.dart';

// 绘制期异常是"卡死级"故障:paint 每帧执行,clamp 参数非法就每帧抛一次,
// 主线程被错误处理拖死(实测:白屏 / 回到底部点不动 / 整个卡死)。
// 这里把两个越界点钉死。
void main() {
  group('stackSegmentHeight · 堆叠柱段高', () {
    test('常规:至少 1px,且不超过真实高度', () {
      expect(stackSegmentHeight(h: 50, gap: 2, isBottom: false), 48);
      expect(stackSegmentHeight(h: 50, gap: 2, isBottom: true), 50); // 底段不扣 gap
      expect(stackSegmentHeight(h: 3, gap: 2, isBottom: false), 1); // 扣完不足 1px → 抬到 1
    });

    test('极小段高不再抛异常(原 bug:clamp(1.0, h) 且 h<1 时下界>上界)', () {
      expect(() => stackSegmentHeight(h: 0.5, gap: 2, isBottom: false), returnsNormally);
      expect(stackSegmentHeight(h: 0.5, gap: 2, isBottom: false), 0.5);
      expect(() => stackSegmentHeight(h: 0, gap: 2, isBottom: false), returnsNormally);
      expect(stackSegmentHeight(h: 1, gap: 2, isBottom: false), 1);
    });
  });

  group('stackLabelX · 日期标签位置', () {
    test('常规:居中', () {
      expect(stackLabelX(centerX: 100, labelWidth: 20, padLeft: 8, viewWidth: 400), 90);
    });

    test('标签贴右边:被夹在 viewWidth - labelWidth', () {
      expect(stackLabelX(centerX: 395, labelWidth: 30, padLeft: 8, viewWidth: 400), 370);
    });

    test('窄屏/长标签不再抛异常(原 bug:上界 < 下界)', () {
      // 视口 100,标签 95 → 上界 5 < padLeft 8
      expect(() => stackLabelX(centerX: 50, labelWidth: 95, padLeft: 8, viewWidth: 100),
          returnsNormally);
      expect(stackLabelX(centerX: 50, labelWidth: 95, padLeft: 8, viewWidth: 100), 8);
      // 极端:标签比视口还宽 → 上界为负
      expect(() => stackLabelX(centerX: 50, labelWidth: 200, padLeft: 8, viewWidth: 100),
          returnsNormally);
    });
  });
}
