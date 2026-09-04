import { describe, expect, it } from 'vitest';
import { transformMessage } from '../src/protocol/transform.js';
import { startsBackgroundWork } from '../src/protocol/types.js';

describe('transformMessage', () => {
  it('assistant 三种 block → thinking/text/tool_use', () => {
    const out = transformMessage({
      type: 'assistant', session_id: 's1',
      message: { role: 'assistant', content: [
        { type: 'thinking', thinking: '想一下' },
        { type: 'text', text: '你好' },
        { type: 'tool_use', id: 't1', name: 'Read', input: { file_path: 'a.ts' } },
      ] },
    });
    expect(out).toEqual([
      { kind: 'thinking', content: '想一下' },
      { kind: 'text', role: 'assistant', content: '你好' },
      { kind: 'tool_use', toolId: 't1', toolName: 'Read', toolInput: { file_path: 'a.ts' } },
    ]);
  });
  it('user tool_result → tool_result(is_error 透传,结构化内容序列化)', () => {
    const out = transformMessage({
      type: 'user', session_id: 's1',
      message: { role: 'user', content: [
        { type: 'tool_result', tool_use_id: 't1', content: 'file body', is_error: true },
        { type: 'tool_result', tool_use_id: 't2', content: [{ type: 'text', text: 'hi' }] },
      ] },
    });
    expect(out).toEqual([
      { kind: 'tool_result', toolId: 't1', content: 'file body', isError: true },
      { kind: 'tool_result', toolId: 't2', content: JSON.stringify([{ type: 'text', text: 'hi' }]), isError: false },
    ]);
  });
  it('user 纯文本回显(非工具行)→ 空,不进聊天流', () => {
    const out = transformMessage({
      type: 'user', session_id: 's1',
      message: { role: 'user', content: [{ type: 'text', text: 'internal echo' }] },
    });
    expect(out).toEqual([]);
  });
  it('stream_event 文本/思考增量', () => {
    const text = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: '早' } } });
    const think = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: '嗯' } } });
    const other = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_start' } });
    expect(text).toEqual([{ kind: 'stream_delta', content: '早' }]);
    expect(think).toEqual([{ kind: 'thinking_delta', content: '嗯' }]);
    expect(other).toEqual([]);
  });
  it('result success → usage + complete(0)', () => {
    const out = transformMessage({
      type: 'result', subtype: 'success', session_id: 's', result: 'done',
      total_cost_usd: 0.05, duration_ms: 1234, num_turns: 3,
      usage: { input_tokens: 10, output_tokens: 5, cache_read_input_tokens: 100, cache_creation_input_tokens: 20 },
      modelUsage: {
        'glm-5.3-flash': { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 100, cacheCreationInputTokens: 20, costUSD: 0.03, contextWindow: 200000, maxOutputTokens: 8192, webSearchRequests: 0 },
        'deepseek-v4': { inputTokens: 1, outputTokens: 1, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, costUSD: 0.02, contextWindow: 128000, maxOutputTokens: 4096, webSearchRequests: 0 },
      },
    });
    expect(out).toEqual([
      {
        kind: 'usage', inputTokens: 10, outputTokens: 5,
        cacheReadInputTokens: 100, cacheCreationInputTokens: 20,
        totalCostUsd: 0.05, durationMs: 1234, numTurns: 3,
        contextWindow: 200000, maxOutputTokens: 8192, // 主模型 = costUSD 最高那条
      },
      { kind: 'complete', exitCode: 0, aborted: false },
    ]);
  });
  it('result success 缺 modelUsage/缓存字段 → 补 0,不炸', () => {
    const out = transformMessage({
      type: 'result', subtype: 'success', session_id: 's',
      total_cost_usd: 0, duration_ms: 1, usage: { input_tokens: 1, output_tokens: 1 },
    });
    expect(out[0]).toMatchObject({ kind: 'usage', cacheReadInputTokens: 0, cacheCreationInputTokens: 0, numTurns: 0, contextWindow: 0, maxOutputTokens: 0 });
  });
  it('result error_max_turns → error + complete(1)', () => {
    const out = transformMessage({ type: 'result', subtype: 'error_max_turns', session_id: 's', errors: ['too many turns'] });
    expect(out[0]).toEqual({ kind: 'error', content: 'too many turns' });
    expect(out[1]).toEqual({ kind: 'complete', exitCode: 1, aborted: false });
  });
  it('init/未知 → 空', () => {
    expect(transformMessage({ type: 'system', subtype: 'init', session_id: 's' })).toEqual([]);
    expect(transformMessage({ type: 'keep_alive' })).toEqual([]);
  });
});

describe('startsBackgroundWork', () => {
  it('Bash run_in_background / Monitor 触发;普通工具不触发', () => {
    const bgBash = { kind: 'tool_use' as const, toolId: '1', toolName: 'Bash', toolInput: { run_in_background: true } };
    const fgBash = { kind: 'tool_use' as const, toolId: '2', toolName: 'Bash', toolInput: {} };
    const monitor = { kind: 'tool_use' as const, toolId: '3', toolName: 'Monitor', toolInput: {} };
    const read = { kind: 'tool_use' as const, toolId: '4', toolName: 'Read', toolInput: {} };
    expect(startsBackgroundWork([bgBash])).toBe(true);
    expect(startsBackgroundWork([fgBash, read])).toBe(false);
    expect(startsBackgroundWork([monitor])).toBe(true);
  });
});
