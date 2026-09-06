import { describe, expect, it } from 'vitest';
import { nextFire, cronPartsMatch } from '../src/cron.js';

// 固定基准:2026-09-07T10:30:15 周一
const base = new Date(2026, 8, 7, 10, 30, 15);

const at = (y: number, mo: number, d: number, h: number, mi: number) => new Date(y, mo - 1, d, h, mi);

describe('nextFire · cron 下一触发时刻(本地时区)', () => {
  it('*/5 分钟:对齐到下一个 5 的倍数分钟', () => {
    expect(nextFire('*/5 * * * *', base)).toEqual(at(2026, 9, 7, 10, 35));
  });
  it('固定时刻 30 14 * * *:今天已过则明天', () => {
    expect(nextFire('30 14 * * *', base)).toEqual(at(2026, 9, 7, 14, 30));
    const later = new Date(2026, 8, 7, 15, 0, 0);
    expect(nextFire('30 14 * * *', later)).toEqual(at(2026, 9, 8, 14, 30));
  });
  it('范围与列表:周一到周五 / 多值', () => {
    const sat = new Date(2026, 8, 12, 10, 0, 0); // 周六
    expect(nextFire('0 9 * * 1-5', sat)).toEqual(at(2026, 9, 14, 9, 0)); // 下周一
    expect(nextFire('0 9 * * 0,3', sat)).toEqual(at(2026, 9, 13, 9, 0)); // 下周日(0,3 含周日)
  });
  it('日/月字段:指定日期', () => {
    expect(nextFire('0 8 28 2 *', base)).toEqual(at(2027, 2, 28, 8, 0));
    expect(nextFire('0 8 1 9 *', base)).toEqual(at(2027, 9, 1, 8, 0)); // 今年 9/1 已过
  });
  it('精确到秒:同分钟内应取下一分钟匹配', () => {
    const b2 = new Date(2026, 8, 7, 10, 35, 10);
    expect(nextFire('*/5 * * * *', b2)).toEqual(at(2026, 9, 7, 10, 40));
  });
  it('非法表达式返回 null', () => {
    expect(nextFire('bad', base)).toBeNull();
    expect(nextFire('99 * * * *', base)).toBeNull();
  });
});

describe('cronPartsMatch · 单字段匹配', () => {
  it('支持 * /n 范围 列表', () => {
    expect(cronPartsMatch('*', 7, 0, 59)).toBe(true);
    expect(cronPartsMatch('*/10', 30, 0, 59)).toBe(true);
    expect(cronPartsMatch('*/10', 35, 0, 59)).toBe(false);
    expect(cronPartsMatch('1-5', 3, 1, 7)).toBe(true);
    expect(cronPartsMatch('1-5', 6, 1, 7)).toBe(false);
    expect(cronPartsMatch('0,15,30', 15, 0, 59)).toBe(true);
  });
});
