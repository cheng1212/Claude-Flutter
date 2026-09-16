// 聊天页:reversed 列表 + 六枚图标快捷条 + 权限面板 + 输入条。
// 布局参考 zremote chat_page(quick chips/选项弹层/计划弹层/SendOrStop),状态走 ZApp。
import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderAbstractViewport, RenderSliverMultiBoxAdaptor, ScrollDirection, SliverMultiBoxAdaptorParentData;
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

import '../chat_scroll_anchor.dart';
import '../core/motion.dart';
import '../debug_log.dart';
import '../panel_utils.dart';
import '../session_utils.dart';
import '../state/reducer.dart';
import '../state/zapp.dart';
import '../theme.dart';
import 'tasks_sheet.dart';
import 'text_select_sheet.dart';
import 'toast.dart';
import '../ws.dart';
import 'row_actions.dart';
import 'rows.dart';

/// 单张图片字节上限:超过的整张跳过(data URI 要进 WS 消息体)。
/// 上限推导:server 按 data URI 字符串长度卡 5MB(MAX_IMAGE_URI),base64 膨胀
/// 4/3——5MB 二进制编出来约 6.7MB 字符会被服务端静默剔除。取 3.75MB 二进制
/// 对应恰好 ≤5MB 字符,再留余量取整 3MB。
const int kMaxImageBytes = 3 * 1024 * 1024;

/// 单帧行数增长超过这个量,就认定是"换底/加载"而不是"逐条新增":不播入场动画。
/// 阈值取 30:正常流式/工具事件一次只加 1~3 行,远超 30 的跳变必是批量替换。
const int kMaxFreshRows = 30;

/// 入场动画水位推进。返回 [freshFrom](水位起点,只有它之前的行播动画)
/// 与推进后的 [watermark]。
///
/// 为什么要有这个函数:换底时 rows 会一次性暴涨(实测 500 → 6617),若还按旧水位算,
/// 几千行被当成"新行"同时建动画;流式每秒重建几十次 → 动画反复重启 → 整屏 opacity
/// 长期接近 0 = **白屏**(而且数据是好的,看门狗不报 rows=0,极难定位)。
/// 抽出纯函数便于回归。
({int freshFrom, int watermark}) advanceAnimWatermark({
  required int current,
  required int rowCount,
  required bool loading,
}) {
  var wm = current;
  if (loading && rowCount > wm) wm = rowCount; // 历史加载中:不播
  if (rowCount > wm + kMaxFreshRows) wm = rowCount; // 跳变(换底):不播
  final freshFrom = wm.clamp(0, rowCount);
  if (rowCount > wm) wm = rowCount;
  return (freshFrom: freshFrom, watermark: wm);
}

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
  bool _animatingToBottom = false; // 回到底部动画进行中(此时禁止补偿,防互相打断)
  int _planRowCount = -1; // 上次算计划时的行数(derivePlanSteps 全量扫描的缓存键)
  bool _thinkingExpanded = false; // 流式思考区:展开看全文(默认一行摘要)
  int _animatedUpTo = 0; // 行入场动画水位:已播过入场动画的行数(按行只播一次)
  bool _searching = false; // 聊天内搜索模式(读态:隐藏输入区,结果面板替代消息列表)
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  List<PlanStep>? _stickyPlan; // 计划弹层的粘性缓存:工具行被翻篇也不闪没
  bool _cronsOn = false; // 会话里有活跃定时任务时点亮
  bool _stopping = false; // 已点停止、在等 CLI 落定的窗口期(乐观反馈)
  String? _thinking; // 思考等级:low/medium/high/off;null = 模型默认(on)
  bool _queueExpanded = false; // 排队面板折叠/展开(折叠只显示第一条)

  /// 多选批量复制:长按任意消息 → 菜单「多选」进入。
  /// 收集的是**行对象本身**(按 identical 判身份),不引额外 id —— 与
  /// chat_scroll_anchor.dart 判行身份的做法一致;行被换底重建时选中自然失效,
  /// 这正是我们要的语义(旧行已经不存在了)。
  bool _picking = false;
  final Set<ChatRow> _picked = <ChatRow>{};

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
    _planRowCount = -1; // 新会话:计划缓存作废(行数可能恰好相同)
    _anchorSample = null; // 新会话:锚行基线作废(内容整体更换)
    _followLocked = false;
    app.openSession(widget.sessionId);
    // 定时任务徽标进页面拉一次即可;放 build 里会随每帧重绘反复打接口
    app.crons(sessionId: widget.sessionId).then((list) {
      if (mounted && _cronsOn != list.isNotEmpty) setState(() => _cronsOn = list.isNotEmpty);
    });
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
    // 计划粘性缓存:新一轮计划(或 TaskList 快照)会覆盖。derivePlanSteps 返回 null
    // 有两种情形——整段历史都没计划(粘性缓存留给翻页抖动),或本轮计划被清空;
    // 后者要靠「有工具行但推不出计划」区分,避免旧计划一直粘在面板上。
    //
    // ⚠️ 按行数缓存:derivePlanSteps 是全量 O(n) 扫描,而 _onApp 会被每个事件触发
    // (流式高频时每秒几十次)。长会话几千行时,每帧扫一遍正是"大量输出就卡住"的来源。
    // 计划只由 tool_use 行决定,行数没变就不必重算。
    if (chat.rows.length != _planRowCount) {
      _planRowCount = chat.rows.length;
      final derived = derivePlanSteps(chat.rows);
      if (derived != null) {
        _stickyPlan = derived;
      } else if (chat.rows.isEmpty && app.historyLoading) {
        _stickyPlan = null;
      }
    }
    _queueAnchorCheck();
    setState(() {});
  }

  // ── 锚行滚动锚定(对齐 zremote,治「飘来飘去/一闪一闪」)──
  // 旧「内容总高度增量 + jumpTo 一步跳」方案已废,两大缺陷:
  // ① 方向性:历史端内容长高(图片解码/markdown 重排)时,屏幕内容没动、
  //    总高多了 G,按增量补会把用户往历史端推整个 G —— 「飘老远」的根因;
  // ② 观感:jumpTo 直接改 pixels,量到的高度和下一帧实际高度常不一致,
  //    每帧跳一次就是「一闪一闪」。
  // 新方案:以「视口顶可见历史行(行对象 + 视口内 y)」为锚,内容变化前后
  // 锚行 y 差就是该补的位移;身份变了(翻页/换底)重定基线一分不补 ——
  // 换底/翻页防误补由此天然涵盖,不再需要 _compensateRows 三套散装标记。
  // 纯函数(阈值/锁存/步进规划)在 ../chat_scroll_anchor.dart,可单测。

  /// 锚行基线:上次采样(行对象 + 视口内 y);null = 不可锚,重定基线。
  AnchorSample? _anchorSample;
  double _coalescedAnchorDelta = 0; // 帧末合并桶:同帧多触发源只补一次(闪的来源)
  bool _anchorFlushScheduled = false;
  bool _anchorAnimating = false; // 单飞锁:并发 animateTo 互抢目标值就是抖动
  Timer? _anchorAnimTimer;
  bool _followLocked = false; // 「在看历史」锁存:锁存期间内容增长只计未读,不拽人

  /// 内容变化后的锚行检查(post-frame:布局完成后才能量 y)。
  void _queueAnchorCheck() {
    if (_compensateQueued) return;
    _compensateQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _compensateQueued = false;
      if (!mounted || !_listCtrl.hasClients) return;
      _anchorAgainstGrowth();
    });
  }

  void _anchorAgainstGrowth() {
    final next = _sampleTopRow();
    if (next == null) return; // 锚不可用:基线保持原样,不补
    final delta = ViewportAnchor.compensate(prev: _anchorSample, next: next);
    _trackAnchorBaseline(); // 本次采样即新基线:下次变化的对比点
    if (delta == null) return;
    final pos = _listCtrl.position;
    final gap = pos.maxScrollExtent - pos.pixels; // 距最新端
    // 贴底且未锁存:在底部就该自然跟随(新行追加把人往下推是正确行为),锚定退场。
    // 锁存期间即使 gap 很小也必须补 —— 用户就是要停在原地看历史。
    if (gap <= AnchorThresholds.exitPx && !_followLocked) return;
    _queueAnchorGrowth(delta);
  }

  /// 从 [root] 向下找最近的 [RenderAbstractViewport]。
  ///
  /// 为什么不用 [RenderAbstractViewport.of]:`ScrollPosition.context` 的
  /// notificationContext 指向 Scrollable 自己的 RawGestureDetector,而它包在
  /// 视口**外面** —— 拿它向上找永远找不到(debug 断言 / release 抛 TypeError),
  /// 于是每次内容变化都炸一次、锚定形同虚设。向下的第一个视口才是要的那个。
  RenderAbstractViewport? _viewportUnder(RenderObject? root) {
    if (root == null) return null;
    if (root is RenderAbstractViewport) return root;
    RenderAbstractViewport? found;
    root.visitChildren((child) {
      found ??= _viewportUnder(child);
    });
    return found;
  }

  /// 采样视口顶(最旧端)第一条可见**历史行**。头部槽(计划面板/加载提示)
  /// 与流式区(列表外)不锚:头部槽身份不稳,锚它会引入抖动。
  /// 找不到可锚行返回 null,基线保持原样。
  AnchorSample? _sampleTopRow() {
    if (!mounted || !_listCtrl.hasClients) return null;
    final pos = _listCtrl.position;
    if (!pos.hasContentDimensions || !pos.hasPixels) return null;
    final viewport = _viewportUnder(pos.context.notificationContext?.findRenderObject());
    if (viewport == null) return null;
    RenderSliverMultiBoxAdaptor? sliver;
    viewport.visitChildren((child) {
      if (sliver == null && child is RenderSliverMultiBoxAdaptor) sliver = child;
    });
    final box0 = sliver;
    if (box0 == null) return null;
    RenderBox? topChild;
    var topY = double.infinity;
    box0.visitChildren((child) {
      final box = child as RenderBox;
      final y = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
      if (y < topY) {
        topY = y;
        topChild = box;
      }
    });
    final tc = topChild;
    if (tc == null || !tc.hasSize) return null;
    final idx = (tc.parentData as SliverMultiBoxAdaptorParentData).index;
    if (idx == null) return null;
    final rows = chat.rows;
    if (idx < 0 || idx >= rows.length) return null; // 计划面板/会话头槽:不锚
    return AnchorSample(rows[rows.length - 1 - idx], topY); // 行对象即身份(identical)
  }

  /// 滚动期间基线实时跟随:手势/惯性/程序化滚动引起的锚行 y 变化全部吞进
  /// 基线,绝不进补偿 —— 否则停稳后的第一帧会把整个滚动距离当「内容增量」
  /// 回放一遍,视口被拽回滚动前。
  void _trackAnchorBaseline() {
    final next = _sampleTopRow();
    if (next != null) _anchorSample = next;
  }

  /// 补偿量进帧末合并桶(同帧多触发源各算一次会跳两次)。
  void _queueAnchorGrowth(double growth) {
    if (growth <= 0) return;
    _coalescedAnchorDelta += growth;
    if (_anchorFlushScheduled) return;
    _anchorFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorFlushScheduled = false;
      final delta = _coalescedAnchorDelta;
      _coalescedAnchorDelta = 0;
      if (!mounted || _dragging || _animatingToBottom) return;
      // 贴底且未锁存:在底部自然跟随,不补
      final pos = _listCtrl.position;
      final gap = pos.maxScrollExtent - pos.pixels;
      if (gap <= AnchorThresholds.exitPx && !_followLocked) return;
      _applyAnchorGrowth(delta);
    });
  }

  /// 补偿落位:阈值过滤 + 单步上限 + 短动画(闪烁修复核心)+ 单飞锁。
  void _applyAnchorGrowth(double growth) {
    if (!_listCtrl.hasClients) return;
    final pos = _listCtrl.position;
    if (!pos.hasContentDimensions || !pos.hasPixels) return;
    if (pos.userScrollDirection != ScrollDirection.idle) return; // 惯性中不打断
    final step = AnchorMath.plan(growth);
    if (step.delta == 0 && step.leftover == 0) return;
    if (_anchorAnimating) {
      _coalescedAnchorDelta += growth; // 并进桶里,动画结束再走
      _scheduleAnchorFlush();
      return;
    }
    if (step.leftover > 0) {
      _coalescedAnchorDelta += step.leftover; // 超上限的欠账留给下一帧
      _scheduleAnchorFlush();
    }
    final target = (pos.pixels + step.delta).clamp(0.0, pos.maxScrollExtent);
    if ((target - pos.pixels).abs() < AnchorMath.minStepPx) return;
    _anchorAnimating = true;
    _anchorAnimTimer?.cancel();
    _anchorAnimTimer = Timer(Duration(milliseconds: step.durationMs), () {
      _anchorAnimating = false;
      if (_coalescedAnchorDelta.abs() >= AnchorMath.minStepPx) _scheduleAnchorFlush();
    });
    pos.animateTo(target, duration: Duration(milliseconds: step.durationMs), curve: Curves.linear);
  }

  void _scheduleAnchorFlush() {
    if (_anchorFlushScheduled) return;
    _anchorFlushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _anchorFlushScheduled = false;
      final delta = _coalescedAnchorDelta;
      _coalescedAnchorDelta = 0;
      if (!mounted || _dragging || _animatingToBottom) return;
      if (delta.abs() >= AnchorMath.minStepPx) _applyAnchorGrowth(delta);
    });
  }

  /// 回到底部:动画期间**禁止锁位补偿**。
  /// 补偿用的 jumpTo 会 goIdle 掉进行中的动画 —— 两者互相打断时动画永远到不了 0,
  /// 表现就是"点了回到底部卡住"(实测反馈;卡住只能重启)。
  Future<void> _toBottom() async {
    if (!_listCtrl.hasClients || _animatingToBottom) return;
    _followLocked = false; // 回到底部 = 解除「在看历史」锁存
    _anchorSample = null; // 锚行基线作废(视口内容已换)
    setState(() => _animatingToBottom = true);
    try {
      await _listCtrl.animateTo(0,
          duration: kDurPage, curve: kCurveOut);
    } on Object catch (e) {
      ZLog.w('scroll', 'animateTo 失败: $e', dedupeKey: 'toBottom');
    } finally {
      if (mounted) setState(() => _animatingToBottom = false);
    }
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
  /// 上限 9(对齐 zremote:一次最多带 9 个图片/文件)。
  Future<void> _pickAndUploadFiles() async {
    const maxFiles = 9;
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

  /// 相册选图(支持多选)→ 读字节 → base64 data URI(最多 9 张,单张 ≤ 5MB)。
  Future<void> _pickImagesFromGallery({bool camera = false}) async {
    const maxImages = 9;
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
        await app.apiGroups();
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
                // 上下文占用:实时(message_start)优先 → 上一轮落库的真实值 →
                // REST 里最近一次快照。口径是"最近一次 API 请求的 prompt 大小",
                // 不是整轮累计,所以不会出现 >100% 的越界值。
                final liveCtx = chat.effectiveContextTokens;
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
                        Icon(Icons.query_stats_rounded, size: 17, color: ZT.aqua),
                        const SizedBox(width: 8),
                        Text('用量信息',
                            style: TextStyle(
                                fontSize: 15.5, fontWeight: FontWeight.w900, color: ZT.ink)),
                        const Spacer(),
                        _compactButton(),
                      ]),
                      const SizedBox(height: 12),
                      // —— 上下文:大环形窗口占用 + 三项指标(参考稿布局)——
                      _usageSection('用量统计', [
                        Row(children: [
                          _usageRing(ctxTokens, ctxWindow),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(children: [
                              _statLine(Icons.layers_rounded, ZT.aqua, '上下文',
                                  ctxWindow > 0
                                      ? '${_fmtTokens(ctxTokens)} / ${_fmtTokens(ctxWindow)}'
                                      : _fmtTokens(ctxTokens)),
                              _statLine(Icons.bolt_rounded, ZT.lemon, '缓存命中率',
                                  hitRate != null ? '${(hitRate * 100).toStringAsFixed(1)}%' : '—'),
                              _statLine(Icons.upload_rounded, ZT.grape, '单轮输出上限',
                                  (u?.maxOutputTokens ?? 0) > 0 ? _fmtTokens(u!.maxOutputTokens) : '—'),
                            ]),
                          ),
                        ]),
                        if (ctxTokens == 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('还没有用量数据;发一条消息跑完一轮后这里会有完整统计。',
                                style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
                          ),
                        if (app.lastCompact != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                                '上次压缩 ${_fmtTokens(app.lastCompact!.pre)} → '
                                '${_fmtTokens(app.lastCompact!.post)}'
                                '(${app.lastCompact!.trigger == 'auto' ? '自动' : '手动'})',
                                style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: ZT.aqua)),
                          ),
                      ]),
                      // —— 最近一轮(WS 实时)——
                      if (u != null)
                        _usageSection('最近一轮详情', [
                          _statGrid([
                            (Icons.login_rounded, ZT.aqua, '输入', _fmtTokens(u.inputTokens),
                                '缓存读 ${_fmtTokens(u.cacheReadInputTokens)} / 写 ${_fmtTokens(u.cacheCreationInputTokens)}'),
                            (Icons.logout_rounded, ZT.aqua, '输出', _fmtTokens(u.outputTokens), null),
                            (Icons.repeat_rounded, ZT.grape, '轮次',
                                u.numTurns > 0 ? '${u.numTurns}' : '—', null),
                            (Icons.timer_outlined, ZT.lemon, '耗时',
                                u.durationMs >= 1000
                                    ? '${(u.durationMs / 1000).toStringAsFixed(1)}s'
                                    : '${u.durationMs}ms',
                                null),
                            (Icons.attach_money_rounded, ZT.rose, '费用',
                                '\$${u.totalCostUsd.toStringAsFixed(4)}', null),
                          ]),
                        ]),
                      // —— 累计(REST 聚合)——
                      if (runs > 0)
                        _usageSection('累计统计($runs 轮)', [
                          _statGrid([
                            (Icons.login_rounded, ZT.aqua, '输入合计',
                                _fmtTokens((totals['inputTokens'] as num?)?.toInt() ?? 0),
                                '缓存读 ${_fmtTokens((totals['cacheReadInputTokens'] as num?)?.toInt() ?? 0)}'),
                            (Icons.logout_rounded, ZT.aqua, '输出合计',
                                _fmtTokens((totals['outputTokens'] as num?)?.toInt() ?? 0), null),
                            (Icons.attach_money_rounded, ZT.rose, '费用合计',
                                '\$${((totals['costUsd'] as num?) ?? 0).toStringAsFixed(4)}', null),
                            (Icons.timer_outlined, ZT.lemon, '耗时合计',
                                '${(((totals['durationMs'] as num?)?.toInt() ?? 0) / 1000).toStringAsFixed(0)}s',
                                null),
                          ]),
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
                        ]),
                      // —— 工具使用明细:一行一枚小chip ——
                      if (tools.isNotEmpty)
                        _usageSection('工具使用明细(共 ${tools.length} 项)', [
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final t in tools)
                                if (t is Map)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 4),
                                    decoration: ShapeDecoration(
                                      color: ZT.surface,
                                      shape: StadiumBorder(
                                          side: BorderSide(width: 1.1, color: ZT.edge)),
                                    ),
                                    child: Text('${t['toolName']} ×${t['count']}',
                                        style: TextStyle(
                                            fontSize: 11, color: ZT.inkSoft,
                                            fontFamily: ZT.mono)),
                                  ),
                            ],
                          ),
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

  String _fmtTokens(int n) => fmtTokens(n); // 按量级自适应单位(K/M/G),规则见 session_utils.fmtTokens

  /// 手动压缩上下文:确认 → 发 /compact → 按钮转圈 → 收到压缩边界后回执。
  /// 反馈分三段(点击/进行中/完成),不让人对着一个没动静的按钮猜。
  Widget _compactButton() {
    final busy = app.compacting;
    return GestureDetector(
      onTap: busy ? null : () => _confirmCompact(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: ShapeDecoration(
          color: busy ? ZT.line : ZT.primary,
          shape: StadiumBorder(
              side: BorderSide(width: 1.4, color: busy ? ZT.edge : ZT.primary)),
          shadows: busy ? null : ZT.hard(dx: 2, dy: 2),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (busy)
            SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(strokeWidth: 1.8, color: ZT.inkSoft),
            )
          else
            Icon(Icons.compress_rounded, size: 13, color: ZT.onInk),
          const SizedBox(width: 5),
          Text(busy ? '压缩中…' : '压缩上下文',
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w800,
                  color: busy ? ZT.inkSoft : ZT.onInk)),
        ]),
      ),
    );
  }

  Future<void> _confirmCompact() async {
    final ctx = chat.effectiveContextTokens;
    final win = chat.usage?.contextWindow ?? 0;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx2) => AlertDialog(
        backgroundColor: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(ZT.radius),
          side: BorderSide(color: ZT.edge, width: 1.4),
        ),
        title: Text('压缩上下文', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: ZT.ink)),
        content: Text(
          win > 0 && ctx > 0
              ? '当前占用约 ${_fmtTokens(ctx)} / ${_fmtTokens(win)}。\n\n'
                  '压缩会把前面的对话总结成摘要,腾出空间继续干活。摘要会替代原文进入后续上下文,细节可能丢失。'
              : '压缩会把前面的对话总结成摘要,腾出空间继续干活。\n\n摘要会替代原文进入后续上下文,细节可能丢失。',
          style: TextStyle(fontSize: 13.5, height: 1.5, color: ZT.inkSoft),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx2, false),
            child: Text('取消', style: TextStyle(fontWeight: FontWeight.w700, color: ZT.inkSoft)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx2, true),
            child: Text('开始压缩', style: TextStyle(fontWeight: FontWeight.w800, color: ZT.primaryDeep)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final before = app.lastCompact;
    await app.compactContext();
    if (!mounted) return;
    showToast(context, app.error != null ? app.error! : '正在压缩上下文,完成后会提示…');
    // 压缩是异步的(CLI 要跑一会儿):轮询等结果,拿到就回执
    unawaited(_awaitCompact(before));
  }

  /// 等压缩结果(最多 60 秒),完成时给百分比式回执。
  Future<void> _awaitCompact(Object? before) async {
    for (var i = 0; i < 120; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!mounted) return;
      if (!app.compacting) {
        final c = app.lastCompact;
        if (c != null && !identical(c, before)) {
          final saved = c.pre - c.post;
          showToast(context,
              '上下文已压缩:${_fmtTokens(c.pre)} → ${_fmtTokens(c.post)}'
              '${saved > 0 ? '(省下 ${_fmtTokens(saved)})' : ''}');
        }
        return;
      }
    }
  }

  /// 大环形窗口占用:中间百分比,超 85% 变红提醒该压缩了。
  /// 上下文**不可能超过窗口**,所以 >100% 一定是旧口径(整轮累计)的历史数据 ——
  /// 这时显示「待更新」而不是 965% 这种吓人又无意义的数字,跑完新一轮自动变准。
  Widget _usageRing(int ctxTokens, int ctxWindow) {
    final rawFrac = ctxWindow > 0 ? ctxTokens / ctxWindow : 0.0;
    final stale = rawFrac > 1.0;
    final frac = rawFrac.clamp(0.0, 1.0);
    final pct = rawFrac * 100;
    final color = stale
        ? ZT.inkFaint
        : (frac > 0.85 ? ZT.rose : (frac > 0.6 ? ZT.lemon : ZT.aqua));
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: 96,
          height: 96,
          child: CircularProgressIndicator(
            value: stale ? 0 : frac,
            strokeWidth: 9,
            strokeCap: StrokeCap.round,
            backgroundColor: ZT.edge,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              stale
                  ? '待更新'
                  : (ctxTokens > 0 ? '${pct.toStringAsFixed(pct >= 100 ? 0 : 1)}%' : '—'),
              style: TextStyle(
                  fontSize: stale ? 12 : 17,
                  fontWeight: FontWeight.w900,
                  color: stale ? ZT.inkFaint : ZT.ink)),
          Text(stale ? '跑一轮后变准' : '窗口占用',
              style: TextStyle(fontSize: stale ? 8.5 : 10, color: ZT.inkFaint)),
        ]),
      ]),
    );
  }

  /// 指标行(图标 + 标签 + 值),用在环图右侧。
  Widget _statLine(IconData icon, Color color, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 11.5, color: ZT.inkFaint)),
        const Spacer(),
        Text(value,
            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: ZT.ink)),
      ]),
    );
  }

  /// 指标网格:每行 2 个,小卡片(参考稿的网格观感,但适配窄屏)。
  Widget _statGrid(List<(IconData, Color, String, String, String?)> items) {
    final rows = <Widget>[];
    for (var i = 0; i < items.length; i += 2) {
      final a = items[i];
      final b = i + 1 < items.length ? items[i + 1] : null;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _statTile(a)),
          const SizedBox(width: 6),
          Expanded(child: b == null ? const SizedBox.shrink() : _statTile(b)),
        ]),
      ));
    }
    return Column(children: rows);
  }

  Widget _statTile((IconData, Color, String, String, String?) t) {
    final (icon, color, label, value, sub) = t;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: ShapeDecoration(
        color: ZT.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(width: 1.1, color: ZT.edge),
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 10.5, color: ZT.inkFaint)),
        ]),
        const SizedBox(height: 2),
        Text(value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: ZT.ink)),
        if (sub != null)
          Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 9.5, color: ZT.inkFaint)),
      ]),
    );
  }

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

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    // 面板活跃态一次算好:右上角下拉与快捷条共用。
    final planOn = _stickyPlan != null || derivePlanSteps(chat.rows) != null;
    final subsOn = deriveSubagents(chat.rows).isNotEmpty;
    final bgOn = deriveBackgrounds(chat.rows).isNotEmpty;
    return Scaffold(
      backgroundColor: ZT.bg,
      appBar: _picking
          ? _pickingAppBar()
          : AppBar(
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
                // Token 总量只在会话列表卡片上显示(用户要求聊天页不显示,避免标题拥挤)
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
                // 锚行基线实时跟随滚动(手势/惯性/程序化引起的 y 变化全部吞进
                // 基线,不进补偿 —— 否则停稳后第一帧会把滚动距离回放一遍)
                _trackAnchorBaseline();
                // FollowLock 意图锁存:主动滚离(>exitPx)上锁,滚回 ≤releasePx 解锁
                final gap = _listCtrl.position.maxScrollExtent - _listCtrl.offset;
                if (FollowLock.shouldLock(
                    atBottomGap: gap,
                    locked: _followLocked,
                    maxScrollExtent: _listCtrl.position.maxScrollExtent)) {
                  _followLocked = true;
                } else if (_followLocked &&
                    FollowLock.shouldRelease(
                        atBottomGap: gap, maxScrollExtent: _listCtrl.position.maxScrollExtent)) {
                  _followLocked = false;
                }
                final away = _listCtrl.offset > 60;
                if (away != _listAway) setState(() => _listAway = away);
                // 滑到最旧端附近:按需拉更旧的一页(打开会话只拉了最新 100 条)。
                // reverse 列表 maxScrollExtent 就是"最旧端"。
                final pos = _listCtrl.position;
                if (chat.hasMoreOlder &&
                    !app.loadingOlder &&
                    pos.maxScrollExtent > 0 &&
                    pos.pixels > pos.maxScrollExtent - 400) {
                  unawaited(app.loadOlder());
                }
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
                        onTap: () => _toBottom(), // 动画期间会禁用锁位补偿,防互相打断卡住
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
          if (!_searching && !_picking) _queueBar(),
          if (!_searching && !_picking) _composer(),
          if (!_searching && !_picking) _quickBar(planOn, subsOn || bgOn),
          if (!_searching && _picking) _batchBar(),
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

  // ------------------------------------------------- 行级长按菜单 / 多选

  /// 行级手势层:长按弹动作菜单;多选态下点行 = 勾选。
  ///
  /// 包在**列表层**而不是各行 widget 内部:一处覆盖全部行类型(用户/助手/思考/
  /// 工具/报错),而且长按气泡留白也算数 —— 原来只有精确长按在文字上才有反应
  /// (SelectableText 的原生选字菜单),长按留白、图片消息、卡片空白处一律没反应,
  /// 用户的体感就是「长按没反应」。行内文字已一并改为不可选中(见 rows.dart
  /// MarkdownBody.selectable 的说明),长按手势才能完整归这里。
  Widget _wrapRow(ChatRow data, Widget row) {
    if (_picking) {
      final on = _picked.contains(data);
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _togglePick(data),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 11, right: 8),
            child: Icon(
              on ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 17,
              color: on ? ZT.primary : ZT.inkFaint,
            ),
          ),
          Expanded(child: row),
        ]),
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 用按下的**全局坐标**定位菜单,不做 RenderBox 换算:行在 reverse 列表里被
      // 回收/复用,拿 box 反而容易算歪。
      onLongPressStart: (d) => _openRowMenu(data, d.globalPosition),
      child: row,
    );
  }

  /// 长按浮出动作菜单(微信式:贴着按下的位置,越界由 showMenu 自己收敛)。
  Future<void> _openRowMenu(ChatRow data, Offset at) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final action = await showMenu<RowAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(at.dx, at.dy, 1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final item in rowMenuFor(data))
          PopupMenuItem<RowAction>(
            value: item.action,
            height: 42,
            // 不写死颜色:文案样式由 theme.popupMenuTheme 按亮暗主题给
            child: Text(item.label),
          ),
      ],
    );
    if (action == null || !mounted) return;
    await _runRowAction(data, action);
  }

  Future<void> _runRowAction(ChatRow data, RowAction action) async {
    switch (action) {
      case RowAction.selectText:
        await showTextSelectSheet(
          context,
          title: rowRoleLabel(data),
          text: selectableTextFor(data),
        );
      case RowAction.quote:
        if (chat.running) {
          showToast(context, '当前回合运行中,结束后再引用发送');
          return;
        }
        app.sendChat(
            '【引用 ${rowRoleLabel(data)} 的消息】\n${rowCopyText(data)}\n\n请基于以上内容继续');
      case RowAction.multiSelect:
        _enterPicking(data);
      case RowAction.copyAll:
      case RowAction.copyPlain:
      case RowAction.copyToolInput:
      case RowAction.copyToolOutput:
        final text = copyPayloadFor(data, action) ?? '';
        if (text.trim().isEmpty) {
          showToast(context, '这条没有可复制的文字');
          return;
        }
        await _copyText(text);
    }
  }

  Future<void> _copyText(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    await HapticFeedback.selectionClick();
    if (mounted) showToast(context, '已复制');
  }

  void _enterPicking(ChatRow first) => setState(() {
        _picking = true;
        _picked
          ..clear()
          ..add(first);
      });

  void _exitPicking() => setState(() {
        _picking = false;
        _picked.clear();
      });

  void _togglePick(ChatRow row) => setState(() {
        if (!_picked.remove(row)) _picked.add(row);
      });

  void _pickAll() => setState(() {
        final all = chat.rows.toSet();
        if (all.isNotEmpty && _picked.containsAll(all)) {
          _picked.clear();
        } else {
          _picked
            ..clear()
            ..addAll(all);
        }
      });

  /// 复制已选:按**时间正序**(聊天顺序,不是勾选顺序)拼接,带角色前缀。
  Future<void> _copyPicked() async {
    final ordered = chat.rows.where(_picked.contains).toList();
    if (ordered.isEmpty) {
      showToast(context, '还没选消息');
      return;
    }
    await _copyText(composeSelection(ordered));
    if (mounted) _exitPicking();
  }

  /// 多选态的顶部条(替换普通标题):对齐会话页 _pickingAppBar 的既有做法。
  AppBar _pickingAppBar() {
    final all = chat.rows;
    final allPicked = all.isNotEmpty && _picked.length >= all.length;
    return AppBar(
      leading: IconButton(
        tooltip: '退出多选',
        icon: const Icon(Icons.close_rounded, size: 22),
        onPressed: _exitPicking,
      ),
      title: Text('已选 ${_picked.length} / ${all.length}',
          style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: ZT.ink)),
      actions: [
        IconButton(
          tooltip: allPicked ? '取消全选' : '全选',
          icon: Icon(allPicked ? Icons.deselect_rounded : Icons.select_all_rounded,
              size: 21),
          onPressed: _pickAll,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 多选态的底部条:替换输入区(批量选择时不该还能打字/发消息)。
  Widget _batchBar() {
    final enabled = _picked.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: InkWell(
          borderRadius: BorderRadius.circular(ZT.radius),
          onTap: enabled ? _copyPicked : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: ShapeDecoration(
              color: ZT.primary,
              shape: StadiumBorder(
                  side: BorderSide(width: 1.4, color: ZT.primaryDeep)),
              shadows: enabled ? ZT.hard(dx: 2, dy: 2) : null,
            ),
            child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.content_copy_rounded, size: 15, color: ZT.onInk),
                  const SizedBox(width: 6),
                  Text('复制已选 ${_picked.length} 条',
                      style: TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w800, color: ZT.onInk)),
                ]),
          ),
        ),
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
    // 行入场动画水位:只有"逐条增长"才播 180ms 淡入。
    // ⚠️ 换底/加载时 rows 会一次性暴涨(实测 500 → 6617):按旧水位算,几千行被当成
    // "新行"同时建动画,而流式每秒重建几十次 → 动画反复重启,整屏 opacity 长期接近 0
    // = 白屏(用户实测;日志里 rows 正常增长、无异常,所以不是数据问题)。
    // 单次增长超过 kMaxFreshRows 就认定是换底/加载:水位直接对齐,一行都不播。
    // 停止盲区复位:回合一旦落定(complete/error/abort 任一到达),乐观的"停止中"
    // 必须清掉。原来只在发送新消息时复位 —— 于是回合自然结束后再开新一轮,
    // 按钮一上来就是「停止中…」转圈且禁用(onTap 为 null),按不动(实测"停不掉")。
    if (_stopping && !chat.running) _stopping = false;
    final anim = advanceAnimWatermark(
        current: _animatedUpTo, rowCount: rows.length, loading: app.historyLoading);
    final freshFrom = anim.freshFrom;
    _animatedUpTo = anim.watermark;

    return ListView.builder(
      reverse: true,
      controller: _listCtrl,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      itemCount: rows.length + 2,
      itemBuilder: (context, i) {
        if (i < rows.length) {
          final data = rows[rows.length - 1 - i];
          final row = _wrapRow(data, buildChatRow(data));
          // reverse 列表 i 越小越新:新增行(未过水位)播 fade+slide 180ms 入场
          if (i < rows.length - freshFrom) {
            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: kDurNormal,
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
          // 最旧端:显示"加载更早"状态(打开会话只拉了最新 100 条,更旧的按需取)
          final olderHint = app.loadingOlder
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2, color: ZT.primary)),
                    const SizedBox(width: 8),
                    Text('正在加载更早的消息…',
                        style: TextStyle(fontSize: 12, color: ZT.inkFaint)),
                  ]),
                )
              : chat.hasMoreOlder
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Center(
                        child: Text('滑到顶会自动加载更早的消息',
                            style: TextStyle(fontSize: 11.5, color: ZT.inkFaint)),
                      ),
                    )
                  : const SizedBox.shrink();
          return Column(children: [
            olderHint,
            if (app.historyLoading)
              Padding(
                padding: const EdgeInsets.all(14),
                child: Center(
                    child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: ZT.primary))),
              )
            else
              _sessionHeader(),
          ]);
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
              // 限高 + 内部滚动(reverse:锚定最新):流式面板只当一行「正在回复」
              // 进度条用(用户裁定 2026-09-14:1/10 屏,对齐 zremote 面板封顶标准),
              // 长输出内部滚动跟尾,绝不挤压历史阅读区。
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.10),
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
          // 流式思考:默认一行摘要,点开看全文(限高 30% 屏 + 内部滚动,
          // 不把聊天区挤没)。用户要求"深度思考要能展开"。
          Container(
            margin: const EdgeInsets.only(top: 8, right: 24),
            decoration: BoxDecoration(
              color: ZT.surface,
              borderRadius: BorderRadius.circular(ZT.radius),
              border: Border.all(width: 1.2, color: ZT.grape.withValues(alpha: ZT.palette.neoShadow ? 1 : 0.5)),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(ZT.radius),
                onTap: () => setState(() => _thinkingExpanded = !_thinkingExpanded),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      PulseDot(color: ZT.grape, animate: true, size: 6),
                      const SizedBox(width: 6),
                      Text('深度思考中',
                          style: TextStyle(
                              fontSize: 11, fontWeight: FontWeight.w800, color: ZT.grape)),
                      const Spacer(),
                      if (!_thinkingExpanded)
                        Flexible(
                          child: Text(thinking,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11, color: ZT.inkFaint, fontStyle: FontStyle.italic)),
                        ),
                      const SizedBox(width: 4),
                      Icon(_thinkingExpanded ? Icons.expand_less : Icons.expand_more,
                          size: 15, color: ZT.inkFaint),
                    ]),
                    if (_thinkingExpanded)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                              maxHeight: MediaQuery.of(context).size.height * 0.3),
                          child: SingleChildScrollView(
                            reverse: true, // 思考是持续追加的:锚定最新一行
                            child: SelectableText(thinking,
                                style: TextStyle(
                                    fontSize: 11.5, height: 1.45,
                                    color: ZT.inkSoft, fontStyle: FontStyle.italic)),
                          ),
                        ),
                      ),
                  ]),
                ),
              ),
            ),
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
        // 已选图片预览条:64px 小缩略图(对齐 zremote),点图滑动预览,右上角 X 移除
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
                  separatorBuilder: (_, _) => const SizedBox(width: 6),
                  itemBuilder: (context, i) => Stack(children: [
                    GestureDetector(
                      onTap: () => showChatImageViewer(context, images, initialIndex: i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: chatImageThumb(images[i], size: 64),
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

/// 输入区右侧按钮形态(纯函数,便于测试)。
enum ComposerButtons {
  /// 空闲:只有发送键
  send,

  /// 回合进行中且输入框为空:只有停止键(保持干净)
  stop,

  /// 回合进行中且输入框有内容(文字/图片/附件):发送 + 停止双键
  sendAndStop,
}

/// 判定规则:
/// - [canStop] = 在线且在跑(断线时 running 可能是冻结假象,不认);
/// - 运行中只要有输入就给发送键——否则用户打了字/选了图却没有入口发出去
///   (原来运行中整个按钮被停止键取代,排队/插话功能等于摸不到)。
ComposerButtons composerButtonsOf({required bool canStop, required bool hasText}) {
  if (!canStop) return ComposerButtons.send;
  return hasText ? ComposerButtons.sendAndStop : ComposerButtons.stop;
}

class _SendOrStopState extends State<_SendOrStop> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    switch (composerButtonsOf(canStop: widget.canStop, hasText: widget.hasText)) {
      case ComposerButtons.stop:
        return _stopButton();
      case ComposerButtons.sendAndStop:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          _sendButton(enabled: true),
          const SizedBox(width: 7),
          _stopButton(),
        ]);
      case ComposerButtons.send:
        return _sendButton(enabled: widget.hasText);
    }
  }

  /// 停止键(带乐观反馈:点下瞬间转「停止中」,不等 CLI 掐断流再转回)
  Widget _stopButton() {
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

  Widget _sendButton({required bool enabled}) {
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
