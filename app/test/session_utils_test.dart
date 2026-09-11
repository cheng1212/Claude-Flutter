import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/session_utils.dart';

Map<String, dynamic> session({
  String id = 's1',
  String title = '会话',
  bool running = false,
  String? lastStatus,
  String? lastPreview,
  String? project,
  List<String> tags = const [],
  bool pinned = false,
  bool archived = false,
  String model = 'glm-5.3-flash',
}) =>
    {
      'id': id,
      'title': title,
      'isRunning': running,
      'last_status': lastStatus,
      'last_preview': lastPreview,
      'project': project,
      'tags': tags,
      'is_pinned': pinned ? 1 : 0,
      'archived': archived ? 1 : 0,
      'model': model,
    };

void main() {
  group('statusBadgeOf', () {
    test('运行中优先于一切', () {
      expect(statusBadgeOf(session(running: true, lastStatus: 'error')), (label: '进行中', kind: 'running'));
    });
    test('lastStatus 映射 已完成/失败/已暂停', () {
      expect(statusBadgeOf(session(lastStatus: 'success')), (label: '已完成', kind: 'done'));
      expect(statusBadgeOf(session(lastStatus: 'error')), (label: '失败', kind: 'failed'));
      expect(statusBadgeOf(session(lastStatus: 'interrupted')), (label: '已暂停', kind: 'paused'));
      expect(statusBadgeOf(session(lastStatus: 'aborted')), (label: '已暂停', kind: 'paused'));
    });
    test('无 run 的会话显示 已结束', () {
      expect(statusBadgeOf(session()), (label: '已结束', kind: 'ended'));
    });
  });

  group('filterSessions', () {
    final list = [
      session(id: 'a', title: 'zcode flutter', lastPreview: '给我讲个故事', pinned: true, lastStatus: null, project: 'Flutter'),
      session(id: 'b', title: 'Claude flutter', lastPreview: '全部代码都已提交', lastStatus: 'success', project: 'Flutter'),
      session(id: 'c', title: 'API 调试', lastPreview: '这个接口返回的数据格式有问题', lastStatus: 'error', project: '后端'),
      session(id: 'd', title: '旧归档', archived: true),
    ];

    test('全部:隐藏归档', () {
      final r = filterSessions(list, filter: SessionFilter.all);
      expect(r.map((s) => s['id']), ['a', 'b', 'c']);
    });
    test('置顶:只留置顶且非归档', () {
      expect(filterSessions(list, filter: SessionFilter.pinned).map((s) => s['id']), ['a']);
    });
    test('归档:只留归档', () {
      expect(filterSessions(list, filter: SessionFilter.archived).map((s) => s['id']), ['d']);
    });
    test('项目:按 project 过滤', () {
      expect(filterSessions(list, filter: SessionFilter.project, project: 'Flutter').map((s) => s['id']), ['a', 'b']);
    });
    test('关键词:命中标题/预览/标签,大小写不敏感', () {
      expect(filterSessions(list, filter: SessionFilter.all, query: 'ZCODE').map((s) => s['id']), ['a']);
      expect(filterSessions(list, filter: SessionFilter.all, query: '接口返回').map((s) => s['id']), ['c']);
    });
  });

  group('tagsOf', () {
    test('JSON 字符串与 List 都能读', () {
      expect(tagsOf({'tags': '["Flutter","重要"]'}), ['Flutter', '重要']);
      expect(tagsOf({'tags': ['x']}), ['x']);
      expect(tagsOf({'tags': '[]'}), isEmpty);
      expect(tagsOf({}), isEmpty);
    });
  });

  group('cron 时间文案', () {
    final now = DateTime(2026, 9, 7, 12, 0, 0);
    test('未来触发:钟表时刻 + 倒计时', () {
      final iso = DateTime(2026, 9, 8, 9, 30).toIso8601String();
      expect(cronNextLabel(iso, now), '9月8日 09:30 · 21小时30分后');
    });
    test('已过点:只给钟表时刻(等待触发)', () {
      final iso = DateTime(2026, 9, 7, 8, 0).toIso8601String();
      expect(cronNextLabel(iso, now), '9月7日 08:00');
    });
    test('空或坏值:无排期', () {
      expect(cronNextLabel(null, now), '无排期');
      expect(cronNextLabel('xxx', now), '无排期');
    });
    test('循环任务给 7 天自动过期;一次性不给', () {
      final created = DateTime(2026, 9, 7, 12, 0).toIso8601String();
      expect(cronExpiryLabel(created, recurring: true), '9月14日 12:00 自动过期');
      expect(cronExpiryLabel(created, recurring: false), isNull);
      expect(cronExpiryLabel(null, recurring: true), isNull);
    });
  });

  group('chatPhase 相位判据', () {
    test('连接不在位一律断线,running 冻结也不能假显示', () {
      expect(chatPhase(running: true, hasPermission: true, socketOpen: false), 'reconnecting');
      expect(chatPhase(running: true, hasPermission: false, socketOpen: false), 'reconnecting');
    });
    test('连接在位:permission > running > idle', () {
      expect(chatPhase(running: true, hasPermission: true, socketOpen: true), 'permission');
      expect(chatPhase(running: true, hasPermission: false, socketOpen: true), 'running');
      expect(chatPhase(running: false, hasPermission: false, socketOpen: true), 'idle');
    });
  });

  group('filterSessions 未分类哨兵', () {
    test('kUncategorizedProject 只保留无项目归属的未归档会话', () {
      final rows = [
        {'id': 'a', 'project': '商城'},
        {'id': 'b', 'project': ''},
        {'id': 'c'},
        {'id': 'd', 'project': '', 'archived': 1},
      ];
      final out = filterSessions(rows,
          filter: SessionFilter.project, project: kUncategorizedProject);
      expect(out.map((s) => s['id']), ['b']);
    });
  });

  group('joinProjectCwd', () {
    test('按服务器路径分隔符拼项目 cwd', () {
      expect(joinProjectCwd('C:\\Users\\x\\zcode-projects', '商城'), 'C:\\Users\\x\\zcode-projects\\商城');
      expect(joinProjectCwd('/home/x/zcode-projects', 'shop'), '/home/x/zcode-projects/shop');
      expect(joinProjectCwd('C:\\root\\', 'p'), 'C:\\root\\p');
    });
  });

  group('thinkingOptionsFor', () {
    test('deepseek 系三档(低/中/高);qwen 与其他 开/关', () {
      expect(thinkingOptionsFor('deepseek-v4-flash'), [('低', 'low'), ('中', 'medium'), ('高', 'high')]);
      expect(thinkingOptionsFor('DeepSeek-V4-Pro'), [('低', 'low'), ('中', 'medium'), ('高', 'high')]);
      expect(thinkingOptionsFor('go-qwen3.8-flash'), orderedEquals([('开', 'on'), ('关', 'off')]));
      expect(thinkingOptionsFor('glm-5.3-flash'), orderedEquals([('开', 'on'), ('关', 'off')]));
      expect(thinkingOptionsFor('default'), orderedEquals([('开', 'on'), ('关', 'off')]));
    });
  });
}
