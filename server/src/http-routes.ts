import type { FastifyInstance } from 'fastify';
import path from 'node:path';
import type { Db } from './db.js';
import { createSession, listSessions, getSession, updateSession, deleteSession, listMessages, sessionUsageSummary, forkSession, buildSessionExport, listCrons, markCronDeleted } from './db.js';
import { importLocalSessions, reloadSessionTranscript, listSubagents, readSubagentTranscript, subagentCounts } from './local-sessions.js';
import { readOutputTail } from './backgrounds.js';
import { listProjects, createProject, renameProject, renameProjectSessions, deleteProjectDir, projectSessionIds } from './projects.js';
import { listModels, listModelGroups, loadRoutes } from './routes.js';

export function registerHttpRoutes(app: FastifyInstance, deps: { db: Db; routesPath: string; onSessionDeleted?: (sessionId: string) => void; onSessionPatched?: (sessionId: string, patch: { model?: string; permissionMode?: string }) => void; isRunning?: (sessionId: string) => boolean; isAwaiting?: (sessionId: string) => boolean; backgrounds?: (sessionId: string) => unknown[]; projectsRoot?: string }): void {
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
      isRunning: deps.isRunning?.(row.id) ?? false,
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

  // 定时任务列表(active;next_fire 现算,倒计时数据源)
  // ?session= 会话过滤:app 会话弹层/快捷条指示灯都以"本会话"语义使用,漏传会混入别会话的 cron
  app.get('/api/crons', async (req) => {
    const q = req.query as { session?: string };
    return { crons: listCrons(deps.db, q.session || undefined) };
  });

  app.delete('/api/crons/:id', async (req) => {
    markCronDeleted(deps.db, (req.params as { id: string }).id);
    return { ok: true };
  });

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
}
