// 按平台选择 HTTP 实现:web 走 fetch,原生走 dart:io。
export 'http_io.dart' if (dart.library.js_interop) 'http_web.dart';
