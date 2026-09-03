import type { Server } from 'node:http';
import { WebSocketServer, type WebSocket } from 'ws';
import type { Db } from '../db.js';
import { appendMessage, updateSession } from '../db.js';
import type { OutboundEvent, RunRegistry } from '../runs/run-registry.js';

type RuntimeLike = {
  send(text: string): Promise<void>;
  abort(): Promise<void>;
  answerPermission(requestId: string, decision: { allow: boolean; updatedInput?: unknown; message?: string }): void;
};

export type WsGatewayDeps = {
  db: Db;
  token: string;
  registry: RunRegistry;
  runtimeFor(appSessionId: string, opts: { cwd?: string; model?: string | null; permissionMode?: string }): RuntimeLike;
};

type StateWs = WebSocket & { authed?: boolean; subs?: Set<string> };

// complete 由 registry.finish/兜底发,不落 messages;session_created 落 sessions 表
const PERSIST_KINDS = new Set(['text', 'thinking', 'tool_use', 'tool_result', 'error']);

function send(ws: WebSocket, payload: unknown): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(payload));
}

export function attachWsGateway(server: Server, deps: WsGatewayDeps): void {
  const wss = new WebSocketServer({ server });
  const runtimes = new Map<string, RuntimeLike>();
  // 每会话一条全局订阅(持久化+广播只做一次);refs = 订阅中的连接数
  const sessionSubs = new Map<string, { off: () => void; refs: number }>();

  const fanout = (sessionId: string, event: OutboundEvent): void => {
    if (PERSIST_KINDS.has(event.kind)) {
      const content = event.kind === 'tool_use'
        ? JSON.stringify((event as unknown as { toolInput: unknown }).toolInput)
        : String((event as { content?: string }).content ?? '');
      appendMessage(deps.db, sessionId, {
        kind: event.kind,
        role: (event as { role?: string }).role,
        content,
        meta: event,
      });
    } else if (event.kind === 'session_created') {
      updateSession(deps.db, sessionId, { providerSessionId: (event as { providerSessionId: string }).providerSessionId });
    }
    for (const client of wss.clients) {
      const c = client as StateWs;
      if (c.authed && c.subs?.has(sessionId)) send(c, { ...event, sessionId });
    }
  };

  const ensureSub = (sessionId: string): void => {
    const existing = sessionSubs.get(sessionId);
    if (existing) { existing.refs++; return; }
    sessionSubs.set(sessionId, { refs: 1, off: deps.registry.subscribe(sessionId, (e) => fanout(sessionId, e)) });
  };

  const dropRef = (sessionId: string): void => {
    const entry = sessionSubs.get(sessionId);
    if (!entry) return;
    entry.refs--;
    if (entry.refs <= 0) { entry.off(); sessionSubs.delete(sessionId); }
  };

  wss.on('connection', (raw: WebSocket) => {
    const ws = raw as StateWs;
    const subs = new Set<string>();
    ws.subs = subs;

    ws.on('message', (rawMsg) => {
      let data: Record<string, unknown>;
      try { data = JSON.parse(String(rawMsg)); } catch { return; }
      const type = data.type as string;

      if (type === 'auth') {
        ws.authed = data.token === deps.token;
        send(ws, ws.authed ? { kind: 'authenticated' } : { kind: 'error', content: 'unauthorized' });
        if (!ws.authed) ws.close();
        return;
      }
      if (!ws.authed) { send(ws, { kind: 'error', content: 'unauthorized' }); ws.close(); return; }

      if (type === 'ping') { send(ws, { kind: 'pong' }); return; }

      if (type === 'chat.subscribe') {
        const entries = Array.isArray(data.sessions) ? data.sessions as { sessionId?: string; lastSeq?: number }[] : [];
        for (const entry of entries) {
          const sessionId = String(entry?.sessionId ?? '');
          if (!sessionId) continue;
          if (!subs.has(sessionId)) { subs.add(sessionId); ensureSub(sessionId); }
          const live = deps.registry.isRunning(sessionId);
          send(ws, { kind: 'subscribed', sessionId, isProcessing: live, lastSeq: deps.registry.lastSeq(sessionId) });
          const replayed = deps.registry.replay(sessionId, entry.lastSeq ?? 0);
          if (replayed.length) send(ws, { kind: 'replay', sessionId, events: replayed });
        }
        return;
      }

      if (type === 'chat.permission-response') {
        const runtime = runtimes.get(String(data.sessionId ?? ''));
        runtime?.answerPermission(String(data.requestId ?? ''), {
          allow: Boolean(data.allow),
          updatedInput: data.updatedInput,
          message: typeof data.message === 'string' ? data.message : undefined,
        });
        return;
      }

      if (type === 'chat.abort') {
        const sessionId = String(data.sessionId ?? '');
        const runtime = runtimes.get(sessionId);
        if (runtime) void runtime.abort();
        return;
      }

      if (type === 'chat.send') {
        const sessionId = String(data.sessionId ?? '');
        const content = typeof data.content === 'string' ? data.content : '';
        const options = (data.options ?? {}) as { model?: string; permissionMode?: string };
        if (!sessionId || !content) { send(ws, { kind: 'error', content: 'sessionId and content required' }); return; }
        if (deps.registry.isRunning(sessionId)) { send(ws, { kind: 'error', content: 'RUN_IN_PROGRESS', sessionId }); return; }

        let runtime = runtimes.get(sessionId);
        if (!runtime) {
          runtime = deps.runtimeFor(sessionId, { model: options.model, permissionMode: options.permissionMode });
          runtimes.set(sessionId, runtime);
        }
        if (!subs.has(sessionId)) { subs.add(sessionId); ensureSub(sessionId); } // 发送方至少自己收到
        deps.registry.begin(sessionId);
        runtime.send(content).catch((error: unknown) => {
          deps.registry.push(sessionId, { kind: 'error', content: error instanceof Error ? error.message : String(error) });
        }).finally(() => {
          const last = deps.registry.lastEvent(sessionId);
          if (!last || last.kind !== 'complete') deps.registry.finish(sessionId, 1, false); // 兜底,不与 runtime 重复
        });
        return;
      }
    });

    ws.on('close', () => {
      for (const sessionId of subs) dropRef(sessionId);
      subs.clear();
    });
  });
}
