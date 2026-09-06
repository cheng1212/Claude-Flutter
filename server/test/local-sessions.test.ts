import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { openDb, listSessions, listMessages, getSessionByProviderSessionId, deleteSession } from '../src/db.js';
import { importLocalSessions } from '../src/local-sessions.js';

let tempDir: string;

const line = (obj: unknown): string => JSON.stringify(obj);

/** 写一个项目转写文件到 temp/projects/<encoded-cwd>/<sessionId>.jsonl。 */
function writeTranscript(sessionId: string, encodedCwd: string, rows: unknown[]): string {
  const dir = path.join(tempDir, 'projects', encodedCwd);
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, `${sessionId}.jsonl`);
  fs.writeFileSync(file, `${rows.map(line).join('\n')}\n`, 'utf8');
  return file;
}

beforeEach(() => {
  tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-localsess-'));
  process.env.ZCODE_CLAUDE_HOME = tempDir;
});

afterEach(() => {
  delete process.env.ZCODE_CLAUDE_HOME;
  fs.rmSync(tempDir, { recursive: true, force: true });
});

describe('local-sessions', () => {
  it('导入 ~/.claude/projects 转写 → sessions(source=local)+messages,幂等', () => {
    const db = openDb(':memory:');
    // history.jsonl 提供 A 的 display 标题
    fs.writeFileSync(
      path.join(tempDir, 'history.jsonl'),
      `${line({ sessionId: 'sess-a', display: '我的聊天' })}\n`,
      'utf8',
    );
    // session A: 用户文本 + assistant(text+thinking+tool_use) + tool_result + 收尾文本
    writeTranscript('sess-a', 'D--cheng-zcode', [
      { sessionId: 'sess-a', cwd: 'D:\\cheng\\zcode', type: 'user', message: { role: 'user', content: 'Hello' } },
      {
        sessionId: 'sess-a', cwd: 'D:\\cheng\\zcode', type: 'assistant',
        message: {
          role: 'assistant',
          content: [
            { type: 'text', text: 'Hi there' },
            { type: 'thinking', thinking: 'step 1...' },
            { type: 'tool_use', id: 't1', name: 'Read', input: { file: 'a.md' } },
          ],
        },
      },
      {
        sessionId: 'sess-a', cwd: 'D:\\cheng\\zcode', type: 'user',
        message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'file content', is_error: false }] },
      },
      { sessionId: 'sess-a', cwd: 'D:\\cheng\\zcode', type: 'assistant', message: { role: 'assistant', content: 'Done' } },
    ]);
    // session B: 无 history,靠末尾 last-prompt 定标题
    writeTranscript('sess-b', 'D--somewhere', [
      { sessionId: 'sess-b', cwd: 'D:\\somewhere', type: 'user', message: { role: 'user', content: 'question' } },
      { sessionId: 'sess-b', type: 'last-prompt', lastPrompt: 'Where is the water?' },
    ]);
    // subagent 转写必须跳过(路径含 subagents,且内容无 sessionId/cwd)
    const subagentDir = path.join(tempDir, 'projects', 'D--somewhere', `sess-b${path.sep}subagents`);
    fs.mkdirSync(subagentDir, { recursive: true });
    fs.writeFileSync(path.join(subagentDir, 'agent-1.jsonl'), `${line({ type: 'user' })}\n`, 'utf8');

    const first = importLocalSessions(db);
    expect(first.imported).toBe(2); // sess-a + sess-b; subagent 文件跳过
    expect(first.skipped).toBe(1); // subagents/agent-1.jsonl

    const sessions = listSessions(db);
    expect(sessions.length).toBe(2);
    const a = sessions.find((s) => s.provider_session_id === 'sess-a')!;
    const b = sessions.find((s) => s.provider_session_id === 'sess-b')!;
    expect(a.source).toBe('local');
    expect(a.title).toBe('我的聊天'); // 来自 history.jsonl display
    expect(a.cwd).toBe('D:\\cheng\\zcode');
    expect(b.source).toBe('local');
    expect(b.title).toBe('Where is the water?'); // 来自末尾 last-prompt

    // A 的消息按 seq 铺开,meta 是完整出站事件
    const msgs = listMessages(db, a.id, { limit: 200, offset: 0 });
    expect(msgs.total).toBe(6);
    const seq4 = msgs.messages.find((m) => m.seq === 4)!;
    const meta4 = JSON.parse(seq4.meta!) as Record<string, unknown>;
    expect(meta4.kind).toBe('tool_use');
    expect(meta4.toolId).toBe('t1');
    expect(meta4.toolName).toBe('Read');
    const seq5 = msgs.messages.find((m) => m.seq === 5)!;
    const meta5 = JSON.parse(seq5.meta!) as Record<string, unknown>;
    expect(meta5.kind).toBe('tool_result');
    expect(meta5.isError).toBe(false);

    // 主键判重,二次导入不重复、不覆盖
    const second = importLocalSessions(db);
    expect(second.imported).toBe(0);
    expect(second.skipped).toBe(3); // sess-a + sess-b + subagents 文件
    expect(listSessions(db).length).toBe(2);

    expect(getSessionByProviderSessionId(db, 'sess-a')?.id).toBe(a.id);
  });

  it('标题兜底:无 history、无末尾标题行时用 cwd 目录名', () => {
    const db = openDb(':memory:');
    writeTranscript('sess-c', 'my-project', [
      { sessionId: 'sess-c', cwd: 'D:\\proj\\my-project', type: 'user', message: { role: 'user', content: 'hi' } },
    ]);
    const res = importLocalSessions(db);
    expect(res.imported).toBe(1);
    const c = listSessions(db)[0];
    expect(c.title).toBe('my-project');
  });

  it('过滤内部内容 / 系统提示,不渲染成用户气泡', () => {
    const db = openDb(':memory:');
    writeTranscript('sess-d', 'proj', [
      { sessionId: 'sess-d', cwd: 'D:\\proj', type: 'user', message: { role: 'user', content: '<system-reminder>x</system-reminder>' } },
      { sessionId: 'sess-d', cwd: 'D:\\proj', type: 'user', message: { role: 'user', content: 'real question' } },
    ]);
    importLocalSessions(db);
    const d = listSessions(db)[0];
    const msgs = listMessages(db, d.id, { limit: 200, offset: 0 });
    expect(msgs.total).toBe(1);
  });

  it('删除过的会话不复活(墓碑):重跑导入不会再导回来', () => {
    const db = openDb(':memory:');
    writeTranscript('sess-e', 'proj-e', [
      { sessionId: 'sess-e', cwd: 'D:\\proj-e', type: 'user', message: { role: 'user', content: 'to be deleted' } },
    ]);
    writeTranscript('sess-f', 'proj-e', [
      { sessionId: 'sess-f', cwd: 'D:\\proj-e', type: 'user', message: { role: 'user', content: 'keep me' } },
    ]);
    expect(importLocalSessions(db).imported).toBe(2);

    const e = getSessionByProviderSessionId(db, 'sess-e')!;
    expect(deleteSession(db, e.id)).toBe(true);
    expect(listSessions(db).length).toBe(1);

    // 转录文件还在磁盘上,但墓碑挡住重新导入
    const again = importLocalSessions(db);
    expect(again.imported).toBe(0);
    expect(listSessions(db).length).toBe(1);
    expect(getSessionByProviderSessionId(db, 'sess-e')).toBeUndefined();
  });
});

describe('reloadSessionTranscript · 完整重载', () => {
  it('从磁盘转录补回缺失消息,幂等,无转录返回 merged:0', async () => {
    const { openDb, createSession, updateSession, listMessages } = await import('../src/db.js');
    const { reloadSessionTranscript } = await import('../src/local-sessions.js');
    const fs = await import('node:fs');
    const os = await import('node:os');
    const path = await import('node:path');

    const home = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-reload-'));
    const projDir = path.join(home, 'projects', 'D--work-app');
    fs.mkdirSync(projDir, { recursive: true });
    const provId = 'prov-reload-1';
    fs.writeFileSync(path.join(projDir, provId + '.jsonl'), [
      JSON.stringify({ type: 'user', sessionId: provId, cwd: 'D:\work\app', message: { role: 'user', content: '丢失的提问' } }),
      JSON.stringify({ type: 'assistant', sessionId: provId, message: { role: 'assistant', content: [{ type: 'text', text: '丢失的回答' }] } }),
      '',
    ].join('\n'));

    process.env.ZCODE_CLAUDE_HOME = home;
    try {
      const db = openDb(':memory:');
      const s = createSession(db, { title: '断了' });
      updateSession(db, s.id, { providerSessionId: provId });

      const r1 = reloadSessionTranscript(db, s.id);
      expect(r1.merged).toBe(2);
      const page = listMessages(db, s.id, { limit: 10 });
      expect(page.total).toBe(2);
      expect(page.messages.map((m) => JSON.parse(m.meta).content ?? m.content)).toContain('丢失的提问');

      const r2 = reloadSessionTranscript(db, s.id);
      expect(r2.merged).toBe(0); // 幂等
      expect(listMessages(db, s.id, { limit: 10 }).total).toBe(2);

      const none = reloadSessionTranscript(db, 'no-provider');
      expect(none.merged).toBe(0);
    } finally {
      delete process.env.ZCODE_CLAUDE_HOME;
      fs.rmSync(home, { recursive: true, force: true });
    }
  });
});
