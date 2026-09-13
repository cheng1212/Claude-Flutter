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
  /** PATCH 落库成功后回调(仅带本次 PATCH 的字段):运行中的 runtime 现场热设模式/模型。 */
  onSessionPatched?: (sessionId: string, patch: { model?: string; permissionMode?: string }) => void;
  /** app 点「重启服务器」:拉起新实例并退出(index 侧实现,不传则接口回 501) */
  onRestart?: () => void;
  /** 「立即运行」定时任务:与调度器共用同一条触发管线(index 侧包 gateway.triggerSession) */
  triggerSession?: (sessionId: string, prompt: string) => boolean;
  /** 面板删定时任务时,让活着的那条 CLI 也撤销它的 session-only 任务(返回是否已通知) */
  cancelCronInCli?: (sessionId: string, cron: string, prompt: string) => boolean;
  /** 实际源码目录(index 侧用 import.meta.url 推出):/api/health 暴露,用于自证跑的是哪棵树 */
  sourceDir?: string;
  /** 进程启动时刻(ISO),同健康检查暴露 */
  startedAt?: string;
  /** 会话是否在跑(注入 registry.isRunning):列表接口据此标"运行中"徽章 */
  isRunning?: (sessionId: string) => boolean;
  /** 后台任务列表(注入 BackgroundRegistry.list):/api/sessions/:id/backgrounds */
  backgrounds?: (sessionId: string) => unknown[];
  /** 项目文件夹总目录(/api/projects 列出/新建子文件夹) */
  projectsRoot?: string;
  /** 会话是否在等审批(注入 runtime.pendingPermissions):列表接口据此标"待确认"徽章 */
  isAwaiting?: (sessionId: string) => boolean;
  /** 在跑会话数(注入):health 暴露,手机端诊断"连的是不是旧进程" */
  runningCount?: () => number;
  /** web 端构建产物目录(dist):非空则挂 SPA 静态托管,根路径直接出 web 登录页 */
  webDir?: string;
};

// /download 只认安全文件名:杜绝路径穿越(../、反斜杠、隐藏文件)
const DOWNLOAD_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

// server 自身版本(health 暴露):模块相对定位优先(vitest/任意目录直启都对),
// cwd 兜底;都读不到就 'unknown',不影响启动。
let SERVER_VERSION = 'unknown';
try {
  SERVER_VERSION = (JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8')) as { version?: string }).version ?? SERVER_VERSION;
} catch {
  try {
    SERVER_VERSION = (JSON.parse(fs.readFileSync(path.join(process.cwd(), 'package.json'), 'utf8')) as { version?: string }).version ?? SERVER_VERSION;
  } catch {
    // 编译产物挪了窝也找不到 → 保持 'unknown'
  }
}

export async function buildApp(opts: AppOptions): Promise<FastifyInstance> {
  const app = fastify();
  // 文件上传:二进制 body 由手机端直传(文件名走 X-File-Name 头),按 buffer 原样收
  app.addContentTypeParser(
    'application/octet-stream',
    { parseAs: 'buffer' },
    (_req, _body, done) => done(null),
  );
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
    // 启动自证:实际加载的源码目录/进程/启动时刻。排查"改完没生效"时,
    // 一眼就能看出跑的是哪棵树——踩过两次的坑(相对路径 src/index.ts + 错误 cwd
    // 会静默加载另一棵树的旧代码,命令行路径还会被 junction 伪装)。
    sourceDir: opts.sourceDir ?? '',
    cwd: process.cwd(),
    pid: process.pid,
    startedAt: opts.startedAt ?? '',
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
    registerHttpRoutes(app, { db: opts.db, routesPath: opts.routesPath, onSessionDeleted: opts.onSessionDeleted, onSessionPatched: opts.onSessionPatched, isRunning: opts.isRunning, isAwaiting: opts.isAwaiting, backgrounds: opts.backgrounds, projectsRoot: opts.projectsRoot, onRestart: opts.onRestart, triggerSession: opts.triggerSession, cancelCronInCli: opts.cancelCronInCli });
  }
  if (opts.webDir) {
    // SPA 静态托管:非 /api 的 GET → webDir 下文件,未命中回 index.html(前端路由刷新不 404)。
    // 壳页面无密钥免鉴权;数据全在 /api(token 保护)。必须注册在 API 路由之后,不遮任何接口。
    const MIME: Record<string, string> = {
      '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css',
      '.svg': 'image/svg+xml', '.png': 'image/png', '.ico': 'image/x-icon',
      '.json': 'application/json', '.woff2': 'font/woff2', '.map': 'application/json',
    };
    const webRoot = path.join(opts.webDir, '');
    const sendIndex = (reply: import('fastify').FastifyReply) => {
      const file = path.join(webRoot, 'index.html');
      try {
        reply.header('Content-Length', fs.statSync(file).size);
        return reply.type('text/html; charset=utf-8').send(fs.createReadStream(file));
      } catch {
        return reply.code(404).send({ error: 'web 构建产物不存在(ZCODE_WEB_DIR)' });
      }
    };
    app.get('/*', async (req, reply) => {
      const pathname = decodeURIComponent(req.url.split('?')[0] ?? '/');
      const rel = pathname.replace(/^\/+/, '') || 'index.html';
      const file = path.join(webRoot, rel);
      // 穿越防护:归约后必须仍落在 webDir 内,越界一律 404
      if (!file.startsWith(webRoot)) return reply.code(404).send({ error: 'not found' });
      let st: fs.Stats;
      try {
        st = fs.statSync(file);
      } catch {
        return sendIndex(reply); // SPA fallback:前端路由刷新不 404
      }
      if (!st.isFile()) return sendIndex(reply);
      reply.header('Content-Length', st.size);
      reply.type(MIME[path.extname(file).toLowerCase()] ?? 'application/octet-stream');
      return reply.send(fs.createReadStream(file));
    });
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
