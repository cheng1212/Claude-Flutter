import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/ui/crons_sheet.dart';

void main() {
  group('cronTitleOf · 从 prompt 提炼标题', () {
    test('取首句(中文标点断句)', () {
      expect(cronTitleOf('10分钟后示例提醒。运行 date 命令获取当前时间'), '10分钟后示例提醒');
      expect(cronTitleOf('每分钟提醒:通宵审计跑到早上9点。继续干活'), '每分钟提醒:通宵审计跑到早上9点');
      expect(cronTitleOf('检查构建！然后报告'), '检查构建');
    });

    test('英文标点同样断句', () {
      expect(cronTitleOf('Nightly audit. Keep going until 9am'), 'Nightly audit');
      expect(cronTitleOf('Build check; report back'), 'Build check');
    });

    test('多行只取第一行', () {
      expect(cronTitleOf('早安汇报\n第二行内容'), '早安汇报');
    });

    test('无标点则整句截断到 24 字加省略号', () {
      final long = '这是一个非常非常长的没有标点的任务描述需要被截断处理掉多余的部分';
      final t = cronTitleOf(long);
      expect(t.endsWith('…'), isTrue);
      expect(t.length, 25); // 24 + 省略号
      expect(cronTitleOf('短标题'), '短标题');
    });

    test('空内容给占位,不返回空串(卡片标题不能是空白)', () {
      expect(cronTitleOf(''), '(未命名)');
      expect(cronTitleOf('   '), '(未命名)');
      expect(cronTitleOf('\n\n'), '(未命名)');
    });

    test('以标点开头时不返回空标题(退回首行)', () {
      expect(cronTitleOf('。先做这个'), '。先做这个');
    });
  });
}
