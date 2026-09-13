// 聊天页:reversed 列表 + 六枚图标快捷条 + 权限面板 + 输入条。
// 布局参考 zremote chat_page(quick chips/选项弹层/计划弹层/SendOrStop),状态走 ZApp。
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../debug_log.dart';
import '../panel_utils.dart';
import '../session_utils.dart';
import '../state/reducer.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'tasks_sheet.dart';
import 'toast.dart';
import '../ws.dart';
import 'rows.dart';

/// 单张图片字节上限:超过的整张跳过(data URI 要进 WS 消息体)。
/// 上限推导:server 按 data URI 字符串长度卡 5MB(MAX_IMAGE_URI),base64 膨胀
/// 4/3——5MB 二进制编出来约 6.7MB 字符会被服务端静默剔除。取 3.75MB 二进制
/// 对应恰好 ≤5MB 字符,再留余量取整 3MB。
const int kMaxImageBytes = 3 * 1024 * 1024;

/// isolate 任务: picked 图片路径 → data URI 列表。必须是顶层函数(compute 要求);
/// 读文件+base64 是纯 CPU 活,主线程做会在编码瞬间掉帧。超限单张跳过。
List<String> _encodeImagesJob(List<String> paths) {
  final uris = <String>[];
  for (final path in paths) {
    final bytes = File(path).readAsBytesSync();
    if (bytes.lengthInBytes > kMaxImageBytes) continue;
    final mime = lookupMimeType(path) ?? 'image/jpeg';
    uris.add('data:$mime;base64,${base64Encode(bytes)}');
  }
  return uris;
}

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

  /// 已上传到电脑的附件(路径引用型):显示名 + 电脑上的绝对路径。
  /// 发送时以文本路径随消息告诉 CLI(CLI 在本地可直接读),不走 base64。
  final _pendingFiles = ValueNotifier<List<({String name, String path})>>(const []);
  final ImagePicker _picker = ImagePicker();
  final ScrollController _listCtrl = ScrollController(); // 「回到底部」药丸
  bool _listAway = false; // 视口离开底部(>60px):显示「回到底部」药丸
  bool _dragging = false; // 用户手指拖动中(补偿跳过,防 jumpTo 杀手势)
  bool _compensateQueued = false; // 本帧已排过补偿(同帧多次 notify 只补一次)
  int _animatedUpTo = 0; // 行入场动画水位:已播过入场动画的行数(按行只播一次)
  bool _searching = false; // 聊天内搜索模式(读态:隐藏输入区,结果面板替代消息列表)
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  List<PlanStep>? _stickyPlan; // 计划弹层的粘性缓存:工具行被翻篇也不闪没
  bool _cronsOn = false; // 会话里有活跃定时任务时点亮
  bool _stopping = false; // 已点停止、在等 CLI 落定的窗口期(乐观反馈)
  String? _thinking; // 思考等级:low/medium/high/off;null = 模型默认(on)
  bool _queueExpanded = false; // 排队面板折叠/展开(折叠只显示第一条)
  int _totalTokens = 0; // 当前会话累计消耗 Token(输入+输出+缓存读写),AppBar 显示
  bool _prevRunning = false; // 上一帧 running:回落瞬间刷新 Token 总量

  /// 任务中心:子代理 / 后台 / 定时 三 Tab(底部「任务」磁贴呼出)。
  Future<void> _openTasks() async {
    await showModalBottomSheet(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => TasksSheet(
        app: app,
        sessionId: widget.sessionId,
        rows: List<ToolRow>.from(chat.rows.whereType<ToolRow>()),
      ),
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
    // 定时任务徽标进页面拉一次即可;放 build 里会随每帧重绘反复打接口
    app.crons(sessionId: widget.sessionId).then((list) {
      if (mounted && _cronsOn != list.isNotEmpty) setState(() => _cronsOn = list.isNotEmpty);
    });
    _loadTotalTokens();
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    _input.dispose();
    _pendingImages.dispose();
    _pendingFiles.dispose();
    _listCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onApp() {
    if (!mounted) return;
    // 计划粘性缓存:新一轮 TodoWrite 会覆盖
    final derived = derivePlanSteps(chat.rows);
    if (derived != null) _stickyPlan = derived;
    if (chat.rows.isEmpty && derived == null && app.historyLoading) _stickyPlan = null;
    final wasRunning = _prevRunning;
    _prevRunning = chat.running;
    if (wasRunning && !chat.running) _loadTotalTokens(); // 一轮落定,累计 Token 变了
    _queueScrollCompensation();
    setState(() {});
  }

  /// AppBar 的会话累计 Token(输入+输出+缓存读写);拉不到保持 0 不显示。
  Future<void> _loadTotalTokens() async {
    final u = await app.sessionUsage(widget.sessionId);
    if (!mounted) return;
    final totals = u?['totals'];
    var n = 0;
    if (totals is Map) {
      n = (totals['inputTokens'] as num? ?? 0).toInt() +
          (totals['outputTokens'] as num? ?? 0).toInt() +
          (totals['cacheReadInputTokens'] as num? ?? 0).toInt() +
          (totals['cacheCreationInputTokens'] as num? ?? 0).toInt();
    }
    setState(() => _totalTokens = n);
  }

  /// 滚离底部看历史期间的一次性锁位:回合进行中每帧新增内容(行追加/面板变化)
  /// 会把正在读的内容挪走。帧末量 maxScrollExtent 差值(reverse 列表 = 底部侧新增量),
  /// 只在「离开底部 + 非拖动 + 回合在跑」时补偿;一帧只排一次,不搞逐帧循环。
  void _queueScrollCompensation() {
    if (_compensateQueued || !_listAway || _dragging || !chat.running) return;
    if (!_listCtrl.hasClients) return;
    final before = _listCtrl.position.maxScrollExtent;
    _compensateQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _compensateQueued = false;
      if (!mounted || !_listCtrl.hasClients || !_listAway || _dragging) return;
      final pos = _listCtrl.position;
      final delta = pos.maxScrollExtent - before;
      // 只补增长(内容往下加);缩小(面板收起)让视口自然扩大,不回拉
      if (delta <= 1 || pos.userScrollDirection != ScrollDirection.idle) return;
      ZLog.i('scroll', 'comp +${delta.toStringAsFixed(0)}px off=${pos.pixels.toStringAsFixed(0)}');
      _listCtrl.jumpTo(math.min(pos.pixels + delta, pos.maxScrollExtent));
    });
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
    var text = _input.text.trim();
    final images = _pendingImages.value;
    final files = _pendingFiles.value;
    if (text.isEmpty && images.isEmpty && files.isEmpty) return;
    // 文件路径引用:CLI 在电脑本地,直接告诉它文件在哪即可读/处理
    if (files.isNotEmpty) {
      final refs = files.map((f) => '- ${f.name} → ${f.path}').join('\n');
      text = text.isEmpty
          ? '我上传了附件,路径如下:\n$refs\n请处理'
          : '$text\n\n附件:\n$refs';
    }
    if (chat.running) {
      _showRunConflictDialog(text, images); // 正在回复:排队 / 打断立即发送
      return;
    }
    _consumeComposer(() {
      _stopping = false; // 新回合开跑,停止盲区状态作废
      // 显式带上当前 model/权限模式/思考等级:热切换双保险(服务端本来也会读 DB 最新值)
      final ok = app.sendChat(text, model: _model, permissionMode: _mode, thinking: _thinking, images: images);
      if (!ok) showToast(context, '发送失败:原文已留在输入框');
    });
  }

  /// 清空输入区(发出去或已入队后调用)。
  void _consumeComposer(VoidCallback action) {
    action();
    _input.clear();
    _pendingImages.value = const [];
    _pendingFiles.value = const [];
    HapticFeedback.lightImpact();
    FocusScope.of(context).unfocus(); // 收起键盘,别压着半屏看回复
  }

  /// 正在回复时点发送:中央弹窗二选一——排队(等回复结束自动推)或立即发送(打断当前)。
  Future<void> _showRunConflictDialog(String text, List<String> images) async {
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: BorderSide(color: ZT.edge, width: 1.4),
        ),
        title: Row(children: [
          Icon(Icons.hourglass_top_rounded, size: 18, color: ZT.primaryDeep),
          const SizedBox(width: 8),
          Text('会话正在回复', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ZT.ink)),
        ]),
        content: Text(
          '这条消息要排队等回复结束,还是打断当前回复立即发送?',
          style: TextStyle(fontSize: 13.5, height: 1.5, color: ZT.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'queue'),
            child: Text('排队', style: TextStyle(fontWeight: FontWeight.w800, color: ZT.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'now'),
            child: Text('立即发送', style: TextStyle(fontWeight: FontWeight.w800, color: ZT.primaryDeep)),
          ),
        ],
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'queue') {
      final r = app.enqueue(text, images: images);
      if (r == 'duplicate') {
        showToast(context, '队列里已有相同消息,没有重复加入');
        return;
      }
      _consumeComposer(() {});
      showToast(context, '已排队,回复结束后自动发送');
    } else if (choice == 'now') {
      _consumeComposer(() {});
      unawaited(app.interruptAndSend(text,
          model: _model, permissionMode: _mode, thinking: _thinking, images: images));
      showToast(context, '正在打断当前回复…');
    }
  }

  /// 附件入口弹层:拍照 / 相册 / 文件 三选一(点选即执行)。
  Future<void> _showAttachSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: ZT.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('拍照', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(sheetContext);
              _pickImagesFromGallery(camera: true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选择图片', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(sheetContext);
              _pickImagesFromGallery();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('上传文件(PDF/文档/任意)', style: TextStyle(fontSize: 14)),
            onTap: () {
              Navigator.pop(sheetContext);
              _pickAndUploadFiles();
            },
          ),
        ]),
      ),
    );
  }

  /// 文件选择(file_picker)→ 上传到电脑 → 以路径引用入待发列表。
  Future<void> _pickAndUploadFiles() async {
    const maxFiles = 4;
    if (_pendingFiles.value.length >= maxFiles) {
      if (mounted) showToast(context, '一次最多 $maxFiles 个文件');
      return;
    }
    // 12.x: pickFiles 返回 List<PlatformFile>(非 null);逐个转 XFile
    final result = await FilePicker.pickFiles();
    final picked = [
      for (final pf in result) pf.xFile,
    ];
    if (picked.isEmpty) return;
    for (final f in picked.take(maxFiles - _pendingFiles.value.length)) {
      try {
        final r = await app.uploadFile(f.name, await f.readAsBytes());
        if (mounted) {
          final next = [..._pendingFiles.value, r];
          _pendingFiles.value = next;
          showToast(context, '已上传: ${r.name}');
        }
      } on Object catch (e) {
        if (mounted) showToast(context, '${f.name} 上传失败: $e');
      }
    }
  }

  /// 相册选图(支持多选)→ 读字节 → base64 data URI(最多 4 张,单张 ≤ 5MB)。
  Future<void> _pickImagesFromGallery({bool camera = false}) async {
    const maxImages = 4;
    final remaining = maxImages - _pendingImages.value.length;
    if (remaining <= 0) {
      if (mounted) showToast(context, '一次最多 $maxImages 张');
      return;
    }
    try {
      // 拾取即压缩到 1280px/80:base64 要进 WS 消息体,原图又大又没必要
      final picked = camera
          ? await (_picker.pickImage(source: ImageSource.camera,
                  maxWidth: 1280, maxHeight: 1280, imageQuality: 80))
              .then((f) => f == null ? <XFile>[] : <XFile>[f])
          : await _picker.pickMultiImage(
              maxWidth: 1280, maxHeight: 1280, imageQuality: 80);
      if (picked.isEmpty) return;
      // 读字节+base64 丢 isolate:几张几 MB 的图在主线程编码会掉帧
      final uris = await compute(_encodeImagesJob, [for (final p in picked) p.path]);
      final skippedBig = picked.length - uris.length; // 超限单张静默跳过计数
      if (uris.isEmpty) {
        if (mounted) showToast(context, '图片超过 ${kMaxImageBytes ~/ (1024 * 1024)}MB,换个小的');
        return;
      }
      final next = [..._pendingImages.value, ...uris];
      var dropped = 0;
      if (next.length > maxImages) {
        dropped = next.length - maxImages;
        next.removeRange(maxImages, next.length);
      }
      _pendingImages.value = next;
      if (dropped > 0 && mounted) {
        showToast(context, '最多 $maxImages 张,超出 $dropped 张未添加');
      } else if (skippedBig > 0 && mounted) {
        showToast(context, '$skippedBig 张超过 ${kMaxImageBytes ~/ (1024 * 1024)}MB,未添加');
      }
    } on Object catch (e) {
      if (mounted) showToast(context, '选图失败: $e');
    }
  }

  /// 模型选择弹层:选模型(分组)→ 思考等级(随模型动态变档位)→ 完成。
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
    final sheetHeight = MediaQuery.of(context).size.height * 0.75;
    final picked = await showModalBottomSheet<(String, String?)>(
      context: context,
      backgroundColor: ZT.surface,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          constraints: BoxConstraints(maxHeight: sheetHeight),
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: _ModelThinkingSheet(
            groups: app.modelGroups,
            currentModel: current,
            currentThinking: _thinking,
          ),
        ),
      ),
    );
    if (picked == null) return;
    final (model, thinking) = picked;
    if (model != current) await app.patchSession(widget.sessionId, model: model);
    if (!mounted) return;
    setState(() => _thinking = thinking);
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
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(ZT.radius)),
        side: BorderSide(color: ZT.edge),
      ),
      builder: (ctx) => SafeArea(
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
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
      shape: RoundedRectangleBorder(
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
                  Icon(Icons.account_tree_rounded, size: 18, color: ZT.primary),
                  const SizedBox(width: 8),
                  const Text('执行计划',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                  const Spacer(),
                  if (steps != null)
                    Text('${steps.where((s) => s.completed).length}/${steps.length}',
                        style: TextStyle(
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
      shape: RoundedRectangleBorder(
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
                      Row(children: [
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
          Text(label, style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
          const Spacer(),
          Text(value,
              style: TextStyle(
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
        Text(label, style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
        const Spacer(),
        Flexible(
          child: Text(value,
              textAlign: TextAlign.right,
              style: TextStyle(
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
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: AppBar(
        title: Row(children: [
          Expanded(
            child: Text(_title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2)),
          ),
          if (_totalTokens > 0) ...[
            Icon(Icons.electric_bolt_rounded, size: 11, color: ZT.inkFaint),
            const SizedBox(width: 2),
            Text(_fmtTokens(_totalTokens),
                style: TextStyle(
                    fontSize: 10.5, fontWeight: FontWeight.w800, color: ZT.inkFaint)),
            const SizedBox(width: 7),
          ],
          const SizedBox(width: 8),
          StatusChip(phase: _phase(), compact: true),
        ]),
        actions: const [],
      ),
      body: SafeArea(
        child: Column(children: [
          if (app.socket.state == ZSocketState.reconnecting) _reconnectStrip(),
          if (app.error != null) _errorStrip(),
          const Divider(height: 1),
          if (_searching) ...[
            _searchBar(),
            Expanded(child: _searchResults()),
          ] else ...[
          Expanded(
            child: NotificationListener<ScrollNotification>(
              onNotification: (n) {
                if (n is ScrollStartNotification && n.dragDetails != null) {
                  _dragging = true;
                } else if (n is ScrollEndNotification) {
                  _dragging = false;
                }
                if (!_listCtrl.hasClients) return false;
                final away = _listCtrl.offset > 60;
                if (away != _listAway) setState(() => _listAway = away);
                return false;
              },
              child: Stack(children: [
                _list(),
                if (_listAway)
                  Positioned(
                    right: 16,
                    bottom: 12,
                    child: Material(
                      color: ZT.surface,
                      borderRadius: BorderRadius.circular(99),
                      elevation: 3,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(99),
                        onTap: () => _listCtrl.animateTo(0,
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeOutCubic),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Icon(Icons.arrow_downward_rounded, size: 14, color: ZT.primaryDeep),
                            const SizedBox(width: 4),
                            Text('回到底部',
                                style: TextStyle(
                                    fontSize: 12, fontWeight: FontWeight.w700, color: ZT.primaryDeep)),
                          ]),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
          ],
          if (chat.rows.isEmpty && !app.historyLoading && !_searching && !chat.running)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.waving_hand_rounded, size: 30, color: ZT.inkFaint),
                  const SizedBox(height: 12),
                  Text('发第一条消息,开始这个会话',
                      style: TextStyle(fontSize: 13, color: ZT.inkFaint)),
                ]),
              ),
            ),
          if (!_searching && _showStreamingPanel) _streamingArea(compact: _listAway)!,
          if (!_searching && chat.pendingPermission != null)
            PermissionCard(
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
          if (!_searching) _queueBar(),
          if (!_searching) _composer(),
          if (!_searching) _quickBar(planOn, subsOn || bgOn),
        ]),
      ),
    );
  }

  String _phase() => chatPhase(
        running: chat.running,
        hasPermission: chat.pendingPermission != null,
        socketOpen: app.socket.state == ZSocketState.open,
      );

  Widget _reconnectStrip() {
    return Material(
      color: ZT.lemon,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Row(children: [
          PulseDot(color: ZT.rose, animate: true, size: 7),
          const SizedBox(width: 8),
          Text('连接不稳(${app.linkFailure ?? '重连中'})……事件会自动补齐',
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.onInk)),
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
            Icon(Icons.error_outline_rounded, size: 14, color: ZT.rose),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${app.error}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.rose)),
            ),
            Icon(Icons.close_rounded, size: 14, color: ZT.rose),
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

  /// 底部快捷条:模型 + 安全/思考/计划/任务/刷新 共 6 个等宽磁贴。
  /// 子代理/后台/定时合并进「任务」磁贴(三 Tab 弹窗);引用在右上角直达。
  /// 模型贴直显当前模型名(超宽省略号,长按 Tooltip 看完整 id);有状态时点亮。
  Widget _quickBar(bool planOn, bool taskOn) {
    final tiles = <(IconData, String, String, Color?, bool, VoidCallback)>[
      (Icons.shield_rounded, '安全', '权限模式:${_modeLabel(_mode)}', _mode == 'default' ? null : ZT.lemon, false, _pickMode),
      (Icons.query_stats_rounded, '思考', '用量统计', chat.usage == null ? null : ZT.aqua, false, _openUsageSheet),
      (Icons.account_tree_rounded, '计划', '执行计划', planOn ? ZT.primary : null, false, _openPlanSheet),
      // 任务中心:子代理/后台/定时 三 Tab;任一有活动点亮紫色
      (
        Icons.checklist_rounded,
        '任务',
        '子代理 · 后台任务 · 定时任务',
        (taskOn || _cronsOn) ? ZT.grape : null,
        false,
        _openTasks,
      ),
      (Icons.refresh_rounded, '刷新', '全量重载:从 CLI 转录补回丢失消息', null, app.historyLoading, () async {
        final merged = await app.fullReload(widget.sessionId);
        if (mounted) {
          showToast(context, switch (merged) {
            > 0 => '完整重载:补回 $merged 条丢失消息',
            == 0 => '已对齐 CLI 转录,没有缺失消息',
            _ => '已按 CLI 转录重建(清掉了 ${-merged} 条旧进程残留事件)',
          });
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
    // itemCount = rows + 1(计划面板) + 1(会话头/加载);流式区已移出列表成为独立面板
    // (reverse 列表锚点钉底,流式区在列表内长高会把历史内容顶走=「滚来滚去」的根因)
    final plan = derivePlanSteps(rows);
    final planIdx = rows.length;
    final headIdx = rows.length + 1;
    // 行入场动画水位:历史换底/会话切换时水位对齐行数(不播);仅新增行播一次(规格四 180ms)
    if (app.historyLoading && rows.length > _animatedUpTo) _animatedUpTo = rows.length;
    final freshFrom = _animatedUpTo.clamp(0, rows.length);
    if (rows.length > _animatedUpTo) _animatedUpTo = rows.length;

    return ListView.builder(
      reverse: true,
      controller: _listCtrl,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      itemCount: rows.length + 2,
      itemBuilder: (context, i) {
        if (i < rows.length) {
          final row = buildChatRow(rows[rows.length - 1 - i]);
          // reverse 列表 i 越小越新:新增行(未过水位)播 fade+slide 180ms 入场
          if (i < rows.length - freshFrom) {
            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              builder: (context, t, child) => Opacity(
                opacity: t,
                child: Transform.translate(offset: Offset(0, 4 * (1 - t)), child: child),
              ),
              child: row,
            );
          }
          return row;
        }
        if (i == planIdx) {
          return plan == null
              ? const SizedBox.shrink()
              : PlanPanel(steps: plan);
        }
        if (i == headIdx) {
          return app.historyLoading
              ? Padding(
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

  Widget _searchBar() {
    final hits = searchChatRows(chat.rows, _searchQuery);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            onChanged: (v) => setState(() => _searchQuery = v),
            style: const TextStyle(fontSize: 13.5),
            decoration: const InputDecoration(
              hintText: '在聊天记录中搜索…',
              prefixIcon: Icon(Icons.search_rounded, size: 20),
              isDense: true,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('${hits.length} 处',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ZT.inkSoft)),
        IconButton(
          tooltip: '退出搜索',
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: _exitSearch,
        ),
      ]),
    );
  }

  void _exitSearch() {
    _searchCtrl.clear();
    setState(() {
      _searching = false;
      _searchQuery = '';
    });
  }

  Widget _searchResults() {
    final hits = searchChatRows(chat.rows, _searchQuery);
    if (hits.isEmpty) {
      return Center(
        child: Text(_searchQuery.trim().isEmpty ? '输入关键词搜索聊天记录' : '没有匹配的消息',
            style: TextStyle(fontSize: 12.5, color: ZT.inkFaint)),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
      itemCount: hits.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final h = hits[i];
        return HardCard(
          padding: const EdgeInsets.all(11),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: ShapeDecoration(
                  color: ZT.surfaceHi,
                  shape: StadiumBorder(side: ZT.inkSide(w: 1)),
                ),
                child: Text(h.roleLabel,
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: ZT.inkSoft)),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: h.content));
                  showToast(context, '已复制');
                },
                child: Icon(Icons.copy_rounded, size: 15, color: ZT.inkSoft),
              ),
            ]),
            const SizedBox(height: 6),
            Text(h.content,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 1.4, color: ZT.ink)),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () {
                  if (chat.running) {
                    showToast(context, '当前回合运行中,结束后再引用发送');
                    return;
                  }
                  app.sendChat('【引用 ${h.roleLabel} 的消息】\n${h.content}\n\n请基于以上内容继续');
                  _exitSearch();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: ShapeDecoration(
                    color: ZT.primary.withValues(alpha: 0.12),
                    shape: StadiumBorder(side: BorderSide(width: 1.2, color: ZT.primary)),
                  ),
                  child: Text('引用发送',
                      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: ZT.primaryDeep)),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  /// 是否显示流式面板:有流式内容,或已发送且全部工具已收尾(静默骨架行)。
  bool get _showStreamingPanel {
    final hasStream =
        (chat.streamingText?.isNotEmpty ?? false) ||
        (chat.streamingThinking?.isNotEmpty ?? false);
    if (hasStream || chat.pendingPermission != null) return true;
    return chat.running;
  }

  /// 流式面板(独立于消息列表):只在有内容或骨架行时占位,返回 null = 不显示。
  /// 列表里不再放流式区——reverse 列表锚点钉底,流式区在列表内长高会把历史
  /// 内容顶走(「滚来滚去」根因);搬出来后长高吃自己的固定空间,列表纹丝不动。
  ///
  /// 紧凑态([compact],用户滚离底部看历史时):面板收成一行「正在回复/深度思考中」
  /// 细条。展开态面板每长一截就把列表视口压扁一截,历史内容跟着挪——读历史期间
  /// 收成定高细条,列表几乎纹丝不动;回到底部恢复全文。
  Widget? _streamingArea({bool compact = false}) {
    final thinking = chat.streamingThinking;
    final text = chat.streamingText;
    final hasContent = (thinking != null && thinking.isNotEmpty) || (text != null && text.isNotEmpty);
    if (!hasContent) {
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
    if (compact) {
      final busy = thinking != null && thinking.isNotEmpty;
      return Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 2),
        child: Row(children: [
          PulseDot(color: busy ? ZT.grape : ZT.primary, animate: true, size: 6),
          const SizedBox(width: 6),
          Text(busy ? '深度思考中……(回到底部看全文)' : '正在回复……(回到底部看全文)',
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800,
                  color: busy ? ZT.grape : ZT.primaryDeep)),
        ]),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text != null && text.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 10),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                PulseDot(color: ZT.primary, animate: true, size: 6),
                const SizedBox(width: 6),
                Text('正在回复',
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w800,
                        color: ZT.primaryDeep,
                        letterSpacing: 0.5)),
              ]),
              const SizedBox(height: 3),
              // 边吐字边渲染 Markdown(200ms 节流 + 未闭合围栏补闭合),
              // 与落定后的 AssistantBlock 同一渲染管线,落定瞬间不再跳变。
              // 限高 + 内部滚动(reverse:锚定最新):长回复吃自己的空间,不再无限挤压列表。
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.42),
                child: SingleChildScrollView(
                  reverse: true,
                  child: MemoMarkdown(
                    text: text,
                    streaming: true,
                    baseStyle: TextStyle(fontSize: 14, height: 1.5, color: ZT.ink),
                  ),
                ),
              ),
            ]),
          ),
        if (thinking != null && thinking.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 8, right: 24),
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
            decoration: BoxDecoration(
              color: ZT.surface,
              borderRadius: BorderRadius.circular(ZT.radius),
              border: Border.all(width: 1.2, color: ZT.grape.withValues(alpha: ZT.palette.neoShadow ? 1 : 0.5)),
            ),
            child: Row(children: [
              PulseDot(color: ZT.grape, animate: true, size: 6),
              const SizedBox(width: 6),
              Text('深度思考中',
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

  /// 发送排队面板:会话 running 时发的消息在这里排队,回复结束可自动消化(开关)。
  /// 每条:📌置顶 / ✏️修改 / ⚡打断立即发送 / 🗑️删除;默认折叠只显示第一条。
  Widget _queueBar() {
    final sid = widget.sessionId;
    final q = app.queueOf(sid);
    if (q.isEmpty) return const SizedBox.shrink();
    final auto = app.autoConsumeOf(sid);
    final shown = _queueExpanded ? q : q.take(1).toList();
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: ZT.lemon,
        border: Border(
          top: BorderSide(color: ZT.line, width: 1.1),
          bottom: BorderSide(color: ZT.line, width: 1.1),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _queueExpanded = !_queueExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.low_priority_rounded, size: 14, color: ZT.inkSoft),
                const SizedBox(width: 6),
                Text('排队中 ${q.length} 条',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: ZT.inkSoft)),
                Icon(_queueExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    size: 16, color: ZT.inkSoft),
              ]),
            ),
          ),
          const Spacer(),
          Text('自动消化', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: ZT.inkFaint)),
          SizedBox(
            height: 30,
            child: Switch(
              value: auto,
              activeThumbColor: ZT.primary,
              onChanged: (v) => app.setAutoConsume(sid, on: v),
            ),
          ),
        ]),
        for (var i = 0; i < shown.length; i++)
          Row(children: [
            Expanded(
              child: Text(
                shown[i].text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, height: 1.35, color: ZT.ink),
              ),
            ),
            if (i > 0)
              _queueIcon(sid, i, Icons.push_pin_outlined, '置顶', ZT.inkSoft),
            _queueIcon(sid, i, Icons.edit_outlined, '修改', ZT.inkSoft),
            _queueIcon(sid, i, Icons.bolt_rounded, '打断并立即发送', ZT.primaryDeep),
            _queueIcon(sid, i, Icons.delete_outline_rounded, '删除', ZT.rose),
          ]),
        if (!_queueExpanded && q.length > 1)
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _queueExpanded = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
              child: Text('… 还有 ${q.length - 1} 条,点开展开',
                  style: TextStyle(fontSize: 11.5, color: ZT.inkFaint)),
            ),
          ),
      ]),
    );
  }

  Widget _queueIcon(String sid, int index, IconData icon, String tip, Color color) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      tooltip: tip,
      icon: Icon(icon, size: 17, color: color),
      onPressed: () => _onQueueAction(sid, index, tip),
    );
  }

  Future<void> _onQueueAction(String sid, int index, String tip) async {
    final q = app.queueOf(sid);
    if (index >= q.length) return;
    final m = q[index];
    switch (tip) {
      case '置顶':
        app.promoteQueued(sid, index);
      case '修改':
        await _editQueuedDialog(sid, index, m);
      case '打断并立即发送':
        unawaited(app.sendQueuedNow(sid, index,
            model: _model, permissionMode: _mode, thinking: _thinking));
        showToast(context, '正在打断当前回复…');
      case '删除':
        app.removeQueued(sid, index);
    }
  }

  /// 编辑排队文案:改成与队内其他条重复时拒绝并提示。
  Future<void> _editQueuedDialog(String sid, int index, QueuedMessage m) async {
    final ctrl = TextEditingController(text: m.text);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: BorderSide(color: ZT.edge, width: 1.4),
        ),
        title: Text('修改排队消息', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ZT.ink)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          style: TextStyle(fontSize: 13.5, color: ZT.ink),
          decoration: InputDecoration(
            hintText: '修改要发送的内容',
            border: const OutlineInputBorder(),
            focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: ZT.primary, width: 1.4)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text('取消', style: TextStyle(fontWeight: FontWeight.w700, color: ZT.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text('保存', style: TextStyle(fontWeight: FontWeight.w800, color: ZT.primaryDeep)),
          ),
        ],
      ),
    );
    if (saved != true || !mounted) return;
    final text = ctrl.text.trim();
    if (text.isEmpty) {
      showToast(context, '内容为空,没有修改');
      return;
    }
    if (!app.editQueued(sid, index, text)) {
      showToast(context, '队列里已有相同消息,修改未生效');
    }
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
            style: TextStyle(
                fontSize: 10.5, fontWeight: FontWeight.w700, color: ZT.inkFaint),
          ),
        ),
      ]),
    );
  }

  // ---------------------------------------------------------------- composer

  /// data URI 预览:88px 缩略图条,点选某张 -> 全屏预览,左右滑看上一张/下一张。

  Widget _composer() {
    return Container(
      decoration: BoxDecoration(
        color: ZT.bg,
        border: Border(top: BorderSide(width: 1.2, color: ZT.edge)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // 已选文件附件条:文件图标卡,点 X 移除
        ValueListenableBuilder<List<({String name, String path})>>(
          valueListenable: _pendingFiles,
          builder: (context, files, _) {
            if (files.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 44,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: files.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: ShapeDecoration(
                      color: ZT.surface,
                      shape: StadiumBorder(side: ZT.inkSide(w: 1.2)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.insert_drive_file_rounded, size: 15, color: ZT.aqua),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(files[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: ZT.ink)),
                      ),
                      const SizedBox(width: 6),
                      GestureDetector(
                        onTap: () {
                          final next = [...files]..removeAt(i);
                          _pendingFiles.value = next;
                        },
                        child: Icon(Icons.close_rounded, size: 14, color: ZT.inkSoft),
                      ),
                    ]),
                  ),
                ),
              ),
            );
          },
        ),
        // 已选图片预览条:88px 缩略图,点图滑动预览,右上角 X 移除
        ValueListenableBuilder<List<String>>(
          valueListenable: _pendingImages,
          builder: (context, images, _) {
            if (images.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: 88,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: images.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, i) => Stack(children: [
                    GestureDetector(
                      onTap: () => showChatImageViewer(context, images, initialIndex: i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: chatImageThumb(images[i], size: 88),
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: () {
                          final next = [...images]..removeAt(i);
                          _pendingImages.value = next;
                        },
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: ZT.ink.withValues(alpha: 0.6),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.close_rounded, size: 13, color: Colors.white),
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
            tooltip: '添加附件(图片/拍照/文件)',
            onPressed: _showAttachSheet,
            icon: Icon(Icons.add_circle_outline_rounded, size: 24, color: ZT.inkSoft),
          ),
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              style: TextStyle(fontSize: 14, fontFamily: ZT.mono, color: ZT.ink),
              decoration: const InputDecoration(
                hintText: '让它干活…',
                contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 逐字刷新:不依赖页面重建;再叠一层监听已选图片——只选图不输字时,
          // 单靠 _input 不会重建按钮,发送键会一直灰着发不出去。
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _input,
            builder: (context, value, _) => ValueListenableBuilder<List<String>>(
              valueListenable: _pendingImages,
              builder: (context, images, _) => ValueListenableBuilder<
                  List<({String name, String path})>>(
                valueListenable: _pendingFiles,
                builder: (context, files, _) => _SendOrStop(
                // 断线时 running 可能是冻结的假象(complete 到不了):只认"在线且在跑"
                canStop: chat.running && app.socket.state == ZSocketState.open,
                stopping: _stopping && chat.running,
                hasText: value.text.trim().isNotEmpty ||
                    images.isNotEmpty ||
                    files.isNotEmpty,
                onSend: _send,
                onStop: () {
                  HapticFeedback.mediumImpact();
                  setState(() => _stopping = true); // 乐观反馈:别等 CLI 掐断流才给动静
                  app.abort();
                },
                ),
              ),
            ),
          ),
        ]),
      ]),
    );
  }
}

// ---------------------------------------------------------------- widgets

/// 二级模型选择器:一级供应商列表,点供应商展开该组的模型列表。
/// 模型 + 思考等级 一体选择弹层:思考档位随选中模型动态变化
/// (deepseek 系三档,qwen 系与其他 开/关),「完成」一次性带回两者。
/// 再点一次已选中的档位 = 回到「默认」(不注入,模型自己的行为)。
class _ModelThinkingSheet extends StatefulWidget {
  final List<Map<String, dynamic>> groups;
  final String currentModel;
  final String? currentThinking;

  const _ModelThinkingSheet({
    required this.groups,
    required this.currentModel,
    this.currentThinking,
  });

  @override
  State<_ModelThinkingSheet> createState() => _ModelThinkingSheetState();
}

class _ModelThinkingSheetState extends State<_ModelThinkingSheet> {
  late String _model;
  String? _thinking;

  @override
  void initState() {
    super.initState();
    _model = widget.currentModel;
    _thinking = widget.currentThinking;
  }

  @override
  Widget build(BuildContext context) {
    final options = thinkingOptionsFor(_model);
    // 换了模型后原档位不在新选项里 → 回落默认
    final selected = options.any((o) => o.$2 == _thinking) ? _thinking : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _ModelGroupPicker(
            groups: widget.groups,
            current: _model,
            onPick: (m) => setState(() {
              _model = m;
              if (!thinkingOptionsFor(m).any((o) => o.$2 == _thinking)) _thinking = null;
            }),
          ),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Icon(Icons.psychology_alt_rounded, size: 15, color: ZT.grape),
          const SizedBox(width: 6),
          const Text('思考等级', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800)),
          const SizedBox(width: 6),
          Text(selected == null ? '· 默认' : '',
              style: TextStyle(fontSize: 11, color: ZT.inkFaint)),
        ]),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final (label, value) in options) _thinkingPill(label, value, selected == value),
          ],
        ),
        const SizedBox(height: 12),
        BigButton(
          label: '完成',
          icon: Icons.check_rounded,
          onPressed: () => Navigator.pop(context, (_model, _thinking)),
        ),
      ],
    );
  }

  Widget _thinkingPill(String label, String value, bool selected) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: () => setState(() => _thinking = _thinking == value ? null : value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: ShapeDecoration(
          color: selected ? ZT.primary.withValues(alpha: 0.14) : ZT.bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
            side: ZT.inkSide(w: selected ? 1.5 : 1.2, color: selected ? ZT.primary : ZT.edge),
          ),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: selected ? ZT.primary : ZT.inkSoft)),
      ),
    );
  }
}

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
            child: Padding(
              padding: EdgeInsets.only(right: 8),
              child: Icon(Icons.arrow_back_rounded, size: 20, color: ZT.inkSoft),
            ),
          ),
        Icon(Icons.dns_rounded, size: 18, color: ZT.primary),
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
                        color: ZT.inkSoft,
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
                          style: TextStyle(
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
/// AskUserQuestion 是「模型问用户」,不是「用户授权模型」——同一骨架但语义分流:
/// 标题去工具名、选项 description 常显、单选圆多选方、按钮「跳过」。
/// 公开为 PermissionCard 以便单测覆盖两种语义分支。
class PermissionCard extends StatefulWidget {
  final PermissionReq req;

  /// rememberTool = 用户勾了「本会话总是允许」:server 端记名,同工具后续免弹。
  final void Function(bool allow, String message, Map<String, dynamic>? updatedInput, [bool rememberTool]) onAnswer;

  const PermissionCard({super.key, required this.req, required this.onAnswer});

  @override
  State<PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<PermissionCard> {
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
    final header = '${q['header'] ?? ''}'.trim();
    final options = (q['options'] as List?) ?? const [];
    final multi = q['multiSelect'] == true;
    final picked = _picked.putIfAbsent(question, () => <String>{});
    return [
      Padding(
        padding: const EdgeInsets.only(top: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (header.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(right: 7, top: 1),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: ZT.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(header,
                  style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w800, color: ZT.primaryDeep)),
            ),
          Expanded(
            child: Text(question,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, height: 1.35)),
          ),
          // 单选/多选必须一眼可辨:否则用户点第二个静默清掉第一个,会当成 bug。
          Padding(
            padding: const EdgeInsets.only(left: 6, top: 1),
            child: Text(multi ? '可多选' : '单选',
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: ZT.inkFaint)),
          ),
        ]),
      ),
      // 选项整行可点:label 一行,description 直接铺在下行常显。
      // 原来把 description 塞 tooltip —— 手机没有 hover,等于没给用户看。
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          children: [
            for (final o in options)
              if (o is Map)
                _askOption(
                  label: '${o['label'] ?? ''}',
                  description: '${o['description'] ?? ''}'.trim(),
                  selected: picked.contains('${o['label'] ?? ''}'),
                  multi: multi,
                  onTap: () => setState(() {
                    final label = '${o['label'] ?? ''}';
                    if (multi) {
                      picked.contains(label) ? picked.remove(label) : picked.add(label);
                    } else {
                      picked
                        ..clear()
                        ..add(label);
                    }
                  }),
                ),
          ],
        ),
      ),
    ];
  }

  /// 单个选项:左侧单选圆点 / 多选方框,右侧 label + description。
  Widget _askOption({
    required String label,
    required String description,
    required bool selected,
    required bool multi,
    required VoidCallback onTap,
  }) {
    final accent = ZT.primary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Material(
        color: selected ? accent.withValues(alpha: 0.10) : ZT.surfaceHi,
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                width: selected ? 1.6 : 1.0,
                color: selected ? accent : ZT.line,
              ),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: _marker(selected: selected, multi: multi, accent: accent),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 12.5,
                          height: 1.3,
                          fontWeight: selected ? FontWeight.w800 : FontWeight.w700,
                          color: ZT.ink)),
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(description,
                          style: TextStyle(fontSize: 11.5, height: 1.35, color: ZT.inkSoft)),
                    ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  /// 单选=圆形(选中实心点),多选=方形(选中打勾)。形状本身就是语义。
  Widget _marker({required bool selected, required bool multi, required Color accent}) {
    if (multi) {
      return Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: selected ? accent : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(width: 1.4, color: selected ? accent : ZT.inkFaint),
        ),
        child: selected ? Icon(Icons.check_rounded, size: 12, color: ZT.onInk) : null,
      );
    }
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(width: 1.4, color: selected ? accent : ZT.inkFaint),
      ),
      alignment: Alignment.center,
      child: selected
          ? Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: accent))
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final questions = _questions;
    final isAsk = _isAsk && questions.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: ZT.surface,
        // 问询卡用主色(是"问你话"),审批卡用琥珀(是"要你授权") —— 颜色分流语义。
        border: Border(top: BorderSide(width: 1.4, color: isAsk ? ZT.primary : ZT.lemon)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Icon(isAsk ? Icons.help_outline_rounded : Icons.verified_user_rounded,
              size: 15, color: isAsk ? ZT.primary : ZT.lemon),
          const SizedBox(width: 7),
          Expanded(
            child: isAsk
                // 问询卡是「模型在问你」,标题就是它要问的事 —— 别再把内部工具名
                // AskUserQuestion 摆在标题位,那不是用户需要知道的信息。
                ? Text(questions.length > 1 ? '需要你确认 ${questions.length} 个问题' : '需要你确认',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800))
                : Text('权限请求 · ${widget.req.toolName}',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
          ),
        ]),
        if (isAsk)
          for (final q in questions) ..._questionWidgets(q)
        else ...[
          if (_prettyInput.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 130),
                child: SingleChildScrollView(
                  child: SelectableText(_prettyInput,
                      style: TextStyle(
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
              child: isAsk
                  // 问询卡上是「模型问你」,不是「申请授权」。原「拒绝」语义错位
                  // (像在批权限);改成「跳过」——它是"这题我不答",而非否决。
                  ? BigButton(
                      label: '跳过',
                      color: ZT.surfaceHi,
                      textColor: ZT.inkSoft,
                      onPressed: () => widget.onAnswer(false, _message.text.trim(), null),
                    )
                  : BigButton(
                      label: '拒绝',
                      color: ZT.rose,
                      textColor: Colors.white,
                      onPressed: () => widget.onAnswer(false, _message.text.trim(), null),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: isAsk
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
        if (!isAsk)
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
      PulseDot(color: ZT.primary, animate: true, size: 6),
      const SizedBox(width: 6),
      Expanded(
        child: Text('$label $hint',
            style: TextStyle(fontSize: 11, color: ZT.inkSoft, fontFamily: ZT.sans)),
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

  /// 已点停止、正在等 CLI 落定的窗口期:按钮转圈防重复点,给即时反馈
  final bool stopping;

  const _SendOrStop({
    required this.canStop,
    required this.hasText,
    required this.onSend,
    required this.onStop,
    this.stopping = false,
  });

  @override
  State<_SendOrStop> createState() => _SendOrStopState();
}

class _SendOrStopState extends State<_SendOrStop> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    // 停止乐观反馈:点下瞬间就转「停止中」,不等 CLI 掐断流再转回(0.5~3 秒体感盲区)
    if (widget.canStop) {
      final stopping = widget.stopping;
      return GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: stopping ? null : widget.onStop,
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
            shadows: _pressed ? const [] : ZT.hard(dx: 2.5, dy: 2.5, color: ZT.rose),
          ),
          child: stopping
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                )
              : const Icon(Icons.stop_rounded, color: Colors.white, size: 26),
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
