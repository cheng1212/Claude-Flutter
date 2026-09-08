// 用量信息页:时间范围 + 模型筛选 + 总览 + 每日堆叠柱 + 模型明细。
// 数据源 /api/usage(server runs 表聚合);视图解析/切片在 ../usage_stats.dart(纯函数)。
// 版式对照 zremote usage_page:neubrutalist 卡片(citrus 下墨线+硬阴影),奶油主题下自动柔和。
import 'package:flutter/material.dart';

import '../state/zapp.dart';
import '../theme.dart';
import '../usage_stats.dart';

class UsagePage extends StatefulWidget {
  final ZApp app;

  const UsagePage({super.key, required this.app});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  UsageRangeChoice _choice = UsageRangeChoice.sevenDays;
  String? _modelFilter; // null = 全部模型

  ZApp get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    _load();
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  void _load() => app.loadUsageStats(range: _choice.serverRange);

  @override
  Widget build(BuildContext context) {
    final view = app.usageStats == null ? null : parseUsageStats(app.usageStats);
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: const Text('用量信息', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: app.usageStatsLoading ? null : _load,
            icon: app.usageStatsLoading
                ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 21),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: view == null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.insights_rounded, size: 40, color: ZT.inkFaint),
                const SizedBox(height: 12),
                Text(app.usageStatsLoading ? '统计中…' : '暂无用量数据',
                    style: TextStyle(fontSize: 13, color: ZT.inkSoft)),
                const SizedBox(height: 14),
                BigButton(label: '重新加载', icon: Icons.refresh_rounded, onPressed: app.usageStatsLoading ? null : _load),
              ]),
            )
          : RefreshIndicator(
              color: ZT.primary,
              backgroundColor: ZT.surface,
              onRefresh: () async => _load(),
              child: ListView(padding: const EdgeInsets.fromLTRB(14, 10, 14, 24), children: [
                _rangeCard(),
                const SizedBox(height: 12),
                _overviewCard(view),
                const SizedBox(height: 12),
                _dailyCard(view),
                const SizedBox(height: 12),
                _modelsCard(view),
              ]),
            ),
    );
  }

  // -------------------------------------------------------------- 时间范围

  Widget _rangeCard() {
    return HardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.calendar_month_rounded, size: 16, color: ZT.primary),
          const SizedBox(width: 7),
          const Text('时间范围', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 10),
        for (final c in UsageRangeChoice.values) ...[
          _rangePill(c),
          const SizedBox(height: 8),
        ],
        Divider(height: 18, thickness: 1, color: ZT.line),
        _modelFilterRow(),
      ]),
    );
  }

  Widget _rangePill(UsageRangeChoice c) {
    final selected = c == _choice;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        if (selected) return;
        setState(() => _choice = c);
        _load();
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: selected ? ZT.lemon : ZT.surface,
          shape: StadiumBorder(side: BorderSide(width: selected ? 1.6 : 1.2, color: selected ? ZT.ink : ZT.edge)),
        ),
        child: Text(c.label,
            style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                color: selected ? ZT.ink : ZT.inkSoft)),
      ),
    );
  }

  Widget _modelFilterRow() {
    final view = app.usageStats == null ? null : parseUsageStats(app.usageStats);
    final count = view?.models.length ?? 0;
    return Row(children: [
      Icon(Icons.category_rounded, size: 15, color: ZT.aqua),
      const SizedBox(width: 7),
      const Text('模型类型', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
      const Spacer(),
      PopupMenuButton<String?>(
        tooltip: '筛选模型',
        onSelected: (v) => setState(() => _modelFilter = v),
        itemBuilder: (ctx) => [
          const PopupMenuItem<String?>(value: null, child: Text('全部模型', style: TextStyle(fontSize: 13))),
          if (view != null)
            for (final m in view.models)
              PopupMenuItem<String?>(value: m.modelId, child: Text(m.modelId, style: const TextStyle(fontSize: 12.5))),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: ShapeDecoration(
            color: ZT.surfaceHi,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: ZT.inkSide()),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(_modelFilter ?? '全部模型($count个)',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZT.ink)),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: ZT.inkSoft),
          ]),
        ),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 总览

  Widget _overviewCard(UsageStatsView view) {
    final s = view.summary;
    // 模型筛选时:总量/输入/输出按明细重算;命中率沿用全局口径
    final filtered = _modelFilter != null;
    final models = _filteredModels(view);
    final total = filtered ? models.fold(0, (n, m) => n + m.totalTokens) : s.totalTokens;
    final input = filtered ? models.fold(0, (n, m) => n + m.inputTokens) : s.inputTokens;
    final output = filtered ? models.fold(0, (n, m) => n + m.outputTokens) : s.outputTokens;
    final updated = _shortTime(view.generatedAt);
    return HardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.trending_up_rounded, size: 16, color: ZT.primary),
          const SizedBox(width: 7),
          const Text('总览', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text('${usageRangeLabel(view.range)} · 更新于 $updated',
              style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(formatTokens(total), style: TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: ZT.primary)),
          const SizedBox(width: 8),
          Text('tokens', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZT.inkSoft)),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _statBox('输入', formatTokens(input), ZT.primary)),
          const SizedBox(width: 8),
          Expanded(child: _statBox('输出', formatTokens(output), ZT.primary)),
          const SizedBox(width: 8),
          Expanded(child: _statBox('缓存命中率', '${(s.cacheHitRate * 100).toStringAsFixed(1)}%', ZT.aqua)),
        ]),
        const SizedBox(height: 9),
        Text('缓存读取 ${formatTokens(s.cacheReadTokens)} · 缓存写入 ${formatTokens(s.cacheCreationTokens)}(命中越高越省)',
            style: TextStyle(fontSize: 11, color: ZT.inkSoft)),
        const SizedBox(height: 9),
        Wrap(spacing: 6, runSpacing: 4, children: [
          _metaPill('${s.totalSessions} 会话'),
          _metaPill('${s.totalTurns} 回合'),
          _metaPill('${formatTokens(s.toolCallCount.toDouble())} 次工具调用'),
          _metaPill('活跃 ${s.activeDays} 天'),
          if (s.currentStreakDays > 0) _metaPill('连续 ${s.currentStreakDays} 天'),
          if (filtered) _metaPill('模型:$_modelFilter'),
        ]),
        const SizedBox(height: 8),
        if (s.favoriteModel.isNotEmpty)
          Row(children: [
            Text('常用模型 ', style: TextStyle(fontSize: 11, color: ZT.inkFaint)),
            Expanded(
              child: Text(s.favoriteModel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.ink, fontFamily: ZT.mono)),
            ),
          ]),
      ]),
    );
  }

  Widget _statBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: ShapeDecoration(
        color: ZT.surfaceHi,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: ZT.inkSide()),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
        const SizedBox(height: 3),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: color)),
      ]),
    );
  }

  Widget _metaPill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999), side: ZT.inkSide(w: 1.1)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ZT.inkSoft)),
    );
  }

  // -------------------------------------------------------------- 每日用量

  Widget _dailyCard(UsageStatsView view) {
    final chart = buildUsageTrendChart(_filteredDaily(view));
    if (chart.stacks.isEmpty) {
      return HardCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _dailyHeader(),
          const SizedBox(height: 10),
          Text('该范围内没有用量', style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
        ]),
      );
    }
    final colors = _seriesColors(chart.modelIds);
    return HardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _dailyHeader(),
        const SizedBox(height: 8),
        Wrap(spacing: 10, runSpacing: 4, children: [
          for (var i = 0; i < chart.modelIds.length; i++)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 8, height: 8, decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Text(chart.modelIds[i] == '__other__' ? '其他' : chart.modelIds[i],
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ZT.ink, fontFamily: ZT.mono)),
            ]),
        ]),
        const SizedBox(height: 10),
        SizedBox(
          height: 190,
          width: double.infinity,
          child: CustomPaint(painter: _StackedBarsPainter(chart: chart, colors: colors, labelColor: ZT.inkFaint, gridColor: ZT.line)),
        ),
      ]),
    );
  }

  Widget _dailyHeader() {
    return Row(children: [
      Icon(Icons.bar_chart_rounded, size: 16, color: ZT.grape),
      const SizedBox(width: 7),
      const Text('每日用量(tokens)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
    ]);
  }

  List<Color> _seriesColors(List<String> modelIds) {
    final palette = [ZT.primary, ZT.aqua, ZT.grape, ZT.lemon];
    return [
      for (var i = 0; i < modelIds.length; i++)
        modelIds[i] == '__other__' ? ZT.inkSoft : palette[i % palette.length],
    ];
  }

  // -------------------------------------------------------------- 模型明细

  Widget _modelsCard(UsageStatsView view) {
    final models = _filteredModels(view);
    return HardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.donut_small_rounded, size: 16, color: ZT.aqua),
          const SizedBox(width: 7),
          const Text('模型明细', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text('${models.length} 个模型', style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
        ]),
        const SizedBox(height: 10),
        if (models.isEmpty)
          Text('该范围内没有用量', style: TextStyle(fontSize: 12, color: ZT.inkFaint))
        else
          for (var i = 0; i < models.length; i++) ...[
            _modelRow(models[i], _seriesColors([models[i].modelId])[0]),
            if (i != models.length - 1) const SizedBox(height: 12),
          ],
      ]),
    );
  }

  Widget _modelRow(UsageModelView m, Color color) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 9, height: 9, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(m.modelId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: ZT.ink, fontFamily: ZT.mono)),
        ),
        const SizedBox(width: 8),
        Text(formatTokens(m.totalTokens), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: ZT.ink)),
        const SizedBox(width: 8),
        SizedBox(
          width: 42,
          child: Text('${(m.share * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.right, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZT.inkSoft)),
        ),
      ]),
      const SizedBox(height: 4),
      Text('输入 ${formatTokens(m.inputTokens)} · 输出 ${formatTokens(m.outputTokens)} · ${formatTokens(m.requestCount.toDouble())} 次请求',
          style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
      const SizedBox(height: 5),
      Container(
        height: 5,
        decoration: BoxDecoration(color: ZT.line, borderRadius: BorderRadius.circular(99)),
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: m.share.clamp(0.0, 1.0),
          child: Container(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(99))),
        ),
      ),
    ]);
  }

  // ------------------------------------------------------------------ 工具

  List<UsageModelView> _filteredModels(UsageStatsView view) =>
      _modelFilter == null ? view.models : view.models.where((m) => m.modelId == _modelFilter).toList();

  List<UsageDailyView> _filteredDaily(UsageStatsView view) {
    final sliced = sliceDailyByChoice(view.daily, _choice);
    if (_modelFilter == null) return sliced;
    return [
      for (final d in sliced)
        UsageDailyView(date: d.date, models: [
          for (final (id, n) in d.models)
            if (id == _modelFilter) (id, n),
        ]),
    ];
  }

  String _shortTime(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// 每日堆叠柱:自绘,不引第三方图表库。
class _StackedBarsPainter extends CustomPainter {
  final UsageTrendChart chart;
  final List<Color> colors;
  final Color labelColor;
  final Color gridColor;

  _StackedBarsPainter({required this.chart, required this.colors, required this.labelColor, required this.gridColor});

  @override
  void paint(Canvas canvas, Size size) {
    const padLeft = 40.0;
    const padBottom = 18.0;
    const padTop = 6.0;
    final plotW = size.width - padLeft;
    final plotH = size.height - padBottom - padTop;
    if (plotW <= 0 || plotH <= 0 || chart.stacks.isEmpty) return;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    final labelStyle = TextStyle(fontSize: 9.5, color: labelColor);

    for (var i = 0; i <= 3; i++) {
      final y = padTop + plotH - plotH * i / 3;
      canvas.drawLine(Offset(padLeft, y), Offset(size.width, y), gridPaint);
      final tp = TextPainter(
        text: TextSpan(text: formatTokens(chart.maxY * i / 3), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    final n = chart.stacks.length;
    final slot = plotW / n;
    final barW = slot * 0.52;
    final unit = chart.maxY <= 0 ? 0.0 : plotH / chart.maxY;

    for (var d = 0; d < n; d++) {
      final cx = padLeft + slot * (d + 0.5);
      var y = padTop + plotH;
      for (var s = 0; s < chart.stacks[d].length; s++) {
        final v = chart.stacks[d][s];
        if (v <= 0) continue;
        final h = v * unit;
        canvas.drawRRect(
          BorderRadius.circular(3).toRRect(Rect.fromLTWH(cx - barW / 2, y - h, barW, h)),
          Paint()..color = colors[s],
        );
        y -= h;
      }
      final step = (n / 7).ceil();
      if (d % step == 0 || d == n - 1) {
        final tp = TextPainter(
          text: TextSpan(text: chart.dayLabels[d], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset((cx - tp.width / 2).clamp(padLeft, size.width - tp.width), padTop + plotH + 4));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StackedBarsPainter old) =>
      old.chart != chart || old.colors != colors || old.labelColor != labelColor || old.gridColor != gridColor;
}
