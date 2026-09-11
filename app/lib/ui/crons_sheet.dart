// 定时任务弹层:全局跨会话(AllCronsSheet)+ 本会话面板内容(CronsPanel,任务中心复用)。
import 'dart:async';

import 'package:flutter/material.dart';

import '../session_utils.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'toast.dart';

/// 本会话定时任务面板内容(任务中心三 Tab 复用):秒级倒计时 + 删除 + 时间详情。
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
    final fresh = await widget.app.crons(sessionId: widget.sessionId);
    if (mounted) setState(() => _data = fresh);
  }

  Future<void> _remove(String id) async {
    try {
      await widget.app.deleteCron(id);
    } on Object catch (e) {
      if (mounted) showToast(context, '删除失败: $e');
      return;
    }
    _load();
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
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Text('本会话还没有定时任务。对话里说"每 5 分钟检查一次构建"即可创建。',
            style: TextStyle(fontSize: 12.5, color: ZT.inkFaint, height: 1.6)),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount: list.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final c = list[i];
        final recurring = (c['recurring'] ?? 1) == 1;
        final next = cronNextLabel(c['next_fire'] == null ? null : '${c['next_fire']}', DateTime.now());
        final expiry = cronExpiryLabel(c['created_at'] == null ? null : '${c['created_at']}', recurring: recurring);
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          decoration: ShapeDecoration(
            color: ZT.bg,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ZT.radius),
                side: ZT.inkSide(w: 1.2, color: ZT.lemon.withValues(alpha: ZT.palette.neoShadow ? 1 : 0.5))),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: Text('${c['prompt'] ?? ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, height: 1.4)),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '删除',
                icon: Icon(Icons.delete_outline_rounded, size: 17, color: ZT.rose),
                onPressed: () => _remove('${c['id']}'),
              ),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 8, runSpacing: 4, children: [
              _pillMono('${c['cron'] ?? ''}'),
              _pillMono(recurring ? '循环' : '单次'),
              if ((c['durable'] ?? 0) == 1) _pillMono('跨重启'),
            ]),
            const SizedBox(height: 5),
            Text('⏰ 下次 $next',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ZT.lemon)),
            if (expiry != null) ...[
              const SizedBox(height: 2),
              Text(expiry, style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
            ],
          ]),
        );
      },
    );
  }

  Widget _pillMono(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(width: 1, color: ZT.edge)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontFamily: ZT.mono, color: ZT.inkSoft)),
    );
  }
}

/// 定时任务列表弹层(全局,跨会话):秒级倒计时 + 删除。
class AllCronsSheet extends StatefulWidget {
  final ZApp app;

  const AllCronsSheet({super.key, required this.app});

  @override
  State<AllCronsSheet> createState() => _AllCronsSheetState();
}

class _AllCronsSheetState extends State<AllCronsSheet> {
  late Future<List<Map<String, dynamic>>> _future;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _future = widget.app.crons();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _remove(String id) async {
    try {
      await widget.app.deleteCron(id);
    } on Object catch (e) {
      if (mounted) showToast(context, '删除失败: $e');
      return;
    }
    setState(() => _future = widget.app.crons());
  }

  Widget _pill(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4), side: BorderSide(width: 1, color: ZT.edge)),
      ),
      child: Text(label, style: TextStyle(fontSize: 10.5, fontFamily: ZT.mono, color: ZT.inkSoft)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          sheetHandle(),
          const SizedBox(height: 10),
          Row(children: [
            Icon(Icons.alarm_rounded, size: 18, color: ZT.lemon),
            SizedBox(width: 8),
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
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, i) {
                    final c = list[i];
                    final recurring = (c['recurring'] ?? 1) == 1;
                    final next = cronNextLabel(c['next_fire'] == null ? null : '${c['next_fire']}', DateTime.now());
                    final expiry = cronExpiryLabel(c['created_at'] == null ? null : '${c['created_at']}', recurring: recurring);
                    return Container(
                      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
                      decoration: ShapeDecoration(
                        color: ZT.bg,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(ZT.radius),
                            side: ZT.inkSide(w: 1.2, color: ZT.lemon.withValues(alpha: ZT.palette.neoShadow ? 1 : 0.5))),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text('${c['session_title'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '删除',
                            icon: Icon(Icons.delete_outline_rounded, size: 17, color: ZT.rose),
                            onPressed: () => _remove('${c['id']}'),
                          ),
                        ]),
                        Text('${c['prompt'] ?? ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: ZT.inkSoft)),
                        const SizedBox(height: 5),
                        Row(children: [
                          _pill('${c['cron'] ?? ''}'),
                          const SizedBox(width: 6),
                          _pill(recurring ? '循环' : '一次性'),
                          if ((c['durable'] ?? 0) == 1) ...[
                            const SizedBox(width: 6),
                            _pill('跨重启'),
                          ],
                        ]),
                        const SizedBox(height: 5),
                        Text('⏰ 下次 $next',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ZT.lemon)),
                        if (expiry != null) ...[
                          const SizedBox(height: 2),
                          Text(expiry, style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
                        ],
                      ]),
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
