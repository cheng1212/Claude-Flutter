import type { FastifyInstance } from 'fastify';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomBytes } from 'node:crypto';
import type { Db } from './db.js';
import { createSession, listSessions, getSession, updateSession, deleteSession, listMessages, sessionUsageSummary, forkSession, buildSessionExport, listCrons, markCronDeleted, usageStats, getCron, setCronStatus, resetCron, listCronRuns, recordCronRun } from './db.js';
import { importLocalSessions, reloadSessionTranscript, listSubagents, readSubagentTranscript, subagentCounts, isTranscriptActive } from './local-sessions.js';
import { readOutputTail } from './backgrounds.js';
import { listProjects, createProject, renameProject, renameProjectSessions, deleteProjectDir, projectSessionIds } from './projects.js';
import { listModels, listModelGroups, loadRoutes } from './routes.js';

// Windows 保留设备名(CON/PRN/AUX/NUL/COM1-9/LPT1-9):做文件名会创建失败或行为诡异
const WIN_RESERVED_NAME = /^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)/i;

/** 上传文件名净化:basename 防穿越 → 非法字符/控制字符替换 → 剥尾随点空格(Windows 静默吞)
 *  → 保留名加前缀 → 超长截断(保扩展名)。净化必须自身完备,不依赖 `${Date.now()}_` 前缀兜底。 */
export function sanitizeFileName(raw: string): string {
  let name = path
    .basename(String(raw ?? ''))
    .replace(/[\\/:*?"<>|\x00-\x1f\x7f]/g, '_')
    .replace(/[. ]+$/, '');
  if (!name) name = 'file';
  if (WIN_RESERVED_NAME.test(name)) name = `_${name}`;
  if (name.length > 120) {
    const dot = name.lastIndexOf('.');
    const ext = dot > 0 ? name.slice(dot) : '';
    name = ext.length < 120 ? `${name.slice(0, 120 - ext.length)}${ext}` : name.slice(0, 120);
  }
  return name;
}

export function registerHttpRoutes(app: FastifyInstance, deps: { db: Db; routesPath: string; onSessionDeleted?: (sessionId: string) => void; onSessionPatched?: (sessionId: string, patch: { model?: string; permissionMode?: string }) => void; isRunning?: (sessionId: string) => boolean; isAwaiting?: (sessionId: string) => boolean; backgrounds?: (sessionId: string) => unknown[]; projectsRoot?: string; onRestart?: () => void; triggerSession?: (sessionId: string, prompt: string) => boolean; cancelCronInCli?: (sessionId: string, cron: string, prompt: string) => boolean }): void {
  // 自我重启:先回 202(客户端拿得到响应),再由 index 侧延迟拉起新实例并退出。
  // 重启会掐断本进程所有 WS/在跑回合 —— app 端会看到连接断几秒后自动重连。
  app.post('/api/server/restart', async (_req, reply) => {
    if (!deps.onRestart) return reply.code(501).send({ error: '本进程不支持自我重启(非标准启动方式)' });
    reply.code(202).send({ ok: true, message: '服务器正在重启,约 5-10 秒后自动恢复' });
    deps.onRestart();
  });

  // 项目文件夹:总目录下的子文件夹 = 项目;新建会话/移动会话从这里选,也可现场新建
  app.get('/api/projects', async () => {
    const root = deps.projectsRoot ?? '';
    return { root, projects: root ? listProjects(root) : [] };
  });

  app.post('/api/projects', async (req, reply) => {
    const root = deps.projectsRoot ?? '';
    if (!root) return reply.code(400).send({ error: '未配置项目总目录' });
    const body = (req.body ?? {}) as { name?: unknown };
    const created = createProject(root, String(body.name ?? ''));
    if (!created.ok) return reply.code(400).send({ error: '项目名非法(禁空/禁路径符号/禁 .. 与 Windows 保留名)' });
    return { ok: true, name: created.name, cwd: path.join(root, created.name) };
  });

  // 重命名项目:文件夹改名 + 该项目下(cwd 恰为项目目录)会话 cwd 同步迁移;运行中 → 409
  app.patch('/api/projects/:name', async (req, reply) => {
    const root = deps.projectsRoot ?? '';
    if (!root) return reply.code(400).send({ error: '未配置项目总目录' });
    const oldName = String((req.params as Record<string, unknown>).name ?? '');
    const body = (req.body ?? {}) as { name?: unknown };
    const ids = projectSessionIds(deps.db, root, oldName);
    const running = ids.filter((id) => deps.isRunning?.(id));
    if (running.length) return reply.code(409).send({ error: `项目下有 ${running.length} 个会话正在运行,先停止再操作` });
    const r = renameProject(root, oldName, String(body.name ?? ''));
    if (!r.ok) return reply.code(400).send({ error: r.error ?? '重命名失败' });
    const moved = renameProjectSessions(deps.db, root, oldName, r.name);
    return { ok: true, name: r.name, moved };
  });

  // 删除项目:递归删文件夹(含其中文件) + 级联删该项目下全部会话;运行中 → 409
  app.delete('/api/projects/:name', async (req, reply) => {
    const root = deps.projectsRoot ?? '';
    if (!root) return reply.code(400).send({ error: '未配置项目总目录' });
    const name = String((req.params as Record<string, unknown>).name ?? '');
    const ids = projectSessionIds(deps.db, root, name);
    const running = ids.filter((id) => deps.isRunning?.(id));
    if (running.length) return reply.code(409).send({ error: `项目下有 ${running.length} 个会话正在运行,先停止再操作` });
    for (const id of ids) {
      deps.onSessionDeleted?.(id); // 先中止 runtime/清 registry,防幽灵事件继续落库
      deleteSession(deps.db, id);
    }
    const r = deleteProjectDir(root, name);
    if (!r.ok) return reply.code(400).send({ error: r.error ?? '删除失败' });
    return { ok: true, removed: ids.length };
  });

  app.get('/api/models', async () => listModels(loadRoutes(deps.routesPath)));

  app.get('/api/models/grouped', async () => ({ groups: listModelGroups(loadRoutes(deps.routesPath)) }));

  // 附带 isRunning/awaitingApproval:手机列表标"运行中"/"待确认"徽章;排序本就是 置顶 → 最近更新
  app.get('/api/sessions', async () => {
    const counts = subagentCounts();
    return listSessions(deps.db).map((row) => ({
      ...row,
      subagentCount: counts.get(String(row.provider_session_id ?? '')) ?? 0,
      // 「在跑」有两个来源,缺一不可:
      //  ①本进程 runtime(经 zcode 发的回合)
      //  ②转录最近还在写 = 电脑端 Claude Code 直接在跑这个 local 会话
      //     (这类回合不经 zcode,runs 表停在上一轮的 success,只看 ① 会显示"已完成")
      isRunning: (deps.isRunning?.(row.id) ?? false)
        || isTranscriptActive(row.provider_session_id),
      awaitingApproval: deps.isAwaiting?.(row.id) ?? false,
    }));
  });

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
    const patch: { title?: string; isPinned?: boolean; providerSessionId?: string; model?: string; permissionMode?: string; cwd?: string; archived?: boolean; tags?: string[] } = {};
    if (typeof body.title === 'string') patch.title = body.title;
    if (body.isPinned !== undefined) patch.isPinned = body.isPinned === true || body.isPinned === 'true';
    if (typeof body.providerSessionId === 'string') patch.providerSessionId = body.providerSessionId;
    if (typeof body.model === 'string') patch.model = body.model;
    if (typeof body.permissionMode === 'string' && PERMISSION_MODES.has(body.permissionMode)) patch.permissionMode = body.permissionMode;
    if (typeof body.cwd === 'string') patch.cwd = body.cwd;
    if (body.archived !== undefined) patch.archived = body.archived === true || body.archived === 'true';
    if (Array.isArray(body.tags)) {
      const tags = body.tags.filter((t): t is string => typeof t === 'string' && t.trim().length > 0).map((t) => t.trim());
      if (tags.length <= 10) patch.tags = tags;
    }
    const row = updateSession(deps.db, (req.params as { id: string }).id, patch);
    if (!row) return reply.code(404).send({ error: 'not found' });
    // 真热切换:有活着的 CLI 实例就现场设(模式立即对本回合生效);
    // 没有也不亏,下一条 send 的 runtimeFor 自会读 DB 新值。
    if (patch.model !== undefined || patch.permissionMode !== undefined) {
      deps.onSessionPatched?.((req.params as { id: string }).id, { model: patch.model, permissionMode: patch.permissionMode });
    }
    return row;
  });

  // 定时任务列表(next_fire 现算,倒计时数据源)
  // ?session= 会话过滤:app 会话弹层/快捷条指示灯都以"本会话"语义使用,漏传会混入别会话的 cron
  // ?paused=1 连暂停中的一起返回(管理面板要看全量;调度器口径仍只看 active)
  app.get('/api/crons', async (req) => {
    const q = req.query as { session?: string; paused?: string };
    return { crons: listCrons(deps.db, q.session || undefined, { includePaused: q.paused === '1' }) };
  });

  app.delete('/api/crons/:id', async (req) => {
    const id = (req.params as { id: string }).id;
    const row = getCron(deps.db, id);
    markCronDeleted(deps.db, id);
    // 顺带让活着的那条 CLI 也撤掉它的定时任务:Claude Code 的 cron 只活在 CLI
    // 进程内存里(session-only、不落盘),只删 zcode 镜像的话"面板删了、到点还会跑"。
    // 返回 cliNotified 让面板能如实提示"已通知会话撤销/由下次进程重启自然消失"。
    const cliNotified = row ? (deps.cancelCronInCli?.(row.session_id, row.cron, row.prompt) ?? false) : false;
    return { ok: true, cliNotified };
  });

  // 启用/暂停(面板开关)
  app.patch('/api/crons/:id', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const body = (req.body ?? {}) as { status?: unknown };
    const status = String(body.status ?? '');
    if (status !== 'active' && status !== 'paused') return reply.code(400).send({ error: "status 需为 'active' 或 'paused'" });
    setCronStatus(deps.db, id, status);
    return { ok: true, status };
  });

  // 立即运行一次(不等 cron 到点):与调度器共用同一条触发管线,结果落执行历史
  app.post('/api/crons/:id/run', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const row = getCron(deps.db, id);
    if (!row) return reply.code(404).send({ error: 'not found' });
    if (deps.isRunning?.(row.session_id)) {
      recordCronRun(deps.db, id, row.session_id, 'skipped', '手动运行时会话正在运行');
      return reply.code(409).send({ error: '会话正在运行,先等它跑完' });
    }
    const ok = deps.triggerSession?.(row.session_id, row.prompt) ?? false;
    recordCronRun(deps.db, id, row.session_id, ok ? 'success' : 'failed', ok ? '手动运行' : '触发失败(会话不可用)');
    if (!ok) return reply.code(409).send({ error: '触发失败:会话不可用' });
    return { ok: true };
  });

  // 重启任务:次数/上次结果清零,重新开始计时
  app.post('/api/crons/:id/restart', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    if (!getCron(deps.db, id)) return reply.code(404).send({ error: 'not found' });
    resetCron(deps.db, id);
    return { ok: true };
  });

  // 执行历史(最近 30 条)
  app.get('/api/crons/:id/runs', async (req) => ({
    runs: listCronRuns(deps.db, (req.params as { id: string }).id),
  }));

  // 完整重载:从磁盘 CLI 转录补回中断/重启丢失的事件(幂等)
  app.post('/api/sessions/:id/reload', async (req) => {
    const id = (req.params as { id: string }).id;
    const r = reloadSessionTranscript(deps.db, id, { isRunning: deps.isRunning?.(id) ?? false });
    return { ok: true, ...r };
  });

  // 导出会话为 markdown(JSON 包裹,客户端拿 markdown 落盘/分享)
  app.get('/api/sessions/:id/export', async (req, reply) => {
    const out = buildSessionExport(deps.db, (req.params as { id: string }).id);
    if (!out) return reply.code(404).send({ error: 'not found' });
    return out;
  });

  // 复制会话:消息与配置全拷;fork_from 指向源 CLI 会话,下一轮 send 由 SDK forkSession 分叉独立 provider 会话。
  app.post('/api/sessions/:id/fork', async (req, reply) => {
    const row = forkSession(deps.db, (req.params as { id: string }).id);
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

  // 文件上传(手机 → 电脑):存到会话 cwd 的 uploads/ 子目录,CLI 直接读本地文件。
  // body 为 JSON {fileName, dataB64}(base64,跨平台传输层友好);
  // 会话无 cwd 时自动创建 uploads-<sid8> 工作目录并回填会话(手机新建的会话 cwd 为 null)。
  app.post('/api/sessions/:id/files', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const session = deps.db
      .prepare('SELECT cwd FROM sessions WHERE id=?')
      .get(id) as { cwd: string | null } | undefined;
    if (!session) return reply.code(404).send({ error: '会话不存在' });

    const body = (req.body ?? {}) as { fileName?: unknown; dataB64?: unknown };
    const safeName = sanitizeFileName(String(body.fileName ?? 'file'));
    const dataB64 = String(body.dataB64 ?? '');
    if (!dataB64) return reply.code(400).send({ error: '空文件' });
    const buf = Buffer.from(dataB64, 'base64');
    if (buf.length === 0) return reply.code(400).send({ error: '空文件' });
    if (buf.length > 50 * 1024 * 1024) {
      return reply.code(413).send({ error: '文件超过 50MB 上限' });
    }

    let dir: string;
    if (session.cwd) {
      dir = path.join(session.cwd, 'uploads');
    } else {
      dir = path.join(deps.projectsRoot ?? path.join(os.homedir(), 'zcode-projects'), `uploads-${id.slice(0, 8)}`);
      fs.mkdirSync(dir, { recursive: true });
      deps.db.prepare('UPDATE sessions SET cwd=? WHERE id=?').run(dir, id);
    }
    fs.mkdirSync(dir, { recursive: true });
    const target = path.join(dir, `${Date.now()}_${safeName}`);
    fs.writeFileSync(target, buf);
    return { ok: true, path: target, fileName: safeName, size: buf.length };
  });

  // ── 分块上传(大文件真分块:每块独立请求可重试;tmp 缓冲按序组装)──
  const uploadRoot = path.join(os.tmpdir(), 'zcode-upload-chunks');
  fs.mkdirSync(uploadRoot, { recursive: true });
  const UPLOAD_ID_RE = /^[A-Za-z0-9_-]{8,64}$/;

  app.post('/api/sessions/:id/upload/init', async (req, reply) => {
    const body = (req.body ?? {}) as { fileName?: unknown; totalChunks?: unknown };
    const totalChunks = Number(body.totalChunks);
    if (!Number.isInteger(totalChunks) || totalChunks < 1 || totalChunks > 4096) {
      return reply.code(400).send({ error: 'totalChunks 非法(1..4096)' });
    }
    const uploadId = `${Date.now().toString(36)}-${randomBytes(6).toString('hex')}`;
    fs.mkdirSync(path.join(uploadRoot, uploadId), { recursive: true });
    fs.writeFileSync(
      path.join(uploadRoot, uploadId, 'meta.json'),
      JSON.stringify({ fileName: sanitizeFileName(String(body.fileName ?? 'file')), totalChunks }),
    );
    return { uploadId, have: [] as number[] };
  });

  app.post('/api/sessions/:id/upload/:uploadId/:index', async (req, reply) => {
    const { uploadId, index } = req.params as { uploadId: string; index: string };
    if (!UPLOAD_ID_RE.test(uploadId) || !/^\d+$/.test(index)) return reply.code(400).send({ error: '参数非法' });
    if (!fs.existsSync(path.join(uploadRoot, uploadId, 'meta.json'))) return reply.code(404).send({ error: 'upload 不存在' });
    const raw = req.body;
    if (!Buffer.isBuffer(raw) || raw.length === 0) return reply.code(400).send({ error: '空块' });
    fs.writeFileSync(path.join(uploadRoot, uploadId, `chunk-${Number(index)}`), raw);
    return { ok: true, index: Number(index) };
  });

  app.post('/api/sessions/:id/upload/:uploadId/complete', async (req, reply) => {
    const { uploadId, id } = req.params as { uploadId: string; id: string };
    if (!UPLOAD_ID_RE.test(uploadId)) return reply.code(400).send({ error: '参数非法' });
    const dir = path.join(uploadRoot, uploadId);
    let meta: { fileName: string; totalChunks: number };
    try {
      meta = JSON.parse(fs.readFileSync(path.join(dir, 'meta.json'), 'utf8')) as { fileName: string; totalChunks: number };
    } catch {
      return reply.code(404).send({ error: 'upload 不存在' });
    }
    for (let i = 0; i < meta.totalChunks; i++) {
      if (!fs.existsSync(path.join(dir, `chunk-${i}`))) return reply.code(400).send({ error: `缺块 ${i}` });
    }
    const session = deps.db
      .prepare('SELECT cwd FROM sessions WHERE id=?')
      .get(id) as { cwd: string | null } | undefined;
    if (!session) return reply.code(404).send({ error: '会话不存在' });
    let outDir: string;
    if (session.cwd) {
      outDir = path.join(session.cwd, 'uploads');
    } else {
      outDir = path.join(deps.projectsRoot ?? path.join(os.homedir(), 'zcode-projects'), `uploads-${id.slice(0, 8)}`);
      fs.mkdirSync(outDir, { recursive: true });
      deps.db.prepare('UPDATE sessions SET cwd=? WHERE id=?').run(outDir, id);
    }
    fs.mkdirSync(outDir, { recursive: true });
    const target = path.join(outDir, `${Date.now()}_${meta.fileName}`);
    for (let i = 0; i < meta.totalChunks; i++) {
      fs.appendFileSync(target, fs.readFileSync(path.join(dir, `chunk-${i}`)));
    }
    fs.rmSync(dir, { recursive: true, force: true });
    return { ok: true, path: target, fileName: meta.fileName, size: fs.statSync(target).size };
  });

  app.get('/api/sessions/:id/messages', async (req) => {
    const id = (req.params as { id: string }).id;
    const q = req.query as { limit?: string; offset?: string; beforeSeq?: string };
    return listMessages(deps.db, id, {
      limit: q.limit ? Number(q.limit) : undefined,
      offset: q.offset ? Number(q.offset) : undefined,
      beforeSeq: q.beforeSeq ? Number(q.beforeSeq) : undefined,
    });
  });

  // 后台任务列表(Bash run_in_background + SDK task_* 登记的统一视图;
  // 带落盘输出文件的任务现场读最新输出尾,不等模型调 BashOutput)
  app.get('/api/sessions/:id/backgrounds', async (req) => {
    const rows = (deps.backgrounds?.((req.params as { id: string }).id) ?? []) as Array<Record<string, unknown>>;
    for (const row of rows) {
      if (typeof row.outputFile === 'string' && row.outputFile) {
        row.outputTail = await readOutputTail(row.outputFile);
      }
    }
    return { backgrounds: rows };
  });

  // 子代理虚拟会话:列表(meta 元数据)+ 只读转录。不入 sessions 表,面板按此渲染。
  app.get('/api/sessions/:id/subagents', async (req) => ({
    subagents: listSubagents(deps.db, (req.params as { id: string }).id),
  }));

  app.get('/api/sessions/:id/subagents/:agentId/messages', async (req) => ({
    messages: readSubagentTranscript(
      deps.db,
      (req.params as { id: string }).id,
      (req.params as { agentId: string }).agentId,
    ),
  }));

  // 会话用量聚合:累计 token/缓存/费用 + 最近一轮上下文占用 + 消息构成(按字符量估算)
  app.get('/api/sessions/:id/usage', async (req) => {
    return sessionUsageSummary(deps.db, (req.params as { id: string }).id);
  });

  // 全局用量聚合(runs 表):?range=today|1d|7d|30d|all(默认 7d)→ 总览/按模型/按日×模型
  // 边界用**自然日**:7d = 今天 00:00 往前数 7 天(含今天),today = 今天 00:00 起。
  // 原实现是滚动 168 小时——卡片写「近 7 天」、图例从 9月7日 起,口径对不上用户直觉。
  app.get('/api/usage', async (req) => {
    const range = String((req.query as Record<string, unknown>).range ?? '7d');
    const days = range === 'all' ? 0 : range === 'today' ? 1 : range === '30d' ? 30 : range === '1d' ? 1 : 7;
    let since: string | null = null;
    if (days > 0) {
      const d = new Date();
      d.setHours(0, 0, 0, 0); // 今天 00:00(服务器本地时区)
      d.setDate(d.getDate() - (days - 1)); // 含今天:7d = 今天 + 前 6 天
      since = d.toISOString();
    }
    return { range, generatedAt: new Date().toISOString(), ...usageStats(deps.db, since) };
  });
}
