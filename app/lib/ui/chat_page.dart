// 聊天页:reversed 列表 + 六枚图标快捷条 + 权限面板 + 输入条。
// 布局参考 zremote chat_page(quick chips/选项弹层/计划弹层/SendOrStop),状态走 ZApp。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../panel_utils.dart';
import '../session_utils.dart';
import '../state/reducer.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'chat_panels.dart';
import '../ws.dart';
import 'rows.dart';

class ChatPage extends StatefulWidget {
  final ZApp app;
  final String sessionId;

  const ChatPage({super.key, required this.app, required this.sessionId});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _input = TextEditingController();
  final _pendingImages = ValueNotifier<List<String>>(const []); // data URI 列表
  final ImagePicker _picker = ImagePicker();
  List<PlanStep>? _stickyPlan; // 计划弹层的粘性缓存:工具行被翻篇也不闪没
  bool _cronsOn = false; // 会话里有活跃定时任务时点亮

  Future<void> _pickReference() async {
    final others = app.sessions.where((s) => '${s['id']}' != widget.sessionId).toList();
    if (others.isEmpty) {
      _toastRef('没有其他会话可引用');
      return;
    }
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: ZT.surface,
        title: const Text('引用哪个会话?'),
        children: [
          for (final s in others)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s),
              child: Text('${s['title'] ?? '未命名'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5)),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final fromTitle = '${picked['title'] ?? '会话'}';
    final out = await app.exportSession('${picked['id']}');
    if (!mounted) return;
    if (out == null || out.markdown.trim().isEmpty) {
      _toastRef('「$fromTitle」没有可引用的内容');
      return;
    }
    final msg = buildReferenceMessage(fromTitle: fromTitle, markdown: out.markdown);
    app.sendChat(msg);
    _toastRef('已把「$fromTitle」的上下文发给当前会话');
  }

  void _toastRef(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openSubagents() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SubagentsSheet(
        app: app,
        sessionId: widget.sessionId,
        rows: List<ToolRow>.from(chat.rows.whereType<ToolRow>()),
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openBackgrounds() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => BackgroundsSheet(app: app, sessionId: widget.sessionId),
    );
    if (mounted) setState(() {});
  }

  Future<void> _openCrons() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => _CronsSheet(app: app, sessionId: widget.sessionId),
    );
    if (mounted) setState(() {});
  }

  ZApp get app => widget.app;
  ChatState get chat => app.chat;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    app.openSession(widget.sessionId);
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    _input.dispose();
    _pendingImages.dispose();
    super.dispose();
  }

  void _onApp() {
    if (!mounted) return;
    // 计划粘性缓存:新一轮 TodoWrite 会覆盖
    final derived = derivePlanSteps(chat.rows);
    if (derived != null) _stickyPlan = derived;
    if (chat.rows.isEmpty && derived == null && app.historyLoading) _stickyPlan = null;
    setState(() {});
  }

  // ---------------------------------------------------------------- 会话信息

  Map<String, dynamic>? get _session {
    for (final s in app.sessions) {
      if ('${s['id']}' == widget.sessionId) return s;
    }
    return null;
  }

  String get _title {
    final s = _session;
    final t = s?['title'];
    return t == null || '$t'.isEmpty ? '会话' : '$t';
  }

  String get _model {
    final s = _session;
    final m = s?['model'];
    return m == null || '$m'.isEmpty ? 'default' : '$m';
  }

  String get _mode {
    final s = _session;
    final m = s?['permissionMode'] ?? s?['permission_mode'];
    return m == null || '$m'.isEmpty ? 'default' : '$m';
  }

  String _modeLabel(String mode) => switch (mode) {
        'acceptEdits' => '自动接受编辑',
        'bypassPermissions' => '跳过确认',
        'plan' => '计划模式',
        'dontAsk' => '不问即拒',
        'auto' => '智能判断',
        _ => '每次确认',
      };

  // ---------------------------------------------------------------- 动作

  void _send() {
    final text = _input.text.trim();
    final images = _pendingImages.value;
    if (text.isEmpty && images.isEmpty) return;
    // 显式带上当前 model/权限模式:热切换双保险(服务端本来也会读 DB 最新值)
    final ok = app.sendChat(text, model: _model, permissionMode: _mode, images: images);
    if (!ok) return; // 没发出去:原文留在输入框,改改就能重发,不再凭空消失
    _input.clear();
    _pendingImages.value = const [];
    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus(); // 发完收起键盘,别压着半屏看回复
  }

  /// 相册选图 → 读字节 → base64 data URI(最多 4 张,单张 ≤ 5MB)。
  Future<void> _pickImage() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 2048,
        imageQuality: 85,
      );
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.lengthInBytes > 5 * 1024 * 1024) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('图片超过 5MB,换个小的')));
        }
        return;
      }
      final mime = lookupMimeType(picked.path) ?? 'image/jpeg';
      final uri = 'data:$mime;base64,${base64Encode(bytes)}';
      final next = [..._pendingImages.value, uri];
      if (next.length > 4) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('一次最多 4 张')));
        }
        return;
      }
      _pendingImages.value = next;
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选图失败: $e')));
      }
    }
  }

  /// 二级模型选择:第一级供应商(智谱/深度求索/英伟达…),点进去第二级模型列表。
  Future<void> _pickModel() async {
    final current = _model;
    // 分组数据还没拉到就现拉一次
    if (app.modelGroups.isEmpty) {
      try {
        app.modelGroups = await app.apiGroups();
      } on Object {
        // 拉不到就退回一级平铺
      }
    }
    if (!mounted) return;
    final sheetHeight = MediaQuery.of(context).size.height * 0.7;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(maxHeight: sheetHeight),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: _ModelGroupPicker(
            groups: app.modelGroups,
            current: current,
            onPick: (m) => Navigator.pop(ctx, m),
          ),
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await app.patchSession(widget.sessionId, model: picked);
  }

  Future<void> _pickMode() async {
    const modes = [
      ('default', '每次确认', '敏感操作都先问你'),
      ('acceptEdits', '自动接受编辑', '改文件不问,命令仍要确认'),
      ('plan', '计划模式', '先出计划,批准后再动手'),
      ('dontAsk', '不问即拒', '不再弹审批,没预授权的操作直接拒绝'),
      ('auto', '智能判断', '用模型分类器自动批/拒权限'),
      ('bypassPermissions', '跳过确认', '全部自动放行,慎用'),
    ];
    final current = _mode;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZT.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.shield_rounded, size: 18, color: ZT.lemon),
              SizedBox(width: 8),
              Text('权限模式',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 10),
            for (final (value, label, desc) in modes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _OptionRow(
                  name: value == current ? '$label(当前)' : label,
                  desc: desc,
                  selected: value == current,
                  accent: ZT.lemon,
                  onTap: () => Navigator.pop(ctx, value),
                ),
              ),
          ]),
        ),
      ),
    );
    if (picked == null || picked == current) return;
    await app.patchSession(widget.sessionId, permissionMode: picked);
  }

  /// 计划弹层:AnimatedBuilder 跟着事件流走,粘性缓存防止推导源翻篇闪没。
  Future<void> _openPlanSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => AnimatedBuilder(
        animation: app,
        builder: (ctx, _) {
          final derived = derivePlanSteps(chat.rows);
          if (derived != null) _stickyPlan = derived;
          final steps = derived ?? _stickyPlan;
          return SafeArea(
            child: Container(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.65),
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.account_tree_rounded, size: 18, color: ZT.primary),
                  const SizedBox(width: 8),
                  const Text('执行计划',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  if (steps != null)
                    Text('${steps.where((s) => s.completed).length}/${steps.length}',
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: ZT.primary)),
                ]),
                const SizedBox(height: 12),
                if (steps == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text('还没有计划 —— 让它先用 TodoWrite 列个计划。',
                        style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
                  )
                else
                  Flexible(
                    child: ListView(shrinkWrap: true, children: [
                      for (final step in steps)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            SizedBox(
                              width: 20,
                              child: Icon(
                                step.completed
                                    ? Icons.check_box_rounded
                                    : step.inProgress
                                        ? Icons.indeterminate_check_box_rounded
                                        : Icons.check_box_outline_blank_rounded,
                                size: 16,
                                color: step.completed
                                    ? ZT.primary
                                    : step.inProgress
                                        ? ZT.lemon
                                        : ZT.inkFaint,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                step.content,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.4,
                                  color: step.completed ? ZT.inkFaint : ZT.ink,
                                  decoration: step.completed ? TextDecoration.lineThrough : null,
                                  fontWeight:
                                      step.inProgress ? FontWeight.w700 : FontWeight.w400,
                                ),
                              ),
                            ),
                          ]),
                        ),
                    ]),
                  ),
              ]),
            ),
          );
        },
      ),
    );
  }

  /// 用量面板:最近一轮走 WS 实时状态,累计/上下文快照/构成走 REST 聚合。
  Future<void> _openUsageSheet() async {
    final summaryFuture = app.sessionUsage(widget.sessionId); // 打开时拉一次,不随重建刷
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: AnimatedBuilder(
          animation: app,
          builder: (ctx, _) {
            final u = chat.usage;
            return FutureBuilder<Map<String, dynamic>?>(
              future: summaryFuture,
              builder: (ctx, snap) {
                final agg = snap.data;
                final totals = (agg?['totals'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
                final last = (agg?['last'] as Map?)?.cast<String, dynamic>();
                final composition = (agg?['composition'] as List?) ?? const [];
                final tools = (agg?['tools'] as List?) ?? const [];
                final runs = (agg?['runs'] as num?)?.toInt() ?? 0;
                // 上下文占用:WS 实时优先;没跑过这轮就退回 REST 里最近一次快照
                final liveCtx = u?.contextTokens ?? 0;
                final ctxTokens = liveCtx > 0
                    ? liveCtx
                    : ((last?['contextTokens'] as num?)?.toInt() ?? 0);
                final ctxWindow = (u?.contextWindow ?? 0) > 0
                    ? u!.contextWindow
                    : ((last?['contextWindow'] as num?)?.toInt() ?? 0);
                final hitRate = (u != null && liveCtx > 0) ? u.cacheHitRate : null;
                final totalBytes = composition.fold<int>(
                    0, (s, c) => s + (((c as Map)['bytes'] as num?) ?? 0).toInt());
                return Container(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.of(ctx).size.height * 0.78),
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                  child: SingleChildScrollView(
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                      const Row(children: [
                        Icon(Icons.query_stats_rounded, size: 18, color: ZT.aqua),
                        SizedBox(width: 8),
                        Text('用量',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w900)),
                      ]),
                      const SizedBox(height: 12),
                      // —— 上下文:当前窗口占用 + 缓存命中 ——
                      _usageSection('上下文(最近一轮)', [
                        if (ctxTokens > 0)
                          _usageBar(
                            '窗口占用',
                            ctxWindow > 0
                                ? '${_fmtTokens(ctxTokens)} / ${_fmtTokens(ctxWindow)}'
                                    ' (${(ctxTokens / ctxWindow * 100).toStringAsFixed(1)}%)'
                                : '${_fmtTokens(ctxTokens)} tokens',
                            ctxWindow > 0
                                ? (ctxTokens / ctxWindow).clamp(0.0, 1.0)
                                : null,
                          ),
                        if (hitRate != null)
                          _usageRow('缓存命中率', '${(hitRate * 100).toStringAsFixed(1)}%'),
                        if ((u?.maxOutputTokens ?? 0) > 0)
                          _usageRow('单轮输出上限', _fmtTokens(u!.maxOutputTokens)),
                        if (ctxTokens == 0)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            child: Text('还没有用量数据;发一条消息跑完一轮后这里会有完整统计。',
                                style: TextStyle(
                                    fontSize: 12.5, color: ZT.inkFaint)),
                          ),
                      ]),
                      // —— 最近一轮(WS 实时)——
                      if (u != null)
                        _usageSection('最近一轮', [
                          _usageRow('输入',
                              '${_fmtTokens(u.inputTokens)}(缓存读 ${_fmtTokens(u.cacheReadInputTokens)} / 写 ${_fmtTokens(u.cacheCreationInputTokens)})'),
                          _usageRow('输出', _fmtTokens(u.outputTokens)),
                          if (u.numTurns > 0) _usageRow('轮次', '${u.numTurns}'),
                          _usageRow('耗时', u.durationMs >= 1000
                              ? '${(u.durationMs / 1000).toStringAsFixed(1)} s'
                              : '${u.durationMs} ms'),
                          _usageRow('费用', '\$${u.totalCostUsd.toStringAsFixed(4)}'),
                        ]),
                      // —— 累计(REST 聚合)——
                      if (runs > 0)
                        _usageSection('累计($runs 轮)', [
                          _usageRow('输入合计',
                              '${_fmtTokens((totals['inputTokens'] as num?)?.toInt() ?? 0)}(缓存读 ${_fmtTokens((totals['cacheReadInputTokens'] as num?)?.toInt() ?? 0)})'),
                          _usageRow('输出合计',
                              _fmtTokens((totals['outputTokens'] as num?)?.toInt() ?? 0)),
                          _usageRow('费用合计',
                              '\$${((totals['costUsd'] as num?) ?? 0).toStringAsFixed(4)}'),
                          if (((totals['durationMs'] as num?)?.toInt() ?? 0) > 0)
                            _usageRow('耗时合计',
                                '${((totals['durationMs'] as num?)!.toInt() / 1000).toStringAsFixed(0)} s'),
                        ]),
                      // —— 构成:哪类消息占了多少(按字符量估算)——
                      if (composition.isNotEmpty)
                        _usageSection('消息构成(按字符量估算)', [
                          for (final c in composition)
                            if (c is Map)
                              _usageBar(
                                '${_kindLabel['${c['kind']}'] ?? c['kind']} ×${c['count']}',
                                totalBytes > 0
                                    ? '${((((c['bytes'] as num?) ?? 0).toInt()) / totalBytes * 100).toStringAsFixed(1)}%'
                                    : '0%',
                                totalBytes > 0
                                    ? ((((c['bytes'] as num?) ?? 0).toInt()) / totalBytes)
                                        .clamp(0.0, 1.0)
                                    : null,
                              ),
                          if (tools.isNotEmpty)
                            _usageRow(
                                '工具',
                                tools
                                    .map((t) =>
                                        '${t['toolName']}×${t['count']}')
                                    .join(' · ')),
                        ]),
                    ]),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  static const Map<String, String> _kindLabel = {
    'user': '用户消息',
    'text': '回复文本',
    'thinking': '思考',
    'tool_use': '工具调用',
    'tool_result': '工具结果',
    'error': '错误',
  };

  String _fmtTokens(int n) =>
      n >= 10000 ? '${(n / 1000).toStringAsFixed(n >= 100000 ? 0 : 1)}k' : '$n';

  Widget _usageSection(String title, List<Widget> rows) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
        Text(title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        ...rows,
      ]),
    );
  }

  /// 带占比条的行(上下文占用、构成比例)。
  Widget _usageBar(String label, String value, double? fraction) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(label, style: const TextStyle(fontSize: 12, color: ZT.inkFaint)),
          const Spacer(),
          Text(value,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w800, color: ZT.aqua)),
        ]),
        if (fraction != null) ...[
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 4,
              backgroundColor: ZT.edge,
              valueColor: AlwaysStoppedAnimation(
                  fraction > 0.85 ? ZT.rose : ZT.aqua),
            ),
          ),
        ],
      ]),
    );
  }

  Widget _usageRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label, style: const TextStyle(fontSize: 12, color: ZT.inkFaint)),
        const Spacer(),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w800, color: ZT.aqua)),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    // 面板活跃态一次算好:右上角下拉与快捷条共用。
    final planOn = _stickyPlan != null || derivePlanSteps(chat.rows) != null;
    final subsOn = deriveSubagents(chat.rows).isNotEmpty;
    final bgOn = deriveBackgrounds(chat.rows).isNotEmpty;
    app.crons(sessionId: widget.sessionId).then((list) {
      if (mounted && _cronsOn != list.isNotEmpty) setState(() => _cronsOn = list.isNotEmpty);
    });
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: Row(children: [
          Expanded(
            child: Text(_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(width: 8),
          StatusChip(phase: _phase(), compact: true),
        ]),
        actions: [
          _PanelsMenu(
            cronsOn: _cronsOn,
            subsOn: subsOn,
            bgOn: bgOn,
            onOpen: _openPanel,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (app.socket.state == ZSocketState.reconnecting) _reconnectStrip(),
          if (app.error != null) _errorStrip(),
          const Divider(height: 1),
          Expanded(child: _list()),
          if (chat.pendingPermission != null)
            _PermissionCard(
              req: chat.pendingPermission!,
              onAnswer: (allow, message, updatedInput, [rememberTool = false]) {
                HapticFeedback.lightImpact();
                app.answerPermission(
                  chat.pendingPermission!.requestId,
                  allow: allow,
                  message: message,
                  updatedInput: updatedInput,
                  rememberTool: rememberTool,
                );
              },
            ),
          _composer(),
          _quickBar(planOn),
        ]),
      ),
    );
  }

  String _phase() {
    if (chat.pendingPermission != null) return 'permission';
    if (chat.running) return 'running';
    return 'idle';
  }

  Widget _reconnectStrip() {
    return Material(
      color: ZT.lemon,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(children: [
          const PulseDot(color: ZT.rose, animate: true, size: 7),
          const SizedBox(width: 8),
          Text('连接不稳(${app.linkFailure ?? '重连中'})……事件会自动补齐',
              style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.onInk)),
        ]),
      ),
    );
  }

  Widget _errorStrip() {
    return Material(
      color: ZT.rose.withValues(alpha: 0.16),
      child: InkWell(
        onTap: app.clearError,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          child: Row(children: [
            const Icon(Icons.error_outline_rounded, size: 14, color: ZT.rose),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${app.error}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.rose)),
            ),
            const Icon(Icons.close_rounded, size: 14, color: ZT.rose),
          ]),
        ),
      ),
    );
  }

  /// 当前模型的展示名:分组里的 label 优先,没有就退回 id。
  String _modelLabel() {
    final id = _model;
    if (id == 'default') return '默认模型';
    for (final g in app.modelGroups) {
      for (final m in (g['models'] as List? ?? const [])) {
        if (m is Map && '${m['id']}' == id) return '${m['label'] ?? id}';
      }
    }
    return id;
  }

  /// 「更多」下拉的四个面板入口共用一条分发通道。
  void _openPanel(String which) {
    switch (which) {
      case 'crons':
        _openCrons();
      case 'subs':
        _openSubagents();
      case 'bg':
        _openBackgrounds();
      case 'ref':
        _pickReference();
    }
  }

  /// 底部快捷条:模型 + 安全/思考/计划/刷新 共 5 个等宽磁贴。
  /// 定时任务/子代理/后台/引用收进右上角「更多」下拉(_PanelsMenu),给磁贴留位。
  /// 模型贴直显当前模型名(超宽省略号,长按 Tooltip 看完整 id);有状态时点亮。
  Widget _quickBar(bool planOn) {
    final tiles = <(IconData, String, String, Color?, bool, VoidCallback)>[
      (Icons.shield_rounded, '安全', '权限模式:${_modeLabel(_mode)}', _mode == 'default' ? null : ZT.lemon, false, _pickMode),
      (Icons.query_stats_rounded, '思考', '用量统计', chat.usage == null ? null : ZT.aqua, false, _openUsageSheet),
      (Icons.account_tree_rounded, '计划', '执行计划', planOn ? ZT.primary : null, false, _openPlanSheet),
      (Icons.refresh_rounded, '刷新', '全量重载:从 CLI 转录补回丢失消息', null, app.historyLoading, () async {
        final merged = await app.fullReload(widget.sessionId);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(switch (merged) {
            > 0 => '完整重载:补回 $merged 条丢失消息',
            == 0 => '已对齐 CLI 转录,没有缺失消息',
            _ => '转录重载失败,已按本地历史重建',
          })));
        }
      }),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 2),
      child: Row(
        children: [
          Expanded(
            child: _QuickTile(
              icon: Icons.bolt_rounded,
              label: _modelLabel(),
              tooltip: '模型:$_model',
              accent: _model == 'default' ? null : ZT.aqua,
              onTap: _pickModel,
            ),
          ),
          for (final (icon, label, tooltip, accent, busy, onTap) in tiles) ...[
            const SizedBox(width: 8),
            Expanded(
              child: _QuickTile(
                icon: icon,
                label: label,
                tooltip: tooltip,
                accent: accent,
                busy: busy,
                onTap: onTap,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// reversed 列表:index 0 = 最新,贴着输入框。
  Widget _list() {
    final rows = chat.rows;
    // itemCount = 1(流式区) + rows + 1(计划面板) + 1(会话头/加载)
    final plan = derivePlanSteps(rows);
    final planIdx = rows.length + 1;
    final headIdx = rows.length + 2;

    return ListView.builder(
      reverse: true,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      itemCount: rows.length + 3,
      itemBuilder: (context, i) {
        if (i == 0) return _streamingArea();
        if (i <= rows.length) return buildChatRow(rows[rows.length - i]);
        if (i == planIdx) {
          return plan == null
              ? const SizedBox.shrink()
              : PlanPanel(steps: plan);
        }
        if (i == headIdx) {
          return app.historyLoading
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: Center(
                      child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: ZT.primary))),
                )
              : _sessionHeader();
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _streamingArea() {
    final thinking = chat.streamingThinking;
    final text = chat.streamingText;
    if ((thinking == null || thinking.isEmpty) && (text == null || text.isEmpty)) {
      // 静默期骨架行:已送达、模型还没开口的那段真空期。只在回合真的在跑时出现——
      // 空闲会话进窗口、回复已完成(turn_complete 后流式区清空)都不得显示,
      // 否则就是"一进来就计时/回完话还在计时"。等审批(卡片已亮)或工具在跑(卡片自带走秒)时不重复喊。
      final quiet = chat.running &&
          chat.pendingPermission == null &&
          chat.rows.whereType<ToolRow>().every((r) => r.result != null);
      return quiet
          ? Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _SilenceHint(model: _modelLabel(), upstreamPhase: chat.upstreamPhase, upstreamAt: chat.upstreamAt))
          : const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text != null && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const PulseDot(color: ZT.primary, animate: true, size: 6),
                const SizedBox(width: 6),
                Text('正在回复',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: ZT.primaryDeep,
                        letterSpacing: 0.5)),
              ]),
              const SizedBox(height: 3),
              SelectableText(text,
                  style: const TextStyle(
                      fontSize: 14, height: 1.5, color: ZT.ink, fontFamily: ZT.mono)),
            ]),
          ),
        if (thinking != null && thinking.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8, right: 24),
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            decoration: BoxDecoration(
              color: ZT.surface,
              borderRadius: BorderRadius.circular(ZT.radius),
              border: Border.all(width: 1.2, color: ZT.grape.withValues(alpha: 0.5)),
            ),
            child: Row(children: [
              const PulseDot(color: ZT.grape, animate: true, size: 6),
              const SizedBox(width: 6),
              const Text('深度思考中',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w800, color: ZT.grape)),
              const Spacer(),
              Flexible(
                child: Text(thinking,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11, color: ZT.inkFaint, fontStyle: FontStyle.italic)),
              ),
            ]),
          ),
      ],
    );
  }

  Widget _sessionHeader() {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: ShapeDecoration(
            color: ZT.bg,
            shape: StadiumBorder(side: ZT.inkSide(w: 1.1, color: ZT.line)),
          ),
          child: Text(
            '${_modelLabel()} · ${_modeLabel(_mode)}',
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: ZT.inkFaint),
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- composer

  /// data URI 预览:统一走 rows.dart 的 chatImageThumb(解 base64 走内存,坏图占位)。

  Widget _composer() {
    return Container(
      decoration: const BoxDecoration(
        color: ZT.bg,
        border: Border(top: BorderSide(width: 1.2, color: ZT.edge)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 已选图片预览条
        ValueListenableBuilder<List<String>>(
          valueListenable: _pendingImages,
          builder: (context, images, _) {
            if (images.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 64,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(ZT.radius),
                      child: chatImageThumb(images[i]),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: GestureDetector(
                        onTap: () {
                          final next = [...images]..removeAt(i);
                          _pendingImages.value = next;
                        },
                        child: Container(
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: ZT.ink.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded, size: 12, color: Colors.white),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            );
          },
        ),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          // 添加图片按钮
          IconButton(
            tooltip: '添加图片',
            onPressed: _pickImage,
            icon: const Icon(Icons.image_outlined, size: 22, color: ZT.inkSoft),
          ),
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: const TextStyle(fontSize: 14, fontFamily: ZT.mono, color: ZT.ink),
              decoration: const InputDecoration(
                hintText: '让它干活…',
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 逐字刷新:不依赖页面重建
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (context, value, _) => _SendOrStop(
              canStop: chat.running,
              hasText: value.text.trim().isNotEmpty || _pendingImages.value.isNotEmpty,
              onSend: _send,
              onStop: () {
                HapticFeedback.mediumImpact();
                app.abort();
              },
            ),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- widgets

/// 二级模型选择器:一级供应商列表,点供应商展开该组的模型列表。
class _ModelGroupPicker extends StatefulWidget {
  final List<Map<String, dynamic>> groups;
  final String current;
  final void Function(String modelId) onPick;

  const _ModelGroupPicker({
    required this.groups,
    required this.current,
    required this.onPick,
  });

  @override
  State<_ModelGroupPicker> createState() => _ModelGroupPickerState();
}

class _ModelGroupPickerState extends State<_ModelGroupPicker> {
  Map<String, dynamic>? _openGroup; // null = 显示一级供应商列表

  @override
  Widget build(BuildContext context) {
    if (_openGroup != null) return _level2(_openGroup!);
    return _level1();
  }

  Widget _header(String title, {VoidCallback? onBack}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        if (onBack != null)
          GestureDetector(
            onTap: onBack,
            child: const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.arrow_back_rounded, size: 20, color: ZT.inkSoft),
            ),
          ),
        const Icon(Icons.dns_rounded, size: 18, color: ZT.primary),
        const SizedBox(width: 8),
        Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
      ]),
    );
  }

  /// 一级:供应商(Claude 默认 / 智谱 GLM / 深度求索 / 英伟达…)。
  Widget _level1() {
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      _header('选择供应商'),
      Flexible(
        child: widget.groups.isEmpty
            ? Padding(
                padding: const EdgeInsets.symmetric(vertical: 18),
                child: Text('模型列表为空(后端 /api/models/grouped 没拉到)',
                    style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
              )
            : ListView(shrinkWrap: true, children: [
                for (final g in widget.groups)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _GroupRow(
                      group: g,
                      containsCurrent: _groupHasCurrent(g),
                      onTap: () => setState(() => _openGroup = g),
                    ),
                  ),
              ]),
      ),
    ]);
  }

  /// 二级:该供应商下的模型。
  Widget _level2(Map<String, dynamic> g) {
    final models = (g['models'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      _header('${g['label'] ?? g['id']}', onBack: () => setState(() => _openGroup = null)),
      Flexible(
        child: ListView(shrinkWrap: true, children: [
          for (final m in models)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _OptionRow(
                name: '${m['label'] ?? m['id']}',
                selected: '${m['id']}' == widget.current,
                accent: ZT.primary,
                onTap: () => widget.onPick('${m['id']}'),
              ),
            ),
        ]),
      ),
    ]);
  }

  bool _groupHasCurrent(Map<String, dynamic> g) {
    final models = (g['models'] as List? ?? const []).whereType<Map>();
    return models.any((m) => '${m['id']}' == widget.current);
  }
}

/// 一级供应商行:组名 + 模型数 + 右箭头;当前模型在该组时高亮。
class _GroupRow extends StatelessWidget {
  final Map<String, dynamic> group;
  final bool containsCurrent;
  final VoidCallback onTap;

  const _GroupRow({required this.group, required this.containsCurrent, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final count = (group['models'] as List? ?? const []).length;
    final accent = containsCurrent ? ZT.primary : ZT.ink;
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: containsCurrent ? ZT.primary.withValues(alpha: 0.08) : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(w: containsCurrent ? 1.5 : 1.2, color: containsCurrent ? ZT.primary : ZT.edge),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            child: Row(children: [
              Expanded(
                child: Text('${group['label'] ?? group['id']}',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: accent)),
              ),
              Text('$count 个模型',
                  style: TextStyle(fontSize: 11, color: ZT.inkFaint)),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right_rounded, size: 18, color: ZT.inkFaint),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 底部快捷磁贴:图标在上、短标签在下,外层 Expanded 等宽(按用户排版稿)。
/// 长标签放进 Tooltip(如「权限模式:每次确认」),贴面上只留两字短词。
/// 右上角「更多」下拉:定时任务/子代理/后台/引用 四个面板入口。
/// 快捷条只留高频磁贴,低频面板收进来;有活动的面板在菜单里点亮主题色,
/// 触发按钮上随之亮一颗小圆点,状态不因收纳而消失。
class _PanelsMenu extends StatelessWidget {
  final bool cronsOn;
  final bool subsOn;
  final bool bgOn;
  final void Function(String which) onOpen;

  const _PanelsMenu({
    required this.cronsOn,
    required this.subsOn,
    required this.bgOn,
    required this.onOpen,
  });

  PopupMenuItem<String> _item(String value, IconData icon, String label, Color? accent) {
    final c = accent ?? ZT.inkSoft;
    return PopupMenuItem<String>(
      value: value,
      child: Row(children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: accent ?? ZT.ink)),
        ),
        if (accent != null) PulseDot(color: accent, animate: true, size: 6),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final anyOn = cronsOn || subsOn || bgOn;
    return PopupMenuButton<String>(
      tooltip: '定时 / 子代理 / 后台 / 引用',
      color: ZT.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius), side: ZT.inkSide()),
      onSelected: onOpen,
      itemBuilder: (ctx) => [
        _item('crons', Icons.alarm_rounded, '定时任务', cronsOn ? ZT.lemon : null),
        _item('subs', Icons.hub_rounded, '子代理', subsOn ? ZT.grape : null),
        _item('bg', Icons.memory_rounded, '后台任务', bgOn ? ZT.aqua : null),
        _item('ref', Icons.link_rounded, '引用会话', null),
      ],
      child: Container(
        margin: const EdgeInsets.only(right: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: ShapeDecoration(
          color: ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: ZT.inkSide(w: 1.2),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (anyOn) ...[
            Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: ZT.primary, shape: BoxShape.circle)),
            const SizedBox(width: 5),
          ],
          const Text('更多',
              style: TextStyle(
                  fontSize: 12.5, fontWeight: FontWeight.w700, color: ZT.inkSoft)),
          const SizedBox(width: 4),
          const Icon(Icons.expand_more_rounded, size: 15, color: ZT.inkSoft),
        ]),
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String tooltip;
  final Color? accent;

  /// true = 用小转圈代替图标(如刷新历史拉取中)。
  final bool busy;
  final VoidCallback onTap;

  const _QuickTile({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.accent,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = accent ?? ZT.inkSoft;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          height: 54,
          decoration: ShapeDecoration(
            color: ZT.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZT.radius),
              side: ZT.inkSide(w: 1.2),
            ),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(ZT.radius),
            onTap: onTap,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: c),
                      )
                    : Icon(icon, size: 20, color: c),
                const SizedBox(height: 3),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: c,
                        fontFamily: ZT.mono),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 选项行:整行等宽,选中打勾。
class _OptionRow extends StatelessWidget {
  final String name;
  final String? desc;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  const _OptionRow({
    required this.name,
    this.desc,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Ink(
        decoration: ShapeDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : ZT.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(w: selected ? 1.5 : 1.2, color: selected ? accent : ZT.edge),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          fontFamily: ZT.mono,
                          color: selected ? accent : ZT.ink)),
                  if (desc != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(desc!,
                          style: const TextStyle(
                              fontSize: 11, color: ZT.inkFaint)),
                    ),
                ]),
              ),
              if (selected) Icon(Icons.check_rounded, size: 16, color: accent),
            ]),
          ),
        ),
      ),
    );
  }
}

/// 权限请求卡:显示工具与输入,允许/拒绝(可附留言);非交互工具另给「本会话总是允许」。
// AskUserQuestion 走结构化渲染:问题 + 选项 chips,选中后整包回传 updatedInput。
class _PermissionCard extends StatefulWidget {
  final PermissionReq req;

  /// rememberTool = 用户勾了「本会话总是允许」:server 端记名,同工具后续免弹。
  final void Function(bool allow, String message, Map<String, dynamic>? updatedInput, [bool rememberTool]) onAnswer;

  const _PermissionCard({required this.req, required this.onAnswer});

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  final _message = TextEditingController();
  String? _pretty;
  // AskUserQuestion 的选择:问题文本 → 已选 option label 集合
  final _picked = <String, Set<String>>{};

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  String get _prettyInput {
    if (_pretty != null) return _pretty!;
    try {
      _pretty = widget.req.input.isEmpty
          ? ''
          : const JsonEncoder.withIndent('  ').convert(widget.req.input);
    } on Object {
      _pretty = '${widget.req.input}';
    }
    return _pretty!;
  }

  // ------------------------------------------------------ AskUserQuestion

  bool get _isAsk => widget.req.toolName == 'AskUserQuestion';

  List<Map<String, dynamic>> get _questions {
    if (!_isAsk) return const [];
    final qs = widget.req.input['questions'];
    if (qs is! List) return const [];
    return [for (final q in qs) if (q is Map) q.cast<String, dynamic>()];
  }

  bool get _askReady {
    if (_questions.isEmpty) return false;
    for (final q in _questions) {
      final picked = _picked['${q['question'] ?? ''}'];
      if (picked == null || picked.isEmpty) return false;
    }
    return true;
  }

  /// 应答载荷:原 input + answers(问题 → 逗号连接的选项;多选也这么回)。
  Map<String, dynamic> get _askAnswers {
    final answers = <String, dynamic>{};
    for (final q in _questions) {
      final question = '${q['question'] ?? ''}';
      answers[question] = (_picked[question] ?? const <String>{}).join(', ');
    }
    return {...widget.req.input, 'answers': answers};
  }

  List<Widget> _questionWidgets(Map<String, dynamic> q) {
    final question = '${q['question'] ?? ''}';
    final options = (q['options'] as List?) ?? const [];
    final multi = q['multiSelect'] == true;
    final picked = _picked.putIfAbsent(question, () => <String>{});
    return [
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Text(question, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final o in options)
              if (o is Map)
                FilterChip(
                  label: Text('${o['label'] ?? ''}', style: const TextStyle(fontSize: 12)),
                  tooltip: '${o['description'] ?? ''}',
                  selected: picked.contains('${o['label'] ?? ''}'),
                  onSelected: (sel) => setState(() {
                    if (multi) {
                      sel ? picked.add('${o['label'] ?? ''}') : picked.remove('${o['label'] ?? ''}');
                    } else {
                      picked
                        ..clear()
                        ..add('${o['label'] ?? ''}');
                    }
                  }),
                ),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final questions = _questions;
    return Container(
      decoration: const BoxDecoration(
        color: ZT.surface,
        border: Border(top: BorderSide(width: 1.4, color: ZT.lemon)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          const Icon(Icons.verified_user_rounded, size: 15, color: ZT.lemon),
          const SizedBox(width: 7),
          Expanded(
            child: Text('权限请求 · ${widget.req.toolName}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          ),
        ]),
        if (_isAsk && questions.isNotEmpty)
          for (final q in questions) ..._questionWidgets(q)
        else ...[
          if (_prettyInput.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 130),
                child: SingleChildScrollView(
                  child: SelectableText(_prettyInput,
                      style: const TextStyle(
                          fontSize: 11.5, height: 1.45, fontFamily: ZT.mono, color: ZT.inkSoft)),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              controller: _message,
              style: const TextStyle(fontSize: 12.5),
              decoration: const InputDecoration(
                  isDense: true, hintText: '给它的留言(可空)'),
            ),
          ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Row(children: [
            Expanded(
              child: BigButton(
                label: '拒绝',
                color: ZT.rose,
                textColor: Colors.white,
                onPressed: () => widget.onAnswer(false, _message.text.trim(), null),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _isAsk && questions.isNotEmpty
                  ? BigButton(
                      label: _askReady ? '提交回答' : '请先选择',
                      onPressed: _askReady ? () => widget.onAnswer(true, '', _askAnswers) : null,
                    )
                  : BigButton(
                      label: '允许',
                      onPressed: () => widget.onAnswer(true, _message.text.trim(), null),
                    ),
            ),
          ]),
        ),
        // 审批疲劳的解法:连续干活时同一工具不用一遍遍点。Ask 卡不适用(每次问题不同)。
        if (!_isAsk)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: ZT.lemon,
                  padding: const EdgeInsets.symmetric(vertical: 2),
                ),
                onPressed: () => widget.onAnswer(true, _message.text.trim(), null, true),
                child: Text('本会话总是允许 ${widget.req.toolName}',
                    style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
      ]),
    );
  }
}

/// 静默期骨架行:已送达、模型还没开口。优先用上游中转代理的真实相位
/// ("已转发上游 · 等首包"),没有(非中转模型/旧 server)退回「正在思考」本地猜;
/// 秒数在跳就不像死机;超 5s/15s 分级解释。迟迟无首包不用客户端瞎猜——服务端
/// 看门狗会中断回合并落一条错误,错误行出现瞬间 running 变 false,本行自然消失。
class _SilenceHint extends StatefulWidget {
  final String model;
  final String? upstreamPhase; // 'request'/'first_byte'/null
  final DateTime? upstreamAt; // 相位事件的本地到达时刻
  const _SilenceHint({required this.model, this.upstreamPhase, this.upstreamAt});

  @override
  State<_SilenceHint> createState() => _SilenceHintState();
}

class _SilenceHintState extends State<_SilenceHint> {
  late final _start = DateTime.now();
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final sec = now.difference(_start).inSeconds;
    final phase = widget.upstreamPhase;
    // 有真实相位就从事件到达时刻起秒,没有就从骨架行挂上时刻起秒
    final anchor = widget.upstreamAt ?? _start;
    final phaseSec = now.difference(anchor).inSeconds.clamp(0, 999);
    final String label;
    if (phase == 'request') {
      label = '${widget.model} 已转发上游 · 等首包 ${phaseSec}s';
    } else if (phase == 'first_byte') {
      label = '${widget.model} 上游已回包 · 等首个字 ${phaseSec}s';
    } else {
      label = '${widget.model} 正在思考 ${sec}s';
    }
    // 等得越久,话说得越多:5s 提示可能慢,15s 明说上游没回音、兜底是什么。
    final long = (phase == 'request' ? phaseSec : sec);
    final hint = long >= 15
        ? '· 仍无首包,上游可能拥堵;持续无响应会被自动中断并报错'
        : long >= 5
            ? '· 冷启动或慢路由会慢一些'
            : '';
    return Row(children: [
      const PulseDot(color: ZT.primary, animate: true, size: 6),
      const SizedBox(width: 6),
      Expanded(
        child: Text('$label $hint',
            style: const TextStyle(fontSize: 11, color: ZT.inkSoft, fontFamily: ZT.sans)),
      ),
    ]);
  }
}

/// 发送 / 停止按钮:按下沉进辉光里,松手弹回。
class _SendOrStop extends StatefulWidget {
  final bool canStop;
  final bool hasText;
  final VoidCallback onSend;
  final VoidCallback onStop;

  const _SendOrStop({
    required this.canStop,
    required this.hasText,
    required this.onSend,
    required this.onStop,
  });

  @override
  State<_SendOrStop> createState() => _SendOrStopState();
}

class _SendOrStopState extends State<_SendOrStop> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    if (widget.canStop) {
      return GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onStop,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 46,
          height: 46,
          transform: Matrix4.translationValues(
              _pressed ? 2.5 : 0, _pressed ? 2.5 : 0, 0),
          decoration: ShapeDecoration(
            color: ZT.rose,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(ZT.radius),
              side: ZT.inkSide(w: 1.8, color: ZT.rose),
            ),
            shadows: _pressed ? const [] : ZT.hard(dx: 2.5, dy: 2.5, color: ZT.rose.withValues(alpha: 0.5)),
          ),
          child: const Icon(Icons.stop_rounded, color: Colors.white, size: 26),
        ),
      );
    }
    final enabled = widget.hasText;
    return GestureDetector(
      onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: enabled ? widget.onSend : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 90),
        width: 46,
        height: 46,
        transform: Matrix4.translationValues(
            enabled && _pressed ? 2.5 : 0, enabled && _pressed ? 2.5 : 0, 0),
        decoration: ShapeDecoration(
          color: enabled ? ZT.primary : ZT.line,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(ZT.radius),
            side: ZT.inkSide(
                w: 1.8, color: enabled ? ZT.primary : ZT.edge),
          ),
          shadows: enabled && !_pressed ? ZT.hard(dx: 2.5, dy: 2.5) : null,
        ),
        child: Icon(Icons.arrow_upward_rounded,
            color: enabled ? ZT.onInk : ZT.inkFaint, size: 24),
      ),
    );
  }
}


/// 定时任务弹层:本会话的活跃任务 + 到点倒计时(每秒刷新)+ 删除。
class _CronsSheet extends StatefulWidget {
  final ZApp app;
  final String sessionId;

  const _CronsSheet({required this.app, required this.sessionId});

  @override
  State<_CronsSheet> createState() => _CronsSheetState();
}

class _CronsSheetState extends State<_CronsSheet> {
  late Future<List<Map<String, dynamic>>> _future;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _future = widget.app.crons(sessionId: widget.sessionId);
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
    await widget.app.deleteCron(id);
    setState(() => _future = widget.app.crons(sessionId: widget.sessionId));
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
          const Row(children: [
            Icon(Icons.alarm_rounded, size: 18, color: ZT.lemon),
            SizedBox(width: 8),
            Text('定时任务', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900)),
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
                            side: ZT.inkSide(w: 1.2, color: ZT.lemon.withValues(alpha: 0.5))),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text('${c['prompt'] ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: '删除',
                            icon: const Icon(Icons.delete_outline_rounded, size: 17, color: ZT.rose),
                            onPressed: () => _remove('${c['id']}'),
                          ),
                        ]),
                        const SizedBox(height: 4),
                        Row(children: [
                          _pillMono('${c['cron'] ?? ''}'),
                          const SizedBox(width: 8),
                          _pillMono(recurring ? '循环' : '单次'),
                          if ((c['durable'] ?? 0) == 1) const SizedBox(width: 8),
                          if ((c['durable'] ?? 0) == 1) _pillMono('跨重启'),
                        ]),
                        const SizedBox(height: 5),
                        Text('⏰ 下次 $next',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ZT.lemon)),
                        if (expiry != null) ...[
                          const SizedBox(height: 2),
                          Text(expiry, style: const TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
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

  Widget _pillMono(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
            side: BorderSide(width: 1, color: ZT.edge)),
      ),
      child: Text(label, style: const TextStyle(fontSize: 10.5, fontFamily: ZT.mono, color: ZT.inkSoft)),
    );
  }
}
