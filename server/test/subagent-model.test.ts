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

  it('forcedModel 是真实模型 id → 只放行，绝不写进 model（那是枚举字段，写了整次派发 schema 失败）', async () => {
    const { subagentModelDecision } = await import('../src/protocol/sdk-client.js');
    // 生产路径就是这个形状：会话路由到 go-deepseek-v4-flash，模型自己选了 sonnet
    expect(subagentModelDecision('Agent', { prompt: 'x', model: 'sonnet' }, 'go-deepseek-v4-flash')).toEqual({
      behavior: 'allow',
      updatedInput: { prompt: 'x', model: 'sonnet' }, // 原样保留，没被改成真实 id
    });
    expect(subagentModelDecision('Task', { prompt: 'x' }, 'glm-5.3-flash')).toEqual({
      behavior: 'allow',
      updatedInput: { prompt: 'x' },
    });
  });

  it('未配置强制模型 / 非派发工具 → null(不干预审批)', async () => {
    const { subagentModelDecision } = await import('../src/protocol/sdk-client.js');
    expect(subagentModelDecision('Agent', { model: 'opus' }, undefined)).toBeNull();
    expect(subagentModelDecision('Agent', { model: 'opus' }, '')).toBeNull();
    expect(subagentModelDecision('Bash', { command: 'ls' }, 'haiku')).toBeNull();
  });
});
