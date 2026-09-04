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
  // CORS:浏览器端 Flutter Web 跨域访问;必须先于鉴权钩子注册,OPTIONS 免鉴权短路。
  app.addHook('onRequest', async (req, reply) => {
    reply.header('Access-Control-Allow-Origin', '*');
    reply.header('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    reply.header('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
    if (req.method === 'OPTIONS') {
      await reply.code(204).send();
    }
  });
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
