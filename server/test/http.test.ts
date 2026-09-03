import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';

describe('health + auth', () => {
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
    // 404 = 已通过鉴权闸门到达路由层(路由本身在后续任务实现)
    expect(ok.statusCode).toBe(404);
    await app.close();
  });
});
