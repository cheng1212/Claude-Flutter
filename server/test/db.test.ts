import { describe, expect, it } from 'vitest';
import {
  openDb, createSession, getSession, listSessions, updateSession, buildSessionExport,
  deleteSession, appendMessage, listMessages, createRun, finishRun, failStaleRuns,
} from '../src/db.js';

describe('db', () => {
  it('会话 CRUD + 置顶排序', () => {
    const db = openDb(':memory:');
    const a = createSession(db, { title: 'a' });
    const b = createSession(db, { title: 'b' });
    updateSession(db, b.id, { isPinned: true });
    const list = listSessions(db);
    expect(list[0].id).toBe(b.id);
    expect(list.length).toBe(2);
    expect(getSession(db, a.id)?.permission_mode).toBe('default');
    deleteSession(db, a.id);
    expect(listSessions(db).length).toBe(1);
  });
  it('消息 seq 按会话递增;历史分页(最新在前)', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'x' });
    for (let i = 0; i < 25; i++) {
      appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: `m${i}` });
    }
    const page = listMessages(db, s.id, { limit: 10, offset: 0 });
    expect(page.total).toBe(25);
    expect(page.messages.length).toBe(10);
    expect(page.messages[0].seq).toBe(25);
    const tail = listMessages(db, s.id, { limit: 10, offset: 20 });
    expect(tail.messages[0].seq).toBe(5);
  });
  it('beforeSeq 锚点翻更旧页:新消息插入不漂移', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'x' });
    for (let i = 1; i <= 30; i++) {
      appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: `m${i}` });
    }
    // 第一页取最新 10 条(seq 30..21),minSeq=21;beforeSeq=21 应返回 20..11
    const page = listMessages(db, s.id, { limit: 10, offset: 0 });
    expect(page.messages[0].seq).toBe(30);
    const minSeq = page.messages[page.messages.length - 1].seq;
    expect(minSeq).toBe(21);
    // 模拟翻页期间新插入 5 条(seq 31..35):offset 分页会漂移,锚点分页不受影响
    for (let i = 31; i <= 35; i++) {
      appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: `m${i}` });
    }
    const older = listMessages(db, s.id, { limit: 10, beforeSeq: minSeq });
    expect(older.messages.map((m) => m.seq)).toEqual([20, 19, 18, 17, 16, 15, 14, 13, 12, 11]);
  });
  it('run 记录成本与用量', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'r' });
    const run = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, run.id, { status: 'complete', totalCostUsd: 0.12, usage: { inputTokens: 100, outputTokens: 50 } });
    const row = db.prepare('SELECT * FROM runs WHERE id=?').get(run.id) as { status: string; total_cost_usd: number };
    expect(row.status).toBe('complete');
    expect(row.total_cost_usd).toBeCloseTo(0.12);
  });
  it('failStaleRuns:僵尸 run 标 interrupted,并给每个受影响会话补"重启打断"错误行', () => {
    const db = openDb(':memory:');
    const a = createSession(db, { title: 'a' });
    const b = createSession(db, { title: 'b' });
    createRun(db, a.id, 'glm-5.3-flash');
    createRun(db, b.id, 'glm-5.3-flash');
    createRun(db, a.id, 'glm-5.3-flash'); // 同会话两个僵尸也只补一条错误行
    appendMessage(db, a.id, { kind: 'text', role: 'assistant', content: '已有内容' });
    const changed = failStaleRuns(db);
    expect(changed).toBe(3);
    expect(db.prepare("SELECT COUNT(*) AS c FROM runs WHERE status='running'").get() ).toEqual({ c: 0 });
    // 每个受影响会话补一条 kind=error 的说明行,seq 落在 MAX+1(与锁步一致)
    for (const s of [a, b]) {
      const tail = db.prepare('SELECT seq, kind, content FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT 1').get(s.id) as { seq: number; kind: string; content: string };
      expect(tail.kind).toBe('error');
      expect(tail.content).toContain('服务重启打断');
    }
    const aMax = (db.prepare('SELECT COALESCE(MAX(seq),0) AS m FROM messages WHERE session_id=?').get(a.id) as { m: number }).m;
    expect(aMax).toBe(2); // text#1 → error#2,自动续号
  });
});

describe('会话管理增强', () => {
  it('新会话默认未归档、空标签;updateSession 可改 archived/tags', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 't', cwd: 'D:\proj\myapp' });
    const row = getSession(db, s.id)!;
    expect((row as { archived: number }).archived).toBe(0);
    expect((row as { tags: string }).tags).toBe('[]');
    updateSession(db, s.id, { archived: true, tags: ['Flutter', '重要'] });
    const after = getSession(db, s.id)! as unknown as { archived: number; tags: string };
    expect(after.archived).toBe(1);
    expect(JSON.parse(after.tags)).toEqual(['Flutter', '重要']);
  });

  it('listSessions 附带 lastPreview/lastStatus/project/tags', () => {
    const db = openDb(':memory:');
    const BS = String.fromCharCode(92);
    const s = createSession(db, { title: 'x', cwd: 'D:' + BS + 'work' + BS + 'flutter_app', tags: ['标签A'] });
    appendMessage(db, s.id, { kind: 'text', role: 'user', content: '第一条' });
    appendMessage(db, s.id, { kind: 'tool_use', meta: { toolName: 'Bash' }, content: '{}' });
    appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: '最新回复' });
    const run = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, run.id, { status: 'success' });
    const row = listSessions(db).find(r => r.id === s.id) as unknown as {
      last_preview: string; last_status: string; project: string; tags: string[];
    };
    expect(row.last_preview).toContain('最新回复');
    expect(row.last_status).toBe('success');
    expect(row.project).toBe('flutter_app');
    expect(row.tags).toEqual(['标签A']);
  });

  it('lastPreview 对工具行给出友好摘要,空会话为空', () => {
    const db = openDb(':memory:');
    const empty = createSession(db, { title: 'e' });
    expect((listSessions(db).find(r => r.id === empty.id) as unknown as { last_preview: string }).last_preview).toBe('');
    const s = createSession(db, { title: 'w' });
    appendMessage(db, s.id, { kind: 'thinking', content: '想一想' });
    const row = listSessions(db).find(r => r.id === s.id) as unknown as { last_preview: string };
    expect(row.last_preview).toContain('想一想');
  });

  it('content 含管道符不破坏预览(曾用 | 拼接再 split 导致错位)', () => {
    const db = openDb(':memory:');
    const s1 = createSession(db, { title: 'p1' });
    appendMessage(db, s1.id, { kind: 'text', role: 'assistant', content: '命令 A | B 的输出' });
    const t1 = listSessions(db).find(r => r.id === s1.id) as unknown as { last_preview: string };
    expect(t1.last_preview).toBe('命令 A | B 的输出');

    const s2 = createSession(db, { title: 'p2' });
    appendMessage(db, s2.id, { kind: 'tool_use', meta: { toolName: 'Bash' }, content: '{"command":"ls | wc -l"}' });
    const t2 = listSessions(db).find(r => r.id === s2.id) as unknown as { last_preview: string };
    expect(t2.last_preview).toBe('🔧 Bash');
  });

  it('listSessions 附带累计 totalTokens(输入+输出+缓存读写,跨 run 求和;无 run 为 0)', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: '用量' });
    const r1 = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, r1.id, { status: 'success', usage: { inputTokens: 100, outputTokens: 50, cacheReadInputTokens: 200, cacheCreationInputTokens: 10 } });
    const r2 = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, r2.id, { status: 'success', usage: { inputTokens: 30, outputTokens: 20 } });
    const row = listSessions(db).find(r => r.id === s.id) as unknown as { totalTokens: number };
    expect(row.totalTokens).toBe(410); // (100+50+200+10) + (30+20)
    const bare = createSession(db, { title: '没跑过' });
    const bareRow = listSessions(db).find(r => r.id === bare.id) as unknown as { totalTokens: number };
    expect(bareRow.totalTokens).toBe(0);
  });
});

describe('会话导出', () => {
  it('buildSessionExport 生成含标题/角色/工具/错误的 markdown', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: '导出我', cwd: 'D:\proj', model: 'glm-5.3-flash' });
    appendMessage(db, s.id, { kind: 'text', role: 'user', content: '帮我看看这个接口' });
    appendMessage(db, s.id, { kind: 'thinking', content: '先看返回结构' });
    appendMessage(db, s.id, { kind: 'tool_use', meta: { toolName: 'Bash' }, content: '{"command":"curl -s api"}' });
    appendMessage(db, s.id, { kind: 'tool_result', content: '{"code":200}', meta: {} });
    appendMessage(db, s.id, { kind: 'tool_result', content: '输出里提到 is_error 字样,但其实成功了', meta: {} });
    appendMessage(db, s.id, { kind: 'tool_result', content: 'exit code 1', meta: { isError: true } });
    appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: '接口返回 200,没问题' });
    appendMessage(db, s.id, { kind: 'error', content: '上游超时一次' });
    appendMessage(db, s.id, { kind: 'usage', content: '' });
    appendMessage(db, s.id, { kind: 'complete', content: '' });
    const out = buildSessionExport(db, s.id)!;
    expect(out.filename).toMatch(/\.md$/);
    expect(out.markdown).toContain('# 导出我');
    expect(out.markdown).toContain('glm-5.3-flash');
    expect(out.markdown).toContain('**用户**');
    expect(out.markdown).toContain('接口返回 200,没问题');
    expect(out.markdown).toContain('🔧 **Bash**');
    expect(out.markdown).toContain('curl -s api');
    expect(out.markdown).toContain('⚠️ 上游超时一次');
    expect(out.markdown).not.toContain('complete'); // 控制事件不进导出
    // 失败判定只认 meta.isError:正文含 "is_error" 字样的成功结果不标失败
    expect(out.markdown).toContain('提到 is_error 字样');
    expect(out.markdown.match(/结果\(失败\)/g)).toHaveLength(1);
  });

  it('导出按时间正序、未知会话返回 null', () => {
    const db = openDb(':memory:');
    expect(buildSessionExport(db, 'nope')).toBeNull();
    const s = createSession(db, { title: '顺序' });
    appendMessage(db, s.id, { kind: 'text', role: 'user', content: '第一句' });
    appendMessage(db, s.id, { kind: 'text', role: 'assistant', content: '第二句' });
    const md = buildSessionExport(db, s.id)!.markdown;
    expect(md.indexOf('第一句')).toBeLessThan(md.indexOf('第二句'));
  });
});

describe('定时任务登记', () => {
  it('registerCron 登记并列表(listCrons 附 next_fire),markCronDeleted 幂等删除', async () => {
    const { openDb, createSession, registerCron, listCrons, markCronDeleted } = await import('../src/db.js');
    const db = openDb(':memory:');
    const s = createSession(db, { title: '宿主会话' });
    registerCron(db, s.id, { cron: '*/5 * * * *', prompt: '检查构建', recurring: true, durable: false });
    registerCron(db, s.id, { cron: '0 9 * * 1-5', prompt: '晨报', recurring: true, durable: true });

    const list = listCrons(db);
    expect(list.length).toBe(2);
    expect(list[0]).toMatchObject({ status: 'active', session_title: '宿主会话' });
    expect(new Date(list[0].next_fire ?? '').toString()).not.toBe('Invalid Date');

    markCronDeleted(db, list[0].id);
    markCronDeleted(db, list[0].id); // 幂等
    expect(listCrons(db).length).toBe(1);

    const bySession = listCrons(db, s.id);
    expect(bySession.length).toBe(1);
  });

  it('recordCronToolUse 拦截 CronCreate/CronDelete 工具事件', async () => {
    const { openDb, createSession, recordCronToolUse, listCrons } = await import('../src/db.js');
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'x' });
    recordCronToolUse(db, s.id, { toolName: 'CronCreate', toolInput: { cron: '*/10 * * * *', prompt: '轮询一下', recurring: true } });
    recordCronToolUse(db, s.id, { toolName: 'Other', toolInput: {} });
    expect(listCrons(db).length).toBe(1);
    recordCronToolUse(db, s.id, { toolName: 'CronDelete', toolInput: { cron: '*/10 * * * *', prompt: '轮询一下' } });
    expect(listCrons(db).length).toBe(0);
  });
});
