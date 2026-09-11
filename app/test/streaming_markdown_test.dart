import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/ui/rows.dart';

void main() {
  group('balanceFences(流式预览补闭合)', () {
    test('无围栏原样返回', () {
      const src = '# 标题\n\n正文段落,没有代码块。';
      expect(balanceFences(src), src);
    });

    test('闭合围栏不补', () {
      const src = '前文\n```dart\nint x = 1;\n```\n后文';
      expect(balanceFences(src), src);
    });

    test('未闭合 ``` 补一行闭合', () {
      expect(balanceFences('看这段:\n```python\nprint(1)'), '看这段:\n```python\nprint(1)\n```');
    });

    test('未闭合 ~~~ 补同字符闭合', () {
      expect(balanceFences('~~~\ncode'), '~~~\ncode\n~~~');
    });

    test('开栏更长时短栏不算闭合', () {
      // CommonMark:闭合围栏长度须 >= 开栏,```` 内的 ``` 不闭合
      final out = balanceFences('````\nx\n```\ny');
      expect(out.endsWith('\n```'), isTrue, reason: '仍在栏内,应补闭合');
    });

    test('多段围栏偶数对不补', () {
      const src = '```a\nx\n```\n中段\n```b\ny\n```';
      expect(balanceFences(src), src);
    });

    test('缩进 3 空格内的围栏也识别', () {
      expect(balanceFences('   ```\ncode'), '   ```\ncode\n```');
    });
  });

  group('MemoMarkdown 流式节流', () {
    int fakeNow = 1000;
    Widget host(String text, bool streaming) => MaterialApp(
        home: Scaffold(body: MemoMarkdown(text: text, streaming: streaming)));

    setUp(() {
      fakeNow = 1000;
      MemoMarkdown.nowMs = () => fakeNow;
      MemoMarkdown.parseCount = 0;
    });
    tearDown(() {
      MemoMarkdown.nowMs = () => DateTime.now().millisecondsSinceEpoch;
    });

    testWidgets('流式期间 200ms 内不重排,窗口过后重排,结束立即终渲染', (tester) async {
      await tester.pumpWidget(host('# t1', true));
      expect(MemoMarkdown.parseCount, 1);

      // 节流窗口内文本增长:沿用旧缓存,不发生 parse
      await tester.pumpWidget(host('# t2', true));
      expect(MemoMarkdown.parseCount, 1);

      // 窗口过后:正常重排
      fakeNow = 1300;
      await tester.pumpWidget(host('# t2', true));
      expect(MemoMarkdown.parseCount, 2);

      // 流式结束:绕过节流立即终渲染
      await tester.pumpWidget(host('# t3', false));
      expect(MemoMarkdown.parseCount, 3);
    });

    testWidgets('流式结束(标志翻转但文本相同)也要终渲染', (tester) async {
      await tester.pumpWidget(host('# same', true));
      expect(MemoMarkdown.parseCount, 1);
      fakeNow = 1500;
      await tester.pumpWidget(host('# same', false));
      expect(MemoMarkdown.parseCount, 2, reason: 'streaming 翻 false 需失效缓存重排');
    });

    testWidgets('节流窗内最后一版文本:尾沿定时器补刷', (tester) async {
      await tester.pumpWidget(host('# t1', true));
      expect(MemoMarkdown.parseCount, 1);
      fakeNow = 1050; // 窗口内
      await tester.pumpWidget(host('# t1 t2', true));
      expect(MemoMarkdown.parseCount, 1, reason: '窗口内跳过');
      await tester.pump(const Duration(milliseconds: 250)); // 尾沿定时器到点
      await tester.pump(); // 重排帧
      expect(MemoMarkdown.parseCount, 2, reason: '不再有后续事件也要补上最后一版');
    });

    testWidgets('非流式文本不变时命中缓存,不重排', (tester) async {
      await tester.pumpWidget(host('hello', false));
      expect(MemoMarkdown.parseCount, 1);
      await tester.pumpWidget(host('hello', false));
      expect(MemoMarkdown.parseCount, 1, reason: '记忆化:同文本直接复用缓存 widget');
    });
  });
}
