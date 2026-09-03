import { describe, expect, it } from 'vitest';
import { SessionRuntime, type QueryFn } from '../src/protocol/sdk-client.js';
import type { ProtocolEvent } from '../src/protocol/types.js';

const base = { cwd: 'C:/tmp' };

function collector() {
  const events: ProtocolEvent[] = [];
  return { events, emit: (e: ProtocolEvent) => events.push(e) };
}

const settle = () => new Promise((r) => setTimeout(r, 20));

describe('SessionRuntime', () => {
  it('完整一轮:session_created→text→usage→complete,prompt 流在 result 后关闭', async () => {
    const { events, emit } = collector();
    let promptEnded = false;
    const queryFn: QueryFn = ({ prompt }) => (async function* () {
      yield { type: 'system', subtype: 'init', session_id: 'prov-1' };
      yield {
        type: 'assistant', session_id: 'prov-1',
        message: { role: 'assistant', content: [{ type: 'text', text: '你好' }] },
      };
      yield {
        type: 'result', subtype: 'success', session_id: 'prov-1',
        usage: { input_tokens: 3, output_tokens: 2 }, total_cost_usd: 0.01, duration_ms: 9,
      };
      for await (const _ of prompt) void _;
      promptEnded = true;
    })();
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a1', emit, queryFn });
    await runtime.send('hi');
    expect(events.map((e) => e.kind)).toEqual(['session_created', 'text', 'usage', 'complete']);
    expect(events[0]).toMatchObject({ kind: 'session_created', providerSessionId: 'prov-1' });
    expect(events.at(-1)).toMatchObject({ kind: 'complete', exitCode: 0, aborted: false });
    await settle();
    expect(promptEnded).toBe(true); // result 已发 → 释放 prompt → fake 消费循环退出
  });

  it('resume:构造时带 providerSessionId → 不发 session_created,options.resume 传入', async () => {
    const { events, emit } = collector();
    const seen: { options: Record<string, unknown> | null } = { options: null };
    const queryFn: QueryFn = ({ options }) => {
      seen.options = options as Record<string, unknown>;
      return (async function* () {
        yield {
          type: 'result', subtype: 'success', session_id: 'prov-1',
          usage: {}, total_cost_usd: 0, duration_ms: 1,
        };
      })();
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a1', providerSessionId: 'prov-1', emit, queryFn });
    await runtime.send('继续');
    expect(events.some((e) => e.kind === 'session_created')).toBe(false);
    expect(seen.options?.resume).toBe('prov-1');
  });

  it('canUseTool → permission_request;allow / deny 应答各自生效', async () => {
    const { events, emit } = collector();
    let captured: Record<string, unknown> | null = null;
    const queryFn: QueryFn = ({ options }) => {
      captured = options as Record<string, unknown>;
      return (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      })();
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a2', emit, queryFn, approvalTimeoutMs: 5000 });
    await runtime.send('go');
    const options = captured as unknown as { canUseTool: (t: string, i: unknown) => Promise<{ behavior: string; message?: string }> };

    const allowing = options.canUseTool('Bash', { command: 'dir' });
    const request1 = events.find((e) => e.kind === 'permission_request') as { requestId: string; toolName: string; input: unknown };
    expect(request1.requestId).toBeTruthy();
    expect(request1.toolName).toBe('Bash');
    expect(request1.input).toEqual({ command: 'dir' });
    runtime.answerPermission(request1.requestId, { allow: true });
    await expect(allowing).resolves.toEqual(expect.objectContaining({ behavior: 'allow' }));

    const denying = options.canUseTool('Bash', { command: 'rm -rf /' });
    const request2 = (events.filter((e) => e.kind === 'permission_request') as { requestId: string }[])[1];
    runtime.answerPermission(request2.requestId, { allow: false, message: '不许删库' });
    await expect(denying).resolves.toEqual({ behavior: 'deny', message: '不许删库' });
  });

  it('审批超时 → 自动 deny(message=approval timeout)', async () => {
    const { events, emit } = collector();
    let captured: Record<string, unknown> | null = null;
    const queryFn: QueryFn = ({ options }) => {
      captured = options as Record<string, unknown>;
      return (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      })();
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a2', emit, queryFn, approvalTimeoutMs: 30 });
    await runtime.send('go');
    const options = captured as unknown as { canUseTool: (t: string, i: unknown) => Promise<{ behavior: string; message?: string }> };
    await expect(options.canUseTool('Bash', {})).resolves.toEqual({ behavior: 'deny', message: 'approval timeout' });
  });

  it('后台工作:result 后 prompt 流仍挂;下一轮 send 取代旧流', async () => {
    const { events, emit } = collector();
    const ended: number[] = [];
    let turn = 0;
    const queryFn: QueryFn = ({ prompt }) => {
      const n = ++turn;
      return (async function* () {
        if (n === 1) {
          yield {
            type: 'assistant', session_id: 'p',
            message: { role: 'assistant', content: [{ type: 'tool_use', id: 't', name: 'Bash', input: { command: 'sleep 30', run_in_background: true } }] },
          };
        }
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
        for await (const _ of prompt) void _;
        ended.push(n);
      })();
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a3', emit, queryFn });
    await runtime.send('bg');
    expect(events.some((e) => e.kind === 'complete')).toBe(true); // 客户端视角本轮已完
    await settle();
    expect(ended).toEqual([]); // 流仍挂:等后台工作
    await runtime.send('next'); // 新一轮取代旧 held 流
    await settle();
    expect(ended).toContain(1);
    expect(ended).toContain(2);
  });

  it('abort → complete(aborted:true),不产生 error 事件', async () => {
    const { events, emit } = collector();
    const queryFn: QueryFn = () => {
      let crash: () => void = () => {};
      const gen = (async function* () {
        yield {
          type: 'assistant', session_id: 'p',
          message: { role: 'assistant', content: [{ type: 'text', text: '.' }] },
        };
        await new Promise<void>((_, reject) => { crash = () => reject(new Error('interrupted')); });
      })();
      (gen as unknown as { interrupt: () => void }).interrupt = () => crash();
      return gen;
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a4', emit, queryFn });
    const running = runtime.send('long');
    await settle(); // 让 pump 挂在 await 上
    await runtime.abort();
    await running;
    expect(events.some((e) => e.kind === 'complete' && (e as { aborted: boolean }).aborted)).toBe(true);
    expect(events.some((e) => e.kind === 'error')).toBe(false);
  });
});
