import 'package:flutter_test/flutter_test.dart';

import 'package:zcode_app/usage_stats.dart';

UsageStatsView fixture() => UsageStatsView.fromMap({
      'range': '7d',
      'generatedAt': '2026-09-08T10:00:00.000Z',
      'summary': {
        'totalTokens': 795,
        'inputTokens': 710,
        'outputTokens': 85,
        'cacheReadTokens': 500,
        'cacheCreationTokens': 20,
        'cacheHitRate': 0.7,
        'totalSessions': 2,
        'totalTurns': 4,
        'toolCallCount': 9,
        'activeDays': 2,
        'currentStreakDays': 1,
        'peakDayTokens': 500,
        'favoriteModel': 'glm-5.3-flash',
      },
      'models': [
        {'modelId': 'glm-5.3-flash', 'totalTokens': 780, 'inputTokens': 700, 'outputTokens': 80, 'requestCount': 2, 'share': 0.98},
        {'modelId': 'kimi-k3', 'totalTokens': 15, 'inputTokens': 10, 'outputTokens': 5, 'requestCount': 1, 'share': 0.02},
      ],
      'daily': [
        {'date': '2026-09-07', 'models': [{'modelId': 'glm-5.3-flash', 'totalTokens': 300}]},
        {'date': '2026-09-08', 'models': [
          {'modelId': 'glm-5.3-flash', 'totalTokens': 480},
          {'modelId': 'kimi-k3', 'totalTokens': 15},
        ]},
      ],
    });

void main() {
  group('parseUsageStats', () {
    test('合法快照解析;models/daily 排序正确', () {
      final v = fixture();
      expect(v.summary.totalTokens, 795);
      expect(v.summary.cacheHitRate, closeTo(0.7, 1e-9));
      expect(v.models.first.modelId, 'glm-5.3-flash'); // 总量降序
      expect(v.daily.map((d) => d.date).toList(), ['2026-09-07', '2026-09-08']); // 日期升序
    });

    test('非 Map / 缺 summary 给 null(页面空态)', () {
      expect(parseUsageStats('nope'), isNull);
      expect(parseUsageStats({'range': '7d'}), isNull);
      expect(parseUsageStats(null), isNull);
    });
  });

  group('模型明细 · 缓存命中率', () {
    test('服务端给了 cacheHitRate/cacheReadInputTokens 就直接用', () {
      final v = UsageStatsView.fromMap({
        'range': '7d',
        'summary': {'totalTokens': 10},
        'models': [
          {
            'modelId': 'deepseek-flash', 'totalTokens': 450, 'inputTokens': 400, 'outputTokens': 50,
            'requestCount': 1, 'share': 1.0,
            'cacheReadInputTokens': 300, 'cacheHitRate': 0.75,
          },
        ],
        'daily': [],
      });
      final m = v.models.single;
      expect(m.cacheReadInputTokens, 300);
      expect(m.cacheHitRate, closeTo(0.75, 1e-9));
    });

    test('老服务端无该字段:按同口径本地兜算(缓存读/输入侧),无输入侧为 0', () {
      final v = UsageStatsView.fromMap({
        'range': '7d',
        'summary': {'totalTokens': 10},
        'models': [
          {'modelId': 'a', 'totalTokens': 400, 'inputTokens': 400, 'outputTokens': 0, 'requestCount': 1, 'share': 1.0, 'cacheReadInputTokens': 300},
          {'modelId': 'b', 'totalTokens': 5, 'inputTokens': 0, 'outputTokens': 5, 'requestCount': 1, 'share': 0.0},
        ],
        'daily': [],
      });
      expect(v.models[0].cacheHitRate, closeTo(0.75, 1e-9));
      expect(v.models[1].cacheHitRate, 0);
    });
  });

  group('formatTokens', () {
    test('亿/万/原样三档', () {
      expect(formatTokens(1560000000), '15.6亿');
      expect(formatTokens(5046000), '504.6万');
      expect(formatTokens(9479), '9479');
    });
  });

  group('buildUsageTrendChart', () {
    test('topN 之外的模型归「其他」;全 0 的日子剔除', () {
      final daily = [
        UsageDailyView(date: '2026-09-07', models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 100, inputTokens: 90, outputTokens: 10),
          const UsageDailyModel(modelId: 'b', totalTokens: 50, inputTokens: 45, outputTokens: 5),
          const UsageDailyModel(modelId: 'c', totalTokens: 30, inputTokens: 28, outputTokens: 2),
          const UsageDailyModel(modelId: 'd', totalTokens: 20, inputTokens: 18, outputTokens: 2),
          const UsageDailyModel(modelId: 'e', totalTokens: 10, inputTokens: 9, outputTokens: 1),
        ]),
        UsageDailyView(date: '2026-09-08', models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 200, inputTokens: 180, outputTokens: 20),
        ]),
        UsageDailyView(date: '2026-09-09', models: []), // 全 0 → 不占柱位
      ];
      final c = buildUsageTrendChart(daily, topN: 3);
      expect(c.modelIds, ['a', 'b', 'c', '__other__']);
      expect(c.dayLabels, ['9月7日', '9月8日']);
      expect(c.stacks.length, 2);
      // 9月7日:前三是 100/50/30,其他 = 20+10 = 30
      expect(c.stacks[0], [100, 50, 30, 30]);
      expect(c.stacks[1], [200, 0, 0, 0]);
      expect(c.maxY, greaterThanOrEqualTo(200));
    });
  });

  group('sliceDailyByChoice / 自定义窗口', () {
    test('today 只留今天;7d/30d/all 原样交给服务端口径', () {
      final daily = [
        UsageDailyView(date: usageDayKey(DateTime.now()), models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 1, inputTokens: 1, outputTokens: 0),
        ]),
        UsageDailyView(date: '2000-01-01', models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 2, inputTokens: 2, outputTokens: 0),
        ]),
      ];
      expect(sliceDailyByChoice(daily, UsageRangeChoice.today).length, 1);
      // 窗口语义:7d/30d 只含窗口内的日子,远古条目被切掉;all 全保留
      expect(sliceDailyByChoice(daily, UsageRangeChoice.sevenDays).length, 1);
      expect(sliceDailyByChoice(daily, UsageRangeChoice.all).length, 2);
    });

    test('sliceDailyWindow + aggregateSlice:窗口精筛 + 输入输出重算', () {
      final daily = [
        UsageDailyView(date: '2026-09-07', models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 100, inputTokens: 90, outputTokens: 10),
        ]),
        UsageDailyView(date: '2026-09-08', models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 200, inputTokens: 180, outputTokens: 20),
          const UsageDailyModel(modelId: 'b', totalTokens: 50, inputTokens: 40, outputTokens: 10),
        ]),
        UsageDailyView(date: '2026-09-09', models: [
          const UsageDailyModel(modelId: 'a', totalTokens: 400, inputTokens: 350, outputTokens: 50),
        ]),
      ];
      final s1 = aggregateSlice(sliceDailyWindow(daily, '2026-09-07', '2026-09-08'));
      expect(s1.totalTokens, 350);
      expect(s1.inputTokens, 310);
      expect(s1.outputTokens, 40);
      expect(s1.activeDays, 2);

      final s2 = aggregateSlice(filterDailyModels(sliceDailyWindow(daily, '2026-09-07', '2026-09-09'), {'b'}));
      expect(s2.totalTokens, 50);
      expect(s2.inputTokens, 40);
      expect(s2.activeDays, 1);
    });
  });

  group('usageDayLabel', () {
    test('yyyy-MM-dd → M月d日', () {
      expect(usageDayLabel('2026-09-08'), '9月8日');
      expect(usageDayLabel('bad'), 'bad');
    });
  });
}
