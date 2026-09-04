import { describe, expect, it } from 'vitest';
import { SessionRuntime, type QueryFn, type QueryInstance } from '../src/protocol/sdk-client.js';
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

  it('pendingPermissions 暴露等待中的审批详情;abort 一并拒绝', async () => {
    let captured: Record<string, unknown> | null = null;
    const queryFn: QueryFn = ({ options }) => {
      captured = options as Record<string, unknown>;
      return (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      })();
    };
    const { events, emit } = collector();
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a3', emit, queryFn, approvalTimeoutMs: 60000 });
    await runtime.send('go');
    const options = captured as unknown as { canUseTool: (t: string, i: unknown) => Promise<{ behavior: string; message?: string }> };
    const asking = options.canUseTool('PowerShell', { command: 'npm test' });
    expect(runtime.pendingPermissions()).toHaveLength(1);
    expect(runtime.pendingPermissions()[0]).toMatchObject({ toolName: 'PowerShell', input: { command: 'npm test' } });
    expect(events.filter((e) => e.kind === 'permission_request')).toHaveLength(1);
    await runtime.abort();
    await expect(asking).resolves.toEqual({ behavior: 'deny', message: 'aborted' });
    expect(runtime.pendingPermissions()).toHaveLength(0);
  });

  it('看门狗不误杀:前台工具静默期(有 tool_use 未回结果)续期,结果回来照常完成', async () => {
    const { events, emit } = collector();
    const queryFn: QueryFn = ({ prompt }) => (async function* () {
      yield {
        type: 'assistant', session_id: 'p',
        message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'long-build' } }] },
      };
      // 静默 150ms ≈ 3 个看门狗周期(50ms):旧逻辑第 2 个周期就误杀了
      await new Promise((r) => setTimeout(r, 150));
      yield {
        type: 'user', session_id: 'p',
        message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'Built in 150ms' }] },
      };
      yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      for await (const _ of prompt) void _;
    })();
    const runtime = new SessionRuntime({ ...base, appSessionId: 'w1', emit, queryFn, approvalTimeoutMs: 50 });
    await runtime.send('go');
    const kinds = events.map((e) => e.kind);
    expect(kinds).toContain('tool_use');
    expect(kinds).toContain('tool_result');
    expect(kinds).not.toContain('error'); // 没被看门狗打断
    expect(events.at(-1)).toMatchObject({ kind: 'complete', exitCode: 0 });
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

  it('update():权限模式热更新到下一轮;bypassPermissions 自动补 allowDangerouslySkipPermissions', async () => {
    const { events, emit } = collector();
    const seen: Array<Record<string, unknown>> = [];
    const queryFn: QueryFn = ({ options }) => {
      seen.push(options as Record<string, unknown>);
      return (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      })();
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'u1', permissionMode: 'default', emit, queryFn });
    await runtime.send('第一轮');
    expect(seen[0].permissionMode).toBeUndefined(); // default → 不传,CLI 走本机默认
    expect(seen[0].allowDangerouslySkipPermissions).toBeUndefined();

    runtime.update({ permissionMode: 'acceptEdits' });
    await runtime.send('第二轮');
    expect(seen[1].permissionMode).toBe('acceptEdits');
    expect(seen[1].allowDangerouslySkipPermissions).toBeUndefined();

    runtime.update({ permissionMode: 'bypassPermissions' });
    await runtime.send('第三轮');
    expect(seen[2].permissionMode).toBe('bypassPermissions');
    expect(seen[2].allowDangerouslySkipPermissions).toBe(true);
    expect(events.filter((e) => e.kind === 'complete')).toHaveLength(3);
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

  it('setPermissionModeLive/setModelLive 转发到活实例;无实例时不炸', async () => {
    const { events, emit } = collector();
    const seen: { mode?: string; model?: string } = {};
    let promptEnded = false;
    const queryFn: QueryFn = ({ prompt }) => {
      const gen = (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
        for await (const _ of prompt) void _;
        promptEnded = true;
      })();
      (gen as unknown as { setPermissionMode: (m: string) => Promise<void> }).setPermissionMode = async (m) => { seen.mode = m; };
      (gen as unknown as { setModel: (m?: string) => Promise<void> }).setModel = async (m) => { seen.model = m; };
      return gen as unknown as QueryInstance;
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'lv', emit, queryFn });
    await runtime.setPermissionModeLive('acceptEdits'); // 无实例:静默不炸
    await runtime.setModelLive('glm-x');
    expect(seen.mode).toBeUndefined();
    expect(seen.model).toBeUndefined();

    await runtime.send('起一轮,result 后挂住');
    await runtime.setPermissionModeLive('plan');
    await runtime.setModelLive('glm-x');
    expect(seen).toEqual({ mode: 'plan', model: 'glm-x' });

    await runtime.send('下一轮取代旧流'); // 收尾释放
    await settle();
    expect(promptEnded).toBe(true);
    expect(events.filter((e) => e.kind === 'complete')).toHaveLength(2);
  });

  it('CLI 僵死(interrupt 无效):abort 强裁兜底让回合落定,下一轮可继续', async () => {
    const { events, emit } = collector();
    let turn = 0;
    const queryFn: QueryFn = () => {
      if (++turn === 1) {
        // 僵死 CLI:永不产出、永不结束、interrupt 也没用
        const gen = (async function* (): AsyncGenerator<Record<string, unknown>> {
          await new Promise<void>(() => {});
        })();
        (gen as unknown as { interrupt: () => Promise<void> }).interrupt = async () => {};
        return gen as unknown as QueryInstance;
      }
      return (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      })();
    };
    const runtime = new SessionRuntime({ ...base, appSessionId: 'a5', emit, queryFn, abortForceDelayMs: 30 });
    const first = runtime.send('卡死');
    await settle();
    await runtime.abort(); // interrupt 无效 → 30ms 后强裁
    await first; // 不挂死:强裁把回合结算了
    expect(events.filter((e) => e.kind === 'complete').at(-1)).toMatchObject({ aborted: true });
    await runtime.send('再来'); // turnChain 已推进,新一轮正常跑完
    expect(events.filter((e) => e.kind === 'complete').at(-1)).toMatchObject({ aborted: false });
  });

  it('静默看门狗:整轮无输出超时 → error + 自动中断落定', async () => {
    const { events, emit } = collector();
    const queryFn: QueryFn = () => {
      const gen = (async function* (): AsyncGenerator<Record<string, unknown>> {
        await new Promise<void>(() => {});
      })();
      (gen as unknown as { interrupt: () => Promise<void> }).interrupt = async () => {};
      return gen as unknown as QueryInstance;
    };
    const runtime = new SessionRuntime({
      ...base, appSessionId: 'a6', emit, queryFn,
      approvalTimeoutMs: 40, // 看门狗阈值(测试用极小值)
      abortForceDelayMs: 30,
    });
    await runtime.send('挂机'); // 40ms 看门狗触发 error+abort → 30ms 强裁 → 落定
    expect(events.some((e) => e.kind === 'error')).toBe(true);
    expect(events.filter((e) => e.kind === 'complete').at(-1)).toMatchObject({ aborted: true });
  });
});
