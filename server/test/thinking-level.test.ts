// 思考等级 → SDK thinking 配置映射(纯函数)。
// 实测:DeepSeek 端点 disabled 真实生效,预算分级弱响应(方向对);GLM 忽略参数。
// 协议层按标准 Anthropic thinking 传,端点认多少是端点的事。
import { describe, expect, it } from 'vitest';

describe('thinkingConfigOf · 思考等级映射', () => {
  it('off → disabled;低/中/高 → enabled 分级预算', async () => {
    const { thinkingConfigOf } = await import('../src/protocol/sdk-client.js');
    expect(thinkingConfigOf('off')).toEqual({ type: 'disabled' });
    expect(thinkingConfigOf('low')).toEqual({ type: 'enabled', budgetTokens: 4096 });
    expect(thinkingConfigOf('medium')).toEqual({ type: 'enabled', budgetTokens: 16384 });
    expect(thinkingConfigOf('high')).toEqual({ type: 'enabled', budgetTokens: 31999 });
  });

  it('on 与未设置 → undefined(不注入,维持模型默认行为)', async () => {
    const { thinkingConfigOf } = await import('../src/protocol/sdk-client.js');
    expect(thinkingConfigOf('on')).toBeUndefined();
    expect(thinkingConfigOf(undefined)).toBeUndefined();
    expect(thinkingConfigOf(null)).toBeUndefined();
    expect(thinkingConfigOf('随便什么')).toBeUndefined();
  });
});
