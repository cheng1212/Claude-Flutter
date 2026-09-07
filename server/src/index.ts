import path from 'node:path';
import { attachWsGateway } from './gateway/ws-gateway.js';
import { openDb, failStaleRuns } from './db.js';
import { loadOrCreateConfig } from './config.js';
import { importLocalSessions } from './local-sessions.js';
import { buildApp } from './http.js';
import { loadRoutes, resolveModel } from './routes.js';
import { BackgroundRegistry } from './backgrounds.js';
import { startUpstreamProxy } from './proxy/upstream-proxy.js';
import { RunRegistry } from './runs/run-registry.js';
import { SessionRuntime } from './protocol/sdk-client.js';

const config = loadOrCreateConfig();
const db = openDb(path.join(config.dataDir, 'zcode.db'));
const staleRuns = failStaleRuns(db);
if (staleRuns > 0) console.log(`[zcode-server] marked ${staleRuns} stale run(s) as interrupted`);
const registry = new RunRegistry();
const backgrounds = new BackgroundRegistry();
const runtimes = new Map<string, SessionRuntime>();

// runtimeFor 与 PATCH 回调共用的"会话配置现算":DB 现值 + routes 热读。
// 返回 null = 会话不存在;bareModel = 非路由别名的裸模型名(才值得对 CLI 现场设)。
const refreshCfg = (sessionId: string, opts?: { model?: string | null; permissionMode?: string; thinking?: string }) => {
  const session = db.prepare('SELECT * FROM sessions WHERE id=?').get(sessionId) as
    | { cwd: string | null; provider_session_id: string | null; fork_from: string | null; model: string | null; permission_mode: string }
    | undefined;
  if (!session) return null;
  const modelId = opts?.model ?? session.model ?? 'default';
  // 路由表现读(不缓存启动快照):运行中改 routes.json,聊天路由与 /api/models 立即一致,
  // 不会出现"列表有新模型、聊天却按旧表裸名透传报错"的行为分裂。
  const resolved = resolveModel(loadRoutes(config.routesPath), modelId);
  const cfg = {
    // 显式路由走 routeSettings;default/未知模型交给 CLI 自己的端点
    model: resolved ? undefined : (modelId === 'default' ? undefined : modelId),
    permissionMode: opts?.permissionMode ?? session.permission_mode,
    routeSettings: resolved?.settings ?? null,
    // 思考等级(会话内存态,chat.send options 传入;off/low/medium/high,on=模型默认)
    thinkingLevel: opts?.thinking,
  };
  return {
    session, cfg,
    bareModel: resolved ? null : (modelId === 'default' ? null : modelId),
    // 复制会话:无独立 provider id 且记了 fork_from → 首轮 send 用 SDK forkSession 分叉
    resumeId: session.provider_session_id ?? session.fork_from ?? null,
    fork: !session.provider_session_id && !!session.fork_from,
  };
};

const app = await buildApp({
  token: config.token,
  db,
  routesPath: config.routesPath,
  publicDir: config.publicDir,
  projectsRoot: config.projectsRoot,
  // 会话列表的"运行中"徽章数据源
  isRunning: (sessionId) => registry.isRunning(sessionId),
  backgrounds: (sessionId) => backgrounds.list(sessionId),
  // "待确认"徽章数据源:在跑且 runtime 手里有等审批的请求
  isAwaiting: (sessionId) => {
    const runtime = runtimes.get(sessionId);
    return registry.isRunning(sessionId) && (runtime?.pendingPermissions().length ?? 0) > 0;
  },
  // 会话被删:中止还在跑的 runtime 并清 registry,防幽灵事件继续给已删会话发号落库
  onSessionDeleted(sessionId) {
    const runtime = runtimes.get(sessionId);
    if (runtime) {
      runtimes.delete(sessionId);
      void runtime.abort();
    }
    registry.forget(sessionId);
  },
  // 真热切换:PATCH 落库后,有活着的 CLI 实例就现场设;没有则等下一条 send。
  onSessionPatched(sessionId, patch) {
    const runtime = runtimes.get(sessionId);
    if (!runtime) return;
    const ctx = refreshCfg(sessionId);
    if (ctx) runtime.update(ctx.cfg);
    if (patch.permissionMode) void runtime.setPermissionModeLive(patch.permissionMode);
    if (ctx?.bareModel && patch.model) void runtime.setModelLive(patch.model);
  },
}); // buildApp 内部已挂 REST

const gateway = attachWsGateway(app.server, {
  db,
  token: config.token,
  registry,
  backgrounds,
  runtimeFor(sessionId, opts) {
    const ctx = refreshCfg(sessionId, opts);
    if (!ctx) throw new Error(`session not found: ${sessionId}`);
    const existing = runtimes.get(sessionId);
    if (existing) {
      existing.update(ctx.cfg);
      return existing;
    }
    const runtime = new SessionRuntime({
      appSessionId: sessionId,
      providerSessionId: ctx.resumeId,
      forkSession: ctx.fork,
      cwd: ctx.session.cwd ?? process.cwd(),
      ...ctx.cfg,
      bgCeilingMs: config.bgCeilingMs,
      approvalTimeoutMs: config.approvalTimeoutMs,
      // 子代理模型约束:设置后本服务器所有会话派子代理一律用此模型(如 'haiku')
      subagentModel: process.env.ZCODE_SUBAGENT_MODEL || undefined,
      emit: (event) => registry.push(sessionId, event),
    });
    runtimes.set(sessionId, runtime);
    return runtime;
  },
});

// 上游中转代理:routes.json 里 relayTo 条目(zcode 自家模型)的流量必经之路。
// 计时事件归属最近一次 chat.send 的会话广播出去,手机静默期显示"已转发上游"真状态。
startUpstreamProxy({
  port: config.relayPort,
  routesPath: config.routesPath,
  onStatus: (status) => {
    gateway.notify({ kind: 'upstream_status', sessionId: gateway.lastActiveSession(), ...status });
  },
});
console.log(`[zcode-server] upstream relay proxy on http://127.0.0.1:${config.relayPort}`);

console.log(`[zcode-server] listening on http://0.0.0.0:${config.port}`);
console.log(`[zcode-server] token: ${config.token}`);
await app.listen({ port: config.port, host: '0.0.0.0' });

// 本机会话导入在 listen 之后异步跑:不让手机连上来干等(会话多时全量解析要一会儿)。
void (async () => {
  try {
    const sum = importLocalSessions(db);
    if (sum.imported > 0) console.log(`[zcode-server] imported ${sum.imported} local sessions (${sum.skipped} skipped)`);
  } catch (error) {
    console.warn('[zcode-server] local session import failed:', error instanceof Error ? error.message : error);
  }
})();

// 优雅停机:中断在跑的回合,给落库/finishRun 一点宽限再退,别靠 failStaleRuns 兜底。
let shuttingDown = false;
const shutdown = (signal: string) => {
  if (shuttingDown) return;
  shuttingDown = true;
  const live = [...runtimes.entries()].filter(([id]) => registry.isRunning(id));
  console.log(`[zcode-server] ${signal}: aborting ${live.length} running session(s)...`);
  for (const [, rt] of live) void rt.abort().catch(() => {});
  setTimeout(() => process.exit(0), 3000).unref();
};
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
