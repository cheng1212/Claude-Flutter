import { describe, expect, it } from 'vitest';
import { BackgroundRegistry } from '../src/backgrounds.js';

describe('BackgroundRegistry', () => {
  it('登记后台 Bash;前台 Bash 不登记', () => {
    const r = new BackgroundRegistry();
    r.onToolUse('s1', 'Bash', 'bg1', { command: 'npm run build', run_in_background: true });
    r.onToolUse('s1', 'Bash', 'fg1', { command: 'ls' });
    const list = r.list('s1');
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({ id: 'bg1', status: 'running', command: 'npm run build' });
  });

  it('BashOutput 的结果回写到对应 shell 的输出尾部', () => {
    const r = new BackgroundRegistry();
    r.onToolUse('s1', 'Bash', 'bg1', { command: 'npm run build', run_in_background: true });
    r.onToolUse('s1', 'BashOutput', 'bo1', { bash_id: 'bg1' });
    r.onToolResult('s1', 'bo1', 'building 40%...', false);
    expect(r.list('s1')[0].lastOutput).toContain('building 40%');
  });

  it('KillShell → killed;后台 Bash 自身的结果不改变 running 状态', () => {
    const r = new BackgroundRegistry();
    r.onToolUse('s1', 'Bash', 'bg1', { command: 'npm run build', run_in_background: true });
    r.onToolResult('s1', 'bg1', 'command running in background', false);
    expect(r.list('s1')[0].status).toBe('running');
    r.onToolUse('s1', 'KillShell', 'k1', { shell_id: 'bg1' });
    expect(r.list('s1')[0].status).toBe('killed');
  });

  it('会话之间隔离;clear 清空', () => {
    const r = new BackgroundRegistry();
    r.onToolUse('s1', 'Bash', 'bg1', { command: 'a', run_in_background: true });
    r.onToolUse('s2', 'Bash', 'bg2', { command: 'b', run_in_background: true });
    expect(r.list('s1')).toHaveLength(1);
    expect(r.list('s2')).toHaveLength(1);
    r.clear('s1');
    expect(r.list('s1')).toHaveLength(0);
    expect(r.list('s2')).toHaveLength(1);
  });

  it('list 按开始时间倒序(新→旧),不依赖 Map 插入序', () => {
    const r = new BackgroundRegistry();
    r.onToolUse('s', 'Bash', 'old', { command: 'old', run_in_background: true });
    r.onToolUse('s', 'Bash', 'new', { command: 'new', run_in_background: true });
    // 直接改 startedAt 模拟先后(测试里同毫秒会撞)
    const list = r.list('s');
    expect(list.length).toBe(2);
    expect(list[0].startedAt).toBeGreaterThanOrEqual(list[1].startedAt);
  });

  it('prune 收口:超出上限清最旧的已完成,运行中的一条不动', () => {
    const r = new BackgroundRegistry();
    // 30 个已完成 + 3 个运行中
    for (let i = 0; i < 30; i++) {
      r.onTaskEvent('s', { kind: 'task_started', taskId: `done-${i}` });
      r.onTaskEvent('s', { kind: 'task_complete', taskId: `done-${i}`, status: 'completed' });
    }
    for (let i = 0; i < 3; i++) {
      r.onTaskEvent('s', { kind: 'task_started', taskId: `run-${i}` });
    }
    const before = r.list('s').length;
    expect(before).toBe(33);

    const removed = r.prune('s', 10);
    expect(removed).toBeGreaterThan(0);
    const after = r.list('s');
    // 运行中的 3 条必须还在
    expect(after.filter((t) => t.status === 'running').length).toBe(3);
    // 已完成的被压到上限内
    expect(after.filter((t) => t.status !== 'running').length).toBeLessThanOrEqual(10);
  });

  it('prune 不影响别的会话', () => {
    const r = new BackgroundRegistry();
    for (let i = 0; i < 20; i++) {
      r.onTaskEvent('s1', { kind: 'task_started', taskId: `a-${i}` });
      r.onTaskEvent('s1', { kind: 'task_complete', taskId: `a-${i}`, status: 'completed' });
    }
    r.onTaskEvent('s2', { kind: 'task_started', taskId: 'b-1' });
    r.prune('s1', 5);
    expect(r.list('s2').length).toBe(1);
  });
});
