// 浏览器实现:package:http(底层 fetch/XHR)。跨域靠 server 的 CORS 头。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'http_fn.dart';

HttpFn platformHttp({required String baseUrl, required String token}) {
  final client = http.Client();
  return (method, path, body) async {
    final req = http.Request(method, Uri.parse('$baseUrl$path'))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json';
    if (body != null) req.bodyBytes = utf8.encode(jsonEncode(body));
    try {
      final res = await http.Response.fromStream(await client.send(req))
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 300) {
        throw ZApiException(
          res.body.isEmpty ? (res.reasonPhrase ?? 'error') : res.body,
          status: res.statusCode,
          // 401 = 令牌失效:此前全落 server,「令牌失效请重新登录」文案与自动登出永不触发(审计 #5)
          kind: res.statusCode == 401 ? ApiErrorKind.auth : ApiErrorKind.server,
        );
      }
      return res.body.isEmpty ? null : jsonDecode(res.body);
    } on TimeoutException {
      throw const ZApiException('服务器没有响应(超时)');
    }
  };
}
