// 原生平台(iOS/Android/桌面)实现:dart:io HttpClient。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'http_fn.dart';

HttpFn platformHttp({required String baseUrl, required String token}) {
  return (method, path, body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client
          .openUrl(method, Uri.parse('$baseUrl$path'))
          .timeout(const Duration(seconds: 10));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      if (body != null) {
        // 无 body 的 DELETE/GET 不能带 application/json,Fastify 会 400
        // (FST_ERR_CTP_EMPTY_JSON_BODY)
        req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
        req.add(utf8.encode(jsonEncode(body)));
      }
      final res = await req.close().timeout(const Duration(seconds: 10));
      final text =
          await res.transform(utf8.decoder).join().timeout(const Duration(seconds: 20));
      if (res.statusCode >= 300) {
        throw ZApiException(text.isEmpty ? res.reasonPhrase : text, status: res.statusCode);
      }
      return text.isEmpty ? null : jsonDecode(text);
    } on TimeoutException {
      // finally 里 force close 会掐掉底层 socket,不会留悬挂连接
      throw const ZApiException('服务器没有响应(超时)');
    } finally {
      client.close(force: true);
    }
  };
}
