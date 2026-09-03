import path from 'node:path';
import { attachWsGateway } from './gateway/ws-gateway.js';
import { openDb } from './db.js';
import { loadOrCreateConfig } from './config.js';
import { buildApp } from './http.js';
import { loadRoutes, resolveModel } from './routes.js';
import { RunRegistry } from './runs/run-registry.js';
import { SessionRuntime } from './protocol/sdk-client.js';

const config = loadOrCreateConfig();
const db = openDb(path.join(config.dataDir, 'zcode.db'));
const registry = new RunRegistry();
const routes = loadRoutes(config.routesPath);
const runtimes = new Map<string, SessionRuntime>();

const app = await buildApp({ token: config.token, db, routesPath: config.routesPath }); // buildApp 内部已挂 REST

attachWsGateway(app.server, {
  db,
  token: config.token,
  registry,
  runtimeFor(sessionId, opts) {
    const existing = runtimes.get(sessionId);
    if (existing) return existing;
    const session = db.prepare('SELECT * FROM sessions WHERE id=?').get(sessionId) as
      | { cwd: string | null; provider_session_id: string | null; model: string | null; permission_mode: string }
      | undefined;
    if (!session) throw new Error(`session not found: ${sessionId}`);
    const modelId = opts.model ?? session.model ?? 'default';
    const resolved = resolveModel(routes, modelId);
    const runtime = new SessionRuntime({
      appSessionId: sessionId,
      providerSessionId: session.provider_session_id,
      cwd: session.cwd ?? process.cwd(),
      // 显式路由走 routeSettings;default/未知模型交给 CLI 自己的端点
      model: resolved ? undefined : (modelId === 'default' ? undefined : modelId),
      permissionMode: opts.permissionMode ?? session.permission_mode,
      routeSettings: resolved?.settings ?? null,
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
