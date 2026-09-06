import type { Server } from 'node:http';
import { WebSocketServer, type WebSocket } from 'ws';
import type { Db } from '../db.js';
import { appendMessage, updateSession, maxSeq, createRun, finishRun, recordCronToolUse } from '../db.js';
import type { OutboundEvent, RunRegistry } from '../runs/run-registry.js';

type RuntimeLike = {
  send(text: string, images?: string[]): Promise<void>;
  abort(): Promise<void>;
  answerPermission(requestId: string, decision: { allow: boolean; updatedInput?: unknown; message?: string; rememberTool?: boolean }): void;
  /** 在等用户审批的请求:subscribed(isProcessing=true) 带回,客户端重建审批卡。 */
  pendingPermissions?(): { requestId: string; toolName: string; input: unknown }[];
};

export type WsGatewayDeps = {
  db: Db;
  token: string;
  registry: RunRegistry;
  backgrounds?: {
    onToolUse(sessionId: string, toolName: string, toolId: string, input: unknown): void;
    onToolResult(sessionId: string, toolId: string, content: string, isError: boolean): void;
    onTaskEvent(sessionId: string, ev: {
      kind: string; taskId?: string; toolUseId?: string; description?: string;
      taskType?: string; subagentType?: string; status?: string; summary?: string; outputFile?: string;
    }): void;
  };
  runtimeFor(appSessionId: string, opts: { cwd?: string; model?: string | null; permissionMode?: string }): RuntimeLike;
};

/** attachWsGateway 返回的句柄:供外部(上游代理)往已订阅客户端推瞬态状态。 */
export type WsGatewayHandle = {
  /** upstream_status 等"无 seq、不落库、不补发"的瞬态广播;sessionId 为 null 时发给全部已认证连接。 */
  notify(payload: Record<string, unknown>): void;
  /** 最近一次 chat.send 的会话:上游代理的计时事件归到这里(个人服务器同时只跑一两个回合,足够准)。 */
  lastActiveSession(): string | null;
};

type StateWs = WebSocket & { authed?: boolean; subs?: Set<string>; alive?: boolean };

/** 单帧消息上限(32MB):4 张图(各 ≤5MB data URI)+ JSON 开销也够用,再大直接掐连接。 */
const MAX_WS_FRAME = 32 * 1024 * 1024;
/** 单图 data URI 上限(≈3.7MB 二进制):防一条消息塞几十 MB base64 拖垮 WS、DB 和 CLI。 */
const MAX_IMAGE_URI = 5 * 1024 * 1024;

/** 广播/补发线上的用户图片剥成 imageCount:几 MB 的 base64 不该在实时流和重连补发里
 *  重复传输(手机流量/内存都扛不住);完整 data URI 只进 DB meta(REST 历史仍可回显)。 */
function toWire(event: OutboundEvent): OutboundEvent {
  const images = (event as { images?: string[] }).images;
  if (!images || images.length === 0) return event;
  const wire = { ...event } as OutboundEvent & { images?: string[]; imageCount?: number };
  delete wire.images;
  wire.imageCount = images.length;
  return wire;
}

// 这些 kind 一律落 messages(带行号 seq),保证 registry seq 与 DB seq 严格 lockstep;
// session_created 额外回填 sessions 表。落库与 WS 订阅解耦(见 ensureSub 常驻订阅)。
const PERSIST_KINDS = new Set(['text', 'thinking', 'tool_use', 'tool_result', 'error', 'usage', 'complete', 'session_created']);

function send(ws: WebSocket, payload: unknown): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(payload));
}

/** 控制事件(无 seq,不落库):任一会话开跑/跑完都喊一嗓子,各端刷新会话列表的"运行中"徽章。 */
function broadcastDirty(wss: WebSocketServer, sessionId: string): void {
  for (const client of wss.clients) {
    const c = client as StateWs;
    if (c.authed) send(c, { kind: 'sessions_dirty', sessionId });
  }
}

export function attachWsGateway(server: Server, deps: WsGatewayDeps): WsGatewayHandle {
  const wss = new WebSocketServer({ server, maxPayload: MAX_WS_FRAME });
  const runtimes = new Map<string, RuntimeLike>();
  let lastSend: string | null = null;
  // 每会话一条全局订阅(持久化+广播只做一次);refs = 订阅中的连接数
  const sessionSubs = new Map<string, { off: () => void; refs: number }>();
  // 开跑过的会话常驻一条订阅:落库/收 run 不能依赖"有没有人正看着",
  // 否则零客户端期间的事件只进内存环,重启即丢,run 行也永远停在 running。
  const permanentSubs = new Set<string>();
  // 进行中的 run:落 usage/complete 进 runs 表(会话用量统计的数据源)
  const activeRuns = new Map<string, { runId: string; usage: unknown }>();
  // 后台任务登记(Bash run_in_background / BashOutput / KillShell)
  const backgrounds = deps.backgrounds;

  const fanout = (sessionId: string, event: OutboundEvent): void => {
    if (event.kind === 'tool_use') {
      recordCronToolUse(deps.db, sessionId, event as unknown as { toolName?: unknown; toolInput?: unknown });
      backgrounds?.onToolUse(
        sessionId,
        String((event as { toolName?: unknown }).toolName ?? ''),
        String((event as { toolId?: unknown }).toolId ?? ''),
        (event as { toolInput?: unknown }).toolInput,
      );
    }
    if (event.kind === 'tool_result') {
      backgrounds?.onToolResult(
        sessionId,
        String((event as { toolId?: unknown }).toolId ?? ''),
        String((event as { content?: unknown }).content ?? ''),
        (event as { isError?: unknown }).isError === true,
      );
    }
    if (event.kind === 'task_started' || event.kind === 'task_updated' || event.kind === 'task_complete') {
      backgrounds?.onTaskEvent(sessionId, event as unknown as { kind: string; taskId?: string });
    }
    if (event.kind === 'usage') {
      const row = activeRuns.get(sessionId);
      if (row) row.usage = event; // 完成时随 run 一起落库
    } else if (event.kind === 'complete') {
      const row = activeRuns.get(sessionId);
      if (row) {
        activeRuns.delete(sessionId);
        const u = row.usage as { totalCostUsd?: number } | null;
        finishRun(deps.db, row.runId, {
          status: (event as { aborted?: boolean }).aborted ? 'aborted' : (event as { exitCode?: number }).exitCode === 0 ? 'success' : 'error',
          totalCostUsd: u?.totalCostUsd,
          usage: row.usage,
        });
      }
      broadcastDirty(wss, sessionId); // 跑完:各端列表的"运行中"徽章该灭了
    } else if (event.kind === 'permission_request') {
      // 弹审批也喊一嗓子:会话列表亮琥珀"待确认",那才是最需要用户回去处理的会话
      broadcastDirty(wss, sessionId);
    }
    if (PERSIST_KINDS.has(event.kind)) {
      const content = event.kind === 'tool_use'
        ? JSON.stringify((event as unknown as { toolInput: unknown }).toolInput)
        : String((event as { content?: string }).content ?? '');
      appendMessage(deps.db, sessionId, {
        seq: event.seq, // 用 registry 发的号落库:WS 与 DB 同一 seq 空间
        kind: event.kind,
        role: (event as { role?: string }).role,
        content,
        meta: event,
      });
    }
    if (event.kind === 'session_created') {
      updateSession(deps.db, sessionId, { providerSessionId: (event as { providerSessionId: string }).providerSessionId });
    }
    // 线上载荷剥图 + 全体订阅者复用同一串 JSON(每事件只 stringify 一次)
    const wire = toWire(event);
    const payload = JSON.stringify({ ...wire, sessionId });
    for (const client of wss.clients) {
      const c = client as StateWs;
      if (c.authed && c.subs?.has(sessionId) && c.readyState === c.OPEN) c.send(payload);
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
    entry.refs = Math.max(0, entry.refs - 1);
    if (entry.refs <= 0 && !permanentSubs.has(sessionId)) { entry.off(); sessionSubs.delete(sessionId); }
  };

  // 服务端心跳验活:30s 一轮 ping,两轮无 pong 的死连接(手机杀后台没断干净)强制摘除,
  // 不然 wss.clients 越积越多,fanout 还在往死连接上写。
  const heartbeat = setInterval(() => {
    for (const client of wss.clients) {
      const c = client as StateWs;
      if (c.alive === false) { c.terminate(); continue; }
      c.alive = false;
      c.ping();
    }
  }, 30_000);
  heartbeat.unref();
  wss.on('close', () => clearInterval(heartbeat));

  wss.on('connection', (raw: WebSocket) => {
    const ws = raw as StateWs;
    const subs = new Set<string>();
    ws.subs = subs;
    ws.alive = true;
    ws.on('pong', () => { ws.alive = true; });

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
          // 吸收客户端水位(只进不退):重启后指针从 DB maxSeq 起步,若某客户端已见过
          // 更大的 seq(老服务时代发出去的),把指针抬过去,防新事件 seq 撞车被去重吞掉。
          const clientSeq = Number(entry.lastSeq ?? 0);
          if (Number.isFinite(clientSeq) && clientSeq > 0) deps.registry.seedSeq(sessionId, clientSeq);
          const live = deps.registry.isRunning(sessionId);
          // pending:等审批的请求随 subscribed 带回(App 重启后重建审批卡,不再丢卡卡死)。
          // replay 也会补发 permission_request(占号进缓冲),这里是确定性通道,双保险。
          const pending = live ? runtimes.get(sessionId)?.pendingPermissions?.() ?? [] : [];
          send(ws, { kind: 'subscribed', sessionId, isProcessing: live, lastSeq: deps.registry.lastSeq(sessionId), pending });
          const replayed = deps.registry.replay(sessionId, entry.lastSeq ?? 0);
          if (replayed.length) send(ws, { kind: 'replay', sessionId, events: replayed.map(toWire) });
        }
        return;
      }

      if (type === 'chat.permission-response') {
        const runtime = runtimes.get(String(data.sessionId ?? ''));
        runtime?.answerPermission(String(data.requestId ?? ''), {
          allow: Boolean(data.allow),
          updatedInput: data.updatedInput,
          message: typeof data.message === 'string' ? data.message : undefined,
          rememberTool: data.rememberTool === true,
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
        const images = Array.isArray(data.images)
          ? data.images.filter((x: unknown): x is string =>
              typeof x === 'string' && x.length <= MAX_IMAGE_URI && /^data:image\//.test(x)).slice(0, 4)
          : [];
        const options = (data.options ?? {}) as { model?: string; permissionMode?: string };
        if (!sessionId || (!content && images.length === 0)) { send(ws, { kind: 'error', content: 'sessionId and content required' }); return; }
        if (deps.registry.isRunning(sessionId)) { send(ws, { kind: 'error', content: 'RUN_IN_PROGRESS', sessionId }); return; }

        // 每次 send 都经 runtimeFor 取/建运行时:命中已建实例时,runtimeFor 会用 DB 最新的
        // model/permission_mode(PATCH 后)热更新它,权限模式/换模型不重启即生效。
        // 会话已删/不存在会抛错 → 回 error,不让异常炸掉 ws 事件循环。
        let runtime: RuntimeLike;
        try {
          runtime = deps.runtimeFor(sessionId, { model: options.model, permissionMode: options.permissionMode });
        } catch (error) {
          send(ws, { kind: 'error', content: error instanceof Error ? error.message : String(error), sessionId });
          return;
        }
        runtimes.set(sessionId, runtime);
        lastSend = sessionId; // 上游计时事件的归属(代理看不到会话,只知道流量来了)
        permanentSubs.add(sessionId); // 从此落库不依赖客户端在场
        subs.add(sessionId);
        ensureSub(sessionId); // 发送方收到回显 + 常驻系统引用(refs ≥ 1,客户端全走光也摘不掉)
        // 本地导入的历史消息占了 1..N,先抬 seq 指针,避免新事件 seq 撞车被前端去重吞掉。
        deps.registry.seedSeq(sessionId, maxSeq(deps.db, sessionId));
        deps.registry.begin(sessionId);
        broadcastDirty(wss, sessionId); // 开跑:各端列表亮"运行中"
        // begin 之后任何同步异常都必须 finish 释放 running,否则会话永久卡死(所有 send 被 RUN_IN_PROGRESS 拒)。
        try {
          activeRuns.set(sessionId, { runId: createRun(deps.db, sessionId, options.model ?? null).id, usage: null });
          // 用户消息走 registry:拿到 seq、进环形缓冲(重连补发)、经 fanout 持久化。
          // meta 里只存图片 data URI 引用(前端气泡可回显),不发巨大的 base64 给其他端。
          // CLI 只回显 assistant 侧,不会重复。
          deps.registry.push(sessionId, { kind: 'text', role: 'user', content, ...(images.length ? { images } : {}) });
        } catch (error) {
          deps.registry.finish(sessionId, 1, false);
          send(ws, { kind: 'error', content: error instanceof Error ? error.message : String(error), sessionId });
          return;
        }
        runtime.send(content, images).catch((error: unknown) => {
          deps.registry.push(sessionId, { kind: 'error', content: error instanceof Error ? error.message : String(error) });
        }).finally(() => {
          const last = deps.registry.lastEvent(sessionId);
          if (last && last.kind === 'complete') deps.registry.clearRunning(sessionId); // runtime 已发过终态
          else deps.registry.finish(sessionId, 1, false); // 兜底补发
        });
        return;
      }
    });

    ws.on('close', () => {
      for (const sessionId of subs) dropRef(sessionId);
      subs.clear();
    });
  });

  return {
    notify(payload) {
      const sessionId = payload.sessionId as string | null | undefined;
      const data = JSON.stringify(payload);
      for (const client of wss.clients) {
        const c = client as StateWs;
        if (!c.authed || c.readyState !== c.OPEN) continue;
        // 有归属就只发给订阅者;没有归属(PC CloudCLI 直用中转模型)广播,各端自行取舍
        if (sessionId && !c.subs?.has(sessionId)) continue;
        c.send(data);
      }
    },
    lastActiveSession: () => lastSend,
  };
}
