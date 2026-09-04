// 浏览器实现:package:http(底层 fetch/XHR)。跨域靠 server 的 CORS 头。
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
    final res = await http.Response.fromStream(await client.send(req));
    if (res.statusCode >= 300) {
      throw ZApiException(
          res.body.isEmpty ? (res.reasonPhrase ?? 'error') : res.body,
          status: res.statusCode);
    }
    return res.body.isEmpty ? null : jsonDecode(res.body);
  };
}
