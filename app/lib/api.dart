import 'dart:convert';
import 'dart:io';

/// REST 异常:非 2xx 或网络错误统一包一层。
class ZApiException implements Exception {
  final int? status;
  final String message;
  const ZApiException(this.message, {this.status});

  @override
  String toString() => status == null ? message : 'HTTP $status: $message';
}

/// JSON HTTP 传输 seam:测试注入假件,运行时走 HttpClient。
typedef HttpFn = Future<Object?> Function(String method, String path, Object? body);

/// zcode-server REST 客户端(Bearer token)。
class ZApi {
  ZApi({required this.baseUrl, required this.token, HttpFn? http})
      : _http = http ?? io(baseUrl: baseUrl, token: token);

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

  /// 默认 HttpClient 实现(工厂方法里绑 baseUrl/token)。
  static HttpFn io({required String baseUrl, required String token}) {
    return (method, path, body) async {
      final client = HttpClient();
      try {
        final req = await client.openUrl(method, Uri.parse('$baseUrl$path'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        if (body != null) req.add(utf8.encode(jsonEncode(body)));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        if (res.statusCode >= 300) {
          throw ZApiException(text.isEmpty ? res.reasonPhrase : text,
              status: res.statusCode);
        }
        return text.isEmpty ? null : jsonDecode(text);
      } finally {
        client.close(force: true);
      }
    };
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
