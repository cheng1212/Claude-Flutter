import type { FastifyInstance } from 'fastify';
import type { Db } from './db.js';
import { createSession, listSessions, getSession, updateSession, deleteSession, listMessages } from './db.js';
import { listModels, loadRoutes } from './routes.js';

export function registerHttpRoutes(app: FastifyInstance, deps: { db: Db; routesPath: string }): void {
  app.get('/api/models', async () => listModels(loadRoutes(deps.routesPath)));

  app.get('/api/sessions', async () => listSessions(deps.db));

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

  app.delete('/api/sessions/:id', async (req) => {
    const ok = deleteSession(deps.db, (req.params as { id: string }).id);
    return { ok };
  });

  app.get('/api/sessions/:id/messages', async (req) => {
    const id = (req.params as { id: string }).id;
    const q = req.query as { limit?: string; offset?: string };
    return listMessages(deps.db, id, {
      limit: q.limit ? Number(q.limit) : undefined,
      offset: q.offset ? Number(q.offset) : undefined,
    });
  });
}
