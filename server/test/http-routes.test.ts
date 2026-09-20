import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildApp } from '../src/http.js';
import { openDb, createSession, appendMessage, createRun, finishRun, updateSession } from '../src/db.js';

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

    // 白名单收敛:字符串 'true' 也认;越界 permissionMode 拒收(保持原值)
    const strPin = await app.inject({ method: 'PATCH', url: `/api/sessions/${id}`, headers: H, payload: { isPinned: 'false', permissionMode: 'bogus' } });
    expect((strPin.json() as { is_pinned: number }).is_pinned).toBe(0);
    expect((strPin.json() as { permission_mode: string }).permission_mode).toBe('default');
    const mode = await app.inject({ method: 'PATCH', url: `/api/sessions/${id}`, headers: H, payload: { permissionMode: 'plan' } });
    expect((mode.json() as { permission_mode: string }).permission_mode).toBe('plan');

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

  it('上传文件名净化:穿越收敛/Windows 保留名/控制字符/尾随点空格/超长保扩展名', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const s = createSession(db, { title: 'up' });
    updateSession(db, s.id, { cwd: fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-up-')) });
    const up = async (fileName: string): Promise<string> => {
      const res = await app.inject({
        method: 'POST', url: `/api/sessions/${s.id}/files`, headers: H,
        payload: { fileName, dataB64: Buffer.from('x').toString('base64') },
      });
      expect(res.statusCode).toBe(200);
      return (res.json() as { fileName: string }).fileName;
    };
    expect(await up('a/b/../../evil.txt')).toBe('evil.txt'); // 目录穿越 → basename
    expect(await up('CON.txt')).toBe('_CON.txt'); // Windows 保留名加前缀
    expect(await up('com1')).toBe('_com1');
    expect(await up('报告.txt. . ')).toBe('报告.txt'); // 尾随点/空格提前剥掉
    expect(await up('bell\u0007name.txt')).toBe('bell_name.txt'); // 控制字符替换
    expect(await up('..')).toBe('file'); // 剥完为空 → file
    const long = await up(`${'x'.repeat(200)}.txt`);
    expect(long.length).toBeLessThanOrEqual(120);
    expect(long.endsWith('.txt')).toBe(true); // 超长截断仍保扩展名
    await app.close();
  });

  it('PATCH model/permissionMode 触发 onSessionPatched(真热切换回调),其他字段不触发', async () => {
    const db = openDb(':memory:');
    const calls: Array<{ id: string; patch: { model?: string; permissionMode?: string } }> = [];
    const app = await buildApp({
      token: 't', db, routesPath: 'Z:/none.json',
      onSessionPatched: (id, patch) => calls.push({ id, patch }),
    });
    const s = createSession(db, { title: 'hot' });

    // model + permissionMode:两个字段都透传给回调
    await app.inject({ method: 'PATCH', url: `/api/sessions/${s.id}`, headers: H, payload: { model: 'glm-x', permissionMode: 'plan' } });
    expect(calls).toEqual([{ id: s.id, patch: { model: 'glm-x', permissionMode: 'plan' } }]);

    // title-only PATCH:不触发(没有要热设的东西)
    await app.inject({ method: 'PATCH', url: `/api/sessions/${s.id}`, headers: H, payload: { title: '改名' } });
    expect(calls).toHaveLength(1);

    // 越界 permissionMode 被白名单拒了:不进 patch,也不触发回调
    await app.inject({ method: 'PATCH', url: `/api/sessions/${s.id}`, headers: H, payload: { permissionMode: 'bogus' } });
    expect(calls).toHaveLength(1);
    await app.close();
  });

  it('sessions 列表带 isRunning/awaitingApproval:注入的 registry/runtime 查询决定徽章', async () => {
    const db = openDb(':memory:');
    const live = new Set<string>();
    const awaiting = new Set<string>();
    const app = await buildApp({
      token: 't', db, routesPath: 'Z:/none.json',
      isRunning: (id) => live.has(id),
      isAwaiting: (id) => awaiting.has(id),
    });
    const s = createSession(db, { title: 'live' });

    const list1 = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    let rows = list1.json() as Array<{ id: string; isRunning: boolean; awaitingApproval: boolean }>;
    expect(rows.find((r) => r.id === s.id)?.isRunning).toBe(false);
    expect(rows.find((r) => r.id === s.id)?.awaitingApproval).toBe(false);

    live.add(s.id); // 等价 registry.begin
    awaiting.add(s.id); // 等价 runtime 在等审批
    const list2 = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    rows = list2.json() as Array<{ id: string; isRunning: boolean; awaitingApproval: boolean }>;
    expect(rows.find((r) => r.id === s.id)?.isRunning).toBe(true);
    expect(rows.find((r) => r.id === s.id)?.awaitingApproval).toBe(true);
    await app.close();
  });

  it('sessions 列表带 last_message:最后一条文本消息截断做副标题', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const s = createSession(db, { title: 'sub' });
    appendMessage(db, s.id, { kind: 'text', role: 'user', content: '旧消息' });
    appendMessage(db, s.id, { kind: 'tool_use', content: '{}', meta: { kind: 'tool_use', toolName: 'Bash', toolId: 't' } });
    appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: '最新回复'.padEnd(200, '字') });

    const list = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    const row = (list.json() as Array<{ id: string; last_message?: string }>).find((r) => r.id === s.id);
    expect(row?.last_message?.startsWith('最新回复')).toBe(true);
    expect(row?.last_message?.length).toBeLessThanOrEqual(120);
    // 没有消息的会话:last_message 为 null,不炸
    createSession(db, { title: 'empty' });
    const list2 = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    const empty = (list2.json() as Array<{ title: string; last_message?: string | null }>).find((r) => r.title === 'empty');
    expect(empty?.last_message ?? null).toBeNull();
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

describe('REST · 会话管理增强', () => {
  it('PATCH 支持 archived 与 tags,列表回带增强字段', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const created = await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: '增强' } });
    const id = (created.json() as { id: string }).id;

    const patched = await app.inject({ method: 'PATCH', url: `/api/sessions/${id}`, headers: H, payload: { archived: true, tags: ['Flutter', '重要'] } });
    expect(patched.statusCode).toBe(200);
    const row = patched.json() as { archived: number; tags: string };
    expect(row.archived).toBe(1);
    expect(JSON.parse(row.tags)).toEqual(['Flutter', '重要']);

    const list = await app.inject({ method: 'GET', url: '/api/sessions', headers: H });
    const first = (list.json() as { archived: number; tags: string; last_preview: string; last_status: string | null; project: string | null }[])[0];
    expect(first.archived).toBe(1);
    expect(first.tags).toEqual(['Flutter', '重要']);
    expect(first.last_preview).toBe('');
    expect(first.last_status).toBeNull();
    expect(first.project).toBeNull();
  });
});

describe('REST · 用量', () => {
  it('GET /api/usage 按自然日过滤(含今天),模型明细带缓存命中率', async () => {
    const db = openDb(':memory:');
    const { createRun: mkRun, finishRun: endRun } = await import('../src/db.js');
    const s = createSession(db, { title: '用量' });
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });

    // 今天:deepseek-flash 一条(输入 100 + 缓存读 300 + 输出 50)
    const today = mkRun(db, s.id, 'deepseek-flash');
    endRun(db, today.id, {
      status: 'success',
      usage: { inputTokens: 100, outputTokens: 50, cacheReadInputTokens: 300, cacheCreationInputTokens: 0, numTurns: 1 },
    });
    // 昨天(仍落在 7d 自然日窗口内)
    const y = new Date();
    y.setDate(y.getDate() - 1);
    y.setHours(12, 0, 0, 0);
    const yRun = mkRun(db, s.id, 'glm-5.3-flash');
    db.prepare('UPDATE runs SET started_at=? WHERE id=?').run(y.toISOString(), yRun.id);
    endRun(db, yRun.id, {
      status: 'success',
      usage: { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, numTurns: 1 },
    });
    // 8 天前:7d 窗口外
    const old = new Date();
    old.setDate(old.getDate() - 8);
    old.setHours(12, 0, 0, 0);
    const oRun = mkRun(db, s.id, 'nemotron-3-ultra');
    db.prepare('UPDATE runs SET started_at=? WHERE id=?').run(old.toISOString(), oRun.id);
    endRun(db, oRun.id, {
      status: 'success',
      usage: { inputTokens: 9999, outputTokens: 9999, cacheReadInputTokens: 0, cacheCreationInputTokens: 0, numTurns: 1 },
    });

    const week = (await app.inject({ method: 'GET', url: '/api/usage?range=7d', headers: H })).json() as {
      models: { modelId: string; cacheHitRate: number; cacheReadInputTokens: number }[];
      summary: { totalTokens: number };
    };
    const ids = week.models.map((m) => m.modelId);
    expect(ids).toContain('deepseek-flash');
    expect(ids).toContain('glm-5.3-flash');
    expect(ids).not.toContain('nemotron-3-ultra'); // 8 天前被自然日窗口挡掉
    const ds = week.models.find((m) => m.modelId === 'deepseek-flash')!;
    expect(ds.cacheReadInputTokens).toBe(300);
    expect(ds.cacheHitRate).toBeCloseTo(300 / 400, 5);

    // today:只有今天的模型
    const day = (await app.inject({ method: 'GET', url: '/api/usage?range=today', headers: H })).json() as {
      models: { modelId: string }[];
    };
    expect(day.models.map((m) => m.modelId)).toEqual(['deepseek-flash']);

    // all:全都回来
    const all = (await app.inject({ method: 'GET', url: '/api/usage?range=all', headers: H })).json() as {
      models: { modelId: string }[];
    };
    expect(all.models.map((m) => m.modelId)).toContain('nemotron-3-ultra');
    await app.close();
  });
});

describe('REST · 自我重启', () => {
  it('POST /api/server/restart:先回 202,再触发回调;未注入回调回 501', async () => {
    const db = openDb(':memory:');
    let restarted = 0;
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json', onRestart: () => { restarted += 1; } });
    const res = await app.inject({ method: 'POST', url: '/api/server/restart', headers: H });
    expect(res.statusCode).toBe(202);
    expect((res.json() as { ok: boolean }).ok).toBe(true);
    expect(restarted).toBe(1);
    await app.close();

    // 没注入(如测试装配/非标准启动)→ 501,不假装能重启
    const bare = await buildApp({ token: 't', db: openDb(':memory:'), routesPath: 'Z:/none.json' });
    expect((await bare.inject({ method: 'POST', url: '/api/server/restart', headers: H })).statusCode).toBe(501);
    await bare.close();
  });
});

describe('REST · 定时任务', () => {
  it('GET /api/crons 支持 ?session= 过滤(会话弹层/快捷条只取本会话)', async () => {
    const db = openDb(':memory:');
    const { recordCronToolUse } = await import('../src/db.js');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const a = (await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: 'a' } })).json() as { id: string };
    const b = (await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: 'b' } })).json() as { id: string };
    recordCronToolUse(db, a.id, { toolName: 'CronCreate', toolInput: { cron: '*/10 * * * *', prompt: '给A', recurring: true } });
    recordCronToolUse(db, b.id, { toolName: 'CronCreate', toolInput: { cron: '*/20 * * * *', prompt: '给B', recurring: true } });
    const all = (await app.inject({ method: 'GET', url: '/api/crons', headers: H })).json() as { crons: unknown[] };
    expect(all.crons.length).toBe(2);
    const onlyA = (await app.inject({ method: 'GET', url: `/api/crons?session=${a.id}`, headers: H })).json() as { crons: { prompt: string }[] };
    expect(onlyA.crons.length).toBe(1);
    expect(onlyA.crons[0].prompt).toBe('给A');
  });
});

describe('REST · 复制会话(fork)', () => {
  it('POST /fork 复制消息与配置,fork_from=源 provider_session_id', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const created = await app.inject({ method: 'POST', url: '/api/sessions', headers: H, payload: { title: '源', model: 'glm-5.3-flash' } });
    const id = (created.json() as { id: string }).id;
    const { updateSession } = await import('../src/db.js');
    updateSession(db, id, { providerSessionId: 'prov-src' });
    appendMessage(db, id, { kind: 'text', role: 'user', content: '历史1' });
    appendMessage(db, id, { kind: 'text', role: 'assistant', content: '历史2' });

    const res = await app.inject({ method: 'POST', url: `/api/sessions/${id}/fork`, headers: H });
    expect(res.statusCode).toBe(200);
    const row = res.json() as { id: string; title: string; fork_from: string | null; provider_session_id: string | null; model: string | null };
    expect(row.title).toBe('源 副本');
    expect(row.fork_from).toBe('prov-src');
    expect(row.provider_session_id).toBeNull(); // 等首轮 init 回填新 id
    expect(row.model).toBe('glm-5.3-flash');

    const msgs = await app.inject({ method: 'GET', url: `/api/sessions/${row.id}/messages`, headers: H });
    expect((msgs.json() as { total: number }).total).toBe(2);

    const missing = await app.inject({ method: 'POST', url: '/api/sessions/nope/fork', headers: H });
    expect(missing.statusCode).toBe(404);
  });
});

describe('export + usage 路由(审计补层:此前无直测)', () => {
  it('GET /api/sessions/:id/export 导出 markdown 含标题/模型/消息体;不存在 404', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const s = createSession(db, { title: '导出测试', cwd: 'C:/work/demo' });
    appendMessage(db, s.id, { kind: 'text', role: 'user', content: '你好,帮我看看' });
    appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: '好的,结论是 **42**' });
    appendMessage(db, s.id, { kind: 'tool_use', content: '{"cmd":"ls"}', meta: { toolName: 'Bash', toolId: 't1' } });

    const res = await app.inject({ method: 'GET', url: `/api/sessions/${s.id}/export`, headers: H });
    expect(res.statusCode).toBe(200);
    const body = res.json() as { filename: string; markdown: string };
    expect(body.filename).toContain('导出测试');
    expect(body.markdown).toContain('# 导出测试');
    expect(body.markdown).toContain('C:/work/demo');
    expect(body.markdown).toContain('你好,帮我看看');
    expect(body.markdown).toContain('**42**');

    const missing = await app.inject({ method: 'GET', url: '/api/sessions/nope/export', headers: H });
    expect(missing.statusCode).toBe(404);
    await app.close();
  });

  it('GET /api/usage 与 /api/sessions/:id/usage 返回聚合形状', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const s = createSession(db, { title: '用量' });
    const r = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, r.id, { status: 'success', usage: { inputTokens: 100, outputTokens: 50, cacheReadInputTokens: 300, cacheCreationInputTokens: 0, numTurns: 2, totalCostUsd: 0.01, durationMs: 1000 } });

    const global = await app.inject({ method: 'GET', url: '/api/usage?range=30d', headers: H });
    expect(global.statusCode).toBe(200);
    const g = global.json() as { range: string; summary: { totalTokens: number; totalSessions: number }; models: unknown[]; daily: unknown[] };
    expect(g.range).toBe('30d');
    expect(g.summary.totalSessions).toBe(1);
    expect(g.summary.totalTokens).toBe(450); // 100+300+0+50
    expect(g.models.length).toBe(1);

    const per = await app.inject({ method: 'GET', url: `/api/sessions/${s.id}/usage`, headers: H });
    expect(per.statusCode).toBe(200);
    expect((per.json() as { runs: number }).runs).toBe(1);
    await app.close();
  });
  it('分块上传:init/chunk/complete 组装;缺块 400;octet-stream 收 buffer', async () => {
    const db = openDb(':memory:');
    const app = await buildApp({ token: 't', db, routesPath: 'Z:/none.json' });
    const s = createSession(db, { title: 'chunk' });
    updateSession(db, s.id, { cwd: fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-chunk-')) });
    const init = await app.inject({
      method: 'POST', url: `/api/sessions/${s.id}/upload/init`, headers: H,
      payload: { fileName: 'big.bin', totalChunks: 2 },
    });
    expect(init.statusCode).toBe(200);
    const { uploadId, have } = init.json() as { uploadId: string; have: number[] };
    expect(have).toEqual([]);
    const sendChunk = (i: number, data: string) => app.inject({
      method: 'POST',
      url: `/api/sessions/${s.id}/upload/${uploadId}/${i}`,
      headers: { authorization: 'Bearer t', 'content-type': 'application/octet-stream' },
      payload: Buffer.from(data),
    });
    expect((await sendChunk(0, 'hello ')).statusCode).toBe(200);
    const bad = await app.inject({ method: 'POST', url: `/api/sessions/${s.id}/upload/${uploadId}/complete`, headers: H });
    expect(bad.statusCode).toBe(400);
    expect(bad.json()).toMatchObject({ error: '缺块 1' });
    expect((await sendChunk(1, 'world')).statusCode).toBe(200);
    const done = await app.inject({ method: 'POST', url: `/api/sessions/${s.id}/upload/${uploadId}/complete`, headers: H });
    expect(done.statusCode).toBe(200);
    const out = done.json() as { path: string; fileName: string; size: number };
    expect(out.fileName).toBe('big.bin');
    expect(out.size).toBe(11);
    expect(fs.readFileSync(out.path, 'utf8')).toBe('hello world');
    await app.close();
  });
});
