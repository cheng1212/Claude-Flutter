import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/ui/rows.dart';

String _uriOf(int size) => 'data:image/png;base64,${base64Encode(Uint8List(size))}';

void main() {
  test('同一 uri 只解一次(命中缓存)', () {
    debugClearImageCache();
    final uri = _uriOf(16);
    final first = debugDecodeDataUri(uri);
    final again = debugDecodeDataUri(uri);
    expect(first, isNotNull);
    expect(identical(first, again), isTrue);
    expect(debugImageCacheSize(), 1);
  });

  test('坏 uri 返回 null 且不进缓存', () {
    debugClearImageCache();
    expect(debugDecodeDataUri('not-a-data-uri'), isNull);
    expect(debugDecodeDataUri('data:text/plain;base64,AAAA'), isNull);
    expect(debugImageCacheSize(), 0);
  });

  test('缓存 FIFO 上限 64,最旧的先被淘汰(重解得到新实例)', () {
    debugClearImageCache();
    final oldest = _uriOf(1);
    final oldestBytes = debugDecodeDataUri(oldest);
    for (var i = 0; i < 70; i++) {
      debugDecodeDataUri(_uriOf(8 + i));
    }
    expect(debugImageCacheSize(), 64);
    final reDecoded = debugDecodeDataUri(oldest);
    expect(reDecoded, isNotNull);
    expect(identical(oldestBytes, reDecoded), isFalse);
  });

  test('清缓存后缓存量归零', () {
    debugClearImageCache();
    debugDecodeDataUri(_uriOf(4));
    expect(debugImageCacheSize(), 1);
    debugClearImageCache();
    expect(debugImageCacheSize(), 0);
  });
}
