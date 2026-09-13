import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/ui/chat_page.dart';

// 输入区右侧按钮形态:回归高发区(出过"打一个字按钮就变/运行中发不出消息")。
void main() {
  test('空闲:只有发送键(有无输入都不影响形态,由发送键自己灰/亮)', () {
    expect(composerButtonsOf(canStop: false, hasText: false), ComposerButtons.send);
    expect(composerButtonsOf(canStop: false, hasText: true), ComposerButtons.send);
  });

  test('运行中 + 输入框为空:只有停止键', () {
    expect(composerButtonsOf(canStop: true, hasText: false), ComposerButtons.stop);
  });

  test('运行中 + 有输入(文字/图片/附件):发送 + 停止双键,插话有入口', () {
    expect(composerButtonsOf(canStop: true, hasText: true), ComposerButtons.sendAndStop);
  });

  test('断线(running 冻结假象)不算运行中:仍给发送键', () {
    // canStop 已由调用方按「在线且在跑」算好;断线时传 false → 不该出停止键
    expect(composerButtonsOf(canStop: false, hasText: true), ComposerButtons.send);
  });
}
