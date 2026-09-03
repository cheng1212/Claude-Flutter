# zCode 后端 MVP 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一个 Node 后端,通过 @anthropic-ai/claude-agent-sdk 驱动真 claude CLI,对手机暴露 REST + WS(流式/审批/补发)。

**Architecture:** Fastify(HTTP)+ ws(同一端口 5190);SDK 包在自有 SessionRuntime 后面;每会话一个运行时;RunRegistry 做 seq 缓冲与补发;SQLite 持久化;模型路由只读复用 `~/litellm/claude-routes.json`。

**Tech Stack:** Node 20+ / TypeScript ESM / tsx / vitest / fastify@5 / ws@8 / better-sqlite3 / @anthropic-ai/claude-agent-sdk@^0.3.165

**工作目录:** `D:\cheng\zcode\server`(下文相对路径均基于此)

---

### Task 1: 脚手架 + 健康检查(TDD 起步)

**Files:**
- Create: `package.json`, `tsconfig.json`, `vitest.config.ts`, `src/http.ts`, `test/http.test.ts`

- [ ] **Step 1: 写 package.json / tsconfig / vitest 配置**

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

- [ ] **Step 2: 写失败测试** — `test/http.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';

describe('health', () => {
  it('GET /api/health 返回 ok(无需鉴权)', async () => {
    const app = await buildApp({ token: 't' });
    const res = await app.inject({ method: 'GET', url: '/api/health' });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toEqual({ ok: true });
    await app.close();
  });

  it('其余 /api 需要 Bearer token', async () => {
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

- [ ] **Step 3: 跑测试确认失败** — `npm run test` → FAIL (src/http.js 不存在)
- [ ] **Step 4: 最小实现** — `src/http.ts`
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
- [ ] **Step 5: `npm run test` → PASS;`npx tsc --noEmit` 干净**
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat(server): scaffold + health + bearer auth"`

### Task 2: 配置加载(首次生成 token)

**Files:**
- Create: `src/config.ts`, `test/config.test.ts`

- [ ] **Step 1: 失败测试** — `test/config.test.ts`
```ts
import { fs as memfs } from './helpers.js';
import { describe, expect, it } from 'vitest';
import { loadOrCreateConfig } from '../src/config.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

describe('config', () => {
  it('首次运行生成 token 并写盘;第二次读取同一个', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    const a = loadOrCreateConfig(dir);
    expect(a.token).toMatch(/^[0-9a-f-]{36}$/);
    const b = loadOrCreateConfig(dir);
    expect(b.token).toBe(a.token);
    expect(b.port).toBe(5190);
    fs.rmSync(dir, { recursive: true, force: true });
  });
  it('环境变量 ZCODE_TOKEN 覆盖', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    process.env.ZCODE_TOKEN = 'x';
    const c = loadOrCreateConfig(dir);
    expect(c.token).toBe('x');
    delete process.env.ZCODE_TOKEN;
    fs.rmSync(dir, { recursive: true, force: true });
  });
});
```
- [ ] **Step 2: 跑 → FAIL**
- [ ] **Step 3: 实现** — `src/config.ts`
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
- [ ] **Step 4: `npm run test` → PASS;Commit** `feat(server): config loader`

### Task 3: SQLite 三表 + repo

**Files:**
- Create: `src/db.ts`, `test/db.test.ts`

- [ ] **Step 1: 失败测试** — `test/db.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { openDb, createSession, getSession, listSessions, updateSession, deleteSession, appendMessage, listMessages, createRun, finishRun } from '../src/db.js';

describe('db', () => {
  it('会话 CRUD + 置顶排序', () => {
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
  it('消息 seq 按会话递增;历史分页', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'x' });
    for (let i = 0; i < 25; i++) appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: `m${i}` });
    const page = listMessages(db, s.id, { limit: 10, offset: 0 });
    expect(page.total).toBe(25);
    expect(page.messages.length).toBe(10);
    expect(page.messages[0].seq).toBe(25); // 最新在前
    const tail = listMessages(db, s.id, { limit: 10, offset: 20 });
    expect(tail.messages[0].seq).toBe(5);
  });
  it('run 记录成本与用量', () => {
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
- [ ] **Step 2: 跑 → FAIL**
- [ ] **Step 3: 实现** — `src/db.ts`
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
    .run(id, input.title?.trim() || '新会话', input.cwd ?? null, input.model ?? null, ts, ts);
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
- [ ] **Step 4: `npm run test` → PASS;Commit** `feat(server): sqlite schema + repo`

### Task 4: 模型路由(读 claude-routes.json)

**Files:**
- Create: `src/routes.ts`, `test/routes.test.ts`

- [ ] **Step 1: 失败测试** — `test/routes.test.ts`
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
  it('显式路由 → settings + env', () => {
    const r = resolveModel(fixture as never, 'glm-5.3-flash');
    expect(r?.settings?.env.ANTHROPIC_BASE_URL).toBe('https://open.bigmodel.cn/api/anthropic');
    expect(r?.upstreamModel).toBe('glm-5.3-flash');
  });
  it('default / 未知模型 → 无路由(CLI 用自己的端点)', () => {
    expect(resolveModel(fixture as never, 'default')).toBeNull();
    expect(resolveModel(fixture as never, undefined)).toBeNull();
  });
  it('listModels = default + 显式 keys(不含 defaultRoute 隐式)', () => {
    expect(listModels(fixture as never)).toEqual(['default', 'glm-5.3-flash']);
  });
  it('文件缺失/坏 JSON → 空路由不崩', () => {
    expect(loadRoutes('Z:/nope/nope.json')).toBeNull();
    expect(listModels(null)).toEqual(['default']);
  });
});
```
- [ ] **Step 2: 跑 → FAIL**
- [ ] **Step 3: 实现** — `src/routes.ts`
```ts
import fs from 'node:fs';

export type RouteEntry = { baseUrl?: string; authToken?: string; model?: string };
export type RouteConfig = { defaultRoute?: RouteEntry; routes?: Record<string, RouteEntry> };
export type ResolvedModel = { id: string; upstreamModel: string; settings: { env: { ANTHROPIC_BASE_URL: string; ANTHROPIC_AUTH_TOKEN: string }; model: string } | null };

export function loadRoutes(path: string): RouteConfig | null {
  try { return JSON.parse(fs.readFileSync(path, 'utf8')) as RouteConfig; } catch { return null; }
}

// 语义与 cloudcli 一致:只有显式列出的自定义模型才注入路由;
// default/未列出 → null,CLI 用自己配置的端点,防止 defaultRoute 劫持官方模型。
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
- [ ] **Step 4: `npm run test` → PASS;Commit** `feat(server): model routes loader`

### Task 5: 协议类型 + SDK 消息转换(纯函数,TDD 主战场)

**Files:**
- Create: `src/protocol/types.ts`, `src/protocol/transform.ts`, `test/transform.test.ts`

- [ ] **Step 1: 类型** — `src/protocol/types.ts`
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

/** 后台保活判定:这些工具会把工作留到 result 之后。 */
export const DEFERRED_WORK_TOOLS = new Set(['Monitor', 'ScheduleWakeup', 'CronCreate', 'TaskCreate']);
export function startsBackgroundWork(events: ProtocolEvent[]): boolean {
  return events.some((e) => {
    if (e.kind !== 'tool_use') return false;
    if (e.toolName === 'Bash') return (e.toolInput as { run_in_background?: boolean } | null)?.run_in_background === true;
    return DEFERRED_WORK_TOOLS.has(e.toolName);
  });
}
```
- [ ] **Step 2: 失败测试** — `test/transform.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { transformMessage } from '../src/protocol/transform.js';

describe('transformMessage', () => {
  it('assistant 三种 block → text/thinking/tool_use', () => {
    const out = transformMessage({
      type: 'assistant', session_id: 's1',
      message: { role: 'assistant', content: [
        { type: 'thinking', thinking: '想一下' },
        { type: 'text', text: '你好' },
        { type: 'tool_use', id: 't1', name: 'Read', input: { file_path: 'a.ts' } },
      ] },
    });
    expect(out).toEqual([
      { kind: 'thinking', content: '想一下' },
      { kind: 'text', role: 'assistant', content: '你好' },
      { kind: 'tool_use', toolId: 't1', toolName: 'Read', toolInput: { file_path: 'a.ts' } },
    ]);
  });
  it('user tool_result → tool_result(is_error 透传)', () => {
    const out = transformMessage({
      type: 'user', session_id: 's1',
      message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'file body', is_error: true }] },
    });
    expect(out).toEqual([{ kind: 'tool_result', toolId: 't1', content: 'file body', isError: true }]);
  });
  it('stream_event 文本/思考增量', () => {
    const text = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: '早' } } });
    const think = transformMessage({ type: 'stream_event', session_id: 's', event: { type: 'content_block_delta', delta: { type: 'thinking_delta', thinking: '嗯' } } });
    expect(text).toEqual([{ kind: 'stream_delta', content: '早' }]);
    expect(think).toEqual([{ kind: 'thinking_delta', content: '嗯' }]);
  });
  it('result success → usage + complete(0)', () => {
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
  it('result error_max_turns → error + complete(1)', () => {
    const out = transformMessage({ type: 'result', subtype: 'error_max_turns', session_id: 's', errors: ['too many turns'] });
    expect(out[0]).toEqual({ kind: 'error', content: 'too many turns' });
    expect(out[1]).toEqual({ kind: 'complete', exitCode: 1, aborted: false });
  });
  it('init/未知 → 空', () => {
    expect(transformMessage({ type: 'system', subtype: 'init', session_id: 's' })).toEqual([]);
    expect(transformMessage({ type: 'keep_alive' } as never)).toEqual([]);
  });
});
```
- [ ] **Step 3: 跑 → FAIL**
- [ ] **Step 4: 实现** — `src/protocol/transform.ts`
```ts
import type { ProtocolEvent } from './types.js';

type AnyRecord = Record<string, unknown>;

// SDK 消息 → 内部事件的唯一映射点。纯函数,便于对拍 SDK 升级。
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
- [ ] **Step 5: `npm run test` → PASS;Commit** `feat(server): protocol events + sdk transform`

### Task 6: RunRegistry(seq 单调、环形缓冲、补发、订阅)

**Files:**
- Create: `src/runs/run-registry.ts`, `test/run-registry.test.ts`

- [ ] **Step 1: 失败测试** — `test/run-registry.test.ts`
```ts
import { describe, expect, it } from 'vitest';
import { RunRegistry } from '../src/runs/run-registry.js';

describe('RunRegistry', () => {
  it('seq 按会话单调递增,跨 run 不清零', () => {
    const reg = new RunRegistry();
    reg.begin('s1');
    expect(reg.push('s1', { kind: 'text', role: 'assistant', content: 'a' }).seq).toBe(1);
    reg.finish('s1', 0, false);
    reg.begin('s1');
    expect(reg.push('s1', { kind: 'text', role: 'assistant', content: 'b' }).seq).toBe(2);
  });
  it('replay(afterSeq) 只回缺的;live 订阅收到新事件', () => {
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
    expect(seen).toEqual(['3']); // 退订后不再收
    expect(reg.replay('s', 1).map((e) => (e as { content: string }).content)).toEqual(['2', '3', '4']);
    expect(reg.lastSeq('s')).toBe(4);
  });
  it('缓冲封顶 1000,重放不越界', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    for (let i = 0; i < 1100; i++) reg.push('s', { kind: 'stream_delta', content: 'x' });
    expect(reg.replay('s', 0).length).toBe(1000);
    expect(reg.lastSeq('s')).toBe(1100);
  });
  it('isRunning:begin→true,finish→false', () => {
    const reg = new RunRegistry();
    reg.begin('s');
    expect(reg.isRunning('s')).toBe(true);
    reg.finish('s', 0, false);
    expect(reg.isRunning('s')).toBe(false);
  });
});
```
- [ ] **Step 2: 跑 → FAIL**
- [ ] **Step 3: 实现** — `src/runs/run-registry.ts`
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
- [ ] **Step 4: `npm run test` → PASS;Commit** `feat(server): run registry with seq replay`

### Task 7: SessionRuntime(SDK 包装:审批桥、后台保活、中断)

**Files:**
- Create: `src/protocol/sdk-client.ts`, `src/protocol/cli-path.ts`, `test/sdk-client.test.ts`

- [ ] **Step 1: cli-path(Windows 解析,参考 cloudcli 思路重写)** — `src/protocol/cli-path.ts`
```ts
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// raw spawn 不跟 .cmd wrapper:把 "claude" 解析成真 exe。
export function resolveClaudeExecutable(configured?: string): string {
  const value = (configured ?? process.env.CLAUDE_CLI_PATH ?? 'claude').trim().replace(/^["']|["']$/g, '');
  if (process.platform !== 'win32') return value;
  if (/\.(exe|cjs|js|mjs)$/i.test(value) && (value.includes('/') || value.includes('\\'))) return value;
  try {
    const out = execFileSync('where.exe', [value], { encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'] });
    const candidates = out.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const exe = candidates.find((c) => c.toLowerCase().endsWith('.exe'));
    if (exe) return exe;
    // npm wrapper(.cmd):读内容找 claude.exe 真身
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
  } catch { /* where 失败,交由 SDK 报错 */ }
  return value;
}
```

- [ ] **Step 2: 失败测试** — `test/sdk-client.test.ts`
```ts
import { describe, expect, it, vi } from 'vitest';
import { SessionRuntime } from '../src/protocol/sdk-client.js';
import type { ProtocolEvent } from '../src/protocol/types.js';

// fake query:接收 prompt(异步迭代器)+ options,按脚本吐 SDK 消息。
function fakeQuery(script: Array<Record<string, unknown>>, opts?: {
  onUserMessage?: (m: unknown) => void;
  hangAfterScript?: boolean;
}) {
  return (args: { prompt: AsyncIterable<unknown>; options: Record<string, unknown> }) => {
    expect(args.options.canUseTool).toBeTypeOf('function');
    return (async function* () {
      for (const item of script) yield item;
      if (opts?.hangAfterScript) {
        await new Promise(() => {}); // 模拟保活中的 CLI
      }
    })();
  };
}

const baseOpts = { cwd: 'C:/tmp', dataDir: undefined as string | undefined };

describe('SessionRuntime', () => {
  it('一轮完整对话:发消息 → 收事件 → 完成后释放输入流', async () => {
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
            { type: 'assistant', session_id: 'prov-1', message: { role: 'assistant', content: [{ type: 'text', text: '你好' }] } },
            { type: 'result', subtype: 'success', session_id: 'prov-1', usage: { input_tokens: 3, output_tokens: 2 }, total_cost_usd: 0.01, duration_ms: 9 },
          ]) yield item;
          released = true; // generator 结束 == stdin 释放
        })();
      },
    });
    await runtime.send('hi');
    const kinds = emit.mock.calls.map((c) => (c[0] as ProtocolEvent).kind);
    expect(kinds).toEqual(['session_created', 'text', 'usage', 'complete']);
    expect(released).toBe(true);
  });

  it('canUseTool → permission_request;answerPermission(allow) 后继续', async () => {
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

  it('后台工作:Bash run_in_background 后 result 到了也不释放,下一轮 supersede 释放旧流', async () => {
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
    // result 已到(客户端已收 complete),但流还挂着
    expect(emit.mock.calls.some((c) => (c[0] as ProtocolEvent).kind === 'complete')).toBe(true);
    await runtime.send('next turn'); // 新一轮取代旧 held 流
    expect(releases.length).toBe(1);
  });

  it('abort → complete(aborted:true) 且不再发 error', async () => {
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

- [ ] **Step 3: 跑 → FAIL**
- [ ] **Step 4: 实现** — `src/protocol/sdk-client.ts`
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

/** 一个 app 会话一个实例:串行跑 turn,桥接审批,按需保活。 */
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

  /** 新 turn:取代任何 held 流,串行排队。 */
  async send(text: string): Promise<void> {
    if (this.running) {
      return new Promise((resolve, reject) => { this.queued.push(text); /* 简化:同一会话 WS 层已挡并发 */ resolve(); reject = reject; });
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
    // SDK 0.2.113+ env 是替换:必须带全 process.env;路由时双带端点并删掉干扰 key。
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
            // 后台任务收尾的第二个 result:事件照发,流不再保
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
    // 中断挂起审批,避免 turn 卡死
    for (const resolve of this.pending.values()) resolve({ allow: false, message: 'aborted' });
    this.pending.clear();
    this.release?.();
  }
}
```

注意:测试里 fake 的 `options.__onRelease` 是探针;真实实现里 release 通过 held promise 关闭 generator,`finally` 里的 `release()` 保证 wind-down。超时/交互工具的 pending 解析在 finally 不重复 resolve(Map 已 clear)。

- [ ] **Step 5: `npm run test` → PASS(允许对实现做等价微调,但四个行为断言不能丢);Commit** `feat(server): session runtime over sdk`

### Task 8: WS 网关(auth/四消息/补发/审批回路)

**Files:**
- Create: `src/gateway/ws-gateway.ts`, `test/ws-gateway.test.ts`

- [ ] **Step 1: 失败测试** — `test/ws-gateway.test.ts`
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
  it('未 auth 收 error 并关闭;auth 后 chat.send 走 stub runtime,事件带 seq,补发可用', async () => {
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

    // 1) 未鉴权
    const bad = await wsConnect(port);
    bad.ws.send(JSON.stringify({ type: 'chat.send', sessionId: 'x', content: 'y' }));
    expect((await bad.next()).kind).toBe('error');
    bad.ws.close();

    // 2) 鉴权 + 会话 + 发消息
    const { ws, next } = await wsConnect(port);
    ws.send(JSON.stringify({ type: 'auth', token: 't' }));
    expect((await next()).kind).toBe('authenticated');
    const s = createSession(db, { title: 'ws' });
    ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '你好' }));
    const e1 = await next();
    expect(e1).toMatchObject({ kind: 'text', content: 'echo:你好', seq: 1 });
    const e2 = await next();
    expect(e2).toMatchObject({ kind: 'complete', seq: 2 });

    // 3) 重连补发
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

- [ ] **Step 2: 跑 → FAIL**
- [ ] **Step 3: 实现** — `src/gateway/ws-gateway.ts`
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
      // 持久化文本类事件;complete 由 registry.finish 发,不落 messages
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
          deps.registry.finish(sessionId, 0, false); // 幂等:runtime 已发 complete 时由 seq 去重由调用方约束
          offs.get(sessionId)?.(); offs.delete(sessionId);
        });
        return;
      }
    });

    ws.on('close', () => { for (const off of offs.values()) off(); offs.clear(); });
  });
}
```
说明:`runtimeFor` 的真实实现(在 index.ts)注入 routes/db/emit 桥;`registry.finish` 里 emit 的 `complete` 事件同样走 forward(所以 runtime 已发过 complete 时会出现两条 —— 由 Task 9 在 index 组装时用「runtime 的 complete 事件直接透传,catch 兜底补发」的约定统一;测试中 stub runtime 不发 complete,由 finally 兜底)。

- [ ] **Step 4: `npm run test` → PASS;Commit** `feat(server): ws gateway with auth/replay/approval`

### Task 9: REST 端点 + index 组装

**Files:**
- Create: `src/http-routes.ts`, `src/index.ts`, `test/http-routes.test.ts`
- Modify: `src/http.ts`(挂载 REST + 静态健康)

- [ ] **Step 1: 失败测试** — `test/http-routes.test.ts`
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
    const created = await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: '测试' } });
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
- [ ] **Step 2: 跑 → FAIL**
- [ ] **Step 3: 实现** — 修改 `src/http.ts` 接受 `{ token, db?, routesPath? }` 并调用 `registerHttpRoutes(app, { db, routesPath })`;新建 `src/http-routes.ts`:
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
- [ ] **Step 4: `src/index.ts` 组装**
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
- [ ] **Step 5: `npm run test` 全绿;`npx tsc --noEmit` 干净;Commit** `feat(server): REST + composition root`

### Task 10: 冒烟(真 CLI 一轮)

- [ ] **Step 1: `npm start` 启动(留后台);记下 token**
- [ ] **Step 2: PowerShell 冒烟**:
```powershell
$H = @{ authorization = "Bearer <token>" }
$session = Invoke-RestMethod -Uri http://127.0.0.1:5190/api/sessions -Headers $H -Method Post -Body (@{title='smoke'; cwd='D:\cheng\zcode'} | ConvertTo-Json) -ContentType 'application/json'
$session.id
```
用 Node 一次性 WS 客户端发 `chat.send`("列出当前目录文件,一句话总结"),断言收到 `model`/`text`/`complete` 事件。Ctrl-C 后确认 `claude` 子进程退出。
- [ ] **Step 3: Commit** `test(server): smoke pass` + 更新 README(启动方式/token 位置/协议表)

---

## 验证

1. `npm run test` 全绿 + `npx tsc --noEmit` 零错误
2. Task 10 真机冒烟:PC 上完整一轮对话 + usage 成本事件 + 中止
3. 协议与前端对接:Flutter 侧按本计划的 WS 协议表实现(另立前端 plan)
