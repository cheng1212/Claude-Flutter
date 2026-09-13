import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';
import { openDb } from '../src/db.js';

const H = { authorization: 'Bearer t' };

describe('health + auth', () => {
  it('GET /api/health 返回 ok + 版本/运行信息(无需鉴权)', async () => {
    const app = await buildApp({ token: 't', runningCount: () => 2 });
    const res = await app.inject({ method: 'GET', url: '/api/health' });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { ok: boolean; version: string; uptimeSec: number; runningSessions: number };
    expect(body.ok).toBe(true);
    expect(typeof body.version).toBe('string');
    expect(body.version).not.toBe('unknown'); // npm 布局下必能读到
    expect(body.uptimeSec).toBeGreaterThanOrEqual(0);
    expect(body.runningSessions).toBe(2);
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

  it('CORS:带浏览器头,OPTIONS 预检 204 且不要求鉴权', async () => {
    const app = await buildApp({ token: 't' });
    const pre = await app.inject({ method: 'OPTIONS', url: '/api/sessions', headers: { origin: 'http://192.168.31.194:8090' } });
    expect(pre.statusCode).toBe(204);
    expect(pre.headers['access-control-allow-origin']).toBe('*');
    expect(pre.headers['access-control-allow-headers']).toContain('Authorization');

    const get = await app.inject({ method: 'GET', url: '/api/health', headers: { origin: 'http://192.168.31.194:8090' } });
    expect(get.headers['access-control-allow-origin']).toBe('*');
    await app.close();
  });
  it('web 静态托管:根路径/SPA 回退/资产 mime/穿越拒绝,且不遮 API', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-web-'));
    fs.writeFileSync(path.join(dir, 'index.html'), '<html>citrus</html>');
    fs.mkdirSync(path.join(dir, 'assets'));
    fs.writeFileSync(path.join(dir, 'assets', 'a.js'), 'console.log(1);');
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json', webDir: dir });

    const root = await app.inject({ method: 'GET', url: '/' });
    expect(root.statusCode).toBe(200);
    expect(root.body).toContain('citrus');
    expect(root.headers['content-type']).toContain('text/html');

    const js = await app.inject({ method: 'GET', url: '/assets/a.js' });
    expect(js.body).toBe('console.log(1);');
    expect(js.headers['content-type']).toContain('text/javascript');

    const spa = await app.inject({ method: 'GET', url: '/chat/some-id' });
    expect(spa.statusCode).toBe(200);
    expect(spa.body).toContain('citrus');

    const evil = await app.inject({ method: 'GET', url: '/..%2F..%2Fsecret.txt' });
    expect(evil.statusCode).toBe(404);

    const api = await app.inject({ method: 'GET', url: '/api/models', headers: H });
    expect(api.statusCode).toBe(200);
    await app.close();
  });
});
