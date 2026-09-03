import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';
import { openDb, createSession } from '../src/db.js';

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
});
