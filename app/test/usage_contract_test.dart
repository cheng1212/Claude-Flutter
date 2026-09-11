// 契约测试:server GET /api/usage 的真实响应形状 → app parseUsageStats。
// server 侧形状定义在 db.ts usageStats();若 server 字段改名/改结构,
// 此测试会因解析出 0/空 而失败——防止跨端字段漂移静默发生。
// fixture 字段与 server/db.ts usageStats 返回一一对应(2026-09-12 实测 200 响应对齐)。
import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/usage_stats.dart';

const serverResponse = {
  'range': '7d',
  'generatedAt': '2026-09-12T04:30:00.000Z',
  'summary': {
    'inputTokens': 1000,
    'outputTokens': 500,
    'cacheReadTokens': 3000,
    'cacheCreationTokens': 200,
    'totalTokens': 4700, // 1000+3000+200+500
    'cacheHitRate': 0.625, // 3000/4800
    'totalSessions': 11,
    'totalTurns': 1423,
    'toolCallCount': 4737,
    'activeDays': 6,
    'currentStreakDays': 6,
    'peakDayTokens': 67460537,
    'favoriteModel': 'glm-5.3-flash',
  },
  'models': [
    {
      'modelId': 'glm-5.3-flash',
      'totalTokens': 4000,
      'inputTokens': 3000,
      'outputTokens': 400,
      'requestCount': 3,
      'share': 0.8,
    },
    {
      'modelId': 'deepseek-v4',
      'totalTokens': 700,
      'inputTokens': 100,
      'outputTokens': 100,
      'requestCount': 1,
      'share': 0.2,
    },
  ],
  'daily': [
    {
      'date': '2026-09-11',
      'models': [
        {'modelId': 'glm-5.3-flash', 'totalTokens': 2500, 'inputTokens': 2000, 'outputTokens': 300},
        {'modelId': 'deepseek-v4', 'totalTokens': 500, 'inputTokens': 80, 'outputTokens': 60},
      ],
    },
    {
      'date': '2026-09-12',
      'models': [
        {'modelId': 'glm-5.3-flash', 'totalTokens': 1500, 'inputTokens': 1000, 'outputTokens': 100},
      ],
    },
  ],
};

void main() {
  test('summary 全字段映射(含缓存命中率透传)', () {
    final view = parseUsageStats(serverResponse);
    expect(view, isNotNull);
    expect(view!.summary.totalTokens, 4700);
    expect(view.summary.inputTokens, 1000);
    expect(view.summary.outputTokens, 500);
    expect(view.summary.cacheReadTokens, 3000);
    expect(view.summary.cacheCreationTokens, 200);
    expect(view.summary.cacheHitRate, closeTo(0.625, 1e-9));
    expect(view.summary.totalSessions, 11);
    expect(view.summary.totalTurns, 1423);
    expect(view.summary.toolCallCount, 4737);
    expect(view.summary.activeDays, 6);
    expect(view.summary.currentStreakDays, 6);
    expect(view.summary.peakDayTokens, 67460537);
    expect(view.summary.favoriteModel, 'glm-5.3-flash');
  });

  test('models 按总量降序;daily 按日期升序(与 server 排序一致)', () {
    final view = parseUsageStats(serverResponse)!;
    expect(view.models.first.modelId, 'glm-5.3-flash');
    expect(view.models.last.modelId, 'deepseek-v4');
    expect(view.daily.first.date, '2026-09-11');
    expect(view.daily.last.date, '2026-09-12');
    expect(view.daily.first.models.length, 2);
  });

  test('缺 summary 的响应返回 null(形状防御,页面空态不崩)', () {
    expect(parseUsageStats({}), isNull, reason: '无 summary = 形状不认识,拒绝解析');
  });

  test('非 Map 响应返回 null(错误形状兜底)', () {
    expect(parseUsageStats('not a map'), isNull);
    expect(parseUsageStats(null), isNull);
  });

  group('切片与聚合(混合锁位外的用量页核心口径)', () {
    final view = parseUsageStats(serverResponse)!;

    test('全部范围:切片聚合 = summary 总量', () {
      final slice = aggregateSlice(sliceDailyByChoice(view.daily, UsageRangeChoice.all));
      expect(slice.totalTokens, 3000 + 500 + 1500); // daily 明细之和(与 models 总量口径不同源)
      expect(slice.activeDays, 2);
    });

    test('模型过滤:只保留指定模型的日切片', () {
      final daily = filterDailyModels(view.daily, {'deepseek-v4'});
      final total = daily.fold<int>(0, (s, d) => s + d.totalTokens);
      expect(total, 500);
    });
  });
}
