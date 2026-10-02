import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';
import { openDb } from '../src/db.js';
import { createAuthThrottle } from '../src/auth-throttle.js';

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

  it('CORS:白名单回显(默认本机回环任意端口),OPTIONS 预检 204 且不要求鉴权;ZCODE_ALLOWED_ORIGINS 可覆盖', async () => {
    const app = await buildApp({ token: 't' });
    // 命中默认白名单(localhost):回显 origin
    const pre = await app.inject({ method: 'OPTIONS', url: '/api/sessions', headers: { origin: 'http://localhost:8090' } });
    expect(pre.statusCode).toBe(204);
    expect(pre.headers['access-control-allow-origin']).toBe('http://localhost:8090');
    expect(pre.headers['access-control-allow-headers']).toContain('Authorization');
    // 未命中(LAN IP):不给 ACAO,浏览器侧自行拦截 —— 唯一凭证是 Bearer 头,不再通配放大
    const lan = await app.inject({ method: 'GET', url: '/api/health', headers: { origin: 'http://192.168.31.194:8090' } });
    expect(lan.headers['access-control-allow-origin']).toBeUndefined();
    await app.close();

    process.env.ZCODE_ALLOWED_ORIGINS = 'http://192.168.31.194:8090';
    try {
      const app2 = await buildApp({ token: 't' });
      const ok = await app2.inject({ method: 'GET', url: '/api/health', headers: { origin: 'http://192.168.31.194:8090' } });
      expect(ok.headers['access-control-allow-origin']).toBe('http://192.168.31.194:8090');
      await app2.close();
    } finally {
      delete process.env.ZCODE_ALLOWED_ORIGINS;
    }

    process.env.ZCODE_ALLOWED_ORIGINS = '*';
    try {
      const app3 = await buildApp({ token: 't' });
      const any = await app3.inject({ method: 'GET', url: '/api/health', headers: { origin: 'http://evil.example' } });
      expect(any.headers['access-control-allow-origin']).toBe('http://evil.example'); // 显式恢复全放行
      await app3.close();
    } finally {
      delete process.env.ZCODE_ALLOWED_ORIGINS;
    }
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

  it('静态穿越回归:兄弟目录前缀(../web-evil/x)在旧检查下可读穿,归约+分隔符锚定后必须 404', async () => {
    const parent = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-webroot-'));
    const dir = path.join(parent, 'web');
    fs.mkdirSync(dir);
    fs.writeFileSync(path.join(dir, 'index.html'), '<html>c</html>');
    // 兄弟目录:名字以 webRoot 的目录名为前缀 —— 旧代码裸 startsWith(webRoot) 会误配放行(实测 200)
    const evil = path.join(parent, 'web-evil');
    fs.mkdirSync(evil);
    fs.writeFileSync(path.join(evil, 'secret.txt'), 'TOPSECRET');
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json', webDir: dir });
    const viaDotDot = await app.inject({ method: 'GET', url: '/..%2Fweb-evil%2Fsecret.txt' });
    expect(viaDotDot.statusCode).toBe(404);
    // 注:裸 /../ 变体无法经 inject 表达 —— light-my-request(与浏览器一样)会在请求前归一化 URL,
    // 到不了 handler;服务端 path.resolve 归约对绕过归一化的原始请求同样兜住(见 handler 注释)。
    // 反斜杠变体(win32 归约)同样拒绝
    const viaBs = await app.inject({ method: 'GET', url: '/..%5Cweb-evil%5Csecret.txt' });
    expect(viaBs.statusCode).toBe(404);
    // 畸形百分号编码:400 而不是 500
    const bad = await app.inject({ method: 'GET', url: '/%ZZ' });
    expect(bad.statusCode).toBe(400);
    await app.close();
  });

  it('鉴权失败限速:连续错 token 到阈值后 429(对的 token 也拒),成功则清零', async () => {
    const app = await buildApp({ token: 't', authThrottle: createAuthThrottle({ maxFails: 3 }) });
    for (let i = 0; i < 3; i++) {
      const r = await app.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer wrong' } });
      expect(r.statusCode).toBe(401);
    }
    const blocked = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    expect(blocked.statusCode).toBe(429); // 已封禁:对的 token 也暂时拒
    await app.close();

    // 正确 token 会清零计数:穿插成功不积累
    const app2 = await buildApp({ token: 't', authThrottle: createAuthThrottle({ maxFails: 3 }) });
    await app2.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer wrong' } });
    await app2.inject({ method: 'GET', url: '/api/sessions', headers: H }); // 成功清零
    await app2.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer wrong' } });
    await app2.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer wrong' } });
    const still = await app2.inject({ method: 'GET', url: '/api/sessions', headers: { authorization: 'Bearer wrong' } });
    expect(still.statusCode).toBe(401); // 只有 2 次连续失败,未到 3
    await app2.close();
  });

  it('health 暴露 weakToken:弱令牌 true,强令牌 false', async () => {
    const weak = await buildApp({ token: '123456' });
    const r1 = await weak.inject({ method: 'GET', url: '/api/health' });
    expect((r1.json() as { weakToken: boolean }).weakToken).toBe(true);
    await weak.close();
    const strong = await buildApp({ token: 'a'.repeat(32) });
    const r2 = await strong.inject({ method: 'GET', url: '/api/health' });
    expect((r2.json() as { weakToken: boolean }).weakToken).toBe(false);
    await strong.close();
  });
});
