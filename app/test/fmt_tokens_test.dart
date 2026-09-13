import 'package:flutter_test/flutter_test.dart';
import 'package:zcode_app/session_utils.dart';

void main() {
  test('fmtTokens 按量级自适应单位(不是一律转兆)', () {
    expect(fmtTokens(0), '0');
    expect(fmtTokens(872), '872'); // 千以内原数
    expect(fmtTokens(1000), '1.0K');
    expect(fmtTokens(1234), '1.2K');
    expect(fmtTokens(48213), '48.2K');
    expect(fmtTokens(482000), '482K'); // ≥100 取整
    expect(fmtTokens(1048215), '1.0M');
    expect(fmtTokens(4712345), '4.7M');
    expect(fmtTokens(104821456), '105M'); // ≥100M 取整(用户示例:104 兆级,一眼可读)
    expect(fmtTokens(104800000), '105M');
    expect(fmtTokens(1234567890), '1.2G');
  });
}
