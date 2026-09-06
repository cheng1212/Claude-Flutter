// zcode-server REST 客户端(Bearer token)。HTTP 实现按平台条件导入。
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

  Future<void> deleteSession(String id) async {
    await _call('DELETE', '/api/sessions/$id', null);
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
  Future<({List<Map<String, dynamic>> messages, int total})> messages(String id, {int limit = 500, int offset = 0}) async {
    final res = await _call('GET', '/api/sessions/$id/messages?limit=$limit&offset=$offset', null);
    if (res is! Map) return (messages: const <Map<String, dynamic>>[], total: 0);
    final list = (res['messages'] as List? ?? const []);
    return (
      messages: [for (final m in list) (m as Map).cast<String, dynamic>()],
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }
}
