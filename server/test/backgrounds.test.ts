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
});
