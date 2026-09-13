// 定时任务弹层:全局跨会话(AllCronsSheet)+ 本会话面板内容(CronsPanel,任务中心复用)。
// 卡片形态参考用户给的样式:标题+开关 / 描述 / 状态徽章行 / 四个操作按钮。
import 'dart:async';

import 'package:flutter/material.dart';

import '../session_utils.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'toast.dart';

/// 从 prompt 提一个像标题的东西:取首行/首句,截断。
/// (CronCreate 没有 title 参数,标题只能从内容里提炼,和参考稿的来源一致。)
String cronTitleOf(String prompt) {
  final firstLine = prompt.split('\n').first.trim();
  if (firstLine.isEmpty) return '(未命名)';
  // 中文句号/问号/叹号/分号 或 英文句点 都当断句
  final m = RegExp(r'[。！？；.!?;]').firstMatch(firstLine);
  final head = m == null ? firstLine : firstLine.substring(0, m.start);
  final cut = head.trim().isEmpty ? firstLine : head.trim();
  return cut.length > 24 ? '${cut.substring(0, 24)}…' : cut;
}

/// 共享卡片:两处面板用同一套渲染,避免"全局"和"本会话"两套样式漂移。
class CronCard extends StatelessWidget {
  final Map<String, dynamic> c;
  final Future<void> Function() onToggle;
  final Future<void> Function() onRunNow;
  final Future<void> Function() onRestart;
  final Future<void> Function() onDelete;
  final Future<void> Function() onHistory;
  final bool busy;
  /// 非空时在标题下显示所属会话(全局列表用)
  final String? sessionLabel;

  const CronCard({
    super.key,
    required this.c,
    required this.onToggle,
    required this.onRunNow,
    required this.onRestart,
    required this.onDelete,
    required this.onHistory,
    this.busy = false,
    this.sessionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final prompt = '${c['prompt'] ?? ''}';
    final cron = '${c['cron'] ?? ''}';
    final paused = '${c['status'] ?? ''}' == 'paused';
    final runCount = (c['run_count'] as num?)?.toInt() ?? 0;
    final lastStatus = '${c['last_status'] ?? ''}';
    final next = cronNextLabel(c['next_fire'] == null ? null : '${c['next_fire']}', DateTime.now());

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.4, color: paused ? ZT.edge : ZT.ink),
        ),
        shadows: paused ? null : ZT.hard(dx: 2, dy: 2),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // —— 标题 + 启用开关 ——
        Row(children: [
          Expanded(
            child: Text(cronTitleOf(prompt),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 14.5, fontWeight: FontWeight.w900, color: paused ? ZT.inkFaint : ZT.ink)),
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          Switch(
            value: !paused,
            activeThumbColor: ZT.primary,
            onChanged: (_) => onToggle(),
          ),
        ]),
        if (sessionLabel != null && sessionLabel!.isNotEmpty) ...[
          const SizedBox(height: 1),
          Row(children: [
            Icon(Icons.chat_bubble_outline_rounded, size: 11, color: ZT.inkFaint),
            const SizedBox(width: 4),
            Flexible(
              child: Text(sessionLabel!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
            ),
          ]),
        ],
        const SizedBox(height: 6),
        // —— 描述(计划内容)——
        Text(prompt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, height: 1.45, color: ZT.inkSoft)),
        const SizedBox(height: 9),
        // —— 徽章行:状态 / 下次触发 / cron / 已跑次数 ——
        Wrap(spacing: 6, runSpacing: 5, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _chip(
            paused ? '已暂停' : '启用中',
            fg: paused ? ZT.inkSoft : ZT.aqua,
            bg: (paused ? ZT.inkSoft : ZT.aqua).withValues(alpha: 0.14),
            border: (paused ? ZT.inkSoft : ZT.aqua).withValues(alpha: 0.55),
            bold: true,
          ),
          if (!paused)
            _chip('⏱ 下次 $next', fg: ZT.ink, bg: ZT.lemon.withValues(alpha: 0.30), border: ZT.lemon, bold: true),
          Text(cron, style: TextStyle(fontSize: 10.5, fontFamily: ZT.mono, color: ZT.inkFaint)),
          Text('已跑 $runCount 次', style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
          if (lastStatus == 'skipped')
            Text('上次跳过', style: TextStyle(fontSize: 10.5, color: ZT.lemon)),
          if (lastStatus == 'failed')
            Text('上次失败', style: TextStyle(fontSize: 10.5, color: ZT.rose)),
        ]),
        const SizedBox(height: 10),
        // —— 四个操作 ——
        Row(children: [
          Expanded(child: _action('立即运行', Icons.bolt_rounded, ZT.primary, onPrimary: true, onTap: onRunNow)),
          const SizedBox(width: 6),
          Expanded(child: _action('重启', Icons.restart_alt_rounded, ZT.ink, onTap: onRestart)),
          const SizedBox(width: 6),
          Expanded(child: _action('删除', Icons.delete_outline_rounded, ZT.rose, onTap: onDelete)),
          const SizedBox(width: 6),
          Expanded(child: _action('执行历史', Icons.history_rounded, ZT.ink, onTap: onHistory)),
        ]),
      ]),
    );
  }

  Widget _chip(String label,
      {required Color fg, required Color bg, required Color border, bool bold = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: ShapeDecoration(
        color: bg,
        shape: StadiumBorder(side: BorderSide(width: 1.1, color: border)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 10.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: fg)),
    );
  }

  Widget _action(String label, IconData icon, Color color,
      {bool onPrimary = false, required Future<void> Function() onTap}) {
    return GestureDetector(
      onTap: busy ? null : () => onTap(),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: ShapeDecoration(
          color: onPrimary ? color : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(width: 1.2, color: onPrimary ? color : ZT.edge),
          ),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon, size: 13, color: onPrimary ? ZT.onInk : color),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w800,
                  color: onPrimary ? ZT.onInk : color)),
        ]),
      ),
    );
  }
}

/// 执行历史弹层:每次触发的时间/结果/备注。
Future<void> showCronHistory(BuildContext context, ZApp app, String cronId) async {
  List<Map<String, dynamic>>? runs;
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: ZT.surface,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
      side: BorderSide(color: ZT.edge),
    ),
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSheetState) {
        runs ??= const [];
        if (runs!.isEmpty) {
          app.cronRuns(cronId).then((r) {
            if (ctx.mounted) setSheetState(() => runs = r);
          });
        }
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.6),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.history_rounded, size: 17, color: ZT.aqua),
                const SizedBox(width: 8),
                Text('执行历史', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: ZT.ink)),
                const Spacer(),
                Text('最近 30 条', style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
              ]),
              const SizedBox(height: 10),
              Flexible(
                child: runs!.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text('还没有执行记录。到点触发或点「立即运行」后会记在这里。',
                            style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6)),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: runs!.length,
                        separatorBuilder: (_, _) => Divider(height: 14, color: ZT.line),
                        itemBuilder: (_, i) {
                          final r = runs![i];
                          final st = '${r['status']}';
                          final (label, color) = switch (st) {
                            'success' => ('成功', ZT.aqua),
                            'skipped' => ('跳过', ZT.lemon),
                            _ => ('失败', ZT.rose),
                          };
                          return Row(children: [
                            Container(width: 7, height: 7, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                            const SizedBox(width: 8),
                            Text(_localTime('${r['started_at']}'),
                                style: TextStyle(fontSize: 12, fontFamily: ZT.mono, color: ZT.ink)),
                            const SizedBox(width: 8),
                            Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: color)),
                            const Spacer(),
                            if ('${r['note'] ?? ''}'.isNotEmpty)
                              Flexible(
                                child: Text('${r['note']}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.right,
                                    style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
                              ),
                          ]);
                        },
                      ),
              ),
            ]),
          ),
        );
      },
    ),
  );
}

String _localTime(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return iso;
  String p(int v) => v.toString().padLeft(2, '0');
  return '${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}:${p(d.second)}';
}

/// 本会话定时任务面板内容(任务中心三 Tab 复用):秒级倒计时 + 开关/运行/重启/删除/历史。
class CronsPanel extends StatefulWidget {
  final ZApp app;
  final String sessionId;

  const CronsPanel({super.key, required this.app, required this.sessionId});

  @override
  State<CronsPanel> createState() => _CronsPanelState();
}

class _CronsPanelState extends State<CronsPanel> {
  List<Map<String, dynamic>>? _data;
  Timer? _tick;
  String? _busyId; // 正在操作的卡片(防连点 + 转圈)

  @override
  void initState() {
    super.initState();
    _load();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final fresh = await widget.app.crons(sessionId: widget.sessionId, includePaused: true);
    if (mounted) setState(() => _data = fresh);
  }

  /// 统一的操作包装:转圈 → 执行 → 提示 → 刷新。
  /// [op] 返回要显示的提示语(删除要区分"已通知/未通知",固定文案说不准)。
  Future<void> _act(String id, Future<String> Function() op) async {
    if (_busyId != null) return;
    setState(() => _busyId = id);
    try {
      final msg = await op();
      if (mounted) showToast(context, msg);
    } on Object catch (e) {
      if (mounted) showToast(context, '操作失败: ${_shortError(e)}');
    } finally {
      if (mounted) setState(() => _busyId = null);
      await _load();
    }
  }

  /// 删除任务:如实区分"已通知会话撤销"与"那边没有进程、任务随之失效"。
  /// Claude Code 的定时任务只活在 CLI 进程里,zcode 删镜像不代表它停了。
  Future<String> _deleteCron(String id) async {
    final notified = await widget.app.deleteCron(id);
    return notified ? '已删除,并已通知该会话撤销' : '已从列表删除(该会话无活跃进程,任务已随之失效)';
  }

  @override
  Widget build(BuildContext context) {
    final list = _data;
    if (list == null) {
      return const Padding(
          padding: EdgeInsets.all(18),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (list.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Text('本会话还没有定时任务。对话里说"每 5 分钟检查一次构建"即可创建。',
            style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6)),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final c = list[i];
        final id = '${c['id']}';
        final paused = '${c['status']}' == 'paused';
        return CronCard(
          c: c,
          busy: _busyId == id,
          onToggle: () => _act(id, () async {
            await widget.app.setCronActive(id, active: paused);
            return paused ? '已恢复' : '已暂停';
          }),
          onRunNow: () => _act(id, () async {
            await widget.app.runCronNow(id);
            return '已触发运行';
          }),
          onRestart: () => _act(id, () async {
            await widget.app.restartCron(id);
            return '已重启,计数清零';
          }),
          onDelete: () => _act(id, () => _deleteCron(id)),
          onHistory: () => showCronHistory(context, widget.app, id),
        );
      },
    );
  }
}

/// 定时任务列表弹层(全局,跨会话)。
class AllCronsSheet extends StatefulWidget {
  final ZApp app;

  const AllCronsSheet({super.key, required this.app});

  @override
  State<AllCronsSheet> createState() => _AllCronsSheetState();
}

class _AllCronsSheetState extends State<AllCronsSheet> {
  late Future<List<Map<String, dynamic>>> _future;
  Timer? _tick;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _future = widget.app.crons(includePaused: true);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _act(String id, Future<String> Function() op) async {
    if (_busyId != null) return;
    setState(() => _busyId = id);
    try {
      final msg = await op();
      if (mounted) showToast(context, msg);
    } on Object catch (e) {
      if (mounted) showToast(context, '操作失败: ${_shortError(e)}');
    } finally {
      if (mounted) setState(() => _busyId = null);
      setState(() => _future = widget.app.crons(includePaused: true));
    }
  }

  Future<String> _deleteCron(String id) async {
    final notified = await widget.app.deleteCron(id);
    return notified ? '已删除,并已通知该会话撤销' : '已从列表删除(该会话无活跃进程,任务已随之失效)';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          sheetHandle(),
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.alarm_rounded, size: 18, color: ZT.lemon),
            const SizedBox(width: 8),
            Text('定时任务 · 全部会话', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900)),
          ]),
          const SizedBox(height: 10),
          Flexible(
            child: FutureBuilder<List<Map<String, dynamic>>>(
              future: _future,
              builder: (ctx, snap) {
                final list = snap.data ?? const <Map<String, dynamic>>[];
                if (snap.connectionState != ConnectionState.done) {
                  return const Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                }
                if (list.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('还没有任何定时任务。在会话里说"每天早上 9 点总结昨日提交"即可创建。',
                        style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6)),
                  );
                }
                return ListView.separated(
                  shrinkWrap: true,
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final id = '${c['id']}';
                    final paused = '${c['status']}' == 'paused';
                    return CronCard(
                      c: c,
                      busy: _busyId == id,
                      sessionLabel: '${c['session_title'] ?? ''}',
                      onToggle: () => _act(id, () async {
                        await widget.app.setCronActive(id, active: paused);
                        return paused ? '已恢复' : '已暂停';
                      }),
                      onRunNow: () => _act(id, () async {
                        await widget.app.runCronNow(id);
                        return '已触发运行';
                      }),
                      onRestart: () => _act(id, () async {
                        await widget.app.restartCron(id);
                        return '已重启,计数清零';
                      }),
                      onDelete: () => _act(id, () => _deleteCron(id)),
                      onHistory: () => showCronHistory(context, widget.app, id),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// 服务端错误文本里常带一长串 JSON,面板提示只留前 40 字。
String _shortError(Object e) {
  final s = '$e';
  return s.length > 40 ? '${s.substring(0, 40)}…' : s;
}
