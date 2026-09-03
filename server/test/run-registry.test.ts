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
  it('缓冲封顶 1000,重放不越界,lastSeq 仍准确', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    for (let i = 0; i < 1100; i++) reg.push('s', { kind: 'stream_delta', content: 'x' });
    expect(reg.replay('s', 0).length).toBe(1000);
    expect(reg.lastSeq('s')).toBe(1100);
    // 最早可重放的 seq 从 101 开始
    expect(reg.replay('s', 0)[0].seq).toBe(101);
  });
  it('isRunning:begin→true,finish→false', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    expect(reg.isRunning('s')).toBe(true);
    reg.finish('s', 0, false);
    expect(reg.isRunning('s')).toBe(false);
  });
});
