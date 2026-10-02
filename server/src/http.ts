import fs from 'node:fs';
import path from 'node:path';
import { createHash, timingSafeEqual } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import fastify from 'fastify';
import { registerHttpRoutes } from './http-routes.js';
import type { Db } from './db.js';
import { createAuthThrottle, type AuthThrottle } from './auth-throttle.js';
import { isWeakToken } from './config.js';

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
  /** 鉴权失败限速器:不传则内部新建(测试可注入假件/调严参数) */
  authThrottle?: AuthThrottle;
};

// /download 只认安全文件名:杜绝路径穿越(../、反斜杠、隐藏文件)
const DOWNLOAD_NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

// CORS 白名单:匹配的 Origin 才回显 ACAO(默认放行本机回环任意端口,Flutter Web dev 用)。
// ZCODE_ALLOWED_ORIGINS=逗号分隔覆盖;条目 `*` 结尾匹配任意前缀,整表 `*` 恢复全放行。
// 唯一凭证是 Bearer 头,通配 `*` 会把泄露后的可利用面放大到任意网页 —— 收紧为白名单回显。
const DEFAULT_ALLOWED_ORIGINS = ['http://localhost:*', 'http://127.0.0.1:*'];

function parseAllowedOrigins(raw: string | undefined): string[] {
  if (raw == null) return DEFAULT_ALLOWED_ORIGINS;
  const list = raw.split(',').map((s) => s.trim()).filter(Boolean);
  return list.length ? list : DEFAULT_ALLOWED_ORIGINS;
}

function originAllowed(rules: string[], origin: string): boolean {
  return rules.some((rule) => (rule === '*' ? true : rule.endsWith('*') ? origin.startsWith(rule.slice(0, -1)) : rule === origin));
}

/** Bearer 常量时间比较:先哈希再比,免去长度泄露与时序侧信道(局域网自用非高危,顺手补齐)。 */
function bearerTokenValid(header: string, token: string): boolean {
  const m = /^Bearer (.+)$/.exec(header);
  if (!m) return false;
  const given = createHash('sha256').update(m[1]).digest();
  const want = createHash('sha256').update(token).digest();
  return timingSafeEqual(given, want);
}

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
  // 文件上传:二进制 body(分块上传 octet-stream)按 buffer 原样收
  app.addContentTypeParser(
    'application/octet-stream',
    { parseAs: 'buffer' },
    (_req, body, done) => done(null, body),
  );
  // CORS:白名单命中才回显(浏览器端 Flutter Web 跨域访问);必须先于鉴权钩子注册,OPTIONS 免鉴权短路。
  const allowedOrigins = parseAllowedOrigins(process.env.ZCODE_ALLOWED_ORIGINS);
  app.addHook('onRequest', async (req, reply) => {
    const origin = req.headers.origin;
    if (typeof origin === 'string' && originAllowed(allowedOrigins, origin)) {
      reply.header('Access-Control-Allow-Origin', origin);
      reply.header('Vary', 'Origin');
      reply.header('Access-Control-Allow-Headers', 'Authorization, Content-Type');
      reply.header('Access-Control-Allow-Methods', 'GET, POST, PATCH, DELETE, OPTIONS');
    }
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
    // 弱令牌暴露在免鉴权的 health 里听着吓人,但弱令牌本身一猜就中(123456),
    // 这里亮出来是为了让登录页/面板能给主人挂"裸奔中"横幅;强令牌恒为 false,零泄露。
    weakToken: isWeakToken(opts.token),
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
    const webRoot = path.resolve(opts.webDir);
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
      let pathname: string;
      try {
        pathname = decodeURIComponent(req.url.split('?')[0] ?? '/');
      } catch {
        return reply.code(400).send({ error: 'bad path' }); // 畸形百分号编码:别让 URIError 变 500
      }
      const rel = pathname.replace(/^\/+/, '') || 'index.html';
      // 穿越防护:resolve 归约后必须**仍落在 webRoot 内**,且前缀检查锚定分隔符 ——
      // 没有尾分隔符时 `..\web-evil\x` 归约成兄弟目录 web-evil,裸前缀 startsWith 会误配放行(实测可读穿)。
      const file = path.resolve(webRoot, rel);
      if (file !== webRoot && !file.startsWith(webRoot + path.sep)) return reply.code(404).send({ error: 'not found' });
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
  // 鉴权:失败按来源限速(堵无限重试爆破弱令牌),成功清零;比较走常量时间。
  const auth = opts.authThrottle ?? createAuthThrottle();
  app.addHook('onRequest', async (req, reply) => {
    if (!req.url.startsWith('/api/') || req.url.startsWith('/api/health')) return;
    if (auth.blocked(req.ip)) {
      await reply.code(429).send({ error: '尝试过多,请稍后再试' });
      return;
    }
    if (!bearerTokenValid(req.headers.authorization ?? '', opts.token)) {
      auth.fail(req.ip);
      await reply.code(401).send({ error: 'unauthorized' });
      return;
    }
    auth.reset(req.ip);
  });
  return app;
}
