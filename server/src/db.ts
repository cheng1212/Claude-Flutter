import Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

export type Db = Database.Database;
export type SessionRow = {
  id: string; title: string; cwd: string | null; provider_session_id: string | null;
  model: string | null; permission_mode: string; is_pinned: number; source: string;
  created_at: string; updated_at: string;
  /** 列表副标题:最后一条文本消息截 120 字(listSessions 附带,非表列) */
  last_message?: string | null;
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
  `);
  // 迁移:旧库 sessions 无 source 列,补上(本地导入的会话置 'local')
  const sessionCols = db.prepare('PRAGMA table_info(sessions)').all() as { name: string }[];
  if (!sessionCols.some((c) => c.name === 'source')) {
    db.exec("ALTER TABLE sessions ADD COLUMN source TEXT NOT NULL DEFAULT 'app'");
  }
  return db;
}

const now = () => new Date().toISOString();

export function createSession(
  db: Db,
  input: { title?: string; cwd?: string; model?: string; source?: 'app' | 'local'; providerSessionId?: string; createdAt?: string; updatedAt?: string } = {},
): SessionRow {
  const id = randomUUID();
  const ts = now();
  db.prepare('INSERT INTO sessions(id,title,cwd,model,source,provider_session_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?)')
    .run(
      id, input.title?.trim() || '新会话', input.cwd ?? null, input.model ?? null,
      input.source ?? 'app', input.providerSessionId ?? null,
      input.createdAt ?? ts, input.updatedAt ?? ts,
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

export function listSessions(db: Db): SessionRow[] {
  // last_message:最后一条文本消息截 120 字做列表副标题(认会话全靠它,不全靠标题)
  return db.prepare(`
    SELECT s.*,
      (SELECT substr(m.content, 1, 120) FROM messages m
        WHERE m.session_id = s.id AND m.kind = 'text'
        ORDER BY m.seq DESC LIMIT 1) AS last_message
    FROM sessions s
    ORDER BY s.is_pinned DESC, s.updated_at DESC
  `).all() as SessionRow[];
}

export function updateSession(
  db: Db, id: string,
  patch: Partial<{ title: string; isPinned: boolean; providerSessionId: string; model: string; permissionMode: string; cwd: string }>,
): SessionRow | undefined {
  const cur = getSession(db, id);
  if (!cur) return undefined;
  db.prepare('UPDATE sessions SET title=?, is_pinned=?, provider_session_id=?, model=?, permission_mode=?, cwd=?, updated_at=? WHERE id=?')
    .run(
      patch.title?.trim() || cur.title,
      patch.isPinned === undefined ? cur.is_pinned : (patch.isPinned ? 1 : 0),
      patch.providerSessionId ?? cur.provider_session_id,
      patch.model ?? cur.model,
      patch.permissionMode ?? cur.permission_mode,
      patch.cwd ?? cur.cwd,
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
