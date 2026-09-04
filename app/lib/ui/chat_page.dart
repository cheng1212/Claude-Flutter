// 聊天页:reversed 列表 + 六枚图标快捷条 + 权限面板 + 输入条。
// 布局参考 zremote chat_page(quick chips/选项弹层/计划弹层/SendOrStop),状态走 ZApp。
import 'dart:convert';

import 'package:flutter/material.dart';

import '../state/reducer.dart';
import '../state/zapp.dart';
import '../theme.dart';
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
  List<PlanStep>? _stickyPlan; // 计划弹层的粘性缓存:工具行被翻篇也不闪没

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
        _ => '每次确认',
      };

  // ---------------------------------------------------------------- 动作

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    _input.clear();
    app.sendChat(text);
  }

  Future<void> _pickModel() async {
    final current = _model;
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: ZT.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.6),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.dns_rounded, size: 18, color: ZT.primary),
              SizedBox(width: 8),
              Text('模型',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
            ]),
            const SizedBox(height: 10),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final m in ['default', ...app.models.where((m) => m != 'default')])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _OptionRow(
                      name: m,
                      selected: m == current,
                      accent: ZT.primary,
                      onTap: () => Navigator.pop(ctx, m),
                    ),
                  ),
              ]),
            ),
          ]),
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
      ('bypassPermissions', '跳过确认', '全部自动放行,慎用'),
      ('plan', '计划模式', '先出计划,批准后再动手'),
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

  Future<void> _openUsageSheet() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: AnimatedBuilder(
          animation: app,
          builder: (ctx, _) {
            final u = chat.usage;
            return Container(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Row(children: [
                  Icon(Icons.query_stats_rounded, size: 18, color: ZT.aqua),
                  SizedBox(width: 8),
                  Text('用量',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                ]),
                const SizedBox(height: 12),
                if (u == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text('这一轮还没产生用量。',
                        style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
                  )
                else ...[
                  _usageRow('输入 tokens', '${u.inputTokens}'),
                  _usageRow('输出 tokens', '${u.outputTokens}'),
                  _usageRow('费用', '\$${u.totalCostUsd.toStringAsFixed(4)}'),
                  _usageRow('耗时', u.durationMs >= 1000
                      ? '${(u.durationMs / 1000).toStringAsFixed(1)} s'
                      : '${u.durationMs} ms'),
                ],
              ]),
            );
          },
        ),
      ),
    );
  }

  Widget _usageRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label, style: const TextStyle(fontSize: 12, color: ZT.inkFaint)),
        const Spacer(),
        Text(value,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w800, color: ZT.aqua)),
      ]),
    );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
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
        actions: const [],
      ),
      body: SafeArea(
        child: Column(children: [
          if (app.socket.state == ZSocketState.reconnecting) _reconnectStrip(),
          if (app.error != null) _errorStrip(),
          _quickBar(),
          const Divider(height: 1),
          Expanded(child: _list()),
          if (chat.pendingPermission != null)
            _PermissionCard(
              req: chat.pendingPermission!,
              onAnswer: (allow, message) => app.answerPermission(
                chat.pendingPermission!.requestId,
                allow: allow,
                message: message,
              ),
            ),
          _composer(),
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

  /// 图标快捷条:等宽均分。有自定状态时点亮。
  Widget _quickBar() {
    final planOn = _stickyPlan != null || derivePlanSteps(chat.rows) != null;
    final chips = <(IconData, String, Color?, VoidCallback)>[
      (Icons.dns_rounded, '模型', _model == 'default' ? null : ZT.aqua, _pickModel),
      (Icons.shield_rounded, '权限模式', _mode == 'default' ? null : ZT.lemon, _pickMode),
      (Icons.account_tree_rounded, '执行计划', planOn ? ZT.primary : null, _openPlanSheet),
      (Icons.query_stats_rounded, '用量', chat.usage == null ? null : ZT.aqua, _openUsageSheet),
      (Icons.refresh_rounded, '刷新历史', null, () => app.openSession(widget.sessionId)),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        children: [
          for (final (icon, tooltip, accent, onTap) in chips)
            Expanded(
              child: Center(
                child: _QuickChip(icon: icon, tooltip: tooltip, accent: accent, onTap: onTap),
              ),
            ),
        ],
      ),
    );
  }

  /// reversed 列表:index 0 = 最新,贴着输入框。
  Widget _list() {
    final rows = chat.rows;
    final tail = <int>{}; // 尾部附加项的 index 集合
    // itemCount = 1(流式区) + rows + 1(计划面板) + 1(会话头/加载)
    final plan = derivePlanSteps(rows);
    final planIdx = rows.length + 1;
    final headIdx = rows.length + 2;
    if (plan != null) tail.add(planIdx);
    tail.add(headIdx);

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
      return const SizedBox.shrink();
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
            '$_model · ${_modeLabel(_mode)}',
            style: const TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: ZT.inkFaint),
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- composer

  Widget _composer() {
    return Container(
      decoration: const BoxDecoration(
        color: ZT.bg,
        border: Border(top: BorderSide(width: 1.2, color: ZT.edge)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
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
            hasText: value.text.trim().isNotEmpty,
            onSend: _send,
            onStop: app.abort,
          ),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------- widgets

/// 底部快捷按钮:纯图标小方块。
class _QuickChip extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? accent;
  final VoidCallback onTap;

  const _QuickChip({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final accent = this.accent ?? ZT.inkSoft;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: Ink(
          width: 34,
          height: 34,
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
            child: Icon(icon, size: 19, color: accent),
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

/// 权限请求卡:显示工具与输入,允许/拒绝(可附留言)。
class _PermissionCard extends StatefulWidget {
  final PermissionReq req;
  final void Function(bool allow, String message) onAnswer;

  const _PermissionCard({required this.req, required this.onAnswer});

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  final _message = TextEditingController();
  String? _pretty;

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

  @override
  Widget build(BuildContext context) {
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
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Row(children: [
            Expanded(
              child: BigButton(
                label: '拒绝',
                color: ZT.rose,
                textColor: Colors.white,
                onPressed: () => widget.onAnswer(false, _message.text.trim()),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: BigButton(
                label: '允许',
                onPressed: () => widget.onAnswer(true, _message.text.trim()),
              ),
            ),
          ]),
        ),
      ]),
    );
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
