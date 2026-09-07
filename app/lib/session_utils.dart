// 会话列表状态徽章与筛选(Dart,与 Flutter 页面解耦,可单测)。

/// 筛选维度(对应参考稿 chips:全部/置顶/归档/项目)。
enum SessionFilter { all, pinned, archived, project }

/// 兼容读取:服务端 snake_case / 部分客户端 camelCase。
dynamic fieldOf(Map<String, dynamic> s, List<String> keys) {
  for (final k in keys) {
    final v = s[k];
    if (v != null) return v;
  }
  return null;
}

List<String> tagsOf(Map<String, dynamic> s) {
  final raw = fieldOf(s, ['tags']);
  if (raw is List) return [for (final t in raw) '$t'];
  if (raw is String && raw.isNotEmpty) {
    try {
      final decoded = raw.replaceAll('&#39;', "'").replaceAll('&quot;', '"');
      if (decoded.startsWith('[')) {
        final inner = decoded.substring(1, decoded.length - 1);
        if (inner.trim().isEmpty) return const [];
        return inner.split(',').map((e) => e.trim().replaceAll('"', '').replaceAll("'", '')).where((e) => e.isNotEmpty).toList();
      }
    } catch (_) {
      return const [];
    }
  }
  return const [];
}

/// 状态徽章:label + 语义色(kind 与 theme.dart 角色色对应)。
({String label, String kind})? statusBadgeOf(Map<String, dynamic> s) {
  if (fieldOf(s, ['isRunning']) == true) return (label: '进行中', kind: 'running');
  switch ('${fieldOf(s, ['last_status', 'lastStatus']) ?? ''}') {
    case 'success':
      return (label: '已完成', kind: 'done');
    case 'error':
      return (label: '失败', kind: 'failed');
    case 'aborted':
    case 'interrupted':
      return (label: '已暂停', kind: 'paused');
    default:
      return (label: '已结束', kind: 'ended');
  }
}

bool _archivedOf(Map<String, dynamic> s) {
  final v = fieldOf(s, ['archived']);
  return v == 1 || v == true;
}

bool _pinnedOf(Map<String, dynamic> s) {
  final v = fieldOf(s, ['isPinned', 'is_pinned']);
  return v == 1 || v == true;
}

/// 按维度 + 关键词过滤(标题/预览/项目名/模型包含,大小写不敏感)。
List<Map<String, dynamic>> filterSessions(
  List<Map<String, dynamic>> sessions, {
  required SessionFilter filter,
  String? query,
  String? project,
}) {
  final q = (query ?? '').trim().toLowerCase();
  bool matchQuery(Map<String, dynamic> s) {
    if (q.isEmpty) return true;
    final preview = '${fieldOf(s, ['last_preview', 'lastMessage', 'last_message'])}';
    final hay = '${s['title'] ?? ''} $preview ${s['project'] ?? ''} ${s['model'] ?? ''} ${tagsOf(s).join(' ')}'.toLowerCase();
    return hay.contains(q);
  }

  return sessions.where((s) {
    final archived = _archivedOf(s);
    switch (filter) {
      case SessionFilter.all:
        if (archived) return false;
      case SessionFilter.pinned:
        if (archived || !_pinnedOf(s)) return false;
      case SessionFilter.archived:
        if (!archived) return false;
      case SessionFilter.project:
        if (archived) return false;
        if (project != null && '${s['project'] ?? ''}' != project) return false;
    }
    return matchQuery(s);
  }).toList();
}

/// 倒计时格式:1天2小时 / 2小时03分 / 5分12秒 / 8秒。
String formatCountdown(Duration d) {
  if (d.isNegative) return '已到点';
  if (d.inDays > 0) return '${d.inDays}天${d.inHours % 24}小时';
  if (d.inHours > 0) return '${d.inHours}小时${(d.inMinutes % 60).toString().padLeft(2, '0')}分';
  if (d.inMinutes > 0) return '${d.inMinutes}分${(d.inSeconds % 60).toString().padLeft(2, '0')}秒';
  return '${d.inSeconds}秒';
}

String _clock(DateTime t) =>
    '${t.month}月${t.day}日 ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// 定时任务下次触发文案:本地钟表时刻 + 剩余倒计时;
/// 已过点只给时刻(CLI 活着才会补触发);空/坏值给「无排期」。
String cronNextLabel(String? nextFireIso, DateTime now) {
  final t = DateTime.tryParse(nextFireIso ?? '')?.toLocal();
  if (t == null) return '无排期';
  final d = t.difference(now);
  return d.isNegative ? _clock(t) : '${_clock(t)} · ${formatCountdown(d)}后';
}

/// 循环任务的 7 天自动过期文案;一次性任务/无创建时间不显示(返回 null)。
String? cronExpiryLabel(String? createdAtIso, {required bool recurring}) {
  if (!recurring) return null;
  final t = DateTime.tryParse(createdAtIso ?? '')?.toLocal();
  if (t == null) return null;
  return '${_clock(t.add(const Duration(days: 7)))} 自动过期';
}

/// 会话相位:状态 chip 与发送/停止按钮的唯一判据。
/// 连接不在位时一律「断线」——运行中状态在断网期间会冻结成假象
/// (complete 事件永远到不了),此时停止无效、发送必败,UI 不许装作还在运行。
String chatPhase({required bool running, required bool hasPermission, required bool socketOpen}) {
  if (!socketOpen) return 'reconnecting';
  if (hasPermission) return 'permission';
  if (running) return 'running';
  return 'idle';
}

/// 项目 cwd 拼接:分隔符认服务器的(总目录里带 \ 就是 Windows 路径),
/// 手机端是 Android,不能用本机分隔符。
String joinProjectCwd(String root, String name) {
  if (root.isEmpty) return name;
  if (root.endsWith('\\') || root.endsWith('/')) return '$root$name';
  final sep = root.contains('\\') ? '\\' : '/';
  return '$root$sep$name';
}

/// 思考等级选项随模型变:deepseek 系三档(低/中/高),qwen 系与其他 开/关。
/// value:low/medium/high = SDK thinking 预算分级;'on' = 不注入(模型默认开);
/// 'off' = 注入 disabled。实测 DeepSeek 开关真实生效、预算弱分级;GLM 忽略参数。
List<(String, String)> thinkingOptionsFor(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('deepseek')) {
    return [('低', 'low'), ('中', 'medium'), ('高', 'high')];
  }
  return [('开', 'on'), ('关', 'off')];
}
