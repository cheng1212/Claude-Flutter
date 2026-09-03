import { describe, expect, it } from 'vitest';
import {
  openDb, createSession, getSession, listSessions, updateSession,
  deleteSession, appendMessage, listMessages, createRun, finishRun,
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
  it('run 记录成本与用量', () => {
    const db = openDb(':memory:');
    const s = createSession(db, { title: 'r' });
    const run = createRun(db, s.id, 'glm-5.3-flash');
    finishRun(db, run.id, { status: 'complete', totalCostUsd: 0.12, usage: { inputTokens: 100, outputTokens: 50 } });
    const row = db.prepare('SELECT * FROM runs WHERE id=?').get(run.id) as { status: string; total_cost_usd: number };
    expect(row.status).toBe('complete');
    expect(row.total_cost_usd).toBeCloseTo(0.12);
  });
});
