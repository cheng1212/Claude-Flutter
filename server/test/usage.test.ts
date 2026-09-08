import { describe, expect, it } from 'vitest';
import { openDb, createSession, createRun, finishRun, usageStats } from '../src/db.js';

const usage = (input: number, output: number, cacheRead = 0, cacheCreation = 0, numTurns = 1) => ({
  inputTokens: input,
  outputTokens: output,
  cacheReadInputTokens: cacheRead,
  cacheCreationInputTokens: cacheCreation,
  totalCostUsd: 0,
  durationMs: 1000,
  numTurns,
});

describe('usageStats · 全局用量聚合', () => {
  it('跨会话/跨模型聚合:输入含缓存、命中率、份额降序、回合与会话数、每日', () => {
    const db = openDb(':memory:');
    const a = createSession(db, { title: 'a' });
    const b = createSession(db, { title: 'b' });
    const r1 = createRun(db, a.id, 'glm-5.3-flash');
    finishRun(db, r1.id, { status: 'success', usage: usage(100, 50, 300, 0, 2) });
    const r2 = createRun(db, a.id, 'glm-5.3-flash');
    finishRun(db, r2.id, { status: 'success', usage: usage(80, 30, 200, 20, 1) });
    const r3 = createRun(db, b.id, 'kimi-k3');
    finishRun(db, r3.id, { status: 'success', usage: usage(10, 5) });

    const agg = usageStats(db, null);
    expect(agg.summary.totalSessions).toBe(2);
    expect(agg.summary.totalTurns).toBe(4); // 2+1+1
    expect(agg.models.length).toBe(2);
    const glm = agg.models.find((m) => m.modelId === 'glm-5.3-flash')!;
    expect(glm.requestCount).toBe(2);
    expect(glm.inputTokens).toBe(700); // 100+300 + 80+200+20(输入含缓存读+写)
    expect(glm.outputTokens).toBe(80);
    expect(agg.models[0].modelId).toBe('glm-5.3-flash'); // 总量降序
    expect(agg.summary.cacheReadTokens).toBe(500);
    expect(agg.summary.cacheHitRate).toBeCloseTo(500 / 710, 5);
    expect(agg.summary.totalTokens).toBe(795);
    expect(agg.summary.favoriteModel).toBe('glm-5.3-flash');
    expect(agg.daily.length).toBe(1); // 全部落在今天
    expect(agg.summary.currentStreakDays).toBeGreaterThanOrEqual(1);
    expect(agg.summary.peakDayTokens).toBe(795);
  });

  it('无 usage 的 run 不计入;sinceIso(未来时间)过滤后为空', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 's' });
    const r = createRun(db, s.id, 'm1');
    finishRun(db, r.id, { status: 'success' }); // 没带 usage
    const r2 = createRun(db, s.id, 'm1');
    finishRun(db, r2.id, { status: 'success', usage: usage(10, 5) });
    expect(usageStats(db, null).summary.totalTokens).toBe(15);
    const early = usageStats(db, new Date(Date.now() + 3600000).toISOString());
    expect(early.summary.totalTokens).toBe(0);
    expect(early.summary.totalSessions).toBe(0);
  });
});
