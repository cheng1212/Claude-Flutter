// HTTP 传输 seam 的类型:平台无关,io/web 两套实现各自实现 HttpFn。
typedef HttpFn = Future<Object?> Function(String method, String path, Object? body);

/// REST 异常:非 2xx 或网络错误统一包一层。
class ZApiException implements Exception {
  final int? status;
  final String message;
  const ZApiException(this.message, {this.status});

  @override
  String toString() => status == null ? message : 'HTTP $status: $message';
}
