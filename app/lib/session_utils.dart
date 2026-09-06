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
