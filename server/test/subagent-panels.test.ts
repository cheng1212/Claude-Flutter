// 子代理虚拟会话:磁盘转录(subagents/agent-*.jsonl + meta.json)→ 列表与只读消息。
// 让子代理以"只读会话"的姿态进面板/列表,不入 sessions 表。
import { beforeEach, describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

let home = '';

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-subagents-'));
  process.env.ZCODE_CLAUDE_HOME = home;
});

function seedSession(provId: string): void {
  const proj = path.join(home, 'projects', 'D--work-app');
  fs.mkdirSync(proj, { recursive: true });
  fs.writeFileSync(path.join(proj, provId + '.jsonl'), [
    JSON.stringify({ sessionId: provId, cwd: 'D:\\work\\app', type: 'user', message: { role: 'user', content: 'hi' } }),
    '',
  ].join('\n'), 'utf8');
}

describe('子代理虚拟会话', () => {
  it('listSubagents:读 meta 元数据,按 mtime 倒序;无转录会话为空', async () => {
    const { openDb, createSession, updateSession } = await import('../src/db.js');
    const { listSubagents } = await import('../src/local-sessions.js');
    const db = openDb(':memory:');
    const s = createSession(db, { title: '父' });
    updateSession(db, s.id, { providerSessionId: 'prov-sub-1' });

    // 没有磁盘文件 → 空
    expect(listSubagents(db, s.id)).toEqual([]);

    seedSession('prov-sub-1');
    const dir = path.join(home, 'projects', 'D--work-app', 'prov-sub-1', 'subagents');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'agent-aaa.jsonl'), [
      JSON.stringify({ parentUuid: null, isSidechain: true, agentId: 'aaa', type: 'user', message: { role: 'user', content: '子任务提示' } }),
      JSON.stringify({ sessionId: 'prov-sub-1', model: 'nvidia/nemotron-3-ultra', type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: '子代理回答' }] } }),
      '',
    ].join('\n'), 'utf8');
    fs.writeFileSync(path.join(dir, 'agent-aaa.meta.json'), JSON.stringify({
      agentType: 'general-purpose', description: '搜集资料', toolUseId: 'tool-1', spawnDepth: 1,
    }));
    fs.writeFileSync(path.join(dir, 'agent-bbb.jsonl'), '', 'utf8');

    const rows = listSubagents(db, s.id);
    expect(rows.length).toBe(2);
    const aaa = rows.find((r: { agentId: string }) => r.agentId === 'agent-aaa');
    expect(aaa).toMatchObject({
      agentId: 'agent-aaa', agentType: 'general-purpose', description: '搜集资料',
      toolUseId: 'tool-1', spawnDepth: 1, model: 'nvidia/nemotron-3-ultra',
    });
    expect((aaa as { bytes: number }).bytes).toBeGreaterThan(0);
    // 转录里没有 model 字段 → 空串(面板显示"继承主模型")
    const bbb = rows.find((r: { agentId: string }) => r.agentId === 'agent-bbb');
    expect((bbb as { model: string }).model).toBe('');
  });

  it('readSubagentTranscript:转录行还原为消息事件,seq 按行序;路径穿越给空', async () => {
    const { openDb, createSession, updateSession } = await import('../src/db.js');
    const { listSubagents, readSubagentTranscript } = await import('../src/local-sessions.js');
    const db = openDb(':memory:');
    const s = createSession(db, { title: '父' });
    updateSession(db, s.id, { providerSessionId: 'prov-sub-2' });
    seedSession('prov-sub-2');
    const dir = path.join(home, 'projects', 'D--work-app', 'prov-sub-2', 'subagents');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'agent-ccc.jsonl'), [
      JSON.stringify({ parentUuid: null, isSidechain: true, agentId: 'ccc', type: 'user', message: { role: 'user', content: '子任务提示' } }),
      JSON.stringify({ sessionId: 'prov-sub-2', type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: '子代理回答' }] } }),
      '',
    ].join('\n'), 'utf8');

    const out = readSubagentTranscript(db, s.id, 'agent-ccc');
    expect(out.map((m: { kind: string; seq: number }) => [m.kind, m.seq])).toEqual([
      ['text', 1], ['text', 2],
    ]);
    expect(out[0]).toMatchObject({ kind: 'text', role: 'user', content: '子任务提示' });
    expect(out[1]).toMatchObject({ kind: 'text', role: 'assistant', content: '子代理回答' });

    expect(readSubagentTranscript(db, s.id, '..%2fevil')).toEqual([]);
    expect(readSubagentTranscript(db, s.id, 'agent-missing')).toEqual([]);
    const orphan = createSession(db, { title: '没转录' });
    updateSession(db, orphan.id, { providerSessionId: 'no-such' });
    expect(listSubagents(db, orphan.id)).toEqual([]);
  });
});
