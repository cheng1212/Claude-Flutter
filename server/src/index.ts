import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { attachWsGateway } from './gateway/ws-gateway.js';
import { openDb, failStaleRuns } from './db.js';
import { loadOrCreateConfig } from './config.js';
import { importLocalSessions } from './local-sessions.js';
import { buildApp } from './http.js';
import { loadRoutes, resolveModel } from './routes.js';
import { BackgroundRegistry } from './backgrounds.js';
import { startUpstreamProxy } from './proxy/upstream-proxy.js';
import { RunRegistry } from './runs/run-registry.js';
import { startCronScheduler } from './cron-scheduler.js';
import { SessionRuntime } from './protocol/sdk-client.js';
import { restartPlan, spawnRestart } from './restart.js';

const config = loadOrCreateConfig();

// 启动自证:入口文件的真实所在目录。入口是相对路径(src/index.ts)+ 错误 cwd 时,
// 会静默加载另一棵树的旧代码,而命令行里的 tsx 路径还可能被 junction 伪装成
// "看起来对"的那棵(踩过两次)。这行 + /api/health 的 sourceDir 让真相一眼可见。
const SOURCE_DIR = path.dirname(fileURLToPath(import.meta.url));
const STARTED_AT = new Date().toISOString();
console.log(`[zcode-server] source: ${SOURCE_DIR}`);
console.log(`[zcode-server] cwd: ${process.cwd()} (pid ${process.pid})`);

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
  webDir: config.webDir,
  projectsRoot: config.projectsRoot,
  sourceDir: SOURCE_DIR,
  startedAt: STARTED_AT,
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
    // 置顶/归档/改名等列表属性变更也广播:否则手机置顶后,电脑端列表
    // 要等下次手动刷新/重连才更新(跨端同步缺口)。sessions_dirty 走
    // gateway.notify(无 seq 不落库,各端 250ms 防抖拉列表),与开跑/跑完同路。
    gateway.notify({ kind: 'sessions_dirty', sessionId });
  },
  // app 点「重启服务器」:拉起脱离进程树的新实例,再走优雅停机退出。
  // gateway 还没建(声明在后面),所以重启动作走闭包引用,调用时已初始化。
  onRestart: () => { void restartSelf(); },
  // 定时任务「立即运行」:复用 gateway 的程序化触发(与到点触发同一条管线)
  triggerSession: (sessionId, prompt) => gateway.triggerSession(sessionId, prompt),
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
await app.listen({ port: config.port, host: '0.0.0.0' });

// cron 调度器:到点任务自动触发对应会话(程序化 chat.send 同管线)
const cronScheduler = startCronScheduler(db, (sessionId, prompt) =>
  gateway.triggerSession(sessionId, prompt),
);

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

// 自我重启(app 端「重启服务器」):拉起**脱离当前进程树**的新实例,再优雅退出。
// 顺序很讲究:先让 REST 应答发出去 → abort 在跑回合并等落库 → 关 HTTP 释放端口
// → 才 spawn 新实例(否则新旧抢 5190)→ 退出。新实例启动要 2~3 秒(tsx 编译),
// 那会儿端口已经空了。
let restarting = false;
async function restartSelf(): Promise<void> {
  if (restarting || shuttingDown) return;
  restarting = true;
  const plan = restartPlan({
    execPath: process.execPath,
    argv: process.argv, // 复现当前启动方式(tsx 加载器 + src/index.ts)
    cwd: process.cwd(),
    logFile: path.join(config.dataDir, 'server.out.log'),
  });
  console.log(`[zcode-server] restart requested: ${plan.cmd} ${plan.args.join(' ')} (cwd=${plan.cwd})`);
  const live = [...runtimes.entries()].filter(([id]) => registry.isRunning(id));
  if (live.length) console.log(`[zcode-server] restart: aborting ${live.length} running session(s)...`);
  for (const [, rt] of live) void rt.abort().catch(() => {});
  // 给 abort 落定/落库留时间(强裁兜底是 6s,这里只等 1.5s:重启不该让用户干等)
  await new Promise((r) => setTimeout(r, 1500));
  try {
    await app.close(); // 释放 5190/5191,让新实例能绑上
  } catch (error) {
    console.warn('[zcode-server] restart: close failed (continuing):', error instanceof Error ? error.message : error);
  }
  try {
    const pid = spawnRestart(plan);
    console.log(`[zcode-server] restart: new instance spawned (pid=${pid}), exiting.`);
  } catch (error) {
    console.error('[zcode-server] restart: spawn failed, staying alive:', error instanceof Error ? error.message : error);
    restarting = false; // 拉不起来就别死,留着旧进程继续服务
    return;
  }
  setTimeout(() => process.exit(0), 300).unref();
}
cronScheduler.stop();
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
