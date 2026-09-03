import type { FastifyInstance } from 'fastify';
import fastify from 'fastify';

export type AppOptions = { token: string };

export async function buildApp(opts: AppOptions): Promise<FastifyInstance> {
  const app = fastify();
  app.get('/api/health', async () => ({ ok: true }));
  app.addHook('onRequest', async (req, reply) => {
    if (!req.url.startsWith('/api/') || req.url.startsWith('/api/health')) return;
    const header = req.headers.authorization ?? '';
    if (header !== `Bearer ${opts.token}`) {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });
  return app;
}
