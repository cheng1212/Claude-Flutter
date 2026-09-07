// 后台任务升级回归:task_* 消息族(task_started/updated/notification)接入登记,
// 富字段(工具关联/状态补丁/输出文件)与 Bash run_in_background 旧行为合并。
import { describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

describe('transform:task_* 富字段透传', () => {
  it('task_started/task_notification/task_updated 携带新字段', async () => {
    const { transformMessage } = await import('../src/protocol/transform.js');
    const started = transformMessage({
      type: 'system', subtype: 'task_started', task_id: 't1', tool_use_id: 'tool9',
      description: '跑构建', task_type: 'local_bash', is_backgrounded: true,
    });
    expect(started).toEqual([{
      kind: 'task_started', taskId: 't1', toolUseId: 'tool9',
      description: '跑构建', taskType: 'local_bash', isBackgrounded: true,
    }]);
    const note = transformMessage({
      type: 'system', subtype: 'task_notification', task_id: 't1',
      status: 'completed', summary: 'done!', output_file: 'C:/tmp/out.log',
    });
    expect(note[0]).toMatchObject({ kind: 'task_complete', taskId: 't1', status: 'completed', summary: 'done!', outputFile: 'C:/tmp/out.log' });
    const upd = transformMessage({ type: 'system', subtype: 'task_updated', task_id: 't1', patch: { status: 'killed' } });
    expect(upd).toEqual([{ kind: 'task_updated', taskId: 't1', status: 'killed' }]);
    // 家务任务仍然过滤
    expect(transformMessage({ type: 'system', subtype: 'task_started', task_id: 'x', ambient: true })).toEqual([]);
  });
});

describe('BackgroundRegistry:task 生命周期', () => {
  it('与 Bash run_in_background 合并为一条;状态补丁;完成带输出文件', async () => {
    const { BackgroundRegistry, readOutputTail } = await import('../src/backgrounds.js');
    const reg = new BackgroundRegistry();
    reg.onToolUse('s1', 'Bash', 'tool9', { command: 'npm run build', run_in_background: true });
    reg.onTaskEvent('s1', {
      kind: 'task_started', taskId: 't1', toolUseId: 'tool9',
      description: '跑构建', taskType: 'local_bash', isBackgrounded: true,
    });
    let rows = reg.list('s1');
    expect(rows.length).toBe(1);
    expect(rows[0]).toMatchObject({ id: 'tool9', taskId: 't1', command: 'npm run build', status: 'running' });

    reg.onTaskEvent('s1', { kind: 'task_updated', taskId: 't1', status: 'killed' });
    expect(reg.list('s1')[0].status).toBe('killed');

    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-bg-'));
    const out = path.join(dir, 'out.log');
    fs.writeFileSync(out, 'l1\nl2\nl3\n', 'utf8');
    reg.onTaskEvent('s1', { kind: 'task_complete', taskId: 't1', status: 'completed', summary: '构建完成', outputFile: out });
    rows = reg.list('s1');
    expect(rows[0]).toMatchObject({ status: 'completed', summary: '构建完成', outputFile: out });
    expect(await readOutputTail(out)).toContain('l3');
    expect(await readOutputTail(path.join(dir, 'nope.log'))).toBe('');

    // toolUseId 不指向已登记行 → 自立条目
    reg.onTaskEvent('s1', { kind: 'task_started', taskId: 't2', description: '研究', taskType: 'local_agent', isBackgrounded: true });
    expect(reg.list('s1').length).toBe(2);
  });
});
