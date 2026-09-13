import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/debug_log.dart';

// 不做 binding 初始化:debugPrint 的限速排空定时器会被测试区当「挂起定时器」判失败,
// 而 ZLog 只是字符串缓冲 + 打印,纯 dart 区跑即可。
void main() {
  setUp(() => ZLog.clear());

  test('环形缓冲:超过 kMax 丢最旧的', () {
    for (var i = 0; i < ZLog.kMax + 50; i++) {
      ZLog.i('t', 'entry#$i#');
    }
    final dump = ZLog.dump();
    expect(dump.contains('entry#49#'), isFalse, reason: '最旧的被挤掉');
    expect(dump.contains('entry#${ZLog.kMax + 49}#'), isTrue, reason: '最新的一条还在');
  });

  test('dedupeKey:10 秒窗口内同 key 只记一条', () {
    ZLog.w('t', '告警A', dedupeKey: 'k1');
    ZLog.w('t', '告警A', dedupeKey: 'k1'); // 同 key:被吞
    ZLog.w('t', '告警B', dedupeKey: 'k2'); // 不同 key:照记
    final lines = ZLog.dump().split('\n');
    expect(lines.length, 2, reason: '同 key 第二条被吞,不同 key 照记');
  });

  test('e 级带 [ERR] 标记;clear 清空', () {
    ZLog.e('t', '炸了');
    expect(ZLog.dump(), contains('[ERR] 炸了'));
    ZLog.clear();
    expect(ZLog.dump(), isEmpty);
  });
}
