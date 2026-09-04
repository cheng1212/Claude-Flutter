import { describe, expect, it } from 'vitest';
import { createServer } from 'node:http';
import { WebSocket } from 'ws';
import { buildApp } from '../src/http.js';
import { attachWsGateway } from '../src/gateway/ws-gateway.js';
import { RunRegistry } from '../src/runs/run-registry.js';
import { openDb, createSession, updateSession } from '../src/db.js';
import { SessionRuntime, type QueryFn } from '../src/protocol/sdk-client.js';
import type { ProtocolEvent } from '../src/protocol/types.js';

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AnyMessage = any;

function listen(app: Awaited<ReturnType<typeof buildApp>>): Promise<number> {
  return new Promise((resolve) => {
    app.server.listen(0, () => resolve((app.server.address() as { port: number }).port));
  });
}

function wsConnect(port: number): Promise<{ ws: WebSocket; next: () => Promise<AnyMessage>; pending: () => AnyMessage[] }> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const queue: any[] = [];
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const waiters: ((v: any) => void)[] = [];
  ws.on('message', (raw) => {
    const parsed = JSON.parse(String(raw));
    const waiter = waiters.shift();
    if (waiter) waiter(parsed);
    else queue.push(parsed);
  });
  return new Promise((resolve) => {
    ws.on('open', () => resolve({
      ws,
      next: () => queue.length ? Promise.resolve(queue.shift() as AnyMessage) : new Promise((r) => waiters.push(r)),
      pending: () => queue as AnyMessage[],
    }));
  });
}

async function waitFor(predicate: () => boolean, timeoutMs = 2000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error('waitFor timeout');
    await new Promise((r) => setTimeout(r, 10));
  }
}

describe('ws gateway', () => {
  it('未 auth 报 error 并关闭;auth 后 chat.send 事件带 seq;重连可补发', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async (text: string) => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `echo:${text}` });
          registry.finish(sessionId, 0, false);
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);

    // 1) 未鉴权 → error + 关闭
    const bad = await wsConnect(port);
    bad.ws.send(JSON.stringify({ type: 'chat.send', sessionId: 'x', content: 'y' }));
    expect((await bad.next()).kind).toBe('error');
    bad.ws.close();

    // 2) 鉴权 + 会话 + 发消息:runtime 自发 complete,不应出现第二条
    const conn1 = await wsConnect(port);
    const { ws, next, pending } = conn1;
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    expect((await next()).kind).toBe('authenticated');
    const s = createSession(db, { title: 'ws' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '你好' }));
    const e1 = await next();
    expect(e1).toMatchObject({ kind: 'text', role: 'user', content: '你好', seq: 1 });
    const e2 = await next();
    expect(e2).toMatchObject({ kind: 'text', content: 'echo:你好', seq: 2 });
    const e3 = await next();
    expect(e3).toMatchObject({ kind: 'complete', exitCode: 0, seq: 3 });
    await new Promise((r) => setTimeout(r, 50)); // 给 finally 一拍,确认没有多余 complete
    expect(pending().filter((m) => m.kind === 'complete')).toHaveLength(0);

    // 3) 重连补发(用户消息也在补发流里)
    const { ws: ws2, next: next2 } = await wsConnect(port);
    ws2.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next2();
    ws2.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    expect((await next2()).kind).toBe('subscribed');
    const replay = await next2();
    expect(replay.kind).toBe('replay');
    expect(replay.events).toHaveLength(3);
    expect(replay.events[0]).toMatchObject({ kind: 'text', role: 'user', content: '你好' });
    ws.close();
    ws2.close();
    await app.close();
  });

  it('chat.send 持久化用户消息(text/role=user,meta 带完整事件)', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async (text: string) => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `r:${text}` });
          registry.finish(sessionId, 0, false);
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'usermsg' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '我的问题' }));
    await next(); // user text
    await next(); // assistant text
    await next(); // complete

    const rows = db.prepare(
      'SELECT kind, role, content, meta FROM messages WHERE session_id=? ORDER BY seq',
    ).all(s.id) as { kind: string; role: string | null; content: string; meta: string | null }[];
    expect(rows[0]).toMatchObject({ kind: 'text', role: 'user', content: '我的问题' });
    const meta = JSON.parse(rows[0].meta ?? '{}') as Record<string, unknown>;
    expect(meta).toMatchObject({ kind: 'text', role: 'user', content: '我的问题', seq: 1 });
    ws.close();
    await app.close();
  });

  it('RUN_IN_PROGRESS 守卫;permission-response / abort 送达 runtime', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    const calls: string[] = [];
    let releaseSend: () => void = () => {};
    const gate = new Promise<void>((r) => { releaseSend = r; });
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: (text: string) => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `got:${text}` });
          return gate; // 不结束:模拟运行中
        },
        answerPermission: (requestId: string) => { calls.push(`perm:${requestId}`); },
        abort: async () => { calls.push('abort'); releaseSend(); },
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);

    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'guard' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'a' }));
    expect((await next()).kind).toBe('text'); // 用户消息
    expect((await next()).kind).toBe('text'); // got:a

    // 运行中再发 → RUN_IN_PROGRESS
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'b' }));
    expect(await next()).toMatchObject({ kind: 'error', content: 'RUN_IN_PROGRESS' });

    ws.send(JSON.stringify({ type: 'chat.permission-response', sessionId: s.id, requestId: 'r1', allow: true }));
    await waitFor(() => calls.some((c) => c.startsWith('perm:')));
    ws.send(JSON.stringify({ type: 'chat.abort', sessionId: s.id }));
    await waitFor(() => calls.includes('abort'));
    expect(await next()).toMatchObject({ kind: 'complete', exitCode: 1 }); // finally 兜底

    // 中断落定后 running 已释放:同一会话能继续发(卡死恢复链路的关键一步)
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'c' }));
    expect(await next()).toMatchObject({ kind: 'text', role: 'user', content: 'c', seq: 4 });
    ws.close();
    await app.close();
  });

  it('runtime 自发 complete 后 running 被清,同一会话可继续下一轮', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async (text: string) => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `echo:${text}` });
          registry.finish(sessionId, 0, false); // runtime 自己发 complete
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'reuse' });

    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'one' }));
    expect(await next()).toMatchObject({ kind: 'text', role: 'user', seq: 1 });
    expect(await next()).toMatchObject({ kind: 'text', content: 'echo:one', seq: 2 });
    expect(await next()).toMatchObject({ kind: 'complete', seq: 3 });

    // 第二轮:不应 RUN_IN_PROGRESS
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'two' }));
    expect(await next()).toMatchObject({ kind: 'text', role: 'user', seq: 4 });
    expect(await next()).toMatchObject({ kind: 'text', content: 'echo:two', seq: 5 });
    expect(await next()).toMatchObject({ kind: 'complete', seq: 6 });
    ws.close();
    await app.close();
  });

  it('双连接订阅同一会话:消息只持久化一份,两边都收到', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async (text: string) => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `r:${text}` });
          registry.finish(sessionId, 0, false);
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);
    const s = createSession(db, { title: 'duo' });

    const connA = await wsConnect(port);
    connA.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await connA.next();
    connA.ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    await connA.next();

    const connB = await wsConnect(port);
    connB.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await connB.next();
    connB.ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    await connB.next();

    connA.ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'hi' }));
    expect(await connA.next()).toMatchObject({ kind: 'text', role: 'user', content: 'hi' });
    expect(await connA.next()).toMatchObject({ kind: 'text', content: 'r:hi' });
    expect(await connA.next()).toMatchObject({ kind: 'complete' });
    expect(await connB.next()).toMatchObject({ kind: 'text', role: 'user', content: 'hi' }); // B 也在听
    expect(await connB.next()).toMatchObject({ kind: 'text', content: 'r:hi' });
    expect(await connB.next()).toMatchObject({ kind: 'complete' });

    const rows = db.prepare('SELECT COUNT(*) AS c FROM messages WHERE session_id=?').get(s.id) as { c: number };
    expect(rows.c).toBe(3); // 用户消息 + 助手回复 + complete(也落库,保证 seq 与 DB 行号同步)
    connA.ws.close();
    connB.ws.close();
    await app.close();
  });

  it('delta 不占号不落库:事件 seq 与 DB 行号 lockstep,补发流不含 delta', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async (text: string) => {
          registry.push(sessionId, { kind: 'stream_delta', content: 'a' });
          registry.push(sessionId, { kind: 'stream_delta', content: 'b' });
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `r:${text}` });
          registry.finish(sessionId, 0, false);
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'delta' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'q' }));
    expect(await next()).toMatchObject({ kind: 'text', role: 'user', seq: 1 });
    const d1 = await next();
    expect(d1).toMatchObject({ kind: 'stream_delta', content: 'a' });
    expect(d1.seq).toBeUndefined(); // 瞬态:无 seq,前端不去重
    expect(await next()).toMatchObject({ kind: 'stream_delta', content: 'b' });
    expect(await next()).toMatchObject({ kind: 'text', content: 'r:q', seq: 2 });
    expect(await next()).toMatchObject({ kind: 'complete', seq: 3 });

    // 事件 seq == DB 行号,一一对齐
    const rows = db.prepare('SELECT seq, kind FROM messages WHERE session_id=? ORDER BY seq').all(s.id) as { seq: number; kind: string }[];
    expect(rows.map((r) => [r.seq, r.kind])).toEqual([[1, 'text'], [2, 'text'], [3, 'complete']]);

    // 重连补发:只有持久化事件,没有 delta 碎片
    const { ws: ws2, next: next2 } = await wsConnect(port);
    ws2.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next2();
    ws2.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    await next2(); // subscribed
    const replay = await next2();
    expect(replay.events.map((e: { kind: string }) => e.kind)).toEqual(['text', 'text', 'complete']);
    ws.close();
    ws2.close();
    await app.close();
  });

  it('订阅吸收客户端水位:老客户端带更大 lastSeq 回来,发号与 DB 行号都越过水位不撞车', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async (text: string) => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: `r:${text}` });
          registry.finish(sessionId, 0, false);
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'wm' });

    // 模拟老服务时代的客户端:seq 水位 17000(DB 只有 0 行)
    ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 17000 }] }));
    const sub = await next();
    expect(sub).toMatchObject({ kind: 'subscribed', sessionId: s.id, lastSeq: 17000 });

    // 之后发送:新 seq 必须 > 17000,否则老客户端按 seq 去重把回显当旧事件丢弃
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'q' }));
    expect(await next()).toMatchObject({ kind: 'text', role: 'user', seq: 17001 });
    expect(await next()).toMatchObject({ kind: 'text', content: 'r:q', seq: 17002 });
    expect(await next()).toMatchObject({ kind: 'complete', seq: 17003 });

    // DB 行号 = 事件号(同一 seq 空间),REST 重建不会与实时流分家
    const rows = db.prepare('SELECT seq FROM messages WHERE session_id=? ORDER BY seq').all(s.id) as { seq: number }[];
    expect(rows.map((r) => r.seq)).toEqual([17001, 17002, 17003]);
    ws.close();
    await app.close();
  });

  it('零客户端也落库:订阅者全走光,持久化与 run 收尾照常(解耦回归)', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    let release: () => void = () => {};
    const gate = new Promise<void>((r) => { release = r; });
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async () => {
          registry.push(sessionId, { kind: 'text', role: 'assistant', content: 'slow' });
          await gate; // 等测试先把客户端关光
          registry.finish(sessionId, 0, false);
        },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'solo' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'go' }));
    await next(); // 用户消息回显
    ws.close(); // 客户端全走光;修复前 fanout 被摘除 → 之后的事件只进内存,run 行永远 running
    await new Promise((r) => setTimeout(r, 50));
    release();
    await new Promise((r) => setTimeout(r, 50));

    const rows = db.prepare('SELECT seq, kind FROM messages WHERE session_id=? ORDER BY seq').all(s.id) as { seq: number; kind: string }[];
    expect(rows.map((r) => [r.seq, r.kind])).toEqual([[1, 'text'], [2, 'text'], [3, 'complete']]);
    const run = db.prepare('SELECT status FROM runs WHERE session_id=?').get(s.id) as { status: string };
    expect(run.status).toBe('success'); // run 收尾没丢
    await app.close();
  });

  it('权限模式 PATCH 后,已建运行时的下一轮 query 收到新 permissionMode(不重启生效)', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    const seenOptions: Array<Record<string, unknown>> = [];
    const runtimes = new Map<string, SessionRuntime>();
    const queryFn: QueryFn = ({ options }) => {
      seenOptions.push(options as Record<string, unknown>);
      return (async function* () {
        yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
      })();
    };
    attachWsGateway(app.server, {
      db, token: 't', registry,
      // 镜像 index.ts runtimeFor:每次 send 都读 DB 现值,已建实例 update() 后复用
      runtimeFor: (sessionId: string) => {
        const session = db.prepare('SELECT * FROM sessions WHERE id=?').get(sessionId) as
          | { provider_session_id: string | null; permission_mode: string }
          | undefined;
        if (!session) throw new Error(`session not found: ${sessionId}`);
        const cfg = { model: undefined, permissionMode: session.permission_mode, routeSettings: null };
        const existing = runtimes.get(sessionId);
        if (existing) { existing.update(cfg); return existing; }
        const runtime = new SessionRuntime({
          appSessionId: sessionId,
          providerSessionId: session.provider_session_id,
          cwd: process.cwd(),
          ...cfg,
          emit: (e) => registry.push(sessionId, e),
          queryFn,
        });
        runtimes.set(sessionId, runtime);
        return runtime;
      },
    });
    const port = await listen(app);
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next();
    const s = createSession(db, { title: 'pm' }); // permission_mode 默认 default

    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'a' }));
    await next(); // user text
    await next(); // usage
    await next(); // complete
    expect(seenOptions[0].permissionMode).toBeUndefined(); // default → 不传

    updateSession(db, s.id, { permissionMode: 'acceptEdits' }); // 等价手机端 PATCH /api/sessions/:id
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'b' }));
    await next(); // user text
    await next(); // usage
    await next(); // complete
    expect(seenOptions).toHaveLength(2);
    expect(seenOptions[1].permissionMode).toBe('acceptEdits'); // 第二轮就热更新到位
    ws.close();
    await app.close();
  });
});

// 引用 ProtocolEvent 类型,防止未使用告警
export type { ProtocolEvent };
