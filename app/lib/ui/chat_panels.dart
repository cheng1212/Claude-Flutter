import 'dart:async';

import 'package:flutter/material.dart';

import '../panel_utils.dart';
import 'subagent_page.dart';
import '../state/reducer.dart';
import '../state/zapp.dart';
import '../theme.dart';
// ---------------------------------------------------------------- 面板弹层

/// 子代理弹层壳:内容体在 [SubagentsPanel](任务中心三 Tab 也复用)。
class SubagentsSheet extends StatelessWidget {
  final ZApp app;
  final String sessionId;
  final List<ToolRow> rows;

  const SubagentsSheet({
    super.key,
    required this.app,
    required this.sessionId,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sheetHandle(),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.hub_rounded, size: 18, color: ZT.grape),
                SizedBox(width: 8),
                Text('子代理', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(child: SubagentsPanel(app: app, sessionId: sessionId, rows: rows)),
          ],
        ),
      ),
    );
  }
}

/// 子代理面板内容:本轮活动(聊天行实时派生)+ 磁盘转录历史(可点开只读视图)。
class SubagentsPanel extends StatefulWidget {
  final ZApp app;
  final String sessionId;
  final List<ToolRow> rows;

  const SubagentsPanel({
    super.key,
    required this.app,
    required this.sessionId,
    required this.rows,
  });

  @override
  State<SubagentsPanel> createState() => _SubagentsPanelState();
}

class _SubagentsPanelState extends State<SubagentsPanel> {
  List<Map<String, dynamic>>? _disk;

  /// 本会话正在用的模型 = 子代理的锁定基准(server 侧 PreToolUse hook 按它改写)。
  /// 从会话列表里查当前会话的 model 字段,拿不到就空(不显示对比)。
  String get _sessionModel {
    for (final s in widget.app.sessions) {
      if ('${s['id']}' == widget.sessionId) return '${s['model'] ?? ''}';
    }
    return '';
  }

  @override
  void initState() {
    super.initState();
    widget.app.subagents(widget.sessionId).then((rows) {
      if (mounted) setState(() => _disk = rows);
    });
  }

  @override
  Widget build(BuildContext context) {
    final live = deriveSubagents(widget.rows);
    final disk = _disk;
    // 列表收口:长会话里子代理只增不减(磁盘转录一个子代理一个文件),
    // 运行中的全留,已完成只留最近 15 个,更早的折叠起来(数据不删,点开还能看)。
    // 按 description 把"本轮活动"和"磁盘转录"归并:命中的磁盘行不再重复列出
    final diskRows = (disk ?? const <Map<String, dynamic>>[]).toList();
    for (final sub in live) {
      final hit = diskRows.indexWhere((d) => '${d['description'] ?? ''}' == sub.description);
      if (hit >= 0) {
        diskRows.removeAt(hit);
      }
    }
    final hasAny = live.isNotEmpty || diskRows.isNotEmpty;
    if (!hasAny) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Text(
          '还没有子代理。对话里让它"派一个子代理去查 X"就会出现。',
          style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6),
        ),
      );
    }
    // 统一成一个列表再收口:运行中的(实时卡)优先 → 已完成的实时卡 → 磁盘转录
    // (磁盘按更新时间倒序,新的在前)。这样"运行中永远在顶上,历史只留最近一批"。
    final merged = <Widget>[];
    final liveRunning = live.where((s) => !s.done).toList();
    final liveDone = live.where((s) => s.done).toList().reversed.toList(); // rows 是正序
    final diskSorted = [...diskRows]..sort((a, b) =>
        '${b['updatedAt'] ?? ''}'.compareTo('${a['updatedAt'] ?? ''}'));
    final ordered = [...liveRunning, ...liveDone, ...diskSorted];
    final trimmed = trimRecent<Object>(ordered, isRunning: (o) => o is SubagentInfo && !o.done);
    for (final o in trimmed.shown) {
      merged.add(o is SubagentInfo ? _liveCard(o) : _diskCard(o as Map<String, dynamic>));
    }
    if (trimmed.hidden > 0) {
      merged.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text('还有 ${trimmed.hidden} 个更早的子代理已折叠(转录仍在,不影响查看)',
            style: TextStyle(fontSize: 11.5, color: ZT.inkFaint)),
      ));
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: merged.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) => merged[i],
    );
  }

  Widget _liveCard(SubagentInfo sub) {
    // 模型:请求的(模型自己挑的)vs 实际(被 server 锁成会话模型)。
    // 两者不一致正是"乱用贵模型"的现场,必须让用户看得见。
    final sessionModel = _sessionModel;
    final requested = sub.requestedModel;
    final asked = requested.isEmpty ? '(未指定)' : requested;
    final locked = requested.isNotEmpty && sessionModel.isNotEmpty && requested != sessionModel;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      decoration: ShapeDecoration(
        color: ZT.bg,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.2, color: ZT.grape.withValues(alpha: ZT.palette.neoShadow ? 1 : 0.5)),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          sub.done
              ? Icon(Icons.check_circle_rounded, size: 16, color: ZT.aqua)
              : SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2, color: ZT.grape),
                ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(sub.description,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          Text(sub.done ? '已完成' : '运行中',
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w700, color: sub.done ? ZT.aqua : ZT.grape)),
          const SizedBox(width: 8),
          Text('${sub.activityCount} 次活动', style: TextStyle(fontSize: 11.5, color: ZT.inkFaint)),
        ]),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (sub.agentType.isNotEmpty)
            Text(sub.agentType, style: TextStyle(fontSize: 10.5, fontFamily: ZT.mono, color: ZT.inkFaint)),
          Text('模型 $asked', style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
          if (locked)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: ShapeDecoration(
                color: ZT.rose.withValues(alpha: 0.12),
                shape: StadiumBorder(side: BorderSide(width: 1, color: ZT.rose)),
              ),
              child: Text('已锁 → $sessionModel',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: ZT.rose)),
            )
          else if (sessionModel.isNotEmpty)
            Text('跟随本会话', style: TextStyle(fontSize: 10.5, color: ZT.aqua)),
        ]),
      ]),
    );
  }

  Widget _diskCard(Map<String, dynamic> d) {
    final type = '${d['agentType'] ?? ''}';
    final depth = (d['spawnDepth'] as num?)?.toInt() ?? 0;
    final model = '${d['model'] ?? ''}';
    final bits = <String>[
      if (type.isNotEmpty) type,
      if (depth > 1) '嵌套 $depth 层',
    ];
    final title = ('${d['description'] ?? ''}'.trim().isNotEmpty)
        ? '${d['description']}'
        : '${d['agentId']}';
    return InkWell(
      borderRadius: BorderRadius.circular(ZT.radius),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SubagentTranscriptPage(
          app: widget.app,
          sessionId: widget.sessionId,
          agentId: '${d['agentId']}',
          title: title,
        ),
      )),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
        decoration: ShapeDecoration(
          color: ZT.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(w: 1.2, color: ZT.edge),
          ),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 15, color: ZT.grape),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 8),
              if (bits.isNotEmpty)
                Text(bits.join(' · '), style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
              Icon(Icons.chevron_right_rounded, size: 16, color: ZT.inkSoft),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(children: [
              Icon(Icons.memory_rounded, size: 12, color: ZT.inkSoft),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                    // 采样不到 = 该子代理没换模型,跟着主模型跑(如实说明,不留空白)
                    model.isNotEmpty ? '实际模型:$model' : '实际模型:跟随本会话${_sessionModel.isEmpty ? '' : '($_sessionModel)'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, fontFamily: ZT.mono, color: ZT.inkSoft)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// 后台任务弹层壳:内容体在 [BackgroundsPanel](任务中心三 Tab 也复用)。
class BackgroundsSheet extends StatelessWidget {
  final ZApp app;
  final String sessionId;

  const BackgroundsSheet({super.key, required this.app, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.65,
        ),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            sheetHandle(),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.memory_rounded, size: 18, color: ZT.aqua),
                SizedBox(width: 8),
                Text('后台任务', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900)),
              ],
            ),
            const SizedBox(height: 10),
            Flexible(child: BackgroundsPanel(app: app, sessionId: sessionId)),
          ],
        ),
      ),
    );
  }
}

/// 后台任务面板内容(server 统一登记:Bash 旧行为 + SDK task_*):
/// 状态徽章 / 运行时长 / summary / 实时输出尾(output_file 现读)。
class BackgroundsPanel extends StatefulWidget {
  final ZApp app;
  final String sessionId;

  const BackgroundsPanel({super.key, required this.app, required this.sessionId});

  @override
  State<BackgroundsPanel> createState() => _BackgroundsPanelState();
}

class _BackgroundsPanelState extends State<BackgroundsPanel> {
  List<Map<String, dynamic>>? _data;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _load();
    // 有运行中任务时 2 秒轮询输出尾;全静了轮询空转不发请求
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _load(quiet: true));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load({bool quiet = false}) async {
    final fresh = await widget.app.backgrounds(widget.sessionId);
    final anyRunning = fresh.any((b) => '${b['status'] ?? 'running'}' == 'running');
    if (!anyRunning) _tick?.cancel();
    if (!mounted) return;
    if (quiet && !anyRunning && (_data ?? const []).isEmpty) return;
    setState(() => _data = fresh);
  }

  ({Color main, Color soft, String label, IconData icon}) _statusStyle(String status) {
    // main/soft 一律深变体:它们落在小图标、描边与状态小字上,
    // 鲜色系在浅底不达 4.5:1(文字)/3:1(非文本)。
    switch (status) {
      case 'running':
        return (main: ZT.aquaText, soft: ZT.aquaText, label: '运行中', icon: Icons.circle_rounded);
      case 'completed':
        return (main: ZT.aquaText, soft: ZT.aquaText, label: '已完成', icon: Icons.check_circle_rounded);
      case 'failed':
        return (main: ZT.roseText, soft: ZT.roseText, label: '失败', icon: Icons.error_outline_rounded);
      case 'paused':
        return (main: ZT.lemonText, soft: ZT.lemonText, label: '已暂停', icon: Icons.pause_circle_outline_rounded);
      case 'killed':
      case 'stopped':
        return (main: ZT.inkSoft, soft: ZT.inkFaint, label: '已停止', icon: Icons.stop_rounded);
      default:
        return (main: ZT.inkSoft, soft: ZT.inkFaint, label: status, icon: Icons.help_outline_rounded);
    }
  }

  String _durationOf(Map<String, dynamic> b) {
    final start = (b['startedAt'] as num?)?.toInt();
    if (start == null) return '';
    final end = (b['endAt'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch;
    final d = Duration(milliseconds: end - start);
    if (d.inMinutes >= 1) return '${d.inMinutes}分${d.inSeconds % 60}秒';
    return '${d.inSeconds}秒';
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return const Padding(
        padding: EdgeInsets.all(18),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (data.isEmpty) {
      return Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Text(
          '没有后台任务。对话里让它"后台跑 flutter build"就会出现。',
          style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6),
        ),
      );
    }
    // 列表收口:后台任务在长会话里同样只增不减(内存登记表),运行中的全留,
    // 已结束的按开始时间倒序只留最近 15 个,更早的折叠(数据不删,server 侧仍留着)。
    final sorted = [...data]..sort((a, b) =>
        ((b['startedAt'] as num?)?.toInt() ?? 0).compareTo((a['startedAt'] as num?)?.toInt() ?? 0));
    final trimmed = trimRecent<Map<String, dynamic>>(sorted,
        isRunning: (b) => '${b['status'] ?? 'running'}' == 'running');
    final rows = trimmed.shown;
    return ListView.separated(
      shrinkWrap: true,
      itemCount: rows.length + (trimmed.hidden > 0 ? 1 : 0),
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        if (i >= rows.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text('还有 ${trimmed.hidden} 个更早的后台任务已折叠',
                style: TextStyle(fontSize: 11.5, color: ZT.inkFaint)),
          );
        }
        final b = rows[i];
        final status = '${b['status'] ?? 'running'}';
        final style = _statusStyle(status);
        final description = (b['description'] ?? '') as String;
        final command = ((b['command'] ?? '') as String).trim();
        final title = command.isNotEmpty ? command : (description.isNotEmpty ? description : '后台任务');
        final summary = ((b['summary'] ?? '') as String).trim();
        final fileTail = ((b['outputTail'] ?? '') as String).trim();
        final lastOutput = ((b['lastOutput'] ?? '') as String).trim();
        final outputTail = fileTail.isNotEmpty ? fileTail : lastOutput;
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          decoration: ShapeDecoration(
            color: ZT.bg,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZT.radius),
              side: ZT.inkSide(
                w: 1.2,
                color: style.soft.withValues(alpha: 0.5),
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(style.icon, size: 12, color: style.main),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontFamily: ZT.mono,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    style.label,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: style.main,
                    ),
                  ),
                  if ((b['startedAt'] as num?) != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      _durationOf(b),
                      style: TextStyle(fontSize: 10.5, color: ZT.inkFaint),
                    ),
                  ],
                ],
              ),
              if (summary.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    summary,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: ZT.inkSoft),
                  ),
                ),
              if (outputTail.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxHeight: 110,
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        outputTail,
                        style: TextStyle(
                          fontSize: 10.5,
                          fontFamily: ZT.mono,
                          color: ZT.inkFaint,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
