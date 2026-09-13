// HTTP 传输 seam 的类型:平台无关,io/web 两套实现各自实现 HttpFn。
typedef HttpFn = Future<Object?> Function(String method, String path, Object? body);

/// REST 异常:非 2xx 或网络错误统一包一层。
/// 错误类别(T7 错误类型化):network=连不上/超时,server=服务端 5xx/业务错,
/// auth=令牌失效。UI 只 switch kind 渲染,不再各自拼文案。
enum ApiErrorKind { network, auth, server }

class ZApiException implements Exception {
  final int? status;
  final String message;
  final ApiErrorKind kind;
  const ZApiException(this.message, {this.status, this.kind = ApiErrorKind.server});

  @override
  String toString() => status == null ? message : 'HTTP $status: $message';
}

/// 错误 → 用户文案的唯一映射点(UI 不得再手拼 $e)。
String apiErrorMessage(Object e) {
  if (e is ZApiException) {
    return switch (e.kind) {
      ApiErrorKind.network => '连不上服务器(检查地址/网络)',
      ApiErrorKind.auth => '令牌失效,请重新登录',
      _ => e.message,
    };
  }
  return '$e';
}
