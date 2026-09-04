// 会话列表:普通模式点开即聊;管理模式可多选置顶/删除。布局参考任务页的管理模式。
import 'package:flutter/material.dart';

import '../state/zapp.dart';
import '../theme.dart';
import 'chat_page.dart';

class SessionsPage extends StatefulWidget {
  final ZApp app;
  final VoidCallback onLogout;

  const SessionsPage({super.key, required this.app, required this.onLogout});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  bool _manage = false;
  final _picked = <String>{};

  ZApp get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    app.refreshSessions();
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    super.dispose();
  }

  void _onApp() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- actions

  Future<void> _openChat(Map<String, dynamic> session) async {
    final id = '${session['id']}';
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatPage(app: app, sessionId: id),
    ));
    app.refreshSessions();
  }

  Future<void> _newSession() async {
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _NewSessionDialog(app: app),
    );
    if (created == null || !mounted) return;
    final id = '${created['id']}';
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ChatPage(app: app, sessionId: id),
    ));
    app.refreshSessions();
  }

  void _toggleManage() {
    setState(() {
      _manage = !_manage;
      _picked.clear();
    });
  }

  Future<void> _deletePicked() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话?'),
        content: Text('将删除选中的 ${_picked.length} 个会话及历史。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除', style: TextStyle(color: ZT.rose))),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _picked.toList();
    try {
      final r = await app.deleteSessions(ids);
      if (mounted && r.missing.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('已删 ${r.deleted} 个;${r.missing.length} 个此前已删过')));
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('删除失败: $e')));
      }
    }
    setState(() => _picked.clear());
  }

  Future<void> _pinPicked() async {
    final pinned = _isPinned(app.sessions.firstWhere(
      (s) => '${s['id']}' == _picked.first,
      orElse: () => const {},
    ));
    for (final id in _picked) {
      try {
        await app.patchSession(id, isPinned: !pinned);
      } on Object catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('操作失败: $e')));
        }
        break;
      }
    }
    setState(() => _picked.clear());
  }

  Future<void> _rename(Map<String, dynamic> session) async {
    final controller = TextEditingController(text: '${session['title'] ?? ''}');
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定')),
        ],
      ),
    );
    if (title == null || title.isEmpty) return;
    try {
      await app.patchSession('${session['id']}', title: title);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('重命名失败: $e')));
      }
    }
  }

  /// 设置面板:显示当前连接信息;「切换服务器」才走登出。别再一点齿轮就掉登录页。
  Future<void> _openSettings() async {
    final link = app.linked ? '已连接' : (app.linkFailure ?? '连接中…');
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.settings_outlined, size: 18, color: ZT.primary),
              SizedBox(width: 8),
              Text('设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 14),
            _settingsRow('连接状态', link),
            _settingsRow('会话数', '${app.sessions.length}'),
            _settingsRow('模型数', '${app.models.length}'),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: BigButton(
                label: '切换服务器(登出)',
                icon: Icons.swap_horiz_rounded,
                color: ZT.rose,
                textColor: Colors.white,
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onLogout();
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _settingsRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label, style: const TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
        const Spacer(),
        Text(value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZT.ink)),
      ]),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final sessions = app.sessions;
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: Row(children: [
          const Icon(Icons.terminal_rounded, size: 19, color: ZT.primary),
          const SizedBox(width: 8),
          Text(_manage ? '已选 ${_picked.length}' : '会话',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        ]),
        actions: [
          if (_manage)
            TextButton(
                onPressed: _toggleManage, child: const Text('完成'))
          else ...[
            // 手动刷新:除了下拉,给个一眼能看到的按钮;"运行中"徽章数据也靠它和 dirty 广播
            IconButton(
                tooltip: '刷新',
                onPressed: app.refreshSessions,
                icon: const Icon(Icons.refresh_rounded, size: 20)),
            IconButton(
                tooltip: '设置',
                onPressed: _openSettings,
                icon: const Icon(Icons.settings_outlined, size: 20)),
            IconButton(
                tooltip: '管理',
                onPressed: sessions.isEmpty ? null : _toggleManage,
                icon: const Icon(Icons.checklist_rounded, size: 20)),
          ],
        ],
      ),
      floatingActionButton: _manage
          ? null
          : FloatingActionButton(
              backgroundColor: ZT.primary,
              foregroundColor: ZT.onInk,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(ZT.radius),
                side: ZT.inkSide(w: 1.5, color: ZT.ink),
              ),
              onPressed: _newSession,
              child: const Icon(Icons.add_rounded),
            ),
      bottomNavigationBar: _manage && _picked.isNotEmpty
          ? _manageBar()
          : null,
      body: Column(children: [
        if (!app.linked) _linkStrip(),
        Expanded(
          child: RefreshIndicator(
            color: ZT.primary,
            backgroundColor: ZT.surface,
            onRefresh: app.refreshSessions,
            child: sessions.isEmpty
                ? ListView(children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.6,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline_rounded,
                                size: 40, color: ZT.inkFaint),
                            const SizedBox(height: 12),
                            Text(app.linked ? '还没有会话' : '等待连接…',
                                style: TextStyle(
                                    fontSize: 13, color: ZT.inkFaint)),
                          ],
                        ),
                      ),
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final s = sessions[i];
                      return _sessionTile(s);
                    },
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _linkStrip() {
    return Material(
      color: ZT.lemon,
      child: InkWell(
        onTap: () => app.bootstrap(),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(children: [
            const PulseDot(color: ZT.rose, animate: true, size: 7),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '未连接(${app.linkFailure ?? app.error ?? '连接中'})—— 点此重连',
                style: const TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.onInk),
              ),
            ),
            const Icon(Icons.refresh_rounded, size: 16, color: ZT.onInk),
          ]),
        ),
      ),
    );
  }

  Widget _sessionTile(Map<String, dynamic> s) {
    final id = '${s['id']}';
    final title = '${s['title'] ?? '未命名会话'}';
    final model = '${s['model'] ?? ''}';
    final pinned = _isPinned(s);
    final running = s['isRunning'] == true;
    final picked = _picked.contains(id);

    return HardCard(
      color: picked ? ZT.surfaceHi : ZT.surface,
      onTap: () {
        if (_manage) {
          setState(() => picked ? _picked.remove(id) : _picked.add(id));
        } else {
          _openChat(s);
        }
      },
      onLongPress: _manage ? null : _toggleManage,
      child: Row(children: [
        if (_manage)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Icon(
              picked ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              size: 20,
              color: picked ? ZT.primary : ZT.inkFaint,
            ),
          ),
        if (pinned && !_manage)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Icon(Icons.push_pin_rounded, size: 13, color: ZT.lemon),
          ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 14, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Row(children: [
                if (running)
                  Container(
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: ShapeDecoration(
                      color: ZT.primary.withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(2),
                          side: BorderSide(
                              width: 1, color: ZT.primary.withValues(alpha: 0.5))),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const PulseDot(color: ZT.primary, animate: true, size: 5),
                      const SizedBox(width: 4),
                      Text('运行中',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: ZT.primary,
                              fontFamily: ZT.sans)),
                    ]),
                  ),
                if (s['source'] == 'local')
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: ShapeDecoration(
                      color: ZT.lemon.withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(2),
                          side: BorderSide(
                              width: 1, color: ZT.lemon.withValues(alpha: 0.5))),
                    ),
                    child: const Text('本地',
                        style: TextStyle(
                            fontSize: 10, color: ZT.lemon, fontFamily: ZT.sans)),
                  ),
                if (s['source'] == 'local') const SizedBox(width: 8),
                if (model.isNotEmpty && model != 'default') ...[
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: ShapeDecoration(
                      color: ZT.aqua.withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(2),
                          side: BorderSide(
                              width: 1, color: ZT.aqua.withValues(alpha: 0.5))),
                    ),
                    child: Text(model,
                        style: const TextStyle(
                            fontSize: 10, color: ZT.aqua, fontFamily: ZT.mono)),
                  ),
                  const SizedBox(width: 8),
                ],
                Text(_timeLabel(s),
                    style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
              ]),
            ],
          ),
        ),
        if (!_manage)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.more_vert_rounded, size: 18, color: ZT.inkSoft),
            onPressed: () => _sessionMenu(s),
          ),
      ]),
    );
  }

  Future<void> _sessionMenu(Map<String, dynamic> s) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) {
        final pinned = _isPinned(s);
        return SafeArea(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(height: 6),
            for (final (label, icon, color, onTap) in [
              (
                pinned ? '取消置顶' : '置顶',
                Icons.push_pin_rounded,
                ZT.lemon,
                () => app.patchSession('${s['id']}', isPinned: !pinned)
              ),
              ('重命名', Icons.edit_rounded, ZT.aqua, () => _rename(s)),
              (
                '删除',
                Icons.delete_outline_rounded,
                ZT.rose,
                () async {
                  final ok = await showDialog<bool>(
                    context: ctx,
                    builder: (dctx) => AlertDialog(
                      title: const Text('删除会话?'),
                      content: Text("'${s['title'] ?? ''}' 及其历史将被删除。"),
                      actions: [
                        TextButton(
                            onPressed: () => Navigator.pop(dctx, false),
                            child: const Text('取消')),
                        TextButton(
                            onPressed: () => Navigator.pop(dctx, true),
                            child: const Text('删除',
                                style: TextStyle(color: ZT.rose))),
                      ],
                    ),
                  );
                  if (ok == true) await app.deleteSession('${s['id']}');
                },
              ),
            ])
              ListTile(
                leading: Icon(icon, size: 20, color: color),
                title: Text(label,
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: color)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await onTap();
                },
              ),
            const SizedBox(height: 6),
          ]),
        );
      },
    );
  }

  Widget _manageBar() {
    return Container(
      decoration: const BoxDecoration(
        color: ZT.surface,
        border: Border(top: BorderSide(width: 1.4, color: ZT.primary)),
      ),
      padding: EdgeInsets.only(
          left: 14, right: 14, top: 8, bottom: 8 + MediaQuery.of(context).padding.bottom),
      child: Row(children: [
        Expanded(
          child: BigButton(
            label: '置顶/取消',
            icon: Icons.push_pin_rounded,
            color: ZT.lemon,
            onPressed: _picked.isEmpty ? null : _pinPicked,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: BigButton(
            label: '删除',
            icon: Icons.delete_outline_rounded,
            color: ZT.rose,
            textColor: Colors.white,
            onPressed: _picked.isEmpty ? null : _deletePicked,
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- helpers

  bool _isPinned(Map<String, dynamic> s) {
    final v = s['isPinned'] ?? s['is_pinned'];
    return v == true || v == 1;
  }

  String _timeLabel(Map<String, dynamic> s) {
    final raw = '${s['updatedAt'] ?? s['updated_at'] ?? s['createdAt'] ?? s['created_at'] ?? ''}';
    final t = DateTime.tryParse(raw);
    if (t == null) return '';
    final now = DateTime.now();
    final d = now.difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

/// 新建会话弹窗:标题(可空,后端自动) + 模型(可缺省)。
class _NewSessionDialog extends StatefulWidget {
  final ZApp app;

  const _NewSessionDialog({required this.app});

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  final _title = TextEditingController();
  String _model = 'default';

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    try {
      final s = await widget.app.createSession(
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
        model: _model == 'default' ? null : _model,
      );
      if (mounted) Navigator.pop(context, s);
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('创建失败: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = ['default', ...widget.app.models.where((m) => m != 'default')];
    return AlertDialog(
      backgroundColor: ZT.surface,
      title: const Text('新会话'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(
          controller: _title,
          autofocus: true,
          decoration: const InputDecoration(labelText: '标题(可空)'),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _model,
          dropdownColor: ZT.surface,
          decoration: const InputDecoration(labelText: '模型'),
          items: [
            for (final m in models)
              DropdownMenuItem(value: m, child: Text(m, style: const TextStyle(fontSize: 13))),
          ],
          onChanged: (v) => setState(() => _model = v ?? 'default'),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        BigButton(label: '开始', icon: Icons.bolt_rounded, onPressed: _create),
      ],
    );
  }
}
