// 完整重载的去重回归:同文重复消息(如反复"继续")不得被指纹吞掉。
// 旧实现用"指纹存在即跳过",库里有一条"继续",转录里第二条"继续"就永远补不回来。
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

describe('reloadSessionTranscript · 重复消息补回', () => {
  let home: string;

  beforeEach(() => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-reload-dedup-'));
    process.env.ZCODE_CLAUDE_HOME = home;
  });

  afterEach(() => {
    delete process.env.ZCODE_CLAUDE_HOME;
    fs.rmSync(home, { recursive: true, force: true });
  });

  it('同文消息按条数对齐:库内已有的跳过,余量照补', async () => {
    const { openDb, createSession, updateSession, appendOutbound, listMessages } = await import('../src/db.js');
    const { reloadSessionTranscript } = await import('../src/local-sessions.js');

    const provId = 'prov-dup-1';
    const projDir = path.join(home, 'projects', 'D--work-app');
    fs.mkdirSync(projDir, { recursive: true });
    fs.writeFileSync(path.join(projDir, provId + '.jsonl'), [
      JSON.stringify({ type: 'user', sessionId: provId, cwd: 'D:\\work\\app', message: { role: 'user', content: '继续' } }),
      JSON.stringify({ type: 'assistant', sessionId: provId, message: { role: 'assistant', content: [{ type: 'text', text: '回答A' }] } }),
      JSON.stringify({ type: 'user', sessionId: provId, message: { role: 'user', content: '继续' } }),
      JSON.stringify({ type: 'assistant', sessionId: provId, message: { role: 'assistant', content: [{ type: 'text', text: '回答B' }] } }),
      '',
    ].join('\n'));

    const db = openDb(':memory:');
    const s = createSession(db, { title: '断线' });
    updateSession(db, s.id, { providerSessionId: provId });
    // 库里已有第一轮(中断前实况落库):继续 → 回答A
    appendOutbound(db, s.id, { seq: 1, kind: 'text', role: 'user', content: '继续' });
    appendOutbound(db, s.id, { seq: 2, kind: 'text', role: 'assistant', content: '回答A' });

    const r = reloadSessionTranscript(db, s.id);
    expect(r.merged).toBe(2); // 第二条"继续" + 回答B;回答A 与第一条"继续"已在库

    const contents = listMessages(db, s.id, { limit: 10 })
      .messages.map((m) => String((JSON.parse(String(m.meta)) as { content?: unknown }).content ?? m.content));
    expect(contents.filter((c) => c === '继续').length).toBe(2); // 两条"继续"都在
    expect(contents).toContain('回答B');

    const again = reloadSessionTranscript(db, s.id);
    expect(again.merged).toBe(0); // 幂等
  });
});
