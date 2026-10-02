import { describe, test, expect } from 'vitest';
import { safeUrlTransform } from './rows';

describe('safeUrlTransform · markdown 链接协议白名单(CLI 输出是不可信文本)', () => {
  test('http/https/mailto 与相对路径放行,javascript:/data: 等一律拆掉', () => {
    expect(safeUrlTransform('https://a.b/c')).toBe('https://a.b/c');
    expect(safeUrlTransform('http://a.b/x?y=1')).toBe('http://a.b/x?y=1');
    expect(safeUrlTransform('mailto:a@b.c')).toBe('mailto:a@b.c');
    expect(safeUrlTransform('./x.md')).toBe('./x.md');
    expect(safeUrlTransform('/api/x')).toBe('/api/x');
    expect(safeUrlTransform('#anchor')).toBe('#anchor');
    expect(safeUrlTransform('javascript:alert(1)')).toBe('');
    expect(safeUrlTransform('JaVaScRiPt:alert(1)')).toBe('');
    expect(safeUrlTransform('data:text/html,<b>x</b>')).toBe('');
    expect(safeUrlTransform('vbscript:x')).toBe('');
  });
});
