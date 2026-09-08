// 会话列表(参考稿重设计):搜索 + 筛选 chips + 富卡片(状态/来源/模型/项目/时间)+ 行内菜单。
// 数据来源:server /api/sessions 增强字段(last_preview/last_status/project/tags/archived)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../session_utils.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'chat_page.dart';
import 'crons_sheet.dart';
import 'toast.dart';

class SessionsPage extends StatefulWidget {
  final ZApp app;
  final VoidCallback onLogout;

  /// 由项目 tab 点入时携带的初始项目过滤(AppShell 以 Key 重挂载生效)。
  final String? initialProject;

  const SessionsPage({super.key, required this.app, required this.onLogout, this.initialProject});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  static const _kSortUpdated = 'updated';
  static const _kSortCreated = 'created';
  static const _kNewProject = '__new__'; // 筛选弹窗「新建项目」按钮的哨兵返回值

  final _search = TextEditingController();
  String _query = '';
  SessionFilter _filter = SessionFilter.all;
  String? _project; // 项目 chip 选中时生效
  String _sort = _kSortUpdated;
  bool _reloadTick = false; // 刷新按钮转圈

  /// session_id → 最早的下次触发时间(ISO):卡片 ⏰ 胶囊数据源,秒级 ticker 刷新。
  Map<String, String> _cronNext = {};
  Timer? _tick;

  ZApp get app => widget.app;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    if (widget.initialProject != null) {
      _project = widget.initialProject;
      _filter = SessionFilter.project;
    }
    app.refreshSessions();
    _loadCrons();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _cronNext.isNotEmpty) setState(() {});
    });
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    _tick?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// 拉全部会话的定时任务,取每个会话最早的 next_fire。
  Future<void> _loadCrons() async {
    final list = await app.crons();
    if (!mounted) return;
    final map = <String, String>{};
    for (final c in list) {
      final sid = '${c['session_id']}';
      final iso = '${c['next_fire'] ?? ''}';
      if (iso.isEmpty) continue;
      final cur = map[sid];
      if (cur == null || iso.compareTo(cur) < 0) map[sid] = iso;
    }
    setState(() => _cronNext = map);
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
    _loadCrons();
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
      _toast('重命名失败: $e');
    }
  }

  Future<void> _moveToProject(Map<String, dynamic> session) async {
    final cwd = await _pickProjectCwd();
    if (cwd == null || cwd.isEmpty) return;
    try {
      await app.patchSession('${session['id']}', cwd: cwd);
      _toast('已移动到项目');
    } on Object catch (e) {
      _toast('移动失败: $e');
    }
  }

  /// 项目选择弹层:总目录下的项目文件夹列表,可现场新建,也可自定义路径。返回 cwd。
  Future<String?> _pickProjectCwd() async {
    final pro = await app.projects();
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => _ProjectPickerDialog(app: app, root: pro.root, names: pro.names),
    );
  }

  Future<void> _editTags(Map<String, dynamic> session) async {
    final current = tagsOf(session);
    final controller = TextEditingController(text: current.join(', '));
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '用逗号分隔,如 Flutter, 重要'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('确定')),
        ],
      ),
    );
    if (raw == null) return;
    final tags = raw.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    try {
      await app.patchSession('${session['id']}', tags: tags);
    } on Object catch (e) {
      _toast('标签保存失败: $e');
    }
  }

  Future<void> _fork(Map<String, dynamic> session) async {
    _toast('正在复制「${session['title']}」…');
    try {
      final copy = await app.forkSession('${session['id']}');
      if (!mounted) return;
      showToast(
        context,
        '已创建副本「${copy['title'] ?? ''}」',
        actionLabel: '打开',
        onAction: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatPage(app: app, sessionId: '${copy['id']}'),
          ));
        },
      );
    } on Object catch (e) {
      _toast('复制失败: $e');
    }
  }

  Future<void> _export(Map<String, dynamic> session) async {
    final id = '${session['id']}';
    final title = '${session['title'] ?? '会话'}';
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: FutureBuilder<({String filename, String markdown})?>(
          future: app.exportSession(id),
          builder: (ctx, snap) {
            final out = snap.data;
            return Container(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Icon(Icons.ios_share_rounded, size: 17, color: ZT.aqua),
                  const SizedBox(width: 8),
                  Expanded(child: Text('导出 · $title', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800))),
                  if (out != null)
                    IconButton(
                      tooltip: '复制全文',
                      icon: const Icon(Icons.content_copy_rounded, size: 17),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: out.markdown));
                        showToast(ctx, '已复制到剪贴板');
                      },
                    ),
                ]),
                const SizedBox(height: 8),
                Flexible(
                  child: out == null
                      ? Text('导出失败,请稍后再试。', style: TextStyle(fontSize: 12.5, color: ZT.inkSoft))
                      : SingleChildScrollView(
                          child: SelectableText(
                            out.markdown,
                            style: TextStyle(fontSize: 11.5, height: 1.5, fontFamily: ZT.mono, color: ZT.inkSoft),
                          ),
                        ),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }

  Future<void> _delete(Map<String, dynamic> session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => zDialog(
        title: '删除会话?',
        icon: Icons.delete_outline_rounded,
        accent: ZT.rose,
        content: Text("'${session['title'] ?? ''}' 及其全部历史将被删除,此操作不可撤销。",
            style: const TextStyle(fontSize: 13, height: 1.5)),
        actions: [
          dialogAction('取消', onPressed: () => Navigator.pop(ctx, false)),
          dialogAction('删除', primary: true, color: ZT.rose, onPressed: () => Navigator.pop(ctx, true)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await app.deleteSession('${session['id']}');
    } on Object catch (e) {
      _toast('删除失败: $e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    showToast(context, msg);
  }

  // ---------------------------------------------------------------- helpers

  List<Map<String, dynamic>> _visibleSessions() {
    final raw = app.sessions;
    final sorted = [...raw];
    sorted.sort((a, b) {
      if (_sort == _kSortCreated) {
        return '${b['created_at'] ?? ''}'.compareTo('${a['created_at'] ?? ''}');
      }
      return '${b['updated_at'] ?? ''}'.compareTo('${a['updated_at'] ?? ''}');
    });
    return filterSessions(sorted, filter: _filter, query: _query, project: _project);
  }

  String _previewOf(Map<String, dynamic> s) {
    final v = s['last_preview'] ?? s['last_message'] ?? '';
    return '$v'.trim();
  }

  String _timeLabel(Map<String, dynamic> s) {
    final raw = '${s['updated_at'] ?? s['created_at'] ?? ''}';
    final t = DateTime.tryParse(raw);
    if (t == null) return '';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final sessions = _visibleSessions();
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        leading: Builder(
          builder: (ctx) => IconButton(
            tooltip: '菜单',
            icon: const Icon(Icons.menu_rounded, size: 22),
            onPressed: () => Scaffold.of(ctx).openDrawer(),
          ),
        ),
        title: Row(children: [
          Icon(Icons.terminal_rounded, size: 20, color: ZT.primary),
          SizedBox(width: 8),
          Text('会话', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
        ]),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: _reloadTick
                ? const SizedBox(width: 17, height: 17, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh_rounded, size: 21),
            onPressed: () async {
              setState(() => _reloadTick = true);
              await app.refreshSessions();
              await _loadCrons();
              if (mounted) setState(() => _reloadTick = false);
            },
          ),
          IconButton(
            tooltip: '设置',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined, size: 20),
          ),
          const SizedBox(width: 4),
        ],
      ),
      drawer: Drawer(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(right: Radius.circular(ZT.radius)),
        ),
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
              child: Row(children: [
                Icon(Icons.menu_rounded, size: 18, color: ZT.primary),
                const SizedBox(width: 8),
                Text('菜单', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: ZT.primary)),
              ]),
            ),
            ListTile(
              leading: Icon(Icons.alarm_rounded, size: 20, color: ZT.lemon),
              title: const Text('定时任务(全部会话)', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              onTap: () {
                Navigator.pop(context);
                showModalBottomSheet(
                  context: context,
                  backgroundColor: ZT.surface,
                  isScrollControlled: true,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
                    side: BorderSide(color: ZT.edge),
                  ),
                  builder: (_) => AllCronsSheet(app: app),
                ).then((_) => _loadCrons());
              },
            ),
            ListTile(
              leading: Icon(Icons.settings_outlined, size: 20, color: ZT.inkSoft),
              title: const Text('设置', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              onTap: () {
                Navigator.pop(context);
                _openSettings();
              },
            ),
          ]),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: ZT.primary,
        foregroundColor: ZT.onInk,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: ZT.inkSide(w: 1.5, color: ZT.ink),
        ),
        onPressed: _newSession,
        child: const Icon(Icons.add_rounded, size: 28),
      ),
      body: Column(children: [
        if (!app.linked) _linkStrip(),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          child: TextField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            decoration: InputDecoration(
              hintText: '搜索会话…',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
            ),
          ),
        ),
        SizedBox(
          height: 46,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            children: [
              _chip('全部', SessionFilter.all),
              _chip('置顶', SessionFilter.pinned),
              _chip('归档', SessionFilter.archived),
              _chip(_project == null ? '项目' : '项目 · $_project', SessionFilter.project),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                tooltip: '排序',
                initialValue: _sort,
                onSelected: (v) => setState(() => _sort = v),
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: _kSortUpdated, child: Text('↓ 最近更新')),
                  PopupMenuItem(value: _kSortCreated, child: Text('↓ 最近创建')),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: ShapeDecoration(
                    color: ZT.surface,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                      side: ZT.inkSide(),
                    ),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.swap_vert_rounded, size: 15, color: ZT.inkSoft),
                    SizedBox(width: 4),
                    Text('排序', style: TextStyle(fontSize: 12.5, color: ZT.inkSoft)),
                  ]),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            color: ZT.primary,
            backgroundColor: ZT.surface,
            onRefresh: app.refreshSessions,
            child: sessions.isEmpty
                ? ListView(children: [
                    SizedBox(
                      height: MediaQuery.of(context).size.height * 0.55,
                      child: Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.chat_bubble_outline_rounded, size: 40, color: ZT.inkFaint),
                          const SizedBox(height: 12),
                          Text(app.linked ? '这里空空如也' : '等待连接…',
                              style: TextStyle(fontSize: 13, color: ZT.inkFaint)),
                        ]),
                      ),
                    ),
                  ])
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 90),
                    itemCount: sessions.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _sessionCard(sessions[i]),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _chip(String label, SessionFilter f) {
    final selected = _filter == f && (f != SessionFilter.project || _project != null);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: () {
          if (f == SessionFilter.project) {
            _pickProject();
            return;
          }
          setState(() {
            _filter = f;
            _project = null;
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
          decoration: ShapeDecoration(
            color: selected ? ZT.primary.withValues(alpha: 0.12) : ZT.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(999),
              side: ZT.inkSide(w: selected ? 1.5 : 1.2, color: selected ? ZT.primary : ZT.edge),
            ),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                  color: selected ? ZT.primary : ZT.inkSoft)),
        ),
      ),
    );
  }

  Future<void> _pickProject() async {
    final projects = <String>{};
    for (final s in app.sessions) {
      final p = '${s['project'] ?? ''}';
      final arch = s['archived'];
      if (p.isNotEmpty && !(arch == 1 || arch == true)) projects.add(p);
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('按项目筛选'),
        backgroundColor: ZT.surface,
        children: [
          if (projects.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
              child: Text('还没有项目,在下面新建一个',
                  style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
            ),
          for (final p in projects.toList()..sort)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p, style: const TextStyle(fontSize: 13.5)),
            ),
          const Divider(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: BigButton(
              label: '＋ 新建项目',
              icon: Icons.create_new_folder_outlined,
              expand: true,
              onPressed: () => Navigator.pop(ctx, _kNewProject),
            ),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (picked == _kNewProject) {
      final name = await _promptNewProjectName();
      if (name == null || !mounted) return;
      try {
        await app.createProject(name);
      } on Object catch (e) {
        if (!mounted) return;
        showToast(context, '新建失败: $e');
        return;
      }
      // 新项目还没有会话,筛选选中它 = 空列表占位,建会话即入列
      setState(() {
        _project = name;
        _filter = SessionFilter.project;
      });
      return;
    }
    setState(() {
      if (picked != null) {
        _project = picked;
        _filter = SessionFilter.project;
      } else {
        _project = null;
        if (_filter == SessionFilter.project) _filter = SessionFilter.all;
      }
    });
  }

  /// 新建项目名输入框;zDialog 统一风格。返回 null = 取消/空名。
  Future<String?> _promptNewProjectName() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => zDialog(
        title: '新建项目',
        icon: Icons.create_new_folder_outlined,
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: '项目名,如 商城后端'),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          dialogAction('取消', onPressed: () => Navigator.pop(ctx)),
          dialogAction('创建', primary: true, onPressed: () => Navigator.pop(ctx, ctrl.text.trim())),
        ],
      ),
    );
    ctrl.dispose();
    return (name == null || name.isEmpty) ? null : name;
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
            PulseDot(color: ZT.rose, animate: true, size: 7),
            const SizedBox(width: 8),
            Expanded(
              child: Text('未连接(${app.linkFailure ?? app.error ?? '连接中'})—— 点此重连',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.onInk)),
            ),
            Icon(Icons.refresh_rounded, size: 16, color: ZT.onInk),
          ]),
        ),
      ),
    );
  }

  Widget _sessionCard(Map<String, dynamic> s) {
    final pinned = (s['is_pinned'] ?? 0) == 1 || s['is_pinned'] == true;
    final badge = statusBadgeOf(s);
    final preview = _previewOf(s);
    final model = '${s['model'] ?? ''}';
    final project = '${s['project'] ?? ''}';
    final tags = tagsOf(s);
    final cronIso = _cronNext['${s['id']}'];
    final subagents = (s['subagentCount'] as num?)?.toInt() ?? 0;

    return HardCard(
      color: ZT.surface,
      onTap: () => _openChat(s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          if (pinned) ...[
            Icon(Icons.push_pin_rounded, size: 13, color: ZT.primary),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text('${s['title'] ?? '未命名会话'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: Icon(Icons.more_vert_rounded, size: 18, color: ZT.inkSoft),
            onPressed: () => _sessionMenu(s),
          ),
        ]),
        if (preview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(preview,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZT.inkSoft)),
          ),
        const SizedBox(height: 7),
        Row(children: [
          if (badge != null) _pill(badge.label, badge.kind),
          const SizedBox(width: 6),
          if (cronIso != null)
            Tooltip(
              message: cronNextLabel(cronIso, DateTime.now()),
              child: _pill('⏰ ${_cronCountdown(cronIso)}', 'cron'),
            ),
          if ('${s['source'] ?? ''}' == 'local') _pill('本地', 'local'),
          if (subagents > 0) _pill('子代理 $subagents', 'subagent'),
          const SizedBox(width: 6),
          if (model.isNotEmpty) _pill(model, 'model'),
          const SizedBox(width: 6),
          if (project.isNotEmpty) _pill(project, 'project'),
          for (final t in tags.take(2)) ...[
            const SizedBox(width: 6),
            _pill(t, 'tag'),
          ],
          const Spacer(),
          Text(_timeLabel(s), style: TextStyle(fontSize: 11, color: ZT.inkFaint)),
        ]),
      ]),
    );
  }

  /// 卡片上的紧凑倒计时;完整「时刻 · 倒计时」放 Tooltip。
  String _cronCountdown(String iso) {
    final t = DateTime.tryParse(iso)?.toLocal();
    if (t == null) return '定时';
    final d = t.difference(DateTime.now());
    return d.isNegative ? '待触发' : formatCountdown(d);
  }

  Widget _pill(String label, String kind) {
    final colors = {
      'running': (ZT.primary, ZT.primary),
      'done': (ZT.aqua, ZT.aqua),
      'paused': (ZT.lemon, ZT.lemon),
      'failed': (ZT.rose, ZT.rose),
      'ended': (ZT.inkSoft, ZT.inkFaint),
      'local': (ZT.lemon, ZT.lemon),
      'cron': (ZT.lemon, ZT.lemon),
      'subagent': (ZT.grape, ZT.grape),
      'model': (ZT.aqua, ZT.aqua),
      'project': (ZT.grape, ZT.grape),
      'tag': (ZT.inkSoft, ZT.inkFaint),
    };
    final c = colors[kind] ?? (ZT.inkSoft, ZT.inkFaint);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: c.$1.withValues(alpha: 0.09),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(width: 1, color: c.$2.withValues(alpha: 0.45))),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 10.5, color: c.$1, fontFamily: kind == 'model' ? ZT.mono : ZT.sans)),
    );
  }

  Future<void> _sessionMenu(Map<String, dynamic> s) {
    final pinned = (s['is_pinned'] ?? 0) == 1 || s['is_pinned'] == true;
    final archived = (s['archived'] ?? 0) == 1 || s['archived'] == true;
    return showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 6),
          for (final item in [
            (Icons.edit_rounded, '重命名', ZT.ink, () => _rename(s)),
            (Icons.push_pin_rounded, pinned ? '取消置顶' : '置顶', ZT.ink, () => app.patchSession('${s['id']}', isPinned: !pinned)),
            (Icons.folder_open_rounded, '移动到项目', ZT.ink, () => _moveToProject(s)),
            (Icons.sell_rounded, '添加标签', ZT.ink, () => _editTags(s)),
            (Icons.copy_rounded, '复制会话', ZT.ink, () => _fork(s)),
            (Icons.ios_share_rounded, '导出', ZT.ink, () => _export(s)),
            (
              archived ? Icons.unarchive_rounded : Icons.archive_rounded,
              archived ? '取消归档' : '归档',
              ZT.ink,
              () => app.patchSession('${s['id']}', archived: !archived)
            ),
            (Icons.delete_outline_rounded, '删除', ZT.rose, () => _delete(s)),
          ])
            ListTile(
              leading: Icon(item.$1, size: 19, color: item.$3),
              title: Text(item.$2, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: item.$3)),
              onTap: () async {
                Navigator.pop(ctx);
                await item.$4();
              },
            ),
          const SizedBox(height: 6),
        ]),
      ),
    );
  }

  /// 设置面板(A4 底部导航「我的」落地前的临时位置):连接状态与登出。
  Future<void> _openSettings() async {
    final link = app.linked ? '已连接' : (app.linkFailure ?? '连接中…');
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: ValueListenableBuilder<ZTheme>(
            valueListenable: ZThemeController.notifier,
            builder: (context, current, _) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.settings_outlined, size: 18, color: ZT.primary),
                SizedBox(width: 8),
                Text('设置', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
              ]),
              const SizedBox(height: 14),
              _themeRow(current, (t) => ZThemeController.set(t)),
              const SizedBox(height: 6),
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
      ),
    );
  }

  /// 主题切换行:两个签名色小卡(各画主题底色+主色描边),点选即换即存。
  Widget _themeRow(ZTheme current, ValueChanged<ZTheme> onPick) {
    Widget swatch(ZTheme t) {
      final p = switch (t) {
        ZTheme.cream => kZCream,
        ZTheme.citrus => kZCitrus,
      };
      return Container(
        width: 20,
        height: 13,
        decoration: ShapeDecoration(
          color: p.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(3.5),
            side: BorderSide(width: 1.4, color: p.primary),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text('主题', style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
        const Spacer(),
        for (final t in ZTheme.values)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () => onPick(t),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: ShapeDecoration(
                  color: t == current ? ZT.primary.withValues(alpha: 0.13) : ZT.surface,
                  shape: StadiumBorder(
                      side: BorderSide(width: 1.2, color: t == current ? ZT.primary : ZT.edge)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  swatch(t),
                  const SizedBox(width: 6),
                  Text(t.label,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: t == current ? ZT.primaryDeep : ZT.inkSoft)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _settingsRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label, style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
        const Spacer(),
        Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: ZT.ink)),
      ]),
    );
  }
}

/// 新建会话弹窗(保留原有交互)。
class _NewSessionDialog extends StatefulWidget {
  final ZApp app;

  const _NewSessionDialog({required this.app});

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  final _title = TextEditingController();
  String _model = 'default';
  String? _cwd; // 选中的项目文件夹;null = 默认(服务器目录)
  String _projectLabel = '默认';

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _pickProject() async {
    final pro = await widget.app.projects();
    if (!mounted) return;
    final cwd = await showDialog<String>(
      context: context,
      builder: (ctx) => _ProjectPickerDialog(app: widget.app, root: pro.root, names: pro.names),
    );
    if (cwd == null || !mounted) return;
    setState(() {
      _cwd = cwd;
      final segs = cwd.split(RegExp(r'[\\/]'));
      _projectLabel = segs.isNotEmpty && segs.last.isNotEmpty ? segs.last : cwd;
    });
  }

  Future<void> _create() async {
    try {
      final s = await widget.app.createSession(
        title: _title.text.trim().isEmpty ? null : _title.text.trim(),
        model: _model == 'default' ? null : _model,
        cwd: _cwd,
      );
      if (mounted) Navigator.pop(context, s);
    } on Object catch (e) {
      if (mounted) showToast(context, '创建失败: $e');
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
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.folder_open_rounded, size: 19, color: ZT.grape),
          title: Text('项目:$_projectLabel', style: const TextStyle(fontSize: 13.5)),
          subtitle: _cwd == null ? null : Text(_cwd!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
          trailing: Icon(Icons.chevron_right_rounded, size: 18, color: ZT.inkSoft),
          onTap: _pickProject,
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        BigButton(label: '开始', icon: Icons.bolt_rounded, onPressed: _create),
      ],
    );
  }
}

/// 项目选择弹层:总目录下的项目文件夹列表 + 现场新建 + 自定义路径。返回 cwd。
class _ProjectPickerDialog extends StatefulWidget {
  final ZApp app;
  final String root;
  final List<String> names;

  const _ProjectPickerDialog({required this.app, required this.root, required this.names});

  @override
  State<_ProjectPickerDialog> createState() => _ProjectPickerDialogState();
}

class _ProjectPickerDialogState extends State<_ProjectPickerDialog> {
  final _name = TextEditingController();
  bool _creating = false;
  bool _custom = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _createNew() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    try {
      final cwd = await widget.app.createProject(n);
      if (mounted) Navigator.pop(context, cwd);
    } on Object catch (e) {
      if (mounted) showToast(context, '新建失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: ZT.surface,
      title: const Text('选择项目文件夹'),
      content: SizedBox(
        width: 320,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (widget.root.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('总目录:${widget.root}\n电脑上在这里建子文件夹,就会出现在下面',
                  style: TextStyle(fontSize: 10.5, color: ZT.inkFaint, height: 1.45)),
            ),
          if (_custom)
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(hintText: r'完整工作目录,如 D:\work\myapp'),
            )
          else if (_creating)
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(hintText: '项目名,如 商城后端'),
            )
          else ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: widget.names.isEmpty
                  ? Padding(
                      padding: EdgeInsets.symmetric(vertical: 14),
                      child: Text('总目录下还没有项目文件夹。点下面「新建项目」创建第一个。',
                          style: TextStyle(fontSize: 11.5, color: ZT.inkFaint, height: 1.5)),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final n in widget.names)
                          ListTile(
                            dense: true,
                            leading: Icon(Icons.folder_rounded, size: 19, color: ZT.lemon),
                            title: Text(n, style: const TextStyle(fontSize: 13.5)),
                            onTap: () => Navigator.pop(context, joinProjectCwd(widget.root, n)),
                          ),
                      ],
                    ),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.create_new_folder_rounded, size: 19, color: ZT.grape),
              title: const Text('新建项目…', style: TextStyle(fontSize: 13.5)),
              onTap: () => setState(() => _creating = true),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.edit_location_alt_outlined, size: 19, color: ZT.inkSoft),
              title: const Text('自定义路径…', style: TextStyle(fontSize: 13.5)),
              onTap: () => setState(() => _custom = true),
            ),
          ],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (_creating || _custom) {
              setState(() {
                _creating = false;
                _custom = false;
              });
            } else {
              Navigator.pop(context);
            }
          },
          child: Text(_creating || _custom ? '返回' : '取消'),
        ),
        if (_creating)
          TextButton(onPressed: _createNew, child: const Text('创建并选择'))
        else if (_custom)
          TextButton(
              onPressed: () => Navigator.pop(context, _name.text.trim()),
              child: const Text('确定')),
      ],
    );
  }
}
