import { describe, expect, it } from 'vitest';
import { createServer } from 'node:http';
import { WebSocket } from 'ws';
import { buildApp } from '../src/http.js';
import { attachWsGateway } from '../src/gateway/ws-gateway.js';
import { RunRegistry } from '../src/runs/run-registry.js';
import { openDb, createSession } from '../src/db.js';
import type { SessionRuntime } from '../src/protocol/sdk-client.js';
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
    expect(e1).toMatchObject({ kind: 'text', content: 'echo:你好', seq: 1 });
    const e2 = await next();
    expect(e2).toMatchObject({ kind: 'complete', exitCode: 0, seq: 2 });
    await new Promise((r) => setTimeout(r, 50)); // 给 finally 一拍,确认没有多余 complete
    expect(pending().filter((m) => m.kind === 'complete')).toHaveLength(0);

    // 3) 重连补发
    const { ws: ws2, next: next2 } = await wsConnect(port);
    ws2.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next2();
    ws2.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    expect((await next2()).kind).toBe('subscribed');
    const replay = await next2();
    expect(replay.kind).toBe('replay');
    expect(replay.events).toHaveLength(2);
    ws.close();
    ws2.close();
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
    expect((await next()).kind).toBe('text');

    // 运行中再发 → RUN_IN_PROGRESS
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'b' }));
    expect(await next()).toMatchObject({ kind: 'error', content: 'RUN_IN_PROGRESS' });

    ws.send(JSON.stringify({ type: 'chat.permission-response', sessionId: s.id, requestId: 'r1', allow: true }));
    await waitFor(() => calls.some((c) => c.startsWith('perm:')));
    ws.send(JSON.stringify({ type: 'chat.abort', sessionId: s.id }));
    await waitFor(() => calls.includes('abort'));
    expect(await next()).toMatchObject({ kind: 'complete', exitCode: 1 }); // finally 兜底
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
    expect(await connA.next()).toMatchObject({ kind: 'text', content: 'r:hi' });
    expect(await connA.next()).toMatchObject({ kind: 'complete' });
    expect(await connB.next()).toMatchObject({ kind: 'text', content: 'r:hi' }); // B 也在听
    expect(await connB.next()).toMatchObject({ kind: 'complete' });

    const rows = db.prepare('SELECT COUNT(*) AS c FROM messages WHERE session_id=?').get(s.id) as { c: number };
    expect(rows.c).toBe(1); // 只持久化一份
    connA.ws.close();
    connB.ws.close();
    await app.close();
  });
});

// 引用 ProtocolEvent 类型,防止未使用告警
export type { ProtocolEvent };
