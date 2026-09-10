import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/scroll_utils.dart';

void main() {
  group('compensateStreamScroll', () {
    test('流式区长高:用户在上方,offset 加同样高度锁住视觉位置', () {
      expect(
        compensateStreamScroll(prevH: 100, currH: 140, offset: 500),
        540,
      );
    });

    test('连续两帧增长逐帧累加(防重入/漏补偿)', () {
      final f1 = compensateStreamScroll(prevH: 100, currH: 140, offset: 500)!;
      final f2 = compensateStreamScroll(prevH: 140, currH: 180, offset: f1)!;
      expect(f2, 580);
    });

    test('流式区收起(落定):反向补偿,内容不跳', () {
      expect(
        compensateStreamScroll(prevH: 140, currH: 60, offset: 500),
        420,
      );
    });

    test('在底部容差内(≤24px):跟随最新,不补偿', () {
      expect(compensateStreamScroll(prevH: 100, currH: 140, offset: 0), isNull);
      expect(compensateStreamScroll(prevH: 100, currH: 140, offset: 24), isNull);
    });

    test('高度无变化:不动', () {
      expect(compensateStreamScroll(prevH: 100, currH: 100, offset: 500), isNull);
    });

    test('补偿目标为负(收起幅度超过当前 offset):钳到 0', () {
      expect(
        compensateStreamScroll(prevH: 100, currH: 20, offset: 50),
        0,
      );
    });
  });
}
