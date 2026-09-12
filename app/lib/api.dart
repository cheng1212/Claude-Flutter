// zcode-server REST 客户端(Bearer token)。HTTP 实现按平台条件导入。
import 'dart:convert' show base64Encode;
import 'dart:math' show min;
import 'http_default.dart';
import 'http_fn.dart';

export 'http_fn.dart' show HttpFn, ZApiException;

class ZApi {
  ZApi({required this.baseUrl, required this.token, HttpFn? http})
      : _http = http ?? platformHttp(baseUrl: baseUrl, token: token);

  final String baseUrl; // 形如 http://192.168.x.x:5190
  final String token;
  final HttpFn _http;

  Future<Object?> _call(String method, String path, Object? body) async {
    try {
      return await _http(method, path, body);
    } on ZApiException {
      rethrow;
    } on Object catch (e) {
      throw ZApiException('$e');
    }
  }

  Future<List<String>> models() async {
    final res = await _call('GET', '/api/models', null);
    return [if (res is List) for (final m in res) '$m'];
  }

  /// 分组模型:/api/models/grouped → [{id,label,models:[{id,label}]}]
  Future<List<Map<String, dynamic>>> modelGroups() async {
    final res = await _call('GET', '/api/models/grouped', null);
    final groups = (res is Map ? res['groups'] : null);
    if (groups is List) {
      return [for (final g in groups) (g as Map).cast<String, dynamic>()];
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> sessions() async {
    final res = await _call('GET', '/api/sessions', null);
    if (res is List) {
      return [for (final s in res) (s as Map).cast<String, dynamic>()];
    }
    return const [];
  }

  Future<Map<String, dynamic>> createSession({String? title, String? cwd, String? model}) async {
    final res = await _call('POST', '/api/sessions', {
      'title': ?title,
      'cwd': ?cwd,
      'model': ?model,
    });
    return (res as Map).cast<String, dynamic>();
  }

  Future<void> patchSession(String id, {String? title, bool? isPinned, String? model, String? permissionMode, bool? archived, List<String>? tags, String? cwd}) async {
    await _call('PATCH', '/api/sessions/$id', {
      'title': ?title,
      'isPinned': ?isPinned,
      'model': ?model,
      'permissionMode': ?permissionMode,
      'archived': ?archived,
      'tags': ?tags,
      'cwd': ?cwd,
    });
  }

  /// 复制会话:服务端拷贝消息与配置,fork_from 记源 CLI 会话(下一轮 send 时分叉)。
  Future<Map<String, dynamic>> forkSession(String id) async {
    final res = await _call('POST', '/api/sessions/$id/fork', null);
    return (res as Map).cast<String, dynamic>();
  }

  /// 定时任务列表(active,含 next_fire)。
  Future<List<Map<String, dynamic>>> crons({String? sessionId}) async {
    final res = await _call('GET', sessionId == null ? '/api/crons' : '/api/crons?session=$sessionId', null);
    final list = res is Map ? res['crons'] : null;
    if (list is List) return [for (final c in list) (c as Map).cast<String, dynamic>()];
    return const [];
  }

  /// 删除定时任务(标记删除)。
  Future<void> deleteCron(String id) async {
    await _call('DELETE', '/api/crons/$id', null);
  }

  /// 项目文件夹:总目录 + 其下项目名列表。
  Future<({String root, List<String> names})> projects() async {
    final res = await _call('GET', '/api/projects', null);
    if (res is! Map) return (root: '', names: const <String>[]);
    final list = res['projects'] as List? ?? const [];
    final names = [for (final p in list) if (p is Map) '${p['name']}'];
    return (root: '${res['root'] ?? ''}', names: names);
  }

  /// 新建项目文件夹,返回其 cwd;失败抛错(调用方提示)。
  Future<String> createProject(String name) async {
    final res = await _call('POST', '/api/projects', {'name': name});
    if (res is Map && res['cwd'] != null) return '${res['cwd']}';
    throw Exception('新建项目失败');
  }

  /// 项目重命名:文件夹改名,其下会话 cwd 同步迁移;失败抛错。
  Future<void> renameProject(String oldName, String newName) async {
    await _call('PATCH', '/api/projects/${Uri.encodeComponent(oldName)}', {'name': newName});
  }

  /// 删除项目:递归删文件夹并级联删其下全部会话;失败抛错。
  Future<void> deleteProject(String name) async {
    await _call('DELETE', '/api/projects/${Uri.encodeComponent(name)}', null);
  }

  /// 全局用量聚合:?range=7d|30d|all;形状认不出返回 null。
  Future<Map<String, dynamic>?> usageStats(String range) async {
    final res = await _call('GET', '/api/usage?range=$range', null);
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  /// 完整重载:server 从磁盘 CLI 转录补回丢失事件(幂等),返回 {ok, merged}。
  Future<int> reloadSession(String id) async {
    final res = await _call('POST', '/api/sessions/$id/reload', null);
    final map = res is Map ? res.cast<String, dynamic>() : const <String, dynamic>{};
    return (map['merged'] as num?)?.toInt() ?? 0;
  }

  /// 导出会话为 markdown:服务端拼好,返回 {filename, markdown}。
  Future<({String filename, String markdown})> exportSession(String id) async {
    final res = await _call('GET', '/api/sessions/$id/export', null);
    final map = res is Map ? res.cast<String, dynamic>() : const <String, dynamic>{};
    return (filename: '${map['filename'] ?? '会话.md'}', markdown: '${map['markdown'] ?? ''}');
  }

  /// 后台任务(server 统一登记:Bash 旧行为 + SDK task_*;行含状态/时长/summary/输出尾)。
  Future<List<Map<String, dynamic>>> backgrounds(String id) async {
    final res = await _call('GET', '/api/sessions/$id/backgrounds', null);
    if (res is! Map) return const <Map<String, dynamic>>[];
    final list = res['backgrounds'] as List? ?? const [];
    return [for (final b in list) if (b is Map) b.cast<String, dynamic>()];
  }

  /// 子代理列表(磁盘转录 + meta 元数据):agentId/类型/描述/深度等。
  Future<List<Map<String, dynamic>>> subagents(String id) async {
    final res = await _call('GET', '/api/sessions/$id/subagents', null);
    if (res is! Map) return const <Map<String, dynamic>>[];
    final list = res['subagents'] as List? ?? const [];
    return [for (final b in list) if (b is Map) b.cast<String, dynamic>()];
  }

  /// 子代理转录(只读):按转录行序还原的消息事件。
  Future<List<Map<String, dynamic>>> subagentMessages(String id, String agentId) async {
    final res = await _call('GET', '/api/sessions/$id/subagents/$agentId/messages', null);
    if (res is! Map) return const <Map<String, dynamic>>[];
    final list = res['messages'] as List? ?? const [];
    return [for (final b in list) if (b is Map) b.cast<String, dynamic>()];
  }

  Future<void> deleteSession(String id) async {
    await _call('DELETE', '/api/sessions/$id', null);
  }

  /// 上传文件到当前会话:bytes 走 base64 JSON 直传(server 解码存 cwd/uploads/)。
  /// [onProgress] 按已编码比例近似上报(0.0~1.0);返回电脑上的绝对路径。
  Future<String> uploadFile(String sessionId, String fileName, List<int> bytes,
      {void Function(double progress)? onProgress}) async {
    // base64 分块编码,边编码边上报进度(编码完 = 发送完,本端点为小文件直传)
    // 块长必须是 3 的倍数:base64 按 3 字节对齐,各块独立编码拼接才不会错位;改块长务必保住这一点
    const chunk = 3 * 256 * 1024; // 768KB 原始字节/块
    assert(chunk % 3 == 0);
    var done = 0;
    final parts = <String>[];
    while (done < bytes.length) {
      final end = min(done + chunk, bytes.length);
      parts.add(base64Encode(bytes.sublist(done, end)));
      done = end;
      onProgress?.call(done / bytes.length);
    }
    final dataB64 = parts.join();
    final res = await _call('POST', '/api/sessions/$sessionId/files',
        {'fileName': fileName, 'dataB64': dataB64});
    if (res is Map && res['path'] != null) return '${res['path']}';
    throw ZApiException('上传响应缺少 path');
  }

  /// 批量删除:一次请求;幂等,已删过的 id 记入 missing 不报错。
  Future<({int deleted, List<String> missing})> deleteSessions(List<String> ids) async {
    final res = await _call('POST', '/api/sessions/batch-delete', {'ids': ids});
    final map = res is Map ? res : const {};
    return (
      deleted: (map['deleted'] as num?)?.toInt() ?? 0,
      missing: [if (map['missing'] is List) for (final m in map['missing'] as List) '$m'],
    );
  }

  /// 会话用量聚合:累计 token/缓存/费用 + 最近一轮上下文占用 + 消息构成。
  Future<Map<String, dynamic>?> sessionUsage(String id) async {
    final res = await _call('GET', '/api/sessions/$id/usage', null);
    return res is Map ? res.cast<String, dynamic>() : null;
  }

  /// 历史消息:{messages:[…], total};行内 meta 是完整出站事件(含 seq)。
  /// beforeSeq 给"比该 seq 更旧的一页"——分页期间新消息插入(更高 seq)时,
  /// offset 窗口会整体上移丢一截;按 seq 锚点翻页则免疫漂移。
  Future<({List<Map<String, dynamic>> messages, int total})> messages(String id, {int limit = 500, int offset = 0, int? beforeSeq}) async {
    final q = beforeSeq != null
        ? 'limit=$limit&beforeSeq=$beforeSeq'
        : 'limit=$limit&offset=$offset';
    final res = await _call('GET', '/api/sessions/$id/messages?$q', null);
    if (res is! Map) return (messages: const <Map<String, dynamic>>[], total: 0);
    final list = (res['messages'] as List? ?? const []);
    return (
      messages: [for (final m in list) (m as Map).cast<String, dynamic>()],
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }
}
