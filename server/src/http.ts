import type { FastifyInstance } from 'fastify';
import fastify from 'fastify';
import { registerHttpRoutes } from './http-routes.js';
import type { Db } from './db.js';

export type AppOptions = {
  token: string;
  db?: Db;
  routesPath?: string;
};

export async function buildApp(opts: AppOptions): Promise<FastifyInstance> {
  const app = fastify();
  app.get('/api/health', async () => ({ ok: true }));
  if (opts.db && opts.routesPath) {
    registerHttpRoutes(app, { db: opts.db, routesPath: opts.routesPath });
  }
  app.addHook('onRequest', async (req, reply) => {
    if (!req.url.startsWith('/api/') || req.url.startsWith('/api/health')) return;
    const header = req.headers.authorization ?? '';
    if (header !== `Bearer ${opts.token}`) {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });
  return app;
}
