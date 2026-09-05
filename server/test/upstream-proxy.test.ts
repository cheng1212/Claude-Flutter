import fs from 'node:fs';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import path from 'node:path';
import os from 'node:os';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { resolveRelay, startUpstreamProxy } from '../src/proxy/upstream-proxy.js';

// 模拟上游:断言收到的鉴权/路径/模型名,流式吐 3 段 SSE(带间隔,验证不缓冲)
let seen: { auth: string | undefined; xapi: string | undefined; url: string; model: string } | null = null;
const upstream = http.createServer((req, res) => {
  const chunks: Buffer[] = [];
  req.on('data', (c) => chunks.push(c as Buffer));
  req.on('end', () => {
    seen = {
      auth: req.headers.authorization as string | undefined,
      xapi: req.headers['x-api-key'] as string | undefined,
      url: req.url ?? '',
      model: (JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}') as { model?: string }).model ?? '',
    };
    res.writeHead(200, { 'content-type': 'text/event-stream' });
    res.write('event: message_start\ndata: {"a":1}\n\n');
    setTimeout(() => res.write('event: content_block_delta\ndata: {"b":2}\n\n'), 30);
    setTimeout(() => { res.end('event: message_stop\ndata: {"c":3}\n\n'); }, 60);
  });
});

let routesPath = '';
let proxyPort = 0;
const proxies: http.Server[] = [];

// startUpstreamProxy 内部已经 listen,这里只等绑定完成,绝不能再 listen 一次
async function waitListening(s: http.Server): Promise<number> {
  if (!((s.address() as AddressInfo | null)?.port)) {
    await new Promise<void>((resolve) => s.once('listening', () => resolve()));
  }
  return (s.address() as AddressInfo).port;
}

beforeAll(async () => {
  await new Promise<void>((resolve) => upstream.listen(0, '127.0.0.1', resolve));
  const upstreamPort = (upstream.address() as AddressInfo).port;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'zrelay-'));
  routesPath = path.join(dir, 'routes.json');
  fs.writeFileSync(routesPath, JSON.stringify({
    routes: {
      'glm-test': { baseUrl: `http://127.0.0.1:${upstreamPort}`, authToken: 'tok-target', model: 'glm-test' },
      // 目标带路径前缀(智谱真实形态 /api/anthropic):new URL 丢前缀回归
      'glm-prefixed': {
        baseUrl: `http://127.0.0.1:${upstreamPort}/anthropic-compat`, authToken: 'tok-target', model: 'glm-test',
      },
      'zcode-prefixed': {
        baseUrl: 'http://127.0.0.1:1', authToken: 'local-only', model: 'prefixed-model', relayTo: 'glm-prefixed',
      },
      // relay 条目:model 名与目标不同,验证转发时改写
      'zcode-relay-test': {
        baseUrl: 'http://127.0.0.1:1', authToken: 'local-only', model: 'glm-test', relayTo: 'glm-test',
      },
      'zcode-alias': {
        baseUrl: 'http://127.0.0.1:1', authToken: 'local-only', model: 'alias-name', relayTo: 'glm-test',
      },
    },
  }));
  const proxy = startUpstreamProxy({ port: 0, routesPath });
  proxyPort = await waitListening(proxy);
  proxies.push(proxy);
});

afterAll(() => {
  for (const p of proxies) p.close();
  upstream.close();
});

const post = (body: Record<string, unknown>, url = '/v1/messages') =>
  fetch(`http://127.0.0.1:${proxyPort}${url}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: 'Bearer from-cli', 'x-api-key': 'from-cli' },
    body: JSON.stringify(body),
  });

describe('upstream relay proxy', () => {
  it('healthz / 非 POST 拒绝', async () => {
    const health = await fetch(`http://127.0.0.1:${proxyPort}/healthz`);
    expect(health.status).toBe(200);
    const get = await fetch(`http://127.0.0.1:${proxyPort}/v1/messages`);
    expect(get.status).toBe(405);
  });

  it('SSE 端到端透传 + 鉴权换目标 token + 计时事件齐全', async () => {
    const onStatus = vi.fn();
    const p2 = startUpstreamProxy({ port: 0, routesPath, onStatus });
    proxies.push(p2);
    const port = await waitListening(p2);

    const res = await fetch(`http://127.0.0.1:${port}/v1/messages`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', authorization: 'Bearer from-cli' },
      body: JSON.stringify({ model: 'glm-test', messages: [] }),
    });
    expect(res.status).toBe(200);
    expect(res.headers.get('content-type')).toContain('text/event-stream');
    const text = await res.text();
    expect(text).toContain('message_start');
    expect(text).toContain('content_block_delta');
    expect(text).toContain('message_stop');

    expect(seen).not.toBeNull();
    expect(seen!.xapi).toBe('tok-target');
    expect(seen!.auth).toBe('Bearer tok-target'); // CLI 的旧鉴权被换掉
    expect(seen!.url).toBe('/v1/messages');

    const phases = onStatus.mock.calls.map((c) => (c[0] as { phase: string }).phase);
    expect(phases).toEqual(['request', 'first_byte', 'done']);
    const done = onStatus.mock.calls[2][0] as { ms: number };
    expect(done.ms).toBeGreaterThanOrEqual(0);
  });

  it('relay 条目 model 名与目标不同 → 转发时改写请求体', async () => {
    const res = await post({ model: 'alias-name', messages: [] });
    expect(res.status).toBe(200);
    await res.text();
    expect(seen!.model).toBe('glm-test');
  });

  it('baseUrl 带路径前缀 → 上游收到 前缀+原路径+query(曾整个丢成根路径 405)', async () => {
    const res = await post({ model: 'prefixed-model', messages: [] }, '/v1/messages?beta=true');
    expect(res.status).toBe(200);
    await res.text();
    expect(seen!.url).toBe('/anthropic-compat/v1/messages?beta=true');
  });

  it('无 relay 目标的模型 → 502,不发 request 成功链路事件', async () => {
    const res = await post({ model: 'unknown-model', messages: [] });
    expect(res.status).toBe(502);
    // 不用 res.json():vitest 环境里它对 502 响应给 {},text + parse 才稳
    const raw = await res.text();
    expect(JSON.parse(raw).error.message).toContain('unknown-model');
  });

  it('resolveRelay:直连条目(无 relayTo)不会被误当中转', () => {
    const config = {
      routes: {
        direct: { baseUrl: 'https://a', model: 'same-model' },
        relay: { baseUrl: 'http://127.0.0.1:1', model: 'same-model', relayTo: 'direct' },
      },
    };
    const found = resolveRelay(config as never, 'same-model');
    expect(found?.relay.relayTo).toBe('direct');
    expect(resolveRelay(config as never, 'nope')).toBeNull();
  });
});
