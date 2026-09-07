import { describe, expect, it } from 'vitest';
import { loadOrCreateConfig } from '../src/config.js';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

describe('config', () => {
  it('首次运行生成随机 token 并写盘;第二次读取同一个', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    const a = loadOrCreateConfig(dir);
    expect(a.token).not.toBe('123456');
    expect(a.token.length).toBeGreaterThanOrEqual(20);
    const b = loadOrCreateConfig(dir);
    expect(b.token).toBe(a.token);
    expect(b.port).toBe(5190);
    expect(b.routesPath.toLowerCase()).toContain('claude-routes.json');
    fs.rmSync(dir, { recursive: true, force: true });
  });
  it('显式弱令牌 123456 保留不升级(用户局域网自用明确要求)', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ token: '123456' }));
    const a = loadOrCreateConfig(dir);
    expect(a.token).toBe('123456');
    const b = loadOrCreateConfig(dir);
    expect(b.token).toBe('123456'); // 稳定,不会被偷偷换掉
    fs.rmSync(dir, { recursive: true, force: true });
  });
  it('环境变量 ZCODE_TOKEN 覆盖存储值', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-cfg-'));
    process.env.ZCODE_TOKEN = 'x';
    try {
      const c = loadOrCreateConfig(dir);
      expect(c.token).toBe('x');
    } finally {
      delete process.env.ZCODE_TOKEN;
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
