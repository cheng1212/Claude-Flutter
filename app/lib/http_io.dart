// 原生平台(iOS/Android/桌面)实现:dart:io HttpClient。
import 'dart:convert';
import 'dart:io';

import 'http_fn.dart';

HttpFn platformHttp({required String baseUrl, required String token}) {
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
        throw ZApiException(text.isEmpty ? res.reasonPhrase : text, status: res.statusCode);
      }
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close(force: true);
    }
  };
}
