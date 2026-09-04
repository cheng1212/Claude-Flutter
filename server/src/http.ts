import fs from 'node:fs';
import path from 'node:path';
import type { FastifyInstance } from 'fastify';
import fastify from 'fastify';
import { registerHttpRoutes } from './http-routes.js';
import type { Db } from './db.js';

export type AppOptions = {
  token: string;
  db?: Db;
  routesPath?: string;
  /** 静态分发目录:/download/:name 按精确文件名发送,免鉴权(给手机下载 APK 用) */
  publicDir?: string;
  onSessionDeleted?: (sessionId: string) => void;
  /** 会话是否在跑(注入 registry.isRunning):列表接口据此标"运行中"徽章 */
  isRunning?: (sessionId: string) => boolean;
  /** 在跑会话数(注入):health 暴露,手机端诊断"连的是不是旧进程" */
  runningCount?: () => number;
};

// /download 只认安全文件名:杜绝路径穿越(../、反斜杠、隐藏文件)
const DOWNLOAD_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

// server 自身版本(health 暴露):从 cwd 读 package.json(npm start 的 cwd 就是 server/),
// 读不到就 'unknown',不影响启动。
let SERVER_VERSION = 'unknown';
try {
  SERVER_VERSION = (JSON.parse(fs.readFileSync(path.join(process.cwd(), 'package.json'), 'utf8')) as { version?: string }).version ?? SERVER_VERSION;
} catch {
  // cwd 不是 server 目录(编译产物直启),忽略
}

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
  // health 顺带暴露版本/启动时长/在跑数:手机端一眼判断"连的是新代码还是旧进程"
  app.get('/api/health', async () => ({
    ok: true,
    version: SERVER_VERSION,
    uptimeSec: Math.round(process.uptime()),
    runningSessions: opts.runningCount?.() ?? 0,
  }));
  if (opts.publicDir) {
    // 不在 /api/ 前缀下 → 鉴权钩子放行;手机浏览器直接打开链接即可下载
    app.get('/download/:name', async (req, reply) => {
      const name = (req.params as { name: string }).name;
      if (!DOWNLOAD_NAME_RE.test(name)) return reply.code(404).send({ error: 'not found' });
      const file = path.join(opts.publicDir!, name);
      let st: fs.Stats;
      try {
        st = fs.statSync(file);
      } catch {
        return reply.code(404).send({ error: 'not found' });
      }
      if (!st.isFile()) return reply.code(404).send({ error: 'not found' });
      reply.header('Content-Length', st.size);
      reply.header('Content-Disposition', `attachment; filename="${name}"`);
      reply.type(name.endsWith('.apk') ? 'application/vnd.android.package-archive' : 'application/octet-stream');
      return reply.send(fs.createReadStream(file));
    });
  }
  if (opts.db && opts.routesPath) {
    registerHttpRoutes(app, { db: opts.db, routesPath: opts.routesPath, onSessionDeleted: opts.onSessionDeleted, isRunning: opts.isRunning });
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
