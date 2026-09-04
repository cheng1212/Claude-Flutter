import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';
import { openDb, createSession, appendMessage, createRun, finishRun } from '../src/db.js';

const H = { authorization: 'Bearer t' };

describe('REST', () => {
  it('sessions CRUD + messages + models', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const created = await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: '测试' } });
    expect(created.statusCode).toBe(200);
    const id = (created.json() as { id: string }).id;
    expect(id).toBeTruthy();

    const list = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    expect((list.json() as unknown[]).length).toBe(1);

    const patched = await app.inject({ method: 'PATCH', url: `/api/sessions/${id}`, headers: H, payload: { isPinned: true } });
    expect((patched.json() as { is_pinned: number }).is_pinned).toBe(1);

    const single = await app.inject({ method: 'GET', url: `/api/sessions/${id}`, headers: H });
    expect((single.json() as { id: string }).id).toBe(id);
    const missing = await app.inject({ method: 'GET', url: '/api/sessions/nope', headers: H });
    expect(missing.statusCode).toBe(404);

    const msgs = await app.inject({ method: 'GET', url: `/api/sessions/${id}/messages`, headers: H });
    expect(msgs.json()).toEqual({ messages: [], total: 0 });

    const models = await app.inject({ method: 'GET', url: '/api/models', headers: H });
    expect(models.json()).toEqual(['default']); // 路由文件不存在 → 只有 default

    const del = await app.inject({ method: 'DELETE', url: `/api/sessions/${id}`, headers: H });
    expect((del.json() as { ok: boolean }).ok).toBe(true);
    await app.close();
  });

  it('sessions 列表带 isRunning:注入的 registry 查询决定"运行中"徽章', async () => {
    const db = openDb(':memory:');
    const live = new Set<string>();
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json', isRunning: (id) => live.has(id) });
    const s = createSession(db, { title: 'live' });

    const list1 = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    let rows = list1.json() as Array<{ id: string; isRunning: boolean }>;
    expect(rows.find((r) => r.id === s.id)?.isRunning).toBe(false);

    live.add(s.id); // 等价 registry.begin
    const list2 = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    rows = list2.json() as Array<{ id: string; isRunning: boolean }>;
    expect(rows.find((r) => r.id === s.id)?.isRunning).toBe(true);
    await app.close();
  });

  it('删除幂等 + batch-delete 一次删干净 + 回调收到被删 id', async () => {
    const db = openDb(':memory:');
    const deletedIds: string[] = [];
    const app = await buildApp({
      token: 't', db, routesPath: 'Z:/none.json',
      onSessionDeleted: (id) => deletedIds.push(id),
    });
    const a = createSession(db, { title: 'a' });
    const b = createSession(db, { title: 'b' });

    // 单删 → 再删同一个(已不存在)仍 200 {ok:true},不再 404
    const del1 = await app.inject({ method: 'DELETE', url: `/api/sessions/${a.id}`, headers: H });
    expect(del1.json()).toEqual({ ok: true });
    const del2 = await app.inject({ method: 'DELETE', url: `/api/sessions/${a.id}`, headers: H });
    expect(del2.statusCode).toBe(200);
    expect(del2.json()).toEqual({ ok: true });
    expect(deletedIds).toEqual([a.id]); // 只在真实删除时回调一次

    // 批量:b 存在 + 两个不存在的 id 混着删
    const batch = await app.inject({
      method: 'POST', url: '/api/sessions/batch-delete', headers: H,
      payload: { ids: [b.id, 'ghost-1', 'ghost-2'] },
    });
    expect(batch.json()).toEqual({ ok: true, deleted: 1, missing: ['ghost-1', 'ghost-2'] });
    expect(deletedIds).toEqual([a.id, b.id]);
    expect(db.prepare('SELECT COUNT(*) AS c FROM sessions').get()).toEqual({ c: 0 });
    await app.close();
  });

  it('GET /usage:聚合 runs 的 token/缓存 + 最近上下文快照 + 消息构成与工具排行', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const s = createSession(db, { title: 'usage' });
    const run = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, run.id, {
      status: 'success', totalCostUsd: 0.1,
      usage: {
        inputTokens: 100, outputTokens: 50, cacheReadInputTokens: 900, cacheCreationInputTokens: 10,
        totalCostUsd: 0.1, durationMs: 2000, numTurns: 4, contextWindow: 200000, maxOutputTokens: 8192,
      },
    });
    appendMessage(db, s.id, { kind: 'text', role: 'user', content: '12345' });
    appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: '1234567890' });
    appendMessage(db, s.id, { kind: 'tool_use', content: '{}', meta: { kind: 'tool_use', toolName: 'Bash', toolId: 't' } });
    appendMessage(db, s.id, { kind: 'tool_use', content: '{}', meta: { kind: 'tool_use', toolName: 'Bash', toolId: 't2' } });

    const res = await app.inject({ method: 'GET', url: `/api/sessions/${s.id}/usage`, headers: H });
    const u = res.json() as {
      runs: number;
      totals: Record<string, number>;
      last: { contextTokens: number; contextWindow: number } | null;
      composition: { kind: string; count: number; bytes: number }[];
      tools: { toolName: string; count: number }[];
    };
    expect(u.runs).toBe(1);
    expect(u.totals).toMatchObject({ inputTokens: 100, outputTokens: 50, cacheReadInputTokens: 900, cacheCreationInputTokens: 10, costUsd: 0.1, turns: 4 });
    expect(u.last).toMatchObject({ contextTokens: 1010, contextWindow: 200000 });
    expect(u.composition.find((c) => c.kind === 'text')).toMatchObject({ count: 2, bytes: 15 });
    expect(u.tools).toEqual([{ toolName: 'Bash', count: 2 }]);
    await app.close();
  });
});

describe('GET /download/:name', () => {
  it('免鉴权发送 publicDir 下的文件(APK 类型头 + attachment);不存在的/非法名 404', async () => {
    const db = openDb(':memory:');
    const publicDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-public-'));
    fs.writeFileSync(path.join(publicDir, 'zcode-latest.apk'), 'PKfake-apk');
    try {
      const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json', publicDir });

      // 无 Authorization 头也能拿到
      const ok = await app.inject({ method: 'GET', url: '/download/zcode-latest.apk' });
      expect(ok.statusCode).toBe(200);
      expect(ok.headers['content-type']).toBe('application/vnd.android.package-archive');
      expect(ok.headers['content-disposition']).toBe('attachment; filename="zcode-latest.apk"');
      expect(ok.body).toBe('PKfake-apk');

      // 非法名(路径穿越)与不存在文件都 404,不泄露盘上结构
      const evil = await app.inject({ method: 'GET', url: '/download/..%2Fconfig.json' });
      expect(evil.statusCode).toBe(404);
      const missing = await app.inject({ method: 'GET', url: '/download/nope.apk' });
      expect(missing.statusCode).toBe(404);

      await app.close();
    } finally {
      fs.rmSync(publicDir, { recursive: true, force: true });
    }
  });
});
