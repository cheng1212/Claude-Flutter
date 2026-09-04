import path from 'node:path';
import { attachWsGateway } from './gateway/ws-gateway.js';
import { openDb, failStaleRuns } from './db.js';
import { loadOrCreateConfig } from './config.js';
import { importLocalSessions } from './local-sessions.js';
import { buildApp } from './http.js';
import { loadRoutes, resolveModel } from './routes.js';
import { RunRegistry } from './runs/run-registry.js';
import { SessionRuntime } from './protocol/sdk-client.js';

const config = loadOrCreateConfig();
const db = openDb(path.join(config.dataDir, 'zcode.db'));
const staleRuns = failStaleRuns(db);
if (staleRuns > 0) console.log(`[zcode-server] marked ${staleRuns} stale run(s) as interrupted`);
const registry = new RunRegistry();
const routes = loadRoutes(config.routesPath);
const runtimes = new Map<string, SessionRuntime>();

// 启动时导入本机 Claude Code 真会话(幂等,失败不阻断启动)。
try {
  const sum = importLocalSessions(db);
  if (sum.imported > 0) console.log(`[zcode-server] imported ${sum.imported} local sessions (${sum.skipped} skipped)`);
} catch (error) {
  console.warn('[zcode-server] local session import failed:', error instanceof Error ? error.message : error);
}

const app = await buildApp({
  token: config.token,
  db,
  routesPath: config.routesPath,
  publicDir: config.publicDir,
  // 会话列表的"运行中"徽章数据源
  isRunning: (sessionId) => registry.isRunning(sessionId),
  // 会话被删:中止还在跑的 runtime 并清 registry,防幽灵事件继续给已删会话发号落库
  onSessionDeleted(sessionId) {
    const runtime = runtimes.get(sessionId);
    if (runtime) {
      runtimes.delete(sessionId);
      void runtime.abort();
    }
    registry.forget(sessionId);
  },
}); // buildApp 内部已挂 REST

attachWsGateway(app.server, {
  db,
  token: config.token,
  registry,
  runtimeFor(sessionId, opts) {
    const session = db.prepare('SELECT * FROM sessions WHERE id=?').get(sessionId) as
      | { cwd: string | null; provider_session_id: string | null; model: string | null; permission_mode: string }
      | undefined;
    if (!session) throw new Error(`session not found: ${sessionId}`);
    const modelId = opts.model ?? session.model ?? 'default';
    const resolved = resolveModel(routes, modelId);
    // 会话配置每次现算:用户 PATCH 过 model/permission_mode 后,下一条 send 自动带上新值,
    // 不用重启 server / 不用重建运行时。
    const cfg = {
      // 显式路由走 routeSettings;default/未知模型交给 CLI 自己的端点
      model: resolved ? undefined : (modelId === 'default' ? undefined : modelId),
      permissionMode: opts.permissionMode ?? session.permission_mode,
      routeSettings: resolved?.settings ?? null,
    };
    const existing = runtimes.get(sessionId);
    if (existing) {
      existing.update(cfg);
      return existing;
    }
    const runtime = new SessionRuntime({
      appSessionId: sessionId,
      providerSessionId: session.provider_session_id,
      cwd: session.cwd ?? process.cwd(),
      ...cfg,
      bgCeilingMs: config.bgCeilingMs,
      approvalTimeoutMs: config.approvalTimeoutMs,
      emit: (event) => registry.push(sessionId, event),
    });
    runtimes.set(sessionId, runtime);
    return runtime;
  },
});

console.log(`[zcode-server] listening on http://0.0.0.0:${config.port}`);
console.log(`[zcode-server] token: ${config.token}`);
await app.listen({ port: config.port, host: '0.0.0.0' });
