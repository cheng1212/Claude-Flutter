import { describe, test, expect, vi } from 'vitest';
import { ZApi, ApiError, type FetchFn } from './api';

function okJson(body: unknown): FetchFn {
  return vi.fn(async () => new Response(JSON.stringify(body), { status: 200 }));
}

describe('ZApi', () => {
  test('sends Bearer token and correct path for models()', async () => {
    const f = okJson(['default', 'glm-5.3-flash']);
    const api = new ZApi('http://192.168.1.5:5190', 'tok-1', f);
    const models = await api.models();
    expect(models).toEqual(['default', 'glm-5.3-flash']);
    const call = (f as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit];
    expect(call[0]).toBe('http://192.168.1.5:5190/api/models');
    expect((call[1].headers as Record<string, string>).Authorization).toBe('Bearer tok-1');
  });

  test('modelGroups unwraps res.groups', async () => {
    const f = okJson({ groups: [{ id: 'zhipu', label: '智谱 GLM', models: [{ id: 'glm-5.3-flash', label: 'GLM 5.3 Flash' }] }] });
    const api = new ZApi('http://x:5190', 't', f);
    const groups = await api.modelGroups();
    expect(groups[0].models[0].id).toBe('glm-5.3-flash');
  });

  test('sessions normalizes snake_case to camelCase', async () => {
    const f = okJson([{
      id: 's1', title: '会话', cwd: null, model: 'glm-5.3-flash',
      permission_mode: 'default', is_pinned: 1, source: 'local',
      created_at: '2026-09-05T00:00:00Z', updated_at: '2026-09-05T01:00:00Z', isRunning: false,
    }]);
    const api = new ZApi('http://x:5190', 't', f);
    const rows = await api.sessions();
    expect(rows[0]).toMatchObject({ permissionMode: 'default', isPinned: 1, updatedAt: '2026-09-05T01:00:00Z' });
  });

  test('createSession omits null keys from body', async () => {
    const f = okJson({ id: 's2' });
    const api = new ZApi('http://x:5190', 't', f);
    await api.createSession({ title: undefined, model: 'glm-5.3-flash' });
    const call = (f as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit];
    expect(call[0]).toBe('http://x:5190/api/sessions');
    expect(JSON.parse(call[1].body as string)).toEqual({ model: 'glm-5.3-flash' });
  });

  test('deleteSessions posts batch-delete and parses result', async () => {
    const f = okJson({ ok: true, deleted: 1, missing: ['gone'] });
    const api = new ZApi('http://x:5190', 't', f);
    const r = await api.deleteSessions(['a', 'gone']);
    expect(r).toEqual({ deleted: 1, missing: ['gone'] });
    const call = (f as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit];
    expect(call[0]).toBe('http://x:5190/api/sessions/batch-delete');
    expect(JSON.parse(call[1].body as string)).toEqual({ ids: ['a', 'gone'] });
  });

  test('messages returns rows and total', async () => {
    const f = okJson({ messages: [{ id: 'm1', seq: 1, kind: 'text', meta: '{}' }], total: 1 });
    const api = new ZApi('http://x:5190', 't', f);
    const r = await api.messages('s1', 200);
    expect(r.total).toBe(1);
    expect(r.messages[0].seq).toBe(1);
    const call = (f as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit];
    expect(call[0]).toBe('http://x:5190/api/sessions/s1/messages?limit=200');
  });

  test('non-2xx throws ApiError with status and body', async () => {
    const f = vi.fn(async () => new Response('{"error":"unauthorized"}', { status: 401 }));
    const api = new ZApi('http://x:5190', 'bad', f);
    const err = await api.sessions().catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect((err as ApiError).status).toBe(401);
    expect((err as ApiError).message).toContain('unauthorized');
  });

  test('network failure wraps into ApiError without status', async () => {
    const f = vi.fn(async () => { throw new TypeError('fetch failed'); });
    const api = new ZApi('http://x:5190', 't', f);
    await expect(api.sessions()).rejects.toBeInstanceOf(ApiError);
  });
});

describe('ZApi · 默认 fetch 绑定(Ilegal invocation 防御)', () => {
  test('uses globalThis-bound fetch when no fetchImpl injected', async () => {
    const real = globalThis.fetch;
    let receivedThis: unknown = 'unset';
    globalThis.fetch = function (this: unknown) {
      receivedThis = this;
      return Promise.resolve(new Response(JSON.stringify(['default'])));
    } as typeof fetch;
    try {
      const api = new ZApi('http://x:5190', 't'); // 不注入 fetchImpl
      const models = await api.models();
      expect(models).toEqual(['default']);
      expect(receivedThis === undefined || receivedThis === globalThis).toBe(true);
    } finally {
      globalThis.fetch = real;
    }
  });
  test('uploadFile chunks base64 correctly and reports progress', async () => {
    // 800KB → 768KB + 32KB 两块;3 字节对齐保证拼接 == 整体编码
    const bytes = Uint8Array.from({ length: 800 * 1024 }, (_, i) => i % 251);
    const f = okJson({ ok: true, path: 'D:/proj/uploads/a.bin', fileName: 'a.bin' });
    const api = new ZApi('http://x:5190', 't', f);
    const seen: number[] = [];
    const res = await api.uploadFile('s1', 'a.bin', bytes, (p) => seen.push(p));
    expect(res.path).toBe('D:/proj/uploads/a.bin');
    const call = (f as ReturnType<typeof vi.fn>).mock.calls[0] as [string, RequestInit];
    expect(call[0]).toBe('http://x:5190/api/sessions/s1/files');
    const body = JSON.parse(String(call[1].body)) as { fileName: string; dataB64: string };
    expect(body.fileName).toBe('a.bin');
    let raw = '';
    const step = 0x8000;
    for (let i = 0; i < bytes.length; i += step) {
      raw += String.fromCharCode(...bytes.subarray(i, i + step));
    }
    expect(body.dataB64).toBe(btoa(raw)); // 分块拼接必须与整体编码完全一致
    expect(seen[0]).toBeGreaterThan(0);
    expect(seen[seen.length - 1]).toBe(1);
  });
  test('uploadFile retries 5xx with backoff and succeeds', async () => {
    let calls = 0;
    const f = vi.fn(async () => {
      calls++;
      if (calls < 3) return new Response('boom', { status: 500 });
      return new Response(JSON.stringify({ path: 'p/x', fileName: 'a' }), { status: 200 });
    }) as unknown as FetchFn;
    const api = new ZApi('http://x:5190', 't', f);
    const res = await api.uploadFile('s1', 'a', Uint8Array.from([1, 2, 3]));
    expect(res.path).toBe('p/x');
    expect(calls).toBe(3);
  });

  test('uploadFile does not retry on 4xx', async () => {
    let calls = 0;
    const f = vi.fn(async () => {
      calls++;
      return new Response('unauthorized', { status: 401 });
    }) as unknown as FetchFn;
    const api = new ZApi('http://x:5190', 't', f);
    await expect(api.uploadFile('s1', 'a', Uint8Array.from([1]))).rejects.toThrow();
    expect(calls).toBe(1);
  });
  test('uploadFile large file switches to chunk endpoints and skips have[]', async () => {
    const bytes = Uint8Array.from({ length: 6 * 1024 * 1024 + 1 }, (_, i) => i % 251); // 9 块
    const calls: string[] = [];
    const f = vi.fn(async (url: string | URL) => {
      const u = String(url);
      calls.push(u);
      if (u.endsWith('/upload/init')) return new Response(JSON.stringify({ uploadId: 'u1', have: [0] }), { status: 200 });
      if (/\/upload\/u1\/\d+$/.test(u)) return new Response(JSON.stringify({ ok: true }), { status: 200 });
      return new Response(JSON.stringify({ ok: true, path: 'p/big', fileName: 'a.bin' }), { status: 200 });
    }) as unknown as FetchFn;
    const api = new ZApi('http://x:5190', 't', f);
    const res = await api.uploadFile('s1', 'a.bin', bytes);
    expect(res.path).toBe('p/big');
    expect(calls[0]).toContain('/upload/init');
    const chunkCalls = calls.filter((c) => /\/upload\/u1\/\d+$/.test(c));
    expect(chunkCalls).toHaveLength(8); // 9 块,have=[0] 跳过第 0 块(断点续传)
    expect(calls[calls.length - 1]).toContain('/upload/u1/complete');
  });
});
