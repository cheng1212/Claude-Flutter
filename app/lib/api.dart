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

  Future<void> patchSession(String id, {String? title, bool? isPinned, String? model, String? permissionMode}) async {
    await _call('PATCH', '/api/sessions/$id', {
      'title': ?title,
      'isPinned': ?isPinned,
      'model': ?model,
      'permissionMode': ?permissionMode,
    });
  }

  Future<void> deleteSession(String id) async {
    await _call('DELETE', '/api/sessions/$id', null);
  }

  /// 历史消息:{messages:[…], total};行内 meta 是完整出站事件(含 seq)。
  Future<({List<Map<String, dynamic>> messages, int total})> messages(String id, {int limit = 500}) async {
    final res = await _call('GET', '/api/sessions/$id/messages?limit=$limit', null);
    if (res is! Map) return (messages: const <Map<String, dynamic>>[], total: 0);
    final list = (res['messages'] as List? ?? const []);
    return (
      messages: [for (final m in list) (m as Map).cast<String, dynamic>()],
      total: (res['total'] as num?)?.toInt() ?? 0,
    );
  }
}
