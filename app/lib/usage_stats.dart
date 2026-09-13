// 用量统计展示纯逻辑:/api/usage 快照 → 页面视图。无 Flutter 依赖,可单测。
// 形状对齐 server usageStats(db.ts):summary/models/daily(daily 每模型带输入/输出)。
library;

/// 总览汇总。
class UsageSummaryView {
  final int totalTokens;
  final int inputTokens; // 已含缓存读+写
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;
  final double cacheHitRate; // 0~1
  final int totalSessions;
  final int totalTurns;
  final int toolCallCount;
  final int activeDays;
  final int currentStreakDays;
  final int peakDayTokens;
  final String favoriteModel;

  UsageSummaryView({
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheCreationTokens,
    required this.cacheHitRate,
    required this.totalSessions,
    required this.totalTurns,
    required this.toolCallCount,
    required this.activeDays,
    required this.currentStreakDays,
    required this.peakDayTokens,
    required this.favoriteModel,
  });

  factory UsageSummaryView.fromMap(Map<String, dynamic> m) {
    int i(Object? v) => v is num ? v.toInt() : 0;
    double d(Object? v) => v is num ? v.toDouble() : 0;
    return UsageSummaryView(
      totalTokens: i(m['totalTokens']),
      inputTokens: i(m['inputTokens']),
      outputTokens: i(m['outputTokens']),
      cacheReadTokens: i(m['cacheReadTokens']),
      cacheCreationTokens: i(m['cacheCreationTokens']),
      cacheHitRate: d(m['cacheHitRate']),
      totalSessions: i(m['totalSessions']),
      totalTurns: i(m['totalTurns']),
      toolCallCount: i(m['toolCallCount']),
      activeDays: i(m['activeDays']),
      currentStreakDays: i(m['currentStreakDays']),
      peakDayTokens: i(m['peakDayTokens']),
      favoriteModel: '${m['favoriteModel'] ?? ''}',
    );
  }
}

/// 各模型聚合一行(已含 share)。
class UsageModelView {
  final String modelId;
  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int requestCount;
  final double share;
  final int cacheReadInputTokens;
  final double cacheHitRate;

  UsageModelView({
    required this.modelId,
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    required this.requestCount,
    required this.share,
    this.cacheReadInputTokens = 0,
    this.cacheHitRate = 0,
  });

  factory UsageModelView.fromMap(Map<String, dynamic> m) {
    int i(Object? v) => v is num ? v.toInt() : 0;
    double d(Object? v) => v is num ? v.toDouble() : 0;
    final inputTokens = i(m['inputTokens']);
    final cacheRead = i(m['cacheReadInputTokens']);
    return UsageModelView(
      modelId: '${m['modelId'] ?? ''}',
      totalTokens: i(m['totalTokens']),
      inputTokens: inputTokens,
      outputTokens: i(m['outputTokens']),
      requestCount: i(m['requestCount']),
      share: d(m['share']),
      cacheReadInputTokens: cacheRead,
      // 服务端给了就直用;老服务端没这字段时按同口径本地算
      cacheHitRate: m['cacheHitRate'] != null ? d(m['cacheHitRate']) : (inputTokens > 0 ? cacheRead / inputTokens : 0),
    );
  }
}

/// 每日×模型一行,趋势图数据源。
class UsageDailyModel {
  final String modelId;
  final int totalTokens;
  final int inputTokens; // 含缓存读+写
  final int outputTokens;

  const UsageDailyModel({required this.modelId, required this.totalTokens, required this.inputTokens, required this.outputTokens});

  factory UsageDailyModel.fromMap(Map<String, dynamic> m) {
    int i(Object? v) => v is num ? v.toInt() : 0;
    return UsageDailyModel(
      modelId: '${m['modelId'] ?? ''}',
      totalTokens: i(m['totalTokens']),
      inputTokens: i(m['inputTokens']),
      outputTokens: i(m['outputTokens']),
    );
  }
}

class UsageDailyView {
  final String date; // yyyy-MM-dd
  final List<UsageDailyModel> models;

  UsageDailyView({required this.date, required this.models});

  int get totalTokens => models.fold(0, (s, m) => s + m.totalTokens);

  factory UsageDailyView.fromMap(Map<String, dynamic> m) {
    final list = m['models'];
    return UsageDailyView(
      date: '${m['date'] ?? ''}',
      models: list is List
          ? [for (final e in list) if (e is Map) UsageDailyModel.fromMap(e.cast<String, dynamic>())]
          : const [],
    );
  }
}

/// 用量快照视图。
class UsageStatsView {
  final String range;
  final String generatedAt;
  final UsageSummaryView summary;
  final List<UsageModelView> models;
  final List<UsageDailyView> daily;

  UsageStatsView({
    required this.range,
    required this.generatedAt,
    required this.summary,
    required this.models,
    required this.daily,
  });

  factory UsageStatsView.fromMap(Map<String, dynamic> m) {
    return UsageStatsView(
      range: '${m['range'] ?? ''}',
      generatedAt: '${m['generatedAt'] ?? ''}',
      summary: UsageSummaryView.fromMap(m['summary'] is Map ? (m['summary'] as Map).cast<String, dynamic>() : const {}),
      models: [
        for (final e in m['models'] as List? ?? const [])
          if (e is Map) UsageModelView.fromMap(e.cast<String, dynamic>()),
      ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens)),
      daily: [
        for (final e in m['daily'] as List? ?? const [])
          if (e is Map) UsageDailyView.fromMap(e.cast<String, dynamic>()),
      ]..sort((a, b) => a.date.compareTo(b.date)),
    );
  }
}

/// 响应 → 视图;形状认不出给 null(页面空态)。
UsageStatsView? parseUsageStats(Object? res) {
  if (res is! Map) return null;
  if (res['summary'] is! Map) return null;
  return UsageStatsView.fromMap(res.cast<String, dynamic>());
}

/// token 数 → 中文短格式(15.6亿 / 504.6万 / 9,479)。
String formatTokens(num n) {
  if (n >= 100000000) return '${(n / 100000000).toStringAsFixed(1)}亿';
  if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
  return n.toInt().toString();
}

/// 服务端 range → 中文标签(总览卡右上角)。
String usageRangeLabel(String range) => switch (range) {
      'all' => '全部',
      '30d' => '近 30 天',
      '7d' => '近 7 天',
      _ => range,
    };

/// 时间范围选项(自定义日历在页面层)。
enum UsageRangeChoice { today, threeDays, sevenDays, thirtyDays, all }

extension UsageRangeLabel on UsageRangeChoice {
  String get label => switch (this) {
        UsageRangeChoice.today => '今天',
        UsageRangeChoice.threeDays => '近 3 天',
        UsageRangeChoice.sevenDays => '近 7 天',
        UsageRangeChoice.thirtyDays => '近 30 天',
        UsageRangeChoice.all => '全部',
      };

  /// 应向服务端拉的 range(今天/3 天拉 7d,客户端精筛)。
  String get serverRange => switch (this) {
        UsageRangeChoice.thirtyDays => '30d',
        UsageRangeChoice.all => 'all',
        _ => '7d',
      };
}

/// yyyy-MM-dd → M月d日(图表 x 轴);解析失败原样返回。
String usageDayLabel(String date) {
  final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(date.trim());
  if (m == null) return date;
  return '${int.parse(m.group(2)!)}月${int.parse(m.group(3)!)}日';
}

/// 本地日期键(与 server 分桶口径一致)。
String usageDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// 选项 → 日期窗口(闭区间 yyyy-MM-dd);今天/3 天拉 7d 数据后本地精筛。
(String, String) usageWindowFor(UsageRangeChoice choice, {DateTime? today}) {
  final n = today ?? DateTime.now();
  final end = usageDayKey(n);
  return switch (choice) {
    UsageRangeChoice.today => (end, end),
    UsageRangeChoice.threeDays => (usageDayKey(n.subtract(const Duration(days: 2))), end),
    UsageRangeChoice.sevenDays => (usageDayKey(n.subtract(const Duration(days: 6))), end),
    UsageRangeChoice.thirtyDays => (usageDayKey(n.subtract(const Duration(days: 29))), end),
    UsageRangeChoice.all => ('0000-01-01', '9999-12-31'),
  };
}

/// 日期窗口(闭区间)切片。纯函数。
List<UsageDailyView> sliceDailyWindow(List<UsageDailyView> daily, String startDay, String endDay) =>
    [for (final d in daily) if (d.date.compareTo(startDay) >= 0 && d.date.compareTo(endDay) <= 0) d];

/// 按选项切日期窗口。
List<UsageDailyView> sliceDailyByChoice(List<UsageDailyView> daily, UsageRangeChoice choice) {
  final (start, end) = usageWindowFor(choice);
  return sliceDailyWindow(daily, start, end);
}

/// 按模型集合过滤(空集 = 不过滤)。
List<UsageDailyView> filterDailyModels(List<UsageDailyView> daily, Set<String> only) {
  if (only.isEmpty) return daily;
  return [
    for (final d in daily)
      UsageDailyView(date: d.date, models: [for (final m in d.models) if (only.contains(m.modelId)) m]),
  ];
}

/// 聚合切片:总量/输入/输出/活跃天数(daily 每模型带输入输出,可精确算)。
class UsageSlice {
  final List<UsageDailyView> daily;
  final int totalTokens;
  final int inputTokens;
  final int outputTokens;
  final int activeDays;

  const UsageSlice({
    required this.daily,
    required this.totalTokens,
    required this.inputTokens,
    required this.outputTokens,
    required this.activeDays,
  });
}

UsageSlice aggregateSlice(List<UsageDailyView> daily) {
  var total = 0, input = 0, output = 0, activeDays = 0;
  for (final d in daily) {
    total += d.totalTokens;
    input += d.models.fold(0, (s, m) => s + m.inputTokens);
    output += d.models.fold(0, (s, m) => s + m.outputTokens);
    if (d.totalTokens > 0) activeDays++;
  }
  return UsageSlice(daily: daily, totalTokens: total, inputTokens: input, outputTokens: output, activeDays: activeDays);
}

/// 趋势图数据:每日 token 堆叠柱(前 topN 模型 + 其余归「其他」)。
class UsageTrendChart {
  final List<String> modelIds; // 前 topN + '__other__'
  final List<String> dayLabels; // x 轴(已转 M月d日)
  final List<List<double>> stacks; // [day][series]
  final double maxY; // y 轴顶(向上取整刻度)

  UsageTrendChart({required this.modelIds, required this.dayLabels, required this.stacks, required this.maxY});
}

/// 纯函数:daily → 堆叠柱数据。全 0 的日子不占柱位。
UsageTrendChart buildUsageTrendChart(List<UsageDailyView> daily, {int topN = 4}) {
  final totals = <String, int>{};
  for (final d in daily) {
    for (final m in d.models) {
      if (m.modelId.isEmpty) continue;
      totals[m.modelId] = (totals[m.modelId] ?? 0) + m.totalTokens;
    }
  }
  final ranked = totals.keys.toList()..sort((a, b) => (totals[b] ?? 0).compareTo(totals[a] ?? 0));
  final top = ranked.take(topN).toSet();
  final modelIds = [...top, if (ranked.length > topN) '__other__'];

  final dayLabels = <String>[];
  final stacks = <List<double>>[];
  var maxStack = 0.0;
  for (final d in daily) {
    if (d.totalTokens <= 0) continue;
    final values = List<double>.filled(modelIds.length, 0);
    for (final m in d.models) {
      final idx = top.contains(m.modelId) ? modelIds.indexOf(m.modelId) : modelIds.indexOf('__other__');
      if (idx >= 0 && m.totalTokens > 0) values[idx] += m.totalTokens;
    }
    dayLabels.add(usageDayLabel(d.date));
    stacks.add(values);
    final daySum = values.fold(0.0, (s, v) => s + v);
    if (daySum > maxStack) maxStack = daySum;
  }
  // y 轴顶:向上取 1/2/2.5/5×10^k 的整刻度
  var axis = maxStack <= 0 ? 1.0 : maxStack * 1.15;
  var mag = 1.0;
  while (axis >= 10) {
    axis /= 10;
    mag *= 10;
  }
  for (final step in [1.0, 2.0, 2.5, 5.0, 10.0]) {
    if (step >= axis) {
      axis = step * mag;
      break;
    }
  }
  return UsageTrendChart(modelIds: modelIds, dayLabels: dayLabels, stacks: stacks, maxY: axis);
}
