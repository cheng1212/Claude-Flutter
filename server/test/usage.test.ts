import { describe, expect, it } from 'vitest';
import { openDb, createSession, createRun, finishRun, usageStats, sessionUsageSummary } from '../src/db.js';

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

  it('每个模型带缓存命中率(缓存读 / 输入侧);无输入侧为 0', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 's' });
    const r1 = createRun(db, s.id, 'deepseek-flash');
    finishRun(db, r1.id, { status: 'success', usage: usage(100, 50, 300, 0) });
    const r2 = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, r2.id, { status: 'success', usage: usage(0, 20) }); // 无输入侧
    const agg = usageStats(db, null);
    const ds = agg.models.find((m) => m.modelId === 'deepseek-flash')!;
    expect(ds.cacheReadInputTokens).toBe(300);
    expect(ds.cacheHitRate).toBeCloseTo(300 / 400, 5); // 300 / (100+300)
    const glm = agg.models.find((m) => m.modelId === 'glm-5.3-flash')!;
    expect(glm.cacheHitRate).toBe(0);
  });

  it('上下文占用优先用 contextTokens(真实值),旧数据缺字段才退回累计口径', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 's' });
    // 新数据:整轮累计 6M,但真实上下文只有 300K(最后一次请求的 prompt)
    const r1 = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, r1.id, {
      status: 'success',
      usage: { ...usage(5_000_000, 1000, 1_000_000, 0), contextTokens: 300_000, contextWindow: 1_000_000 },
    });
    const sum = sessionUsageSummary(db, s.id);
    expect(sum.last?.contextTokens).toBe(300_000);
    expect(sum.last?.contextWindow).toBe(1_000_000);
    // 累计仍是累计(整轮相加),与上面的"真实上下文"是两个口径
    expect(sum.totals.inputTokens).toBe(5_000_000);
    expect(sum.totals.cacheReadInputTokens).toBe(1_000_000);

    // 旧数据(无 contextTokens):退回累计口径
    const s2 = createSession(db, { title: 'old' });
    const r2 = createRun(db, s2.id, 'glm-5.3-flash');
    finishRun(db, r2.id, { status: 'success', usage: usage(100, 50, 200, 0) });
    expect(sessionUsageSummary(db, s2.id).last?.contextTokens).toBe(300);
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
