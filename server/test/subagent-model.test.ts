// 子代理模型约束:配置强制模型时,Agent/Task 派发一律改写 input.model(对模型透明);
// 未配置/其他工具 → null(走正常审批链路)。
import { describe, expect, it } from 'vitest';

describe('subagentModelDecision · 子代理模型约束', () => {
  it('Agent/Task + 强制模型 → allow 且 model 被改写,其余输入原样保留', async () => {
    const { subagentModelDecision } = await import('../src/protocol/sdk-client.js');
    const d = subagentModelDecision('Agent', { description: '查资料', prompt: 'p', model: 'opus' }, 'haiku');
    expect(d).toEqual({
      behavior: 'allow',
      updatedInput: { description: '查资料', prompt: 'p', model: 'haiku' },
    });
    expect(subagentModelDecision('Task', { prompt: 'x' }, 'sonnet')).toEqual({
      behavior: 'allow',
      updatedInput: { prompt: 'x', model: 'sonnet' },
    });
  });

  it('未配置强制模型 / 非派发工具 → null(不干预审批)', async () => {
    const { subagentModelDecision } = await import('../src/protocol/sdk-client.js');
    expect(subagentModelDecision('Agent', { model: 'opus' }, undefined)).toBeNull();
    expect(subagentModelDecision('Agent', { model: 'opus' }, '')).toBeNull();
    expect(subagentModelDecision('Bash', { command: 'ls' }, 'haiku')).toBeNull();
  });
});
