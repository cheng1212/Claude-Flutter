// 用量信息页:时间范围(可折叠/日历自定义) + 模型筛选 + 总览 + 每日堆叠柱 + 模型明细。
// 数据源 /api/usage(server runs 表聚合);视图解析/切片在 ../usage_stats.dart(纯函数)。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../state/zapp.dart';
import '../theme.dart';
import '../usage_stats.dart';

/// 堆叠柱里单段的高度:至少 1px 保证可见,但不许超过本段真实高度。
///
/// ⚠️ clamp 的下界必须 ≤ 上界:段高不足 1px(值极小/日子太多)时 `clamp(1.0, h)`
/// 会抛 ArgumentError。绘制代码每帧跑,抛一次就是**每帧一次异常**,主线程被拖死
/// (实测:白屏 / 回到底部点不动 / 整个卡死)。抽成纯函数便于回归。
double stackSegmentHeight({required double h, required double gap, required bool isBottom}) {
  if (h <= 1.0) return h;
  return (h - (isBottom ? 0 : gap)).clamp(1.0, h);
}

/// 日期标签的水平位置:居中,但夹在绘图区内不越界。
/// 窄屏或长标签时 `viewWidth - labelWidth` 可能小于 padLeft(甚至为负),
/// 必须先取 max 当上界,否则同上 —— clamp 抛异常。
double stackLabelX({
  required double centerX,
  required double labelWidth,
  required double padLeft,
  required double viewWidth,
}) {
  final maxX = math.max(padLeft, viewWidth - labelWidth);
  return (centerX - labelWidth / 2).clamp(padLeft, maxX);
}

class UsagePage extends StatefulWidget {
  final ZApp app;

  const UsagePage({super.key, required this.app});

  @override
  State<UsagePage> createState() => _UsagePageState();
}

class _UsagePageState extends State<UsagePage> {
  UsageRangeChoice _choice = UsageRangeChoice.sevenDays;
  DateTimeRange? _custom; // 日历自定义窗口;非空时优先于 _choice
  bool _rangeExpanded = false;
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
                Text(app.usageStatsLoading
                    ? '统计中…'
                    : (app.usageStatsError ? '用量数据加载失败,点下方按钮重试' : '暂无用量数据'),
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

  /// 当前生效窗口(闭区间 yyyy-MM-dd);自定义优先。
  (String, String) get _window {
    if (_custom != null) {
      return (usageDayKey(_custom!.start), usageDayKey(_custom!.end));
    }
    return usageWindowFor(_choice);
  }

  String get _rangeTitle {
    if (_custom != null) {
      return '自定义 ${usageDayLabel(usageDayKey(_custom!.start))}-${usageDayLabel(usageDayKey(_custom!.end))}';
    }
    return _choice.label;
  }

  Widget _rangeCard() {
    return HardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 折叠头:点开展开/收起五档预设 + 日历自定义
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => _rangeExpanded = !_rangeExpanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              Icon(Icons.calendar_month_rounded, size: 16, color: ZT.primary),
              const SizedBox(width: 7),
              const Text('时间范围', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              const Spacer(),
              Text(_rangeTitle, style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
              AnimatedRotation(
                turns: _rangeExpanded ? 0 : -0.25,
                duration: const Duration(milliseconds: 150),
                child: Icon(Icons.expand_more_rounded, size: 20, color: ZT.inkSoft),
              ),
            ]),
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOut,
          crossFadeState: _rangeExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(children: [
              for (final c in UsageRangeChoice.values) ...[
                _rangePill(c),
                const SizedBox(height: 8),
              ],
              _customPill(),
            ]),
          ),
        ),
        Divider(height: 18, thickness: 1, color: ZT.line),
        _modelFilterRow(),
      ]),
    );
  }

  Widget _rangePill(UsageRangeChoice c) {
    final selected = _custom == null && c == _choice;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () {
        setState(() {
          _choice = c;
          _custom = null;
        });
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

  Widget _customPill() {
    final selected = _custom != null;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDateRangePicker(
          context: context,
          firstDate: now.subtract(const Duration(days: 365)),
          lastDate: now,
          initialDateRange: _custom ??
              DateTimeRange(start: now.subtract(const Duration(days: 6)), end: now),
        );
        if (picked == null || !mounted) return;
        setState(() => _custom = picked);
        _load(); // 自定义窗口拉全量,客户端按窗口精筛
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 9),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: selected ? ZT.lemon : ZT.surface,
          shape: StadiumBorder(side: BorderSide(width: selected ? 1.6 : 1.2, color: selected ? ZT.ink : ZT.edge)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.date_range_rounded, size: 15, color: selected ? ZT.ink : ZT.inkSoft),
          const SizedBox(width: 6),
          Text(selected ? _rangeTitle : '自定义',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
                  color: selected ? ZT.ink : ZT.inkSoft)),
        ]),
      ),
    );
  }

  Widget _modelFilterRow() {
    final view = app.usageStats == null ? null : parseUsageStats(app.usageStats);
    final count = view?.models.length ?? 0;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _pickModel(view), // 整行可点,下拉不再"点不了"
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(Icons.category_rounded, size: 15, color: ZT.aqua),
          const SizedBox(width: 7),
          const Text('模型类型', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: ShapeDecoration(
              color: ZT.surfaceHi,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: ZT.inkSide()),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(_modelFilter ?? '全部模型($count个)',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: ZT.ink)),
              Icon(Icons.arrow_drop_down_rounded, size: 20, color: ZT.inkSoft),
            ]),
          ),
        ]),
      ),
    );
  }

  Future<void> _pickModel(UsageStatsView? view) async {
    final picked = await showModalBottomSheet<String?>(
      context: context,
      backgroundColor: ZT.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 12, 18, 4),
            child: Text('模型类型', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          ),
          ListTile(
            dense: true,
            title: const Text('全部模型', style: TextStyle(fontSize: 13.5)),
            trailing: _modelFilter == null ? Icon(Icons.check_rounded, size: 18, color: ZT.primary) : null,
            onTap: () => Navigator.pop(ctx, '__all__'),
          ),
          if (view != null)
            for (final m in view.models)
              ListTile(
                dense: true,
                title: Text(m.modelId, style: const TextStyle(fontSize: 13, fontFamily: ZT.mono)),
                trailing: _modelFilter == m.modelId ? Icon(Icons.check_rounded, size: 18, color: ZT.primary) : null,
                onTap: () => Navigator.pop(ctx, m.modelId),
              ),
          const SizedBox(height: 6),
        ]),
      ),
    );
    if (picked == null || !mounted) return; // 点外部关闭 = 维持
    setState(() => _modelFilter = picked == '__all__' ? null : picked);
  }

  // ------------------------------------------------------------------ 切片

  /// 窗口切片 + 模型过滤后的 daily。
  List<UsageDailyView> _sliceDaily(UsageStatsView view) {
    final (start, end) = _window;
    final sliced = sliceDailyWindow(view.daily, start, end);
    return filterDailyModels(sliced, _modelFilter == null ? const {} : {_modelFilter!});
  }

  // ------------------------------------------------------------------ 总览

  Widget _overviewCard(UsageStatsView view) {
    final s = view.summary;
    final slice = aggregateSlice(_sliceDaily(view));
    final unfiltered = _modelFilter == null && _custom == null; // 全量口径:总览沿用服务端 summary
    final total = unfiltered ? s.totalTokens : slice.totalTokens;
    final input = unfiltered ? s.inputTokens : slice.inputTokens;
    final output = unfiltered ? s.outputTokens : slice.outputTokens;
    final updated = _shortTime(view.generatedAt);
    return HardCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.trending_up_rounded, size: 16, color: ZT.primary),
          const SizedBox(width: 7),
          const Text('总览', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
          const Spacer(),
          Text('$_rangeTitle · 更新于 $updated', style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
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
          if (unfiltered) ...[
            _metaPill('${s.totalSessions} 会话'),
            _metaPill('${s.totalTurns} 回合'),
          ],
          _metaPill('${formatTokens(s.toolCallCount.toDouble())} 次工具调用'),
          _metaPill('活跃 ${slice.activeDays} 天'),
          if (unfiltered && s.currentStreakDays > 0) _metaPill('连续 ${s.currentStreakDays} 天'),
          if (!unfiltered) _metaPill('模型:$_modelFilter'),
        ]),
        const SizedBox(height: 8),
        if (s.favoriteModel.isNotEmpty && unfiltered)
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
    final chart = buildUsageTrendChart(_sliceDaily(view));
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
    final slice = aggregateSlice(_sliceDaily(view));
    final models = _filteredModels(view, slice);
    // 明细行颜色与堆叠柱同源:按图表系列色取色(前 4 名循环色,其余灰),
    // 原写法 _seriesColors([单个]) 恒返回 palette[0],全部行同色且与图表对不上
    final chart = buildUsageTrendChart(_sliceDaily(view));
    final chartColors = _seriesColors(chart.modelIds);
    Color seriesColor(String modelId) {
      final i = chart.modelIds.indexOf(modelId);
      return i >= 0 ? chartColors[i] : ZT.inkSoft;
    }

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
            _modelRow(models[i], seriesColor(models[i].modelId)),
            if (i != models.length - 1) const SizedBox(height: 12),
          ],
      ]),
    );
  }

  /// 明细:优先用服务端 models(过滤模型);窗口/模型切片时按 daily 重算。
  List<UsageModelView> _filteredModels(UsageStatsView view, UsageSlice slice) {
    if (_modelFilter == null && _custom == null && _choice == UsageRangeChoice.all) {
      return view.models;
    }
    // 其余一律按 daily 切片重算,与图表共用同一个时间窗口。
    // 原来"预设窗口直接取服务端 models"是错的:app 选「今天」时拉的是 7d,
    // 模型明细就跟着列出 7 天的模型(实测:今天只用了 2 个模型却显示 6 个)。
    // daily 不含缓存读(服务端按天只带输入/输出),切片路径给不出真实命中率:
    // 命中率取服务端该模型的整体值(口径一致,好过瞎算),请求数按出现天数近似。
    final serverRate = {for (final m in view.models) m.modelId: m.cacheHitRate};
    final serverCacheRead = {for (final m in view.models) m.modelId: m.cacheReadInputTokens};
    final perModel = <String, ({int total, int input, int output, int requests})>{};
    for (final d in slice.daily) {
      for (final m in d.models) {
        if (_modelFilter != null && m.modelId != _modelFilter) continue;
        final p = perModel.putIfAbsent(m.modelId, () => (total: 0, input: 0, output: 0, requests: 0));
        perModel[m.modelId] = (
          total: p.total + m.totalTokens,
          input: p.input + m.inputTokens,
          output: p.output + m.outputTokens,
          requests: p.requests + 1, // 粗略:出现天数近似请求数
        );
      }
    }
    final list = [
      for (final e in perModel.entries)
        UsageModelView(
          modelId: e.key,
          totalTokens: e.value.total,
          inputTokens: e.value.input,
          outputTokens: e.value.output,
          requestCount: e.value.requests,
          share: slice.totalTokens > 0 ? e.value.total / slice.totalTokens : 0,
          cacheReadInputTokens: serverCacheRead[e.key] ?? 0,
          cacheHitRate: serverRate[e.key] ?? 0,
        ),
    ]..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));
    return list;
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
      Text(
          '输入 ${formatTokens(m.inputTokens)} · 输出 ${formatTokens(m.outputTokens)} · '
          '${formatTokens(m.requestCount.toDouble())} 次请求 · 缓存命中 ${(m.cacheHitRate * 100).toStringAsFixed(1)}%',
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

  String _shortTime(String iso) {
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '';
    final hh = d.hour.toString().padLeft(2, '0');
    final mm = d.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// 每日堆叠柱:自绘,不引第三方图表库。柱宽封顶、分段圆角、分段间留 1px 缝。
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
    final barW = slot * 0.52 > 26 ? 26.0 : slot * 0.52; // 柱宽封顶,天数少时不至于糊成一坨
    final unit = chart.maxY <= 0 ? 0.0 : plotH / chart.maxY;
    const segGap = 1.2; // 分段之间的细缝,两模型堆叠时不糊成一块

    for (var d = 0; d < n; d++) {
      final cx = padLeft + slot * (d + 0.5);
      var y = padTop + plotH;
      final segs = [for (var s = 0; s < chart.stacks[d].length; s++) (s, chart.stacks[d][s])]
          .where((e) => e.$2 > 0)
          .toList();
      for (var i = 0; i < segs.length; i++) {
        final (s, v) = segs[i];
        final h = v * unit;
        final top = y - h;
        final isTop = i == segs.length - 1;
        final isBottom = i == 0;
        final r = BorderRadius.only(
          topLeft: Radius.circular(isTop ? 3 : 0),
          topRight: Radius.circular(isTop ? 3 : 0),
          bottomLeft: Radius.circular(isBottom ? 3 : 0),
          bottomRight: Radius.circular(isBottom ? 3 : 0),
        );
        final hDraw = stackSegmentHeight(h: h, gap: segGap, isBottom: isBottom);
        canvas.drawRRect(r.toRRect(Rect.fromLTWH(cx - barW / 2, y - hDraw, barW, hDraw)), Paint()..color = colors[s]);
        y = top;
      }
      final step = (n / 7).ceil();
      if (d % step == 0 || d == n - 1) {
        final tp = TextPainter(
          text: TextSpan(text: chart.dayLabels[d], style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
            canvas,
            Offset(
                stackLabelX(
                    centerX: cx, labelWidth: tp.width, padLeft: padLeft, viewWidth: size.width),
                padTop + plotH + 4));
      }
    }
  }

  @override
  bool shouldRepaint(covariant _StackedBarsPainter old) =>
      old.chart != chart || old.colors != colors || old.labelColor != labelColor || old.gridColor != gridColor;
}
