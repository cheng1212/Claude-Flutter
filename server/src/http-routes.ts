import type { FastifyInstance } from 'fastify';
import type { Db } from './db.js';
import { createSession, listSessions, getSession, updateSession, deleteSession, listMessages, sessionUsageSummary } from './db.js';
import { importLocalSessions } from './local-sessions.js';
import { listModels, listModelGroups, loadRoutes } from './routes.js';

export function registerHttpRoutes(app: FastifyInstance, deps: { db: Db; routesPath: string; onSessionDeleted?: (sessionId: string) => void; onSessionPatched?: (sessionId: string, patch: { model?: string; permissionMode?: string }) => void; isRunning?: (sessionId: string) => boolean }): void {
  app.get('/api/models', async () => listModels(loadRoutes(deps.routesPath)));

  app.get('/api/models/grouped', async () => ({ groups: listModelGroups(loadRoutes(deps.routesPath)) }));

  // 附带 isRunning:手机列表标"运行中"徽章;排序本就是 置顶 → 最近更新
  app.get('/api/sessions', async () =>
    listSessions(deps.db).map((row) => ({ ...row, isRunning: deps.isRunning?.(row.id) ?? false })));

  app.post('/api/sessions/import-local', async (req) => {
    const body = (req.body ?? {}) as { projectsDir?: string };
    return importLocalSessions(deps.db, { projectsDir: body.projectsDir });
  });

  app.post('/api/sessions', async (req) => {
    const body = (req.body ?? {}) as { title?: string; cwd?: string; model?: string };
    return createSession(deps.db, body);
  });

  app.get('/api/sessions/:id', async (req, reply) => {
    const row = getSession(deps.db, (req.params as { id: string }).id);
    if (!row) return reply.code(404).send({ error: 'not found' });
    return row;
  });

  // PATCH 白名单 + 类型收敛:字符串 "false" 不再被真值判断成置顶;
  // permissionMode 只认 CLI 认识的六个值,未知值会被下一轮 buildOptions 原样透传给 CLI 拒掉。
  const PERMISSION_MODES = new Set(['default', 'acceptEdits', 'bypassPermissions', 'plan', 'dontAsk', 'auto']);
  app.patch('/api/sessions/:id', async (req, reply) => {
    const body = (req.body ?? {}) as Record<string, unknown>;
    const patch: { title?: string; isPinned?: boolean; providerSessionId?: string; model?: string; permissionMode?: string; cwd?: string } = {};
    if (typeof body.title === 'string') patch.title = body.title;
    if (body.isPinned !== undefined) patch.isPinned = body.isPinned === true || body.isPinned === 'true';
    if (typeof body.providerSessionId === 'string') patch.providerSessionId = body.providerSessionId;
    if (typeof body.model === 'string') patch.model = body.model;
    if (typeof body.permissionMode === 'string' && PERMISSION_MODES.has(body.permissionMode)) patch.permissionMode = body.permissionMode;
    if (typeof body.cwd === 'string') patch.cwd = body.cwd;
    const row = updateSession(deps.db, (req.params as { id: string }).id, patch);
    if (!row) return reply.code(404).send({ error: 'not found' });
    // 真热切换:有活着的 CLI 实例就现场设(模式立即对本回合生效);
    // 没有也不亏,下一条 send 的 runtimeFor 自会读 DB 新值。
    if (patch.model !== undefined || patch.permissionMode !== undefined) {
      deps.onSessionPatched?.((req.params as { id: string }).id, { model: patch.model, permissionMode: patch.permissionMode });
    }
    return row;
  });

  // 幂等删除:会话不存在 = 已删过,照样 {ok:true}。手机端批量循环里重复删不再 404 报错。
  app.delete('/api/sessions/:id', async (req) => {
    const id = (req.params as { id: string }).id;
    const existed = deleteSession(deps.db, id);
    if (existed) deps.onSessionDeleted?.(id); // 中止 runtime + 清 registry,防幽灵事件落库
    return { ok: true };
  });

  // 批量删除:一次请求搞定,App 不用循环单删(中途失败断一半)。
  app.post('/api/sessions/batch-delete', async (req) => {
    const body = (req.body ?? {}) as { ids?: unknown };
    const ids = Array.isArray(body.ids) ? body.ids.map(String).filter(Boolean).slice(0, 500) : [];
    const deleted: string[] = [];
    for (const id of ids) {
      if (deleteSession(deps.db, id)) deleted.push(id);
    }
    for (const id of deleted) deps.onSessionDeleted?.(id);
    return { ok: true, deleted: deleted.length, missing: ids.filter((i) => !deleted.includes(i)) };
  });

  app.get('/api/sessions/:id/messages', async (req) => {
    const id = (req.params as { id: string }).id;
    const q = req.query as { limit?: string; offset?: string };
    return listMessages(deps.db, id, {
      limit: q.limit ? Number(q.limit) : undefined,
      offset: q.offset ? Number(q.offset) : undefined,
    });
  });

  // 会话用量聚合:累计 token/缓存/费用 + 最近一轮上下文占用 + 消息构成(按字符量估算)
  app.get('/api/sessions/:id/usage', async (req) => {
    return sessionUsageSummary(deps.db, (req.params as { id: string }).id);
  });
}
