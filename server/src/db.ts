import Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';
import { nextFire } from './cron.js';

export type Db = Database.Database;
export type SessionRow = {
  id: string; title: string; cwd: string | null; provider_session_id: string | null;
  model: string | null; permission_mode: string; is_pinned: number; source: string;
  created_at: string; updated_at: string;
  /** 列表副标题:最后一条文本消息截 120 字(listSessions 附带,非表列) */
  last_message?: string | null;
  /** 会话管理增强(listSessions 附带) */
  archived?: number;
  tags?: string;
  fork_from?: string | null;
  /** 友好预览:文本→内容;思考→💭;工具→🔧+工具名(空会话为空串) */
  last_preview?: string;
  /** 最近一次 run 的状态(success/error/aborted/interrupted;无 run 为 null) */
  last_status?: string | null;
  /** cwd 末段,如 D:\work\app → app */
  project?: string | null;
};
export type MessageRow = {
  id: string; session_id: string; seq: number; kind: string; role: string | null;
  content: string; meta: string | null; created_at: string;
};

export function openDb(file: string): Db {
  const db = new Database(file);
  db.pragma('journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS sessions(
      id TEXT PRIMARY KEY, title TEXT NOT NULL, cwd TEXT, provider_session_id TEXT,
      model TEXT, permission_mode TEXT NOT NULL DEFAULT 'default',
      is_pinned INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT 'app',
      created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS messages(
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
      kind TEXT NOT NULL, role TEXT, content TEXT NOT NULL, meta TEXT,
      created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, seq);
    CREATE TABLE IF NOT EXISTS runs(
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL,
      model TEXT, total_cost_usd REAL, usage TEXT, started_at TEXT NOT NULL, ended_at TEXT);
    CREATE INDEX IF NOT EXISTS idx_runs_session ON runs(session_id);
    CREATE TABLE IF NOT EXISTS session_tombstones(
      provider_session_id TEXT PRIMARY KEY, deleted_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS crons(
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, cron TEXT NOT NULL,
      prompt TEXT NOT NULL, recurring INTEGER NOT NULL DEFAULT 1,
      durable INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'active',
      created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_crons_session ON crons(session_id);
  `);
  // 迁移:旧库 sessions 无 source 列,补上(本地导入的会话置 'local')
  const sessionCols = db.prepare('PRAGMA table_info(sessions)').all() as { name: string }[];
  if (!sessionCols.some((c) => c.name === 'source')) {
    db.exec("ALTER TABLE sessions ADD COLUMN source TEXT NOT NULL DEFAULT 'app'");
  }
  // 会话管理增强:归档、标签(JSON 数组字符串)、fork 来源(CLI provider 会话 id)
  if (!sessionCols.some((c) => c.name === 'archived')) {
    db.exec('ALTER TABLE sessions ADD COLUMN archived INTEGER NOT NULL DEFAULT 0');
  }
  if (!sessionCols.some((c) => c.name === 'tags')) {
    db.exec("ALTER TABLE sessions ADD COLUMN tags TEXT NOT NULL DEFAULT '[]'");
  }
  if (!sessionCols.some((c) => c.name === 'fork_from')) {
    db.exec('ALTER TABLE sessions ADD COLUMN fork_from TEXT');
  }
  return db;
}

const now = () => new Date().toISOString();

export function createSession(
  db: Db,
  input: { title?: string; cwd?: string; model?: string; source?: 'app' | 'local'; providerSessionId?: string; createdAt?: string; updatedAt?: string; tags?: string[]; forkFrom?: string } = {},
): SessionRow {
  const id = randomUUID();
  const ts = now();
  db.prepare('INSERT INTO sessions(id,title,cwd,model,source,provider_session_id,created_at,updated_at,tags,fork_from) VALUES(?,?,?,?,?,?,?,?,?,?)')
    .run(
      id, input.title?.trim() || '新会话', input.cwd ?? null, input.model ?? null,
      input.source ?? 'app', input.providerSessionId ?? null,
      input.createdAt ?? ts, input.updatedAt ?? ts,
      JSON.stringify(input.tags ?? []), input.forkFrom ?? null,
    );
  return getSession(db, id)!;
}

export function getSession(db: Db, id: string): SessionRow | undefined {
  return db.prepare('SELECT * FROM sessions WHERE id=?').get(id) as SessionRow | undefined;
}

export function getSessionByProviderSessionId(db: Db, providerSessionId: string): SessionRow | undefined {
  return db.prepare('SELECT * FROM sessions WHERE provider_session_id=?').get(providerSessionId) as SessionRow | undefined;
}

export function maxSeq(db: Db, sessionId: string): number {
  const row = db.prepare('SELECT COALESCE(MAX(seq),0) AS m FROM messages WHERE session_id=?').get(sessionId) as { m: number };
  return row.m;
}

/** 列表行:tags 解析成数组(表里存 JSON 字符串),预览/状态/项目为列表专属增强字段。 */
export type SessionListRow = Omit<SessionRow, 'tags'> & {
  tags: string[];
  last_preview: string;
  last_status: string | null;
  project: string | null;
};

export function listSessions(db: Db): SessionListRow[] {
  // last_message:最后一条文本消息截 120 字做列表副标题(认会话全靠它,不全靠标题)
  // __tail:最后一条消息的 kind|content|meta,JS 侧拼友好预览 last_preview
  const rows = db.prepare(`
    SELECT s.*,
      (SELECT substr(m.content, 1, 120) FROM messages m
        WHERE m.session_id = s.id AND m.kind = 'text'
        ORDER BY m.seq DESC LIMIT 1) AS last_message,
      -- 最后一条消息的 kind/content/meta 分三列取(曾用 '|' 拼,content 含管道符即错位)
      (SELECT m.kind FROM messages m WHERE m.session_id = s.id
        ORDER BY m.seq DESC LIMIT 1) AS __kind,
      (SELECT substr(m.content, 1, 160) FROM messages m WHERE m.session_id = s.id
        ORDER BY m.seq DESC LIMIT 1) AS __content,
      (SELECT COALESCE(m.meta, '') FROM messages m WHERE m.session_id = s.id
        ORDER BY m.seq DESC LIMIT 1) AS __meta,
      (SELECT r.status FROM runs r WHERE r.session_id = s.id
        ORDER BY r.started_at DESC LIMIT 1) AS last_status
    FROM sessions s
    ORDER BY s.is_pinned DESC, s.updated_at DESC
  `).all() as (SessionRow & { __kind?: string | null; __content?: string | null; __meta?: string | null })[];
  return rows.map((r) => {
    const kind = r.__kind ?? '';
    const content = r.__content ?? '';
    const meta = r.__meta ?? '';
    let preview = '';
    if (kind === 'text') preview = content;
    else if (kind === 'thinking') preview = '💭 ' + content;
    else if (kind === 'error') preview = '⚠️ ' + content;
    else if (kind === 'tool_use') {
      let toolName = '工具调用';
      try { toolName = (JSON.parse(meta) as { toolName?: string }).toolName ?? toolName; } catch { /* meta 缺失用默认 */ }
      preview = '🔧 ' + toolName;
    } else if (kind === 'tool_result') preview = '⚙️ 工具结果';
    const BS = String.fromCharCode(92); // 反斜杠(避免字面量被多层转义坑)
    const project = r.cwd ? r.cwd.split(new RegExp('[' + BS + BS + '/]')).filter(Boolean).at(-1) ?? null : null;
    let tags: unknown = [];
    try { tags = JSON.parse(r.tags ?? '[]'); } catch { tags = []; }
    const { __kind: _k, __content: _c, __meta: _m, ...rest } = r;
    return { ...rest, last_preview: preview, project, last_status: r.last_status ?? null, tags: tags as string[] };
  });
}

export function updateSession(
  db: Db, id: string,
  patch: Partial<{ title: string; isPinned: boolean; providerSessionId: string; model: string; permissionMode: string; cwd: string; archived: boolean; tags: string[] }>,
): SessionRow | undefined {
  const cur = getSession(db, id);
  if (!cur) return undefined;
  db.prepare('UPDATE sessions SET title=?, is_pinned=?, provider_session_id=?, model=?, permission_mode=?, cwd=?, archived=?, tags=?, updated_at=? WHERE id=?')
    .run(
      patch.title?.trim() || cur.title,
      patch.isPinned === undefined ? cur.is_pinned : (patch.isPinned ? 1 : 0),
      patch.providerSessionId ?? cur.provider_session_id,
      patch.model ?? cur.model,
      patch.permissionMode ?? cur.permission_mode,
      patch.cwd ?? cur.cwd,
      patch.archived === undefined ? cur.archived : (patch.archived ? 1 : 0),
      patch.tags === undefined ? cur.tags : JSON.stringify(patch.tags),
      now(), id,
    );
  return getSession(db, id);
}

export function touchSession(db: Db, id: string): void {
  db.prepare('UPDATE sessions SET updated_at=? WHERE id=?').run(now(), id);
}

export function deleteSession(db: Db, id: string): boolean {
  const cur = getSession(db, id);
  // 删除的会话在磁盘上的转录文件还在,启动导入器会把它重新导回来。
  // 记墓碑:按 provider_session_id(= 转录文件名)永久拉黑,重启不复活。
  if (cur?.provider_session_id) {
    db.prepare('INSERT OR IGNORE INTO session_tombstones(provider_session_id, deleted_at) VALUES(?,?)')
      .run(cur.provider_session_id, now());
  }
  db.prepare('DELETE FROM messages WHERE session_id=?').run(id);
  db.prepare('DELETE FROM runs WHERE session_id=?').run(id);
  return db.prepare('DELETE FROM sessions WHERE id=?').run(id).changes > 0;
}

/** 会话导出:消息按时间正序拼成 markdown;控制事件(usage/complete 等)不进导出。 */
export function buildSessionExport(db: Db, sessionId: string): { filename: string; markdown: string } | null {
  const s = getSession(db, sessionId);
  if (!s) return null;
  const msgs = db.prepare('SELECT kind, role, content, meta, created_at FROM messages WHERE session_id=? ORDER BY seq')
    .all(sessionId) as { kind: string; role: string | null; content: string; meta: string | null; created_at: string }[];
  const hh = (iso: string) => iso.replace('T', ' ').slice(0, 16);
  const BS = String.fromCharCode(92);
  const NL_CH = String.fromCharCode(10);
  const parts: string[] = [
    `# ${s.title}`,
    '',
    `- 模型:${s.model ?? 'default'}`,
    `- 项目:${s.cwd ?? '未知'}`,
    `- 消息数:${msgs.length}`,
    `- 导出时间:${hh(now())}`,
    '',
    '---',
  ];
  for (const m of msgs) {
    const t = hh(m.created_at);
    if (m.kind === 'text') {
      parts.push('', `**${m.role === 'user' ? '用户' : '助手'}** · ${t}`, '', m.content);
    } else if (m.kind === 'thinking') {
      parts.push('', `> 💭 *思考* · ${t}`, '> ' + m.content.split(NL_CH).join(NL_CH + '> '));
    } else if (m.kind === 'tool_use') {
      let name = '工具';
      try { name = (JSON.parse(m.meta ?? '{}') as { toolName?: string }).toolName ?? name; } catch { /* 忽略 */ }
      parts.push('', `🔧 **${name}** · ${t}`, '', '```', m.content, '```');
    } else if (m.kind === 'tool_result') {
      // 失败标志在 meta.isError(transform 落库时的独立字段);正文里恰好出现
      // "is_error" 字样(比如工具输出了一段含该词的 JSON)不代表这一步失败了
      let bad = false;
      try { bad = (JSON.parse(m.meta ?? '{}') as { isError?: boolean }).isError === true; } catch { /* meta 坏按成功算 */ }
      parts.push('', `⚙️ 结果${bad ? '(失败)' : ''}:`, '', '```', m.content, '```');
    } else if (m.kind === 'error') {
      parts.push('', `⚠️ ${m.content}`);
    }
  }
  const safe = s.title.replace(new RegExp('[' + BS + BS + '/:*?' + String.fromCharCode(34) + '<>|]', 'g'), '_');
  return {
    filename: `${safe || '会话'}-${sessionId.slice(0, 8)}.md`,
    markdown: parts.join(NL_CH),
  };
}

export type CronRow = {
  id: string; session_id: string; cron: string; prompt: string;
  recurring: number; durable: number; status: string;
  created_at: string; next_fire: string | null; session_title?: string;
};

/** 登记一条定时任务(来源:CronCreate 工具事件拦截)。 */
export function registerCron(
  db: Db, sessionId: string,
  input: { cron: string; prompt: string; recurring?: boolean; durable?: boolean },
): CronRow {
  const id = randomUUID();
  db.prepare('INSERT INTO crons(id,session_id,cron,prompt,recurring,durable,status,created_at) VALUES(?,?,?,?,?,?,?,?)')
    .run(id, sessionId, input.cron, input.prompt, input.recurring === false ? 0 : 1, input.durable === true ? 1 : 0, 'active', now());
  return db.prepare('SELECT * FROM crons WHERE id=?').get(id) as CronRow;
}

/** 按内容标记删除(来自 CronDelete 工具事件拦截,幂等)。 */
export function markCronDeleted(db: Db, id: string): void {
  db.prepare("UPDATE crons SET status='deleted' WHERE id=?").run(id);
}

/** active 任务列表;next_fire 现算。sessionId 省略=全部(附会话标题)。 */
export function listCrons(db: Db, sessionId?: string): CronRow[] {
  const rows = (sessionId
    ? db.prepare("SELECT * FROM crons WHERE session_id=? AND status='active' ORDER BY created_at")
    : db.prepare("SELECT c.*, se.title AS session_title FROM crons c LEFT JOIN sessions se ON se.id=c.session_id WHERE c.status='active' ORDER BY c.created_at"))
    .all(...(sessionId ? [sessionId] : [])) as CronRow[];
  const from = new Date();
  return rows.map((r) => {
    const nf = nextFire(r.cron, from);
    return { ...r, next_fire: nf ? nf.toISOString() : null };
  });
}

/** fanout 拦截:CronCreate/CronDelete 工具事件 → 服务端登记(倒计时数据源)。 */
export function recordCronToolUse(db: Db, sessionId: string, event: { toolName?: unknown; toolInput?: unknown }): void {
  const name = String(event.toolName ?? '');
  if (name !== 'CronCreate' && name !== 'CronDelete') return;
  const input = (event.toolInput ?? {}) as { cron?: unknown; prompt?: unknown; recurring?: unknown; durable?: unknown };
  const cron = String(input.cron ?? '');
  const prompt = String(input.prompt ?? '');
  if (!cron || !prompt) return;
  if (name === 'CronCreate') {
    registerCron(db, sessionId, {
      cron,
      prompt,
      recurring: input.recurring !== false,
      durable: input.durable === true,
    });
    return;
  }
  // CronDelete:同会话 + 同 cron + 同 prompt 的 active 记录标记删除
  for (const r of listCrons(db, sessionId)) {
    if (r.cron === cron && r.prompt === prompt) markCronDeleted(db, r.id);
  }
}

/** 复制会话:拷贝消息与配置;fork_from 记源 CLI 会话,首轮 send 由 SDK forkSession 分叉。 */
export function forkSession(db: Db, sourceId: string): SessionRow | null {
  const src = getSession(db, sourceId);
  if (!src) return null;
  let tags: string[] = [];
  try { tags = JSON.parse(src.tags ?? '[]') as string[]; } catch { tags = []; }
  const copy = createSession(db, {
    title: (src.title || '会话') + ' 副本',
    cwd: src.cwd ?? undefined,
    model: src.model ?? undefined,
    tags,
    forkFrom: src.provider_session_id ?? undefined,
  });
  updateSession(db, copy.id, { permissionMode: src.permission_mode });
  const rows = db.prepare('SELECT seq, kind, role, content, meta, created_at FROM messages WHERE session_id=? ORDER BY seq')
    .all(sourceId) as MessageRow[];
  const ins = db.prepare('INSERT INTO messages(id,session_id,seq,kind,role,content,meta,created_at) VALUES(?,?,?,?,?,?,?,?)');
  db.transaction(() => {
    for (const m of rows) ins.run(randomUUID(), copy.id, m.seq, m.kind, m.role, m.content, m.meta, m.created_at);
  })();
  return getSession(db, copy.id) ?? null; // createSession 刚插完必在;?? null 仅收敛类型
}

/** 墓碑集合(导入器拉黑名单)。 */
export function listTombstonedProviderSessionIds(db: Db): Set<string> {
  const rows = db.prepare('SELECT provider_session_id FROM session_tombstones').all() as { provider_session_id: string }[];
  return new Set(rows.map((r) => r.provider_session_id));
}

export function appendMessage(
  db: Db, sessionId: string,
  input: { seq?: number; kind: string; role?: string; content: string; meta?: unknown },
): MessageRow {
  // seq 优先用事件自带号(registry 发的):WS 事件与 DB 行号必须同一空间,
  // 否则 REST 重建出的 lastSeq 与实时事件 seq 分家,前端按 seq 去重会整批丢事件。
  const row = db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE session_id=?').get(sessionId) as { s: number };
  const rec: MessageRow = {
    id: randomUUID(),
    session_id: sessionId,
    seq: input.seq ?? row.s + 1,
    kind: input.kind,
    role: input.role ?? null,
    content: input.content,
    meta: input.meta === undefined ? null : JSON.stringify(input.meta),
    created_at: now(),
  };
  db.prepare('INSERT INTO messages(id,session_id,seq,kind,role,content,meta,created_at) VALUES(?,?,?,?,?,?,?,?)')
    .run(rec.id, rec.session_id, rec.seq, rec.kind, rec.role, rec.content, rec.meta, rec.created_at);
  touchSession(db, sessionId);
  return rec;
}

/** 按给定 seq 落库(本地导入用)。meta 存完整出站事件(含 seq)。 */
export function appendOutbound(
  db: Db, sessionId: string,
  outbound: { seq: number; kind: string; role?: string | null; content?: string; toolInput?: unknown; toolId?: string; isError?: boolean },
): MessageRow {
  const content = outbound.kind === 'tool_use'
    ? JSON.stringify(outbound.toolInput ?? {})
    : String(outbound.content ?? '');
  const rec: MessageRow = {
    id: randomUUID(),
    session_id: sessionId,
    seq: outbound.seq,
    kind: outbound.kind,
    role: outbound.role ?? null,
    content,
    meta: JSON.stringify(outbound),
    created_at: now(),
  };
  db.prepare('INSERT INTO messages(id,session_id,seq,kind,role,content,meta,created_at) VALUES(?,?,?,?,?,?,?,?)')
    .run(rec.id, rec.session_id, rec.seq, rec.kind, rec.role, rec.content, rec.meta, rec.created_at);
  touchSession(db, sessionId);
  return rec;
}

export function listMessages(
  db: Db, sessionId: string, opts: { limit?: number; offset?: number } = {},
): { messages: MessageRow[]; total: number } {
  const total = (db.prepare('SELECT COUNT(*) AS c FROM messages WHERE session_id=?').get(sessionId) as { c: number }).c;
  const limit = Math.min(opts.limit ?? 200, 500);
  const offset = Math.max(opts.offset ?? 0, 0);
  const messages = db.prepare('SELECT * FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT ? OFFSET ?')
    .all(sessionId, limit, offset) as MessageRow[];
  return { messages, total };
}

export function createRun(db: Db, sessionId: string, model: string | null): { id: string } {
  const id = randomUUID();
  db.prepare('INSERT INTO runs(id,session_id,status,model,started_at) VALUES(?,?,?,?,?)')
    .run(id, sessionId, 'running', model, now());
  return { id };
}

export function finishRun(db: Db, runId: string, out: { status: string; totalCostUsd?: number; usage?: unknown }): void {
  db.prepare('UPDATE runs SET status=?, total_cost_usd=?, usage=?, ended_at=? WHERE id=?')
    .run(out.status, out.totalCostUsd ?? null, out.usage ? JSON.stringify(out.usage) : null, now(), runId);
}

/** 启动清扫:上个进程没关掉的 run 标为 interrupted,别永远停在 'running' 污染用量统计。 */
export function failStaleRuns(db: Db): number {
  const stale = db.prepare("SELECT DISTINCT session_id FROM runs WHERE status='running'").all() as { session_id: string }[];
  const changes = db.prepare("UPDATE runs SET status='interrupted', ended_at=? WHERE status='running'").run(now()).changes;
  // 显式补一条错误行:被重启打断的 run,之后的输出永久没落库(工具卡没有 tool_result、
  // 没有 complete)。不补的话刷新后看到的就是"卡住的卡 + 一片空白",像显示 bug;
  // 补了,客户端有明确的"上次运行被打断"说明。appendMessage 自动 MAX(seq)+1,与锁步无冲突。
  for (const { session_id } of stale) {
    appendMessage(db, session_id, {
      kind: 'error',
      content: '服务重启打断了上一轮运行,之后的输出没有记录;请重发或继续',
    });
  }
  return changes;
}

export type UsageSummary = {
  runs: number;
  totals: {
    inputTokens: number; outputTokens: number;
    cacheReadInputTokens: number; cacheCreationInputTokens: number;
    costUsd: number; durationMs: number; turns: number;
  };
  /** 最近一轮的上下文快照:input+cache_read+cache_creation ≈ 当前上下文占用 */
  last: { contextTokens: number; contextWindow: number; maxOutputTokens: number; endedAt: string | null } | null;
  /** 消息构成:按 kind 聚合行数与 content 字节数(上下文占比估算) */
  composition: { kind: string; count: number; bytes: number }[];
  /** 工具调用次数排行 */
  tools: { toolName: string; count: number }[];
};

export function sessionUsageSummary(db: Db, sessionId: string): UsageSummary {
  const totals = {
    inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0,
    costUsd: 0, durationMs: 0, turns: 0,
  };
  let runCount = 0;
  let last: UsageSummary['last'] = null;
  const runRows = db.prepare('SELECT usage, ended_at FROM runs WHERE session_id=? ORDER BY started_at').all(sessionId) as
    { usage: string | null; ended_at: string | null }[];
  for (const r of runRows) {
    if (!r.usage) continue;
    runCount += 1;
    let u: Record<string, number> | null = null;
    try { u = JSON.parse(r.usage) as Record<string, number>; } catch { continue; }
    totals.inputTokens += u.inputTokens ?? 0;
    totals.outputTokens += u.outputTokens ?? 0;
    totals.cacheReadInputTokens += u.cacheReadInputTokens ?? 0;
    totals.cacheCreationInputTokens += u.cacheCreationInputTokens ?? 0;
    totals.costUsd += u.totalCostUsd ?? 0;
    totals.durationMs += u.durationMs ?? 0;
    totals.turns += u.numTurns ?? 0;
    const contextTokens = (u.inputTokens ?? 0) + (u.cacheReadInputTokens ?? 0) + (u.cacheCreationInputTokens ?? 0);
    if (contextTokens > 0) {
      last = {
        contextTokens,
        contextWindow: u.contextWindow ?? 0,
        maxOutputTokens: u.maxOutputTokens ?? 0,
        endedAt: r.ended_at,
      };
    }
  }
  const composition = db.prepare(
    "SELECT kind, COUNT(*) AS count, COALESCE(SUM(LENGTH(content)),0) AS bytes FROM messages WHERE session_id=? GROUP BY kind ORDER BY bytes DESC",
  ).all(sessionId) as { kind: string; count: number; bytes: number }[];
  const tools = db.prepare(
    "SELECT json_extract(meta,'$.toolName') AS toolName, COUNT(*) AS count FROM messages WHERE session_id=? AND kind='tool_use' GROUP BY 1 ORDER BY count DESC",
  ).all(sessionId) as { toolName: string; count: number }[];
  return { runs: runCount, totals, last, composition, tools };
}
