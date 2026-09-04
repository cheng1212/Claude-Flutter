import { describe, expect, it } from 'vitest';
import { RunRegistry } from '../src/runs/run-registry.js';

describe('RunRegistry', () => {
  it('seq 按会话单调递增,跨 run 不清零(finish 的 complete 也占 seq)', () => {
    const reg = new RunRegistry();
    reg.begin('s1');
    expect(reg.push('s1', { kind: 'text', role: 'assistant', content: 'a' }).seq).toBe(1);
    const done = reg.finish('s1', 0, false);
    expect(done.seq).toBe(2);
    expect(done).toMatchObject({ kind: 'complete', exitCode: 0, aborted: false });
    reg.begin('s1');
    expect(reg.push('s1', { kind: 'text', role: 'assistant', content: 'b' }).seq).toBe(3);
  });
  it('replay(afterSeq) 只回缺的;live 订阅收新事件,退订即停', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    reg.push('s', { kind: 'text', role: 'assistant', content: '1' });
    reg.push('s', { kind: 'text', role: 'assistant', content: '2' });
    const seen: string[] = [];
    const off = reg.subscribe('s', (e) => seen.push((e as { content: string }).content));
    reg.push('s', { kind: 'text', role: 'assistant', content: '3' });
    expect(seen).toEqual(['3']);
    off();
    reg.push('s', { kind: 'text', role: 'assistant', content: '4' });
    expect(seen).toEqual(['3']);
    expect(reg.replay('s', 1).map((e) => (e as { content: string }).content)).toEqual(['2', '3', '4']);
    expect(reg.lastSeq('s')).toBe(4);
  });
  it('delta 瞬态:订阅者实时收到但不占 seq、不进环形缓冲', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    const seen: Array<{ kind: string; seq?: number; content: string }> = [];
    reg.subscribe('s', (e) => seen.push(e as { kind: string; seq?: number; content: string }));
    reg.push('s', { kind: 'text', role: 'assistant', content: '1' }); // seq 1
    reg.push('s', { kind: 'stream_delta', content: 'x' });
    reg.push('s', { kind: 'thinking_delta', content: 'y' });
    reg.push('s', { kind: 'text', role: 'assistant', content: '2' }); // seq 2
    // 实时流:delta 原样到达,且不带 seq(前端不去重)
    expect(seen.map((e) => e.kind)).toEqual(['text', 'stream_delta', 'thinking_delta', 'text']);
    expect(seen[1].seq).toBeUndefined();
    expect(seen[1].content).toBe('x');
    // 重放空间只有持久化事件:seq 连续、无 delta
    expect(reg.replay('s', 0).map((e) => (e as { content: string }).content)).toEqual(['1', '2']);
    expect(reg.lastSeq('s')).toBe(2);
  });
  it('缓冲封顶 1000,重放不越界,lastSeq 仍准确', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    for (let i = 0; i < 1100; i++) reg.push('s', { kind: 'text', role: 'assistant', content: 'x' });
    expect(reg.replay('s', 0).length).toBe(1000);
    expect(reg.lastSeq('s')).toBe(1100);
    // 最早可重放的 seq 从 101 开始
    expect(reg.replay('s', 0)[0].seq).toBe(101);
  });
  it('seedSeq 只进不退:向上吸收(DB maxSeq/客户端水位),绝不倒卷已发过的号', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    for (let i = 0; i < 500; i++) reg.push('s', { kind: 'text', role: 'assistant', content: 'x' });
    expect(reg.lastSeq('s')).toBe(500);
    // 指针低于已发号时(seed 到更小的 DB 行号)不倒卷:客户端可能已见过 500,
    // 倒卷会让后续事件拿旧号重发,被前端 seq 去重整批丢弃(界面冻结的根因)。
    reg.seedSeq('s', 42);
    expect(reg.lastSeq('s')).toBe(500);
    expect(reg.push('s', { kind: 'text', role: 'assistant', content: 'n' }).seq).toBe(501);
    // 向上则吸收:重启后从 DB maxSeq 起步,客户端见过更大水位时抬指针防撞号
    const reg2 = new RunRegistry();
    reg2.seedSeq('s', 17000);
    expect(reg2.lastSeq('s')).toBe(17000);
    expect(reg2.push('s', { kind: 'text', role: 'assistant', content: 'm' }).seq).toBe(17001);
  });
  it('isRunning:begin→true,finish→false', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    expect(reg.isRunning('s')).toBe(true);
    reg.finish('s', 0, false);
    expect(reg.isRunning('s')).toBe(false);
  });
});
