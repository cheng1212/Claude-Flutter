# zCode åŽç«¯ MVP å®žæ–½è®¡åˆ’

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ä¸€ä¸ª Node åŽç«¯,é€šè¿‡ @anthropic-ai/claude-agent-sdk é©±åŠ¨çœŸ claude CLI,å¯¹æ‰‹æœºæš´éœ² REST + WS(æµå¼/å®¡æ‰¹/è¡¥å‘)ã€‚

**Architecture:** Fastify(HTTP)+ ws(åŒä¸€ç«¯å£ 5190);SDK åŒ…åœ¨è‡ªæœ‰ SessionRuntime åŽé¢;æ¯ä¼šè¯ä¸€ä¸ªè¿è¡Œæ—¶;RunRegistry åš seq ç¼“å†²ä¸Žè¡¥å‘;SQLite æŒä¹…åŒ–;æ¨¡åž‹è·¯ç”±åªè¯»å¤ç”¨ `~/litellm/claude-routes.json`ã€‚

**Tech Stack:** Node 20+ / TypeScript ESM / tsx / vitest / fastify@5 / ws@8 / better-sqlite3 / @anthropic-ai/claude-agent-sdk@^0.3.165

**å·¥ä½œç›®å½•:** `D:\cheng\zcode\server`(ä¸‹æ–‡ç›¸å¯¹è·¯å¾„å‡åŸºäºŽæ­¤)

---

### Task 1: è„šæ‰‹æž¶ + å¥åº·æ£€æŸ¥(TDD èµ·æ­¥)

**Files:**
- Create: `package.json`, `tsconfig.json`, `vitest.config.ts`, `src/http.ts`, `test/http.test.ts`

- [x] **Step 1: å†™ package.json / tsconfig / vitest é…ç½®**

`package.json`:
```json
{
  "name": "zcode-server",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "tsx watch src/index.ts",
    "start": "tsx src/index.ts",
    "test": "vitest run"
  },
  "dependencies": {
    "@anthropic-ai/claude-agent-sdk": "^0.3.165",
    "better-sqlite3": "^11.10.0",
    "fastify": "^5.2.0",
    "ws": "^8.18.0"
  },
  "devDependencies": {
    "@types/better-sqlite3": "^7.6.12",
    "@types/node": "^22.10.0",
    "@types/ws": "^8.5.13",
    "tsx": "^4.19.0",
    "typescript": "^5.6.0",
    "vitest": "^3.0.0"
  }
}
```

`tsconfig.json`:
```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "strict": true,
    "skipLibCheck": true,
    "noEmit": true,
    "types": ["node"]
  },
  "include": ["src", "test"]
}
```

`vitest.config.ts`:
```ts
import { defineConfig } from 'vitest/config';

export default defineConfig({ test: { include: ['test/**/*.test.ts'] } });
```

- [x] **Step 2: å†™å¤±è´¥æµ‹è¯•** â€” `test/http.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';

describe('health', () => {
  it('GET /api/health è¿”å›ž ok(æ— éœ€é‰´æƒ)', async () => {
    const app = await buildApp({ token: 't' });
    const res = await app.inject({ method: 'GET', url: '/api/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
    await app.close();
  });

  it('å…¶ä½™ /api éœ€è¦ Bearer token', async () => {
    const app = await buildApp({ token: 't' });
    const no = await app.inject({ method: 'GET', url: '/api/sessions' });
    expect(no.statusCode).toBe(401);
    const bad = await app.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer wrong' } });
    expect(bad.statusCode).toBe(401);
    const ok = await app.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer t' } });
    expect(ok.statusCode).toBe(200);
    await app.close();
  });
});
```

- [x] **Step 3: è·‘æµ‹è¯•ç¡®è®¤å¤±è´¥** â€” `npm run test` â†’ FAIL (src/http.js ä¸å­˜åœ¨)
- [x] **Step 4: æœ€å°å®žçŽ°** â€” `src/http.ts`
```ts
import type { FastifyInstance } from 'fastify';
import fastify from 'fastify';

export type AppOptions = { token: string };

export async function buildApp(opts: AppOptions): Promise<FastifyInstance> {
  const app = fastify();
  app.get('/api/health', async () => ({ ok: true }));
  app.addHook('onRequest', async (req, reply) => {
    if (req.url.startsWith('/api/health')) return;
    if (!req.url.startsWith('/api/')) return;
    const header = req.headers.authorization ?? '';
    if (header !== `Bearer ${opts.token}`) {
      await reply.code(401).send({ error: 'unauthorized' });
    }
  });
  return app;
}
```
- [x] **Step 5: `npm run test` â†’ PASS;`npx tsc --noEmit` å¹²å‡€**
- [x] **Step 6: Commit** `git add -A && git commit -m "feat(server): scaffold + health + bearer auth"`

### Task 2: é…ç½®åŠ è½½(é¦–æ¬¡ç”Ÿæˆ token)

**Files:**
- Create: `src/config.ts`, `test/config.test.ts`

- [x] **Step 1: å¤±è´¥æµ‹è¯•** â€” `test/config.test.ts`
```ts
import { fs as memfs } from './helpers.js';
import { describe, expect, it } from 'vitest';
import { loadOrCreateConfig } from '../src/config.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

describe('config', () => {
  it('é¦–æ¬¡è¿è¡Œç”Ÿæˆ token å¹¶å†™ç›˜;ç¬¬äºŒæ¬¡è¯»å–åŒä¸€ä¸ª', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    const a = loadOrCreateConfig(dir);
    expect(a.token).toMatch(/^[0-9a-f-]{36}$/);
    const b = loadOrCreateConfig(dir);
    expect(b.token).toBe(a.token);
    expect(b.port).toBe(5190);
    fs.rmSync(dir, { recursive: true, force: true });
  });
  it('çŽ¯å¢ƒå˜é‡ ZCODE_TOKEN è¦†ç›–', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    process.env.ZCODE_TOKEN = 'x';
    const c = loadOrCreateConfig(dir);
    expect(c.token).toBe('x');
    delete process.env.ZCODE_TOKEN;
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
```
- [x] **Step 2: è·‘ â†’ FAIL**
- [x] **Step 3: å®žçŽ°** â€” `src/config.ts`
```ts
import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export type ServerConfig = {
  token: string;
  port: number;
  dataDir: string;
  routesPath: string;
  bgCeilingMs: number;
  approvalTimeoutMs: number;
};

export function defaultDataDir(): string {
  return process.env.ZCODE_DATA_DIR ?? path.join(os.homedir(), '.zcode-server');
}

export function loadOrCreateConfig(dataDir = defaultDataDir()): ServerConfig {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'config.json');
  let stored: { token?: string } = {};
  try { stored = JSON.parse(fs.readFileSync(file, 'utf8')); } catch { /* first run */ }
  const token = process.env.ZCODE_TOKEN ?? stored.token ?? randomUUID();
  if (!stored.token || stored.token !== token) {
    fs.writeFileSync(file, JSON.stringify({ token }, null, 2));
  }
  return {
    token,
    port: Number(process.env.ZCODE_PORT) || 5190,
    dataDir,
    routesPath: process.env.ZCODE_CLAUDE_ROUTES_PATH
      ?? path.join(os.homedir(), 'litellm', 'claude-routes.json'),
    bgCeilingMs: Number(process.env.ZCODE_BG_CEILING_MS) || 30 * 60 * 1000,
    approvalTimeoutMs: Number(process.env.ZCODE_APPROVAL_TIMEOUT_MS) || 10 * 60 * 1000,
  };
}
```
- [x] **Step 4: `npm run test` â†’ PASS;Commit** `feat(server): config loader`

### Task 3: SQLite ä¸‰è¡¨ + repo

**Files:**
- Create: `src/db.ts`, `test/db.test.ts`

- [x] **Step 1: å¤±è´¥æµ‹è¯•** â€” `test/db.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { openDb, createSession, getSession, listSessions, updateSession, deleteSession, appendMessage, listMessages, createRun, finishRun } from '../src/db.js';

describe('db', () => {
  it('ä¼šè¯ CRUD + ç½®é¡¶æŽ’åº', () => {
    const db = openDb(':memory:');
    const a = createSession(db, { title: 'a' });
    const b = createSession(db, { title: 'b' });
    updateSession(db, b.id, { isPinned: true });
    const list = listSessions(db);
    expect(list[0].id).toBe(b.id);
    expect(list.length).toBe(2);
    expect(getSession(db, a.id)?.permissionMode).toBe('default');
    deleteSession(db, a.id);
    expect(listSessions(db).length).toBe(1);
  });
  it('æ¶ˆæ¯ seq æŒ‰ä¼šè¯é€’å¢ž;åŽ†å²åˆ†é¡µ', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'x' });
    for (let i = 0; i < 25; i++) appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: `m${i}` });
    const page = listMessages(db, s.id, { limit: 10, offset: 0 });
    expect(page.total).toBe(25);
    expect(page.messages.length).toBe(10);
    expect(page.messages[0].seq).toBe(25); // æœ€æ–°åœ¨å‰
    const tail = listMessages(db, s.id, { limit: 10, offset: 20 });
    expect(tail.messages[0].seq).toBe(5);
  });
  it('run è®°å½•æˆæœ¬ä¸Žç”¨é‡', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'r' });
    const run = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, run.id, { status: 'complete', totalCostUsd: 0.12, usage: { inputTokens: 100, outputTokens: 50 } });
    const row = db.prepare('SELECT * FROM runs WHERE id=?').get(run.id) as any;
    expect(row.status).toBe('complete');
    expect(row.total_cost_usd).toBeCloseTo(0.12);
  });
});
```
- [x] **Step 2: è·‘ â†’ FAIL**
- [x] **Step 3: å®žçŽ°** â€” `src/db.ts`
```ts
import Database from 'better-sqlite3';
import { randomUUID } from 'node:crypto';

export type Db = Database.Database;
export type SessionRow = {
  id: string; title: string; cwd: string | null; provider_session_id: string | null;
  model: string | null; permission_mode: string; is_pinned: number; created_at: string; updated_at: string;
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
  db.prepare(`INSERT INTO sessions(id,title,cwd,model,created_at,updated_at) VALUES(?,?,?,?,?,?)`)
    .run(id, input.title?.trim() || 'æ–°ä¼šè¯', input.cwd ?? null, input.model ?? null, ts, ts);
  return getSession(db, id)!;
}
export function getSession(db: Db, id: string): SessionRow | undefined {
  return db.prepare('SELECT * FROM sessions WHERE id=?').get(id) as SessionRow | undefined;
}
export function listSessions(db: Db): SessionRow[] {
  return db.prepare('SELECT * FROM sessions ORDER BY is_pinned DESC, updated_at DESC').all() as SessionRow[];
}
export function updateSession(db: Db, id: string, patch: Partial<{ title: string; isPinned: boolean; providerSessionId: string; model: string; permissionMode: string; cwd: string }>): SessionRow | undefined {
  const cur = getSession(db, id);
  if (!cur) return undefined;
  db.prepare(`UPDATE sessions SET title=?, is_pinned=?, provider_session_id=?, model=?, permission_mode=?, cwd=?, updated_at=? WHERE id=?`)
    .run(patch.title?.trim() || cur.title,
      patch.isPinned === undefined ? cur.is_pinned : (patch.isPinned ? 1 : 0),
      patch.providerSessionId ?? cur.provider_session_id,
      patch.model ?? cur.model,
      patch.permissionMode ?? cur.permission_mode,
      patch.cwd ?? cur.cwd,
      now(), id);
  return getSession(db, id);
}
export function touchSession(db: Db, id: string): void {
  db.prepare('UPDATE sessions SET updated_at=? WHERE id=?').run(now(), id);
}
export function deleteSession(db: Db, id: string): boolean {
  db.prepare('DELETE FROM messages WHERE session_id=?').run(id);
  db.prepare('DELETE FROM runs WHERE session_id=?').run(id);
  const r = db.prepare('DELETE FROM sessions WHERE id=?').run(id);
  return r.changes > 0;
}

export type MessageRow = { id: string; session_id: string; seq: number; kind: string; role: string | null; content: string; meta: string | null; created_at: string };

export function appendMessage(db: Db, sessionId: string, input: { kind: string; role?: string; content: string; meta?: unknown }): MessageRow {
  const row = db.prepare('SELECT COALESCE(MAX(seq),0) AS s FROM messages WHERE session_id=?').get(sessionId) as { s: number };
  const rec: MessageRow = {
    id: randomUUID(), session_id: sessionId, seq: row.s + 1, kind: input.kind,
    role: input.role ?? null, content: input.content,
    meta: input.meta === undefined ? null : JSON.stringify(input.meta), created_at: now(),
  };
  db.prepare(`INSERT INTO messages(id,session_id,seq,kind,role,content,meta,created_at) VALUES(?,?,?,?,?,?,?,?)`)
    .run(rec.id, rec.session_id, rec.seq, rec.kind, rec.role, rec.content, rec.meta, rec.created_at);
  touchSession(db, sessionId);
  return rec;
}
export function listMessages(db: Db, sessionId: string, opts: { limit?: number; offset?: number } = {}): { messages: MessageRow[]; total: number } {
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
```
- [x] **Step 4: `npm run test` â†’ PASS;Commit** `feat(server): sqlite schema + repo`

### Task 4: æ¨¡åž‹è·¯ç”±(è¯» claude-routes.json)

**Files:**
- Create: `src/routes.ts`, `test/routes.test.ts`

- [x] **Step 1: å¤±è´¥æµ‹è¯•** â€” `test/routes.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { loadRoutes, resolveModel, listModels } from '../src/routes.js';

const fixture = {
  defaultRoute: { baseUrl: 'http://127.0.0.1:4001', authToken: 'sk-d' },
  routes: {
    'glm-5.3-flash': { baseUrl: 'https://open.bigmodel.cn/api/anthropic', authToken: 'k', model: 'glm-5.3-flash' },
  },
};

describe('routes', () => {
  it('æ˜¾å¼è·¯ç”± â†’ settings + env', () => {
    const r = resolveModel(fixture as never, 'glm-5.3-flash');
    expect(r?.settings?.env.ANTHROPIC_BASE_URL).toBe('https://open.bigmodel.cn/api/anthropic');
    expect(r?.upstreamModel).toBe('glm-5.3-flash');
  });
  it('default / æœªçŸ¥æ¨¡åž‹ â†’ æ— è·¯ç”±(CLI ç”¨è‡ªå·±çš„ç«¯ç‚¹)', () => {
    expect(resolveModel(fixture as never, 'default')).toBeNull();
    expect(resolveModel(fixture as never, undefined)).toBeNull();
  });
  it('listModels = default + æ˜¾å¼ keys(ä¸å« defaultRoute éšå¼)', () => {
    expect(listModels(fixture as never)).toEqual(['default', 'glm-5.3-flash']);
  });
  it('æ–‡ä»¶ç¼ºå¤±/å JSON â†’ ç©ºè·¯ç”±ä¸å´©', () => {
    expect(loadRoutes('Z:/nope/nope.json')).toBeNull();
    expect(listModels(null)).toEqual(['default']);
  });
});
```
- [x] **Step 2: è·‘ â†’ FAIL**
- [x] **Step 3: å®žçŽ°** â€” `src/routes.ts`
```ts
import fs from 'node:fs';

export type RouteEntry = { baseUrl?: string; authToken?: string; model?: string };
export type RouteConfig = { defaultRoute?: RouteEntry; routes?: Record<string, RouteEntry> };
export type ResolvedModel = { id: string; upstreamModel: string; settings: { env: { ANTHROPIC_BASE_URL: string; ANTHROPIC_AUTH_TOKEN: string }; model: string } | null };

export function loadRoutes(path: string): RouteConfig | null {
  try { return JSON.parse(fs.readFileSync(path, 'utf8')) as RouteConfig; } catch { return null; }
}

// è¯­ä¹‰ä¸Ž cloudcli ä¸€è‡´:åªæœ‰æ˜¾å¼åˆ—å‡ºçš„è‡ªå®šä¹‰æ¨¡åž‹æ‰æ³¨å…¥è·¯ç”±;
// default/æœªåˆ—å‡º â†’ null,CLI ç”¨è‡ªå·±é…ç½®çš„ç«¯ç‚¹,é˜²æ­¢ defaultRoute åŠ«æŒå®˜æ–¹æ¨¡åž‹ã€‚
export function resolveModel(config: RouteConfig | null, modelId: string | undefined): ResolvedModel | null {
  if (!modelId || modelId === 'default') return null;
  const entry = config?.routes?.[modelId];
  if (!entry?.baseUrl) return null;
  return {
    id: modelId,
    upstreamModel: entry.model || modelId,
    settings: {
      env: { ANTHROPIC_BASE_URL: entry.baseUrl, ANTHROPIC_AUTH_TOKEN: entry.authToken ?? '' },
      model: entry.model || modelId,
    },
  };
}

export function listModels(config: RouteConfig | null): string[] {
  return ['default', ...Object.keys(config?.routes ?? {})];
}
```
- [x] **Step 4: `npm run test` â†’ PASS;Commit** `feat(server): model routes loader`

### Task 5: åè®®ç±»åž‹ + SDK æ¶ˆæ¯è½¬æ¢(çº¯å‡½æ•°,TDD ä¸»æˆ˜åœº)

**Files:**
- Create: `src/protocol/types.ts`, `src/protocol/transform.ts`, `test/transform.test.ts`

- [x] **Step 1: ç±»åž‹** â€” `src/protocol/types.ts`
```ts
export type ProtocolEvent =
  | { kind: 'session_created'; providerSessionId: string }
  | { kind: 'text'; role: 'assistant'; content: string }
  | { kind: 'stream_delta'; content: string }
  | { kind: 'thinking'; content: string }
  | { kind: 'thinking_delta'; content: string }
  | { kind: 'tool_use'; toolId: string; toolName: string; toolInput: unknown }
  | { kind: 'tool_result'; toolId: string; content: string; isError: boolean }
  | { kind: 'permission_request'; requestId: string; toolName: string; input: unknown }
  | { kind: 'model'; model: string; endpoint: string | null }
  | { kind: 'usage'; inputTokens: number; outputTokens: number; totalCostUsd: number; durationMs: number }
  | { kind: 'complete'; exitCode: number; aborted: boolean }
  | { kind: 'error'; content: string };

/** åŽå°ä¿æ´»åˆ¤å®š:è¿™äº›å·¥å…·ä¼šæŠŠå·¥ä½œç•™åˆ° result ä¹‹åŽã€‚ */
export const DEFERRED_WORK_TOOLS = new Set(['Monitor', 'ScheduleWakeup', 'CronCreate', 'TaskCreate']);
export function startsBackgroundWork(events: ProtocolEvent[]): boolean {
  return events.some((e) => {
    if (e.kind !== 'tool_use') return false;
    if (e.toolName === 'Bash') return (e.toolInput as { run_in_background?: boolean } | null)?.run_in_background === true;
    return DEFERRED_WORK_TOOLS.has(e.toolName);
  });
}
```
- [x] **Step 2: å¤±è´¥æµ‹è¯•** â€” `test/transform.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { transformMessage } from '../src/protocol/transform.js';

describe('transformMessage', () => {
  it('assistant ä¸‰ç§ block â†’ text/thinking/tool_use', () => {
    const out = transformMessage({
      type: 'assistant', session_id: 's1',
      message: { role: 'assistant', content: [
        { type: 'thinking', thinking: 'æƒ³ä¸€ä¸‹' },
        { type: 'text', text: 'ä½ å¥½' },
        { type: 'tool_use', id: 't1', name: 'Read', input: { file_path: 'a.ts' } },
      ] },
    });
    expect(out).toEqual([
      { kind: 'thinking', content: 'æƒ³ä¸€ä¸‹' },
      { kind: 'text', role: 'assistant', content: 'ä½ å¥½' },
      { kind: 'tool_use', toolId: 't1', toolName: 'Read', toolInput: { file_path: 'a.ts' } },
    ]);
  });
  it('user tool_result â†’ tool_result(is_error é€ä¼ )', () => {
    const out = transformMessage({
      type: 'user', session_id: 's1',
      message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'file body', is_error: true }] },
    });
    expect(out).toEqual([{ kind: 'tool_result', toolId: 't1', content: 'file body', isError: true }]);
  });
  it('stream_event æ–‡æœ¬/æ€è€ƒå¢žé‡', () => {
    const text = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'æ—©' } } });
    const think = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: 'å—¯' } } });
    expect(text).toEqual([{ kind: 'stream_delta', content: 'æ—©' }]);
    expect(think).toEqual([{ kind: 'thinking_delta', content: 'å—¯' }]);
  });
  it('result success â†’ usage + complete(0)', () => {
    const out = transformMessage({
      type: 'result', subtype: 'success', session_id: 's', result: 'done',
      total_cost_usd: 0.05, duration_ms: 1234,
      usage: { input_tokens: 10, output_tokens: 5 },
    });
    expect(out).toEqual([
      { kind: 'usage', inputTokens: 10, outputTokens: 5, totalCostUsd: 0.05, durationMs: 1234 },
      { kind: 'complete', exitCode: 0, aborted: false },
    ]);
  });
  it('result error_max_turns â†’ error + complete(1)', () => {
    const out = transformMessage({ type: 'result', subtype: 'error_max_turns', session_id: 's', errors: ['too many turns'] });
    expect(out[0]).toEqual({ kind: 'error', content: 'too many turns' });
    expect(out[1]).toEqual({ kind: 'complete', exitCode: 1, aborted: false });
  });
  it('init/æœªçŸ¥ â†’ ç©º', () => {
    expect(transformMessage({ type: 'system', subtype: 'init', session_id: 's' })).toEqual([]);
    expect(transformMessage({ type: 'keep_alive' } as never)).toEqual([]);
  });
});
```
- [x] **Step 3: è·‘ â†’ FAIL**
- [x] **Step 4: å®žçŽ°** â€” `src/protocol/transform.ts`
```ts
import type { ProtocolEvent } from './types.js';

type AnyRecord = Record<string, unknown>;

// SDK æ¶ˆæ¯ â†’ å†…éƒ¨äº‹ä»¶çš„å”¯ä¸€æ˜ å°„ç‚¹ã€‚çº¯å‡½æ•°,ä¾¿äºŽå¯¹æ‹ SDK å‡çº§ã€‚
export function transformMessage(msg: AnyRecord): ProtocolEvent[] {
  const type = msg.type as string;
  if (type === 'assistant') {
    const content = (msg.message as AnyRecord | undefined)?.content;
    if (!Array.isArray(content)) return [];
    const out: ProtocolEvent[] = [];
    for (const block of content) {
      const b = block as AnyRecord;
      if (b.type === 'text' && typeof b.text === 'string' && b.text) {
        out.push({ kind: 'text', role: 'assistant', content: b.text });
      } else if (b.type === 'thinking' && typeof b.thinking === 'string' && b.thinking) {
        out.push({ kind: 'thinking', content: b.thinking });
      } else if (b.type === 'tool_use') {
        out.push({ kind: 'tool_use', toolId: String(b.id ?? ''), toolName: String(b.name ?? ''), toolInput: b.input ?? {} });
      }
    }
    return out;
  }
  if (type === 'user') {
    const content = (msg.message as AnyRecord | undefined)?.content;
    if (!Array.isArray(content)) return [];
    const out: ProtocolEvent[] = [];
    for (const block of content) {
      const b = block as AnyRecord;
      if (b.type === 'tool_result') {
        const inner = b.content;
        const text = typeof inner === 'string' ? inner : JSON.stringify(inner ?? '');
        out.push({ kind: 'tool_result', toolId: String(b.tool_use_id ?? ''), content: text, isError: Boolean(b.is_error) });
      }
    }
    return out;
  }
  if (type === 'stream_event') {
    const event = msg.event as AnyRecord | undefined;
    if ((event?.type as string) !== 'content_block_delta') return [];
    const delta = event?.delta as AnyRecord | undefined;
    if (delta?.type === 'text_delta' && typeof delta.text === 'string') return [{ kind: 'stream_delta', content: delta.text }];
    if (delta?.type === 'thinking_delta' && typeof delta.thinking === 'string') return [{ kind: 'thinking_delta', content: delta.thinking }];
    return [];
  }
  if (type === 'result') {
    const out: ProtocolEvent[] = [];
    const usage = msg.usage as AnyRecord | undefined;
    if (msg.subtype === 'success') {
      out.push({
        kind: 'usage',
        inputTokens: Number(usage?.input_tokens ?? 0),
        outputTokens: Number(usage?.output_tokens ?? 0),
        totalCostUsd: Number(msg.total_cost_usd ?? 0),
        durationMs: Number(msg.duration_ms ?? 0),
      });
    } else {
      const errors = Array.isArray(msg.errors) ? msg.errors.join('; ') : String(msg.result ?? msg.subtype ?? 'error');
      out.push({ kind: 'error', content: errors || String(msg.subtype) });
    }
    out.push({ kind: 'complete', exitCode: msg.subtype === 'success' ? 0 : 1, aborted: false });
    return out;
  }
  return [];
}
```
- [x] **Step 5: `npm run test` â†’ PASS;Commit** `feat(server): protocol events + sdk transform`

### Task 6: RunRegistry(seq å•è°ƒã€çŽ¯å½¢ç¼“å†²ã€è¡¥å‘ã€è®¢é˜…)

**Files:**
- Create: `src/runs/run-registry.ts`, `test/run-registry.test.ts`

- [x] **Step 1: å¤±è´¥æµ‹è¯•** â€” `test/run-registry.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { RunRegistry } from '../src/runs/run-registry.js';

describe('RunRegistry', () => {
  it('seq æŒ‰ä¼šè¯å•è°ƒé€’å¢ž,è·¨ run ä¸æ¸…é›¶', () => {
    const reg = new RunRegistry();
    reg.begin('s1');
    expect(reg.push('s1', { kind: 'text', role: 'assistant', content: 'a' }).seq).toBe(1);
    reg.finish('s1', 0, false);
    reg.begin('s1');
    expect(reg.push('s1', { kind: 'text', role: 'assistant', content: 'b' }).seq).toBe(2);
  });
  it('replay(afterSeq) åªå›žç¼ºçš„;live è®¢é˜…æ”¶åˆ°æ–°äº‹ä»¶', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    reg.push('s', { kind: 'text', role: 'assistant', content: '1' });
    reg.push('s', { kind: 'text', role: 'assistant', content: '2' });
    const seen: string[] = [];
    const off = reg.subscribe('s', (e) => seen.push((e as { content: string }).content));
    reg.push('s', { kind: 'text', role: 'assistant', content: '3' });
    expect(seen).toEqual(['3']);
    off();
    reg.push('s', { kind: 'text', role: 'assistant', content: '4' });
    expect(seen).toEqual(['3']); // é€€è®¢åŽä¸å†æ”¶
    expect(reg.replay('s', 1).map((e) => (e as { content: string }).content)).toEqual(['2', '3', '4']);
    expect(reg.lastSeq('s')).toBe(4);
  });
  it('ç¼“å†²å°é¡¶ 1000,é‡æ”¾ä¸è¶Šç•Œ', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    for (let i = 0; i < 1100; i++) reg.push('s', { kind: 'stream_delta', content: 'x' });
    expect(reg.replay('s', 0).length).toBe(1000);
    expect(reg.lastSeq('s')).toBe(1100);
  });
  it('isRunning:beginâ†’true,finishâ†’false', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    expect(reg.isRunning('s')).toBe(true);
    reg.finish('s', 0, false);
    expect(reg.isRunning('s')).toBe(false);
  });
});
```
- [x] **Step 2: è·‘ â†’ FAIL**
- [x] **Step 3: å®žçŽ°** â€” `src/runs/run-registry.ts`
```ts
import type { ProtocolEvent } from '../protocol/types.js';

export type OutboundEvent = { seq: number } & ProtocolEvent;
type Listener = (event: OutboundEvent) => void;

const BUFFER_CAP = 1000;

export class RunRegistry {
  private seq = new Map<string, number>();
  private buffer = new Map<string, OutboundEvent[]>();
  private running = new Set<string>();
  private listeners = new Map<string, Set<Listener>>();

  begin(sessionId: string): void { this.running.add(sessionId); }
  isRunning(sessionId: string): boolean { return this.running.has(sessionId); }

  finish(sessionId: string, exitCode: number, aborted: boolean): void {
    this.push(sessionId, { kind: 'complete', exitCode, aborted });
    this.running.delete(sessionId);
  }

  push(sessionId: string, event: ProtocolEvent): OutboundEvent {
    const next = (this.seq.get(sessionId) ?? 0) + 1;
    this.seq.set(sessionId, next);
    const outbound = { ...event, seq: next } as OutboundEvent;
    const buf = this.buffer.get(sessionId) ?? [];
    buf.push(outbound);
    if (buf.length > BUFFER_CAP) buf.splice(0, buf.length - BUFFER_CAP);
    this.buffer.set(sessionId, buf);
    for (const fn of this.listeners.get(sessionId) ?? []) fn(outbound);
    return outbound;
  }

  subscribe(sessionId: string, fn: Listener): () => void {
    const set = this.listeners.get(sessionId) ?? new Set();
    set.add(fn);
    this.listeners.set(sessionId, set);
    return () => set.delete(fn);
  }

  replay(sessionId: string, afterSeq: number): OutboundEvent[] {
    return (this.buffer.get(sessionId) ?? []).filter((e) => e.seq > afterSeq);
  }

  lastSeq(sessionId: string): number { return this.seq.get(sessionId) ?? 0; }
}
```
- [x] **Step 4: `npm run test` â†’ PASS;Commit** `feat(server): run registry with seq replay`

### Task 7: SessionRuntime(SDK åŒ…è£…:å®¡æ‰¹æ¡¥ã€åŽå°ä¿æ´»ã€ä¸­æ–­)

**Files:**
- Create: `src/protocol/sdk-client.ts`, `src/protocol/cli-path.ts`, `test/sdk-client.test.ts`

- [x] **Step 1: cli-path(Windows è§£æž,å‚è€ƒ cloudcli æ€è·¯é‡å†™)** â€” `src/protocol/cli-path.ts`
```ts
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// raw spawn ä¸è·Ÿ .cmd wrapper:æŠŠ "claude" è§£æžæˆçœŸ exeã€‚
export function resolveClaudeExecutable(configured?: string): string {
  const value = (configured ?? process.env.CLAUDE_CLI_PATH ?? 'claude').trim().replace(/^["']|["']$/g, '');
  if (process.platform !== 'win32') return value;
  if (/\.(exe|cjs|js|mjs)$/i.test(value) && (value.includes('/') || value.includes('\\'))) return value;
  try {
    const out = execFileSync('where.exe', [value], { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    const candidates = out.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const exe = candidates.find((c) => c.toLowerCase().endsWith('.exe'));
    if (exe) return exe;
    // npm wrapper(.cmd):è¯»å†…å®¹æ‰¾ claude.exe çœŸèº«
    for (const c of candidates) {
      try {
        const content = fs.readFileSync(c, 'utf8');
        const match = [...content.matchAll(/["']([^"'\r\n]*claude\.exe)["']/gi)][0];
        if (match) {
          const target = match[1].replace(/^%~dp0[\\/]/i, '').replace(/^\$basedir[\\/]/i, '');
          const resolved = path.isAbsolute(target) ? target : path.resolve(path.dirname(c), target);
          if (fs.existsSync(resolved)) return resolved;
        }
      } catch { /* not a wrapper */ }
    }
  } catch { /* where å¤±è´¥,äº¤ç”± SDK æŠ¥é”™ */ }
  return value;
}
```

- [x] **Step 2: å¤±è´¥æµ‹è¯•** â€” `test/sdk-client.test.ts`
```ts
import { describe, expect, it, vi } from 'vitest';
import { SessionRuntime } from '../src/protocol/sdk-client.js';
import type { ProtocolEvent } from '../src/protocol/types.js';

// fake query:æŽ¥æ”¶ prompt(å¼‚æ­¥è¿­ä»£å™¨)+ options,æŒ‰è„šæœ¬å SDK æ¶ˆæ¯ã€‚
function fakeQuery(script: Array<Record<string, unknown>>, opts?: {
  onUserMessage?: (m: unknown) => void;
  hangAfterScript?: boolean;
}) {
  return (args: { prompt: AsyncIterable<unknown>; options: Record<string, unknown> }) => {
    expect(args.options.canUseTool).toBeTypeOf('function');
    return (async function* () {
      for (const item of script) yield item;
      if (opts?.hangAfterScript) {
        await new Promise(() => {}); // æ¨¡æ‹Ÿä¿æ´»ä¸­çš„ CLI
      }
    })();
  };
}

const baseOpts = { cwd: 'C:/tmp', dataDir: undefined as string | undefined };

describe('SessionRuntime', () => {
  it('ä¸€è½®å®Œæ•´å¯¹è¯:å‘æ¶ˆæ¯ â†’ æ”¶äº‹ä»¶ â†’ å®ŒæˆåŽé‡Šæ”¾è¾“å…¥æµ', async () => {
    let released = false;
    const emit = vi.fn();
    const runtime = new SessionRuntime({
      ...baseOpts,
      appSessionId: 'app1',
      emit,
      queryFn: (args) => {
        return (async function* () {
          for (const item of [
            { type: 'system', subtype: 'init', session_id: 'prov-1' },
            { type: 'assistant', session_id: 'prov-1', message: { role: 'assistant', content: [{ type: 'text', text: 'ä½ å¥½' }] } },
            { type: 'result', subtype: 'success', session_id: 'prov-1', usage: { input_tokens: 3, output_tokens: 2 }, total_cost_usd: 0.01, duration_ms: 9 },
          ]) yield item;
          released = true; // generator ç»“æŸ == stdin é‡Šæ”¾
        })();
      },
    });
    await runtime.send('hi');
    const kinds = emit.mock.calls.map((c) => (c[0] as ProtocolEvent).kind);
    expect(kinds).toEqual(['session_created', 'text', 'usage', 'complete']);
    expect(released).toBe(true);
  });

  it('canUseTool â†’ permission_request;answerPermission(allow) åŽç»§ç»­', async () => {
    const emit = vi.fn();
    let allowFn: ((input: unknown) => Promise<unknown>) | null = null;
    const runtime = new SessionRuntime({
      ...baseOpts,
      appSessionId: 'app2',
      approvalTimeoutMs: 1000,
      emit,
      queryFn: (args) => {
        allowFn = args.options.canUseTool as (input: unknown) => Promise<unknown>;
        return (async function* () {
          yield { type: 'assistant', session_id: 'p', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't9', name: 'Bash', input: { command: 'dir' } }] } };
          yield { type: 'user', session_id: 'p', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't9', content: 'ok' }] } };
          yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
        })();
      },
    });
    await runtime.send('run dir');
    expect(emit.mock.calls.some((c) => (c[0] as ProtocolEvent).kind === 'permission_request')).toBe(true);
    const requestId = (emit.mock.calls.find((c) => (c[0] as ProtocolEvent).kind === 'permission_request')![0] as { requestId: string }).requestId;
    const decision = allowFn!({ tool_name: 'Bash', input: { command: 'dir' } });
    runtime.answerPermission(requestId, { allow: true });
    await expect(decision).resolves.toEqual(expect.objectContaining({ behavior: 'allow' }));
  });

  it('åŽå°å·¥ä½œ:Bash run_in_background åŽ result åˆ°äº†ä¹Ÿä¸é‡Šæ”¾,ä¸‹ä¸€è½® supersede é‡Šæ”¾æ—§æµ', async () => {
    const releases: string[] = [];
    const emit = vi.fn();
    const runtime = new SessionRuntime({
      ...baseOpts,
      appSessionId: 'app3',
      emit,
      queryFn: (args) => {
        const tag = Math.random().toString(36).slice(2);
        return (async function* () {
          try {
            yield { type: 'assistant', session_id: 'p', message: { role: 'assistant', content: [{ type: 'tool_use', id: 't1', name: 'Bash', input: { command: 'sleep 999', run_in_background: true } }] } };
            yield { type: 'result', subtype: 'success', session_id: 'p', usage: {}, total_cost_usd: 0, duration_ms: 1 };
            await new Promise<void>((resolve) => { args.options.__onRelease = () => { releases.push(tag); resolve(); }; });
          } finally { args.options.__onRelease?.(); }
        })();
      },
    });
    await runtime.send('bg');
    // result å·²åˆ°(å®¢æˆ·ç«¯å·²æ”¶ complete),ä½†æµè¿˜æŒ‚ç€
    expect(emit.mock.calls.some((c) => (c[0] as ProtocolEvent).kind === 'complete')).toBe(true);
    await runtime.send('next turn'); // æ–°ä¸€è½®å–ä»£æ—§ held æµ
    expect(releases.length).toBe(1);
  });

  it('abort â†’ complete(aborted:true) ä¸”ä¸å†å‘ error', async () => {
    const emit = vi.fn();
    const runtime = new SessionRuntime({
      ...baseOpts,
      appSessionId: 'app4',
      emit,
      queryFn: () => {
        let wake: () => void = () => {};
        const it = (async function* () {
          yield { type: 'assistant', session_id: 'p', message: { role: 'assistant', content: [{ type: 'text', text: '...' }] } };
          await new Promise<void>((r) => { wake = r; throw new Error('interrupted'); });
        })();
        (it as unknown as { interrupt?: () => void }).interrupt = () => wake();
        return it;
      },
    });
    const running = runtime.send('long');
    await new Promise((r) => setTimeout(r, 10));
    await runtime.abort();
    await running;
    const complete = emit.mock.calls.map((c) => c[0] as ProtocolEvent).find((e) => e.kind === 'complete') as { aborted: boolean } | undefined;
    expect(complete?.aborted).toBe(true);
  });
});
```

- [x] **Step 3: è·‘ â†’ FAIL**
- [x] **Step 4: å®žçŽ°** â€” `src/protocol/sdk-client.ts`
```ts
import { randomUUID } from 'node:crypto';
import { query as defaultQuery } from '@anthropic-ai/claude-agent-sdk';
import { transformMessage } from './transform.js';
import { startsBackgroundWork, type ProtocolEvent } from './types.js';
import { resolveClaudeExecutable } from './cli-path.js';

type QueryFn = typeof defaultQuery;
type AnyRecord = Record<string, unknown>;

export type PermissionDecision = { allow: boolean; updatedInput?: unknown; message?: string; remember?: boolean };

export type RuntimeOptions = {
  appSessionId: string;
  providerSessionId?: string | null;
  cwd: string;
  model?: string | null;
  permissionMode?: string;
  routeSettings?: { env: { ANTHROPIC_BASE_URL: string; ANTHROPIC_AUTH_TOKEN: string }; model: string } | null;
  emit: (event: ProtocolEvent) => void;
  queryFn?: QueryFn;
  bgCeilingMs?: number;
  approvalTimeoutMs?: number;
};

const INTERACTIVE_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode']);

/** ä¸€ä¸ª app ä¼šè¯ä¸€ä¸ªå®žä¾‹:ä¸²è¡Œè·‘ turn,æ¡¥æŽ¥å®¡æ‰¹,æŒ‰éœ€ä¿æ´»ã€‚ */
export class SessionRuntime {
  private opts: RuntimeOptions;
  private queryFn: QueryFn;
  private release: (() => void) | null = null;
  private providerSessionId: string | null;
  private pending = new Map<string, (d: PermissionDecision) => void>();
  private aborted = false;
  private running = false;
  private queued: string[] = [];

  constructor(opts: RuntimeOptions) {
    this.opts = opts;
    this.queryFn = opts.queryFn ?? defaultQuery;
    this.providerSessionId = opts.providerSessionId ?? null;
  }

  currentProviderSessionId(): string | null { return this.providerSessionId; }

  answerPermission(requestId: string, decision: PermissionDecision): void {
    this.pending.get(requestId)?.(decision);
  }

  /** æ–° turn:å–ä»£ä»»ä½• held æµ,ä¸²è¡ŒæŽ’é˜Ÿã€‚ */
  async send(text: string): Promise<void> {
    if (this.running) {
      return new Promise((resolve, reject) => { this.queued.push(text); /* ç®€åŒ–:åŒä¸€ä¼šè¯ WS å±‚å·²æŒ¡å¹¶å‘ */ resolve(); reject = reject; });
    }
    this.running = true;
    this.aborted = false;
    try {
      this.release?.(); this.release = null;
      await this.runTurn(text);
    } finally {
      this.running = false;
    }
  }

  private canUseTool = async (toolName: string, input: unknown): Promise<{ behavior: 'allow' | 'deny'; updatedInput?: unknown; message?: string }> => {
    const requestId = randomUUID();
    this.opts.emit({ kind: 'permission_request', requestId, toolName, input });
    const decision = await new Promise<PermissionDecision | null>((resolve) => {
      this.pending.set(requestId, resolve as (d: PermissionDecision) => void);
      const timeout = this.opts.approvalTimeoutMs ?? 10 * 60 * 1000;
      const interactive = INTERACTIVE_TOOLS.has(toolName);
      const timer = interactive ? null : setTimeout(() => resolve(null), timeout);
      if (interactive) this.pending.set(requestId, (d) => { resolve(d); });
      else this.pending.set(requestId, (d) => { clearTimeout(timer!); resolve(d); });
    });
    this.pending.delete(requestId);
    if (!decision || decision.allow === false) {
      return { behavior: 'deny', message: decision?.message ?? (decision === null ? 'approval timeout' : 'user denied') };
    }
    return { behavior: 'allow', updatedInput: decision.updatedInput ?? input };
  };

  private buildOptions(): AnyRecord {
    // SDK 0.2.113+ env æ˜¯æ›¿æ¢:å¿…é¡»å¸¦å…¨ process.env;è·¯ç”±æ—¶åŒå¸¦ç«¯ç‚¹å¹¶åˆ æŽ‰å¹²æ‰° keyã€‚
    const env: NodeJS.ProcessEnv = { ...process.env };
    let settings: unknown;
    if (this.opts.routeSettings) {
      settings = this.opts.routeSettings;
      env.ANTHROPIC_BASE_URL = this.opts.routeSettings.env.ANTHROPIC_BASE_URL;
      env.ANTHROPIC_AUTH_TOKEN = this.opts.routeSettings.env.ANTHROPIC_AUTH_TOKEN;
      delete env.ANTHROPIC_API_KEY;
    }
    const options: AnyRecord = {
      cwd: this.opts.cwd,
      env,
      pathToClaudeCodeExecutable: resolveClaudeExecutable(),
      model: this.opts.routeSettings?.model ?? this.opts.model ?? undefined,
      permissionMode: this.opts.permissionMode && this.opts.permissionMode !== 'default' ? this.opts.permissionMode : undefined,
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      settingSources: ['project', 'user', 'local'],
      includePartialMessages: true,
      maxThinkingTokens: undefined,
      canUseTool: this.canUseTool,
    };
    if (settings) options.settings = settings;
    if (this.providerSessionId) options.resume = this.providerSessionId;
    return options;
  }

  private async runTurn(text: string): Promise<void> {
    let turnCompleteSent = false;
    let backgroundWorkPending = false;
    let heldForBackground = false;
    let ceilingTimer: NodeJS.Timeout | null = null;

    const release = () => this.release?.();
    this.release = release;

    const held = new Promise<void>((resolve) => { this.release = () => { this.release = release; resolve(); }; });
    const stream = (async function* () { yield { type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null }; await held; })();

    const instance = this.queryFn({ prompt: stream as never, options: this.buildOptions() as never });

    try {
      for await (const raw of instance as AsyncIterable<AnyRecord>) {
        if (raw.type === 'system' && raw.subtype === 'init') {
          if (!this.providerSessionId && typeof raw.session_id === 'string') {
            this.providerSessionId = raw.session_id;
            this.opts.emit({ kind: 'session_created', providerSessionId: raw.session_id });
          }
          continue;
        }
        const events = transformMessage(raw);
        for (const event of events) this.opts.emit(event);
        if (startsBackgroundWork(events)) backgroundWorkPending = true;
        if (raw.type === 'result') {
          if (!turnCompleteSent) {
            turnCompleteSent = true;
            if (backgroundWorkPending) {
              heldForBackground = true;
              ceilingTimer = setTimeout(release, this.opts.bgCeilingMs ?? 30 * 60 * 1000);
              ceilingTimer.unref?.();
            } else {
              release();
            }
          } else {
            // åŽå°ä»»åŠ¡æ”¶å°¾çš„ç¬¬äºŒä¸ª result:äº‹ä»¶ç…§å‘,æµä¸å†ä¿
            release();
          }
        }
        if (this.aborted) break;
      }
    } catch (error) {
      if (!this.aborted) {
        const message = error instanceof Error ? error.message : String(error);
        this.opts.emit({ kind: 'error', content: message });
        if (!turnCompleteSent) {
          turnCompleteSent = true;
          this.opts.emit({ kind: 'complete', exitCode: 1, aborted: false });
        }
      }
    } finally {
      if (ceilingTimer) clearTimeout(ceilingTimer);
      release();
    }
    if (this.aborted && !turnCompleteSent) {
      this.opts.emit({ kind: 'complete', exitCode: 1, aborted: true });
    }
  }

  async abort(): Promise<void> {
    this.aborted = true;
    // ä¸­æ–­æŒ‚èµ·å®¡æ‰¹,é¿å… turn å¡æ­»
    for (const resolve of this.pending.values()) resolve({ allow: false, message: 'aborted' });
    this.pending.clear();
    this.release?.();
  }
}
```

æ³¨æ„:æµ‹è¯•é‡Œ fake çš„ `options.__onRelease` æ˜¯æŽ¢é’ˆ;çœŸå®žå®žçŽ°é‡Œ release é€šè¿‡ held promise å…³é—­ generator,`finally` é‡Œçš„ `release()` ä¿è¯ wind-downã€‚è¶…æ—¶/äº¤äº’å·¥å…·çš„ pending è§£æžåœ¨ finally ä¸é‡å¤ resolve(Map å·² clear)ã€‚

- [x] **Step 5: `npm run test` â†’ PASS(å…è®¸å¯¹å®žçŽ°åšç­‰ä»·å¾®è°ƒ,ä½†å››ä¸ªè¡Œä¸ºæ–­è¨€ä¸èƒ½ä¸¢);Commit** `feat(server): session runtime over sdk`

### Task 8: WS ç½‘å…³(auth/å››æ¶ˆæ¯/è¡¥å‘/å®¡æ‰¹å›žè·¯)

**Files:**
- Create: `src/gateway/ws-gateway.ts`, `test/ws-gateway.test.ts`

- [x] **Step 1: å¤±è´¥æµ‹è¯•** â€” `test/ws-gateway.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { createServer } from 'node:http';
import { WebSocket } from 'ws';
import { buildApp } from '../src/http.js';
import { attachWsGateway } from '../src/gateway/ws-gateway.js';
import { RunRegistry } from '../src/runs/run-registry.js';
import { openDb, createSession } from '../src/db.js';
import type { SessionRuntime } from '../src/protocol/sdk-client.js';
import type { ProtocolEvent } from '../src/protocol/types.js';

function listen(app: Awaited<ReturnType<typeof buildApp>>): Promise<number> {
  return new Promise((resolve) => {
    app.server.listen(0, () => resolve((app.server.address() as { port: number }).port));
  });
}

function wsConnect(port: number): Promise<{ ws: WebSocket; next: () => Promise<any> }> {
  const ws = new WebSocket(`ws://127.0.0.1:${port}`);
  const queue: any[] = [];
  const waiters: ((v: any) => void)[] = [];
  ws.on('message', (raw) => {
    const parsed = JSON.parse(String(raw));
    const w = waiters.shift();
    if (w) w(parsed); else queue.push(parsed);
  });
  return new Promise((resolve) => {
    ws.on('open', () => resolve({
      ws,
      next: () => queue.length ? Promise.resolve(queue.shift()!) : new Promise((r) => waiters.push(r)),
    }));
  });
}

describe('ws gateway', () => {
  it('æœª auth æ”¶ error å¹¶å…³é—­;auth åŽ chat.send èµ° stub runtime,äº‹ä»¶å¸¦ seq,è¡¥å‘å¯ç”¨', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't' });
    const registry = new RunRegistry();
    const runtimes = new Map<string, any>();
    attachWsGateway(app.server, {
      db, token: 't', registry,
      runtimeFor: (sessionId: string) => {
        const emitSink: ((e: ProtocolEvent) => void)[] = [];
        const rt = {
          emitSink,
          send: async (text: string) => {
            registry.push(sessionId, { kind: 'text', role: 'assistant', content: `echo:${text}` });
            registry.finish(sessionId, 0, false);
          },
          answerPermission: () => {},
          abort: async () => {},
        } as unknown as SessionRuntime & { emitSink: ((e: ProtocolEvent) => void)[] };
        runtimes.set(sessionId, rt);
        return rt;
      },
    });
    const port = await listen(app);

    // 1) æœªé‰´æƒ
    const bad = await wsConnect(port);
    bad.ws.send(JSON.stringify({ type: 'chat.send', sessionId: 'x', content: 'y' }));
    expect((await bad.next()).kind).toBe('error');
    bad.ws.close();

    // 2) é‰´æƒ + ä¼šè¯ + å‘æ¶ˆæ¯
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    expect((await next()).kind).toBe('authenticated');
    const s = createSession(db, { title: 'ws' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: 'ä½ å¥½' }));
    const e1 = await next();
    expect(e1).toMatchObject({ kind: 'text', content: 'echo:ä½ å¥½', seq: 1 });
    const e2 = await next();
    expect(e2).toMatchObject({ kind: 'complete', seq: 2 });

    // 3) é‡è¿žè¡¥å‘
    const { ws: ws2, next: next2 } = await wsConnect(port);
    ws2.send(JSON.stringify({ type: 'auth', token: 't' }));
    await next2();
    ws2.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: s.id, lastSeq: 0 }] }));
    const sub = await next2();
    expect(sub.kind).toBe('subscribed');
    const replay = await next2();
    expect(replay.kind).toBe('replay');
    expect(replay.events.length).toBe(2);
    ws.close(); ws2.close();
    await app.close();
  });
});
```

- [x] **Step 2: è·‘ â†’ FAIL**
- [x] **Step 3: å®žçŽ°** â€” `src/gateway/ws-gateway.ts`
```ts
import type { Server } from 'node:http';
import { WebSocketServer, type WebSocket } from 'ws';
import type { Db } from '../db.js';
import { appendMessage, updateSession, touchSession } from '../db.js';
import type { RunRegistry, OutboundEvent } from '../runs/run-registry.js';
import type { ProtocolEvent } from '../protocol/types.js';

type RuntimeLike = {
  send(text: string): Promise<void>;
  abort(): Promise<void>;
  answerPermission(requestId: string, decision: { allow: boolean; updatedInput?: unknown; message?: string }): void;
};

export type WsGatewayDeps = {
  db: Db;
  token: string;
  registry: RunRegistry;
  runtimeFor(appSessionId: string, opts: { cwd?: string; model?: string | null; permissionMode?: string }): RuntimeLike & { providerSessionId?: string | null };
};

const PERSIST_KINDS = new Set(['text', 'thinking', 'tool_use', 'tool_result', 'error']);

function send(ws: WebSocket, payload: unknown): void {
  if (ws.readyState === ws.OPEN) ws.send(JSON.stringify(payload));
}

export function attachWsGateway(server: Server, deps: WsGatewayDeps): void {
  const wss = new WebSocketServer({ server });
  const runtimes = new Map<string, RuntimeLike>();

  wss.on('connection', (ws: WebSocket & { authed?: boolean }) => {
    const offs = new Map<string, () => void>();

    const forward = (sessionId: string, event: OutboundEvent) => {
      // æŒä¹…åŒ–æ–‡æœ¬ç±»äº‹ä»¶;complete ç”± registry.finish å‘,ä¸è½ messages
      if (PERSIST_KINDS.has(event.kind)) {
        const kind = event.kind === 'text' ? 'text' : event.kind;
        appendMessage(deps.db, sessionId, {
          kind, role: (event as { role?: string }).role,
          content: event.kind === 'tool_use' ? JSON.stringify((event as never as { toolInput: unknown }).toolInput) : String((event as { content?: string }).content ?? ''),
          meta: event,
        });
      }
      if (event.kind === 'session_created') {
        updateSession(deps.db, sessionId, { providerSessionId: (event as { providerSessionId: string }).providerSessionId });
      }
      for (const client of wss.clients) {
        const c = client as WebSocket & { authed?: boolean; subs?: Set<string> };
        if (c.authed && c.subs?.has(sessionId)) send(c, { ...event, sessionId });
      }
    };

    ws.on('message', async (raw) => {
      let data: Record<string, unknown>;
      try { data = JSON.parse(String(raw)); } catch { return; }
      const type = data.type as string;

      if (type === 'auth') {
        ws.authed = data.token === deps.token;
        (ws as WebSocket & { subs?: Set<string> }).subs = new Set();
        send(ws, ws.authed ? { kind: 'authenticated' } : { kind: 'error', content: 'unauthorized' });
        if (!ws.authed) ws.close();
        return;
      }
      if (!ws.authed) { send(ws, { kind: 'error', content: 'unauthorized' }); ws.close(); return; }

      if (type === 'ping') { send(ws, { kind: 'pong' }); return; }

      if (type === 'chat.subscribe') {
        const subs = (ws as WebSocket & { subs?: Set<string> }).subs!;
        for (const entry of Array.isArray(data.sessions) ? data.sessions as { sessionId?: string; lastSeq?: number }[] : []) {
          if (!entry?.sessionId) continue;
          subs.add(entry.sessionId);
          const live = deps.registry.isRunning(entry.sessionId);
          send(ws, { kind: 'subscribed', sessionId: entry.sessionId, isProcessing: live, lastSeq: deps.registry.lastSeq(entry.sessionId) });
          const replayed = deps.registry.replay(entry.sessionId, entry.lastSeq ?? 0);
          if (replayed.length) send(ws, { kind: 'replay', sessionId: entry.sessionId, events: replayed });
          if (live && !offs.has(entry.sessionId)) {
            offs.set(entry.sessionId, deps.registry.subscribe(entry.sessionId, (e) => forward(entry.sessionId, e)));
          }
        }
        return;
      }

      if (type === 'chat.permission-response') {
        const runtime = runtimes.get(String(data.sessionId ?? ''));
        runtime?.answerPermission(String(data.requestId), { allow: Boolean(data.allow), updatedInput: data.updatedInput, message: typeof data.message === 'string' ? data.message : undefined });
        return;
      }

      if (type === 'chat.abort') {
        const sessionId = String(data.sessionId ?? '');
        const runtime = runtimes.get(sessionId);
        if (runtime) await runtime.abort();
        return;
      }

      if (type === 'chat.send') {
        const sessionId = String(data.sessionId ?? '');
        const content = typeof data.content === 'string' ? data.content : '';
        const options = (data.options ?? {}) as { model?: string; permissionMode?: string };
        if (!sessionId || !content) { send(ws, { kind: 'error', content: 'sessionId and content required' }); return; }
        if (deps.registry.isRunning(sessionId)) { send(ws, { kind: 'error', content: 'RUN_IN_PROGRESS', sessionId }); return; }
        if (options.model) updateSession(deps.db, sessionId, { model: options.model });
        if (options.permissionMode) updateSession(deps.db, sessionId, { permissionMode: options.permissionMode });

        let runtime = runtimes.get(sessionId);
        if (!runtime) {
          runtime = deps.runtimeFor(sessionId, { model: options.model, permissionMode: options.permissionMode });
          runtimes.set(sessionId, runtime);
        }
        deps.registry.begin(sessionId);
        if (!offs.has(sessionId)) offs.set(sessionId, deps.registry.subscribe(sessionId, (e) => forward(sessionId, e)));
        runtime.send(content).catch((error: unknown) => {
          send(ws, { kind: 'error', content: error instanceof Error ? error.message : String(error), sessionId });
        }).finally(() => {
          deps.registry.finish(sessionId, 0, false); // å¹‚ç­‰:runtime å·²å‘ complete æ—¶ç”± seq åŽ»é‡ç”±è°ƒç”¨æ–¹çº¦æŸ
          offs.get(sessionId)?.(); offs.delete(sessionId);
        });
        return;
      }
    });

    ws.on('close', () => { for (const off of offs.values()) off(); offs.clear(); });
  });
}
```
è¯´æ˜Ž:`runtimeFor` çš„çœŸå®žå®žçŽ°(åœ¨ index.ts)æ³¨å…¥ routes/db/emit æ¡¥;`registry.finish` é‡Œ emit çš„ `complete` äº‹ä»¶åŒæ ·èµ° forward(æ‰€ä»¥ runtime å·²å‘è¿‡ complete æ—¶ä¼šå‡ºçŽ°ä¸¤æ¡ â€”â€” ç”± Task 9 åœ¨ index ç»„è£…æ—¶ç”¨ã€Œruntime çš„ complete äº‹ä»¶ç›´æŽ¥é€ä¼ ,catch å…œåº•è¡¥å‘ã€çš„çº¦å®šç»Ÿä¸€;æµ‹è¯•ä¸­ stub runtime ä¸å‘ complete,ç”± finally å…œåº•)ã€‚

- [x] **Step 4: `npm run test` â†’ PASS;Commit** `feat(server): ws gateway with auth/replay/approval`

### Task 9: REST ç«¯ç‚¹ + index ç»„è£…

**Files:**
- Create: `src/http-routes.ts`, `src/index.ts`, `test/http-routes.test.ts`
- Modify: `src/http.ts`(æŒ‚è½½ REST + é™æ€å¥åº·)

- [x] **Step 1: å¤±è´¥æµ‹è¯•** â€” `test/http-routes.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';
import { openDb, createSession } from '../src/db.js';
import { loadRoutes } from '../src/routes.js';

const H = { authorization: 'Bearer t' };

describe('REST', () => {
  it('sessions CRUD + messages + models', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const created = await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: 'æµ‹è¯•' } });
    expect(created.statusCode).toBe(200);
    const id = created.json().id;
    const list = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    expect(list.json().length).toBe(1);
    const patched = await app.inject({ method: 'PATCH', url: `/api/sessions/${id}`, headers: H, payload: { isPinned: true } });
    expect(patched.json().is_pinned).toBe(1);
    const msgs = await app.inject({ method: 'GET', url: `/api/sessions/${id}/messages`, headers: H });
    expect(msgs.json()).toEqual({ messages: [], total: 0 });
    const models = await app.inject({ method: 'GET', url: '/api/models', headers: H });
    expect(models.json()).toEqual(['default']);
    const del = await app.inject({ method: 'DELETE', url: `/api/sessions/${id}`, headers: H });
    expect(del.statusCode).toBe(200);
    await app.close();
  });
});
```
- [x] **Step 2: è·‘ â†’ FAIL**
- [x] **Step 3: å®žçŽ°** â€” ä¿®æ”¹ `src/http.ts` æŽ¥å— `{ token, db?, routesPath? }` å¹¶è°ƒç”¨ `registerHttpRoutes(app, { db, routesPath })`;æ–°å»º `src/http-routes.ts`:
```ts
import type { FastifyInstance } from 'fastify';
import type { Db } from '../db.js';
import { createSession, listSessions, getSession, updateSession, deleteSession, listMessages } from '../db.js';
import { loadRoutes, listModels } from '../routes.js';

export function registerHttpRoutes(app: FastifyInstance, deps: { db: Db; routesPath: string }): void {
  app.get('/api/models', async () => listModels(loadRoutes(deps.routesPath)));
  app.get('/api/sessions', async () => listSessions(deps.db));
  app.post('/api/sessions', async (req) => {
    const body = (req.body ?? {}) as { title?: string; cwd?: string; model?: string };
    return createSession(deps.db, body);
  });
  app.get('/api/sessions/:id', async (req, reply) => {
    const row = getSession(deps.db, (req.params as { id: string }).id);
    if (!row) await reply.code(404).send({ error: 'not found' });
    return row;
  });
  app.patch('/api/sessions/:id', async (req, reply) => {
    const id = (req.params as { id: string }).id;
    const row = updateSession(deps.db, id, (req.body ?? {}) as never);
    if (!row) await reply.code(404).send({ error: 'not found' });
    return row;
  });
  app.delete('/api/sessions/:id', async (req) => {
    const ok = deleteSession(deps.db, (req.params as { id: string }).id);
    return { ok };
  });
  app.get('/api/sessions/:id/messages', async (req) => {
    const id = (req.params as { id: string }).id;
    const q = req.query as { limit?: string; offset?: string };
    return listMessages(deps.db, id, { limit: q.limit ? Number(q.limit) : undefined, offset: q.offset ? Number(q.offset) : undefined });
  });
}
```
- [x] **Step 4: `src/index.ts` ç»„è£…**
```ts
import { attachWsGateway } from './gateway/ws-gateway.js';
import { openDb } from './db.js';
import { loadOrCreateConfig } from './config.js';
import { buildApp } from './http.js';
import { registerHttpRoutes } from './http-routes.js';
import { loadRoutes, resolveModel } from './routes.js';
import { RunRegistry } from './runs/run-registry.js';
import { SessionRuntime } from './protocol/sdk-client.js';
import path from 'node:path';

const config = loadOrCreateConfig();
const db = openDb(path.join(config.dataDir, 'zcode.db'));
const registry = new RunRegistry();
const routes = loadRoutes(config.routesPath);
const runtimes = new Map<string, SessionRuntime>();

const app = await buildApp({ token: config.token, db, routesPath: config.routesPath });
registerHttpRoutes(app, { db, routesPath: config.routesPath });

attachWsGateway(app.server, {
  db,
  token: config.token,
  registry,
  runtimeFor(sessionId, opts) {
    let runtime = runtimes.get(sessionId);
    if (runtime) return runtime;
    const session = db.prepare('SELECT * FROM sessions WHERE id=?').get(sessionId) as { cwd: string | null; provider_session_id: string | null; model: string | null; permission_mode: string };
    const modelId = opts.model ?? session.model ?? 'default';
    const resolved = resolveModel(routes, modelId);
    runtime = new SessionRuntime({
      appSessionId: sessionId,
      providerSessionId: session.provider_session_id,
      cwd: session.cwd ?? process.cwd(),
      model: resolved ? undefined : modelId === 'default' ? undefined : modelId,
      permissionMode: opts.permissionMode ?? session.permission_mode,
      routeSettings: resolved?.settings ?? null,
      bgCeilingMs: config.bgCeilingMs,
      approvalTimeoutMs: config.approvalTimeoutMs,
      emit: (event) => registry.push(sessionId, event),
    });
    runtimes.set(sessionId, runtime);
    return runtime;
  },
});

console.log(`[zcode-server] listening on http://0.0.0.0:${config.port}`);
console.log(`[zcode-server] token: ${config.token}`);
await app.listen({ port: config.port, host: '0.0.0.0' });
```
- [x] **Step 5: `npm run test` å…¨ç»¿;`npx tsc --noEmit` å¹²å‡€;Commit** `feat(server): REST + composition root`

### Task 10: å†’çƒŸ(çœŸ CLI ä¸€è½®)

- [x] **Step 1: `npm start` å¯åŠ¨(ç•™åŽå°);è®°ä¸‹ token**
- [x] **Step 2: PowerShell å†’çƒŸ**:
```powershell
$H = @{ authorization = "Bearer <token>" }
$session = Invoke-RestMethod -Uri http://127.0.0.1:5190/api/sessions -Headers $H -Method Post -Body (@{title='smoke'; cwd='D:\cheng\zcode'} | ConvertTo-Json) -ContentType 'application/json'
$session.id
```
ç”¨ Node ä¸€æ¬¡æ€§ WS å®¢æˆ·ç«¯å‘ `chat.send`("åˆ—å‡ºå½“å‰ç›®å½•æ–‡ä»¶,ä¸€å¥è¯æ€»ç»“"),æ–­è¨€æ”¶åˆ° `model`/`text`/`complete` äº‹ä»¶ã€‚Ctrl-C åŽç¡®è®¤ `claude` å­è¿›ç¨‹é€€å‡ºã€‚
- [x] **Step 3: Commit** `test(server): smoke pass` + æ›´æ–° README(å¯åŠ¨æ–¹å¼/token ä½ç½®/åè®®è¡¨)

---

## éªŒè¯

1. `npm run test` å…¨ç»¿ + `npx tsc --noEmit` é›¶é”™è¯¯
2. Task 10 çœŸæœºå†’çƒŸ:PC ä¸Šå®Œæ•´ä¸€è½®å¯¹è¯ + usage æˆæœ¬äº‹ä»¶ + ä¸­æ­¢
3. åè®®ä¸Žå‰ç«¯å¯¹æŽ¥:Flutter ä¾§æŒ‰æœ¬è®¡åˆ’çš„ WS åè®®è¡¨å®žçŽ°(å¦ç«‹å‰ç«¯ plan)
