import type { FastifyInstance } from 'fastify';
import type { Db } from './db.js';
import { createSession, listSessions, getSession, updateSession, deleteSession, listMessages, sessionUsageSummary } from './db.js';
import { importLocalSessions } from './local-sessions.js';
import { listModels, listModelGroups, loadRoutes } from './routes.js';

export function registerHttpRoutes(app: FastifyInstance, deps: { db: Db; routesPath: string; onSessionDeleted?: (sessionId: string) => void; isRunning?: (sessionId: string) => boolean }): void {
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

  app.patch('/api/sessions/:id', async (req, reply) => {
    const row = updateSession(deps.db, (req.params as { id: string }).id, (req.body ?? {}) as never);
    if (!row) return reply.code(404).send({ error: 'not found' });
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
