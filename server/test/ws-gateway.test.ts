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

function wsConnect(port: number): Promise<{ ws: WebSocket; next: () => Promise<AnyMessage>; nextAny: () => Promise<AnyMessage>; pending: () => AnyMessage[] }> {
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
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const nextAny = () => queue.length ? Promise.resolve(queue.shift() as AnyMessage) : new Promise((r) => waiters.push(r));
  return new Promise((resolve) => {
    ws.on('open', () => resolve({
      ws,
      // 默认跳过 sessions_dirty 控制帧(列表刷新广播),业务事件断言不用到处防御
      next: () => nextAny().then(function loop(m: AnyMessage): AnyMessage | Promise<AnyMessage> {
        return m.kind === 'sessions_dirty' ? nextAny().then(loop) : m;
      }),
      nextAny,
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
  it('审批恢复:App 重启重连后,subscribed.pending 与 replay 双通道找回待审批', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    const runtimes = new Map<string, SessionRuntime>();
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let captured: any = null;
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor(sessionId: string, opts: { model?: string | null; permissionMode?: string }) {
        const existing = runtimes.get(sessionId);
        if (existing) return existing;
        const rt = new SessionRuntime({
          appSessionId: sessionId,
          cwd: 'C:/tmp',
          model: opts.model ?? null,
          permissionMode: opts.permissionMode,
          approvalTimeoutMs: 60000,
          emit: (e) => registry.push(sessionId, e),
          queryFn: ({ options, prompt }) => {
            captured = options;
            return (async function* () {
              for await (const _ of prompt) void _; // 回合挂住:等审批,永不 result
            })();
          },
        });
        runtimes.set(sessionId, rt);
        return rt;
      },
    });
    const port = await listen(app);
    const s = createSession(db, { title: 'perm' });

    // 第一台"手机":开跑 → CLI 调 canUseTool → 审批挂起 → 掉线(App 重启)
    const a = await wsConnect(port);
    a.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await a.next();
    a.ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '构建 apk' }));
    await waitFor(() => captured !== null);
    const allowing = (captured as { canUseTool: (t: string, i: unknown) => Promise<{ behavior: string }> })
      .canUseTool('Bash', { command: 'flutter build apk' });
    await waitFor(() =>
      (db.prepare('SELECT COUNT(*) AS c FROM messages WHERE session_id=?').get(s.id) as { c: number }).c === 1);
    a.ws.close();

    // 第二台"手机":REST 只能锚到 DB max(permission_request 占号不落库),重连订阅
    const b = await wsConnect(port);
    b.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await b.next();
    const maxSeq = (db.prepare('SELECT COALESCE(MAX(seq),0) AS m FROM messages WHERE session_id=?').get(s.id) as { m: number }).m;
    b.ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: maxSeq }] }));
    const sub = await b.next();
    expect(sub).toMatchObject({ kind: 'subscribed', isProcessing: true });
    const pendings = sub.pending as { requestId: string; toolName: string }[];
    expect(pendings.some((p) => p.toolName === 'Bash')).toBe(true);
    // 通道一(确定性):pending 里的 requestId 直接应答,CLI 侧放行
    b.ws.send(JSON.stringify({ type: 'chat.permission-response', sessionId: s.id, requestId: pendings[0].requestId, allow: true }));
    await expect(allowing).resolves.toEqual(expect.objectContaining({ behavior: 'allow' }));
    // 通道二(缓冲补发):permission_request 占号进环形缓冲,replay 会重放它
    const replay = await b.next();
    expect(replay.kind).toBe('replay');
    expect(replay.events.some((e: { kind: string }) => e.kind === 'permission_request')).toBe(true);
    b.ws.close();
    for (const rt of runtimes.values()) void rt.abort(); // 收尾:挂着的回合 abort 掉
    await app.close();
  });

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

  it('sessions_dirty 广播:未订阅的客户端也收到开跑/跑完通知(会话列表徽章数据源)', async () => {
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

    // 旁听者:只 auth 不订阅——它代表停在会话列表页的手机
    const listener = await wsConnect(port);
    listener.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await listener.nextAny();

    const sender = await wsConnect(port);
    sender.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await sender.nextAny();
    const s = createSession(db, { title: 'dirty' });
    sender.ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'go' }));
    await sender.next(); // user text
    await sender.next(); // assistant text
    await sender.next(); // complete

    // 旁听者收到的两拍都是 sessions_dirty:开跑一拍、跑完一拍,均不占 seq 不落库
    expect(await listener.nextAny()).toMatchObject({ kind: 'sessions_dirty', sessionId: s.id });
    expect(await listener.nextAny()).toMatchObject({ kind: 'sessions_dirty', sessionId: s.id });
    expect(listener.pending().every((m) => m.kind !== 'text')).toBe(true);

    const rows = db.prepare('SELECT COUNT(*) AS c FROM messages WHERE session_id=?').get(s.id) as { c: number };
    expect(rows.c).toBe(3); // 控制帧没进消息表
    listener.ws.close();
    sender.ws.close();
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

  it('图片瘦身:线上(广播+补发)剥 base64 → imageCount,超限图丢弃,DB meta 仍存原图', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => ({
        send: async () => { registry.finish(sessionId, 0, false); },
        answerPermission: () => {},
        abort: async () => {},
      }) as unknown as SessionRuntime,
    });
    const port = await listen(app);

    // 第二台手机先订阅:验证实时广播也是瘦身载荷
    const watcher = await wsConnect(port);
    watcher.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await watcher.nextAny();
    const s = createSession(db, { title: 'img' });
    watcher.ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    expect((await watcher.nextAny()).kind).toBe('subscribed');

    const { ws, next, nextAny } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await nextAny();
    const tiny = `data:image/png;base64,${'A'.repeat(1000)}`;
    const oversized = `data:image/png;base64,${'B'.repeat(5 * 1024 * 1024)}`;
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '看图', images: [tiny, oversized] }));
    const echo = await next(); // 发送方自己的回显
    expect(echo).toMatchObject({ kind: 'text', role: 'user', imageCount: 1 });
    expect(JSON.stringify(echo)).not.toContain('AAAA'); // base64 不上线
    await next(); // complete

    const liveWire = await watcher.next(); // 旁听者收到的实时广播
    expect(liveWire).toMatchObject({ kind: 'text', role: 'user', imageCount: 1 });
    expect(JSON.stringify(liveWire)).not.toContain('AAAA');

    // 重连补发视角:lastSeq 0 → replay 整段历史,同样没有 base64
    const rejoin = await wsConnect(port);
    rejoin.ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    await rejoin.nextAny();
    rejoin.ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    expect((await rejoin.nextAny()).kind).toBe('subscribed');
    const replay = await rejoin.nextAny();
    expect(replay.kind).toBe('replay');
    const userEv = replay.events.find((e: AnyMessage) => e.kind === 'text' && e.role === 'user');
    expect(userEv).toMatchObject({ imageCount: 1 });
    expect(JSON.stringify(replay)).not.toContain('AAAA');

    // DB meta 仍存完整 data URI(REST 历史回显的数据源),超限图在入口就被丢掉
    const meta = (db.prepare("SELECT meta FROM messages WHERE session_id=? AND role='user'").get(s.id) as { meta: string }).meta;
    expect(meta).toContain(tiny);
    expect(meta).not.toContain(oversized);

    // 只带超限图、没文字 → 过滤后空手,直接报参数错,不进运行时
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '', images: [oversized] }));
    expect(await nextAny()).toMatchObject({ kind: 'error', content: 'sessionId and content required' });
    ws.close();
    watcher.ws.close();
    rejoin.ws.close();
    await app.close();
  }, 15000);
});

// 引用 ProtocolEvent 类型,防止未使用告警
export type { ProtocolEvent };
