import Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

export type Db = Database.Database;
export type SessionRow = {
  id: string; title: string; cwd: string | null; provider_session_id: string | null;
  model: string | null; permission_mode: string; is_pinned: number;
  created_at: string; updated_at: string;
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
      is_pinned INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS messages(
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
      kind TEXT NOT NULL, role TEXT, content TEXT NOT NULL, meta TEXT,
      created_at TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, seq);
    CREATE TABLE IF NOT EXISTS runs(
      id TEXT PRIMARY KEY, session_id TEXT NOT NULL, status TEXT NOT NULL,
      model TEXT, total_cost_usd REAL, usage TEXT, started_at TEXT NOT NULL, ended_at TEXT);
  `);
  return db;
}

const now = () => new Date().toISOString();

export function createSession(db: Db, input: { title?: string; cwd?: string; model?: string } = {}): SessionRow {
  const id = randomUUID();
  const ts = now();
  db.prepare('INSERT INTO sessions(id,title,cwd,model,created_at,updated_at) VALUES(?,?,?,?,?,?)')
    .run(id, input.title?.trim() || '新会话', input.cwd ?? null, input.model ?? null, ts, ts);
  return getSession(db, id)!;
}

export function getSession(db: Db, id: string): SessionRow | undefined {
  return db.prepare('SELECT * FROM sessions WHERE id=?').get(id) as SessionRow | undefined;
}

export function listSessions(db: Db): SessionRow[] {
  return db.prepare('SELECT * FROM sessions ORDER BY is_pinned DESC, updated_at DESC').all() as SessionRow[];
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
  db.prepare('DELETE FROM messages WHERE session_id=?').run(id);
  db.prepare('DELETE FROM runs WHERE session_id=?').run(id);
  return db.prepare('DELETE FROM sessions WHERE id=?').run(id).changes > 0;
}

export function appendMessage(
  db: Db, sessionId: string,
  input: { kind: string; role?: string; content: string; meta?: unknown },
): MessageRow {
  const row = db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE session_id=?').get(sessionId) as { s: number };
  const rec: MessageRow = {
    id: randomUUID(),
    session_id: sessionId,
    seq: row.s + 1,
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
