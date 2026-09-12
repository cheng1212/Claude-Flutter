import { describe, test, expect } from 'vitest';
import {
  applyEvent, applyReplay, applyLocalUser, applyPermissionAnswer, rollbackLocalUser,
  emptyChat, K_INTERRUPTED, contextTokens,
} from './chatState';

const text = (seq: number, content: string, role = 'assistant') =>
  ({ kind: 'text', seq, role, content });

describe('applyEvent · seq 去重', () => {
  test('drops events with seq <= lastSeq', () => {
    let s = applyEvent(emptyChat(), text(1, 'a'));
    s = applyEvent(s, text(1, 'a')); // 同 seq 重放
    expect(s.rows).toHaveLength(1);
    expect(s.lastSeq).toBe(1);
  });

  test('accepts out-of-order higher seq and advances lastSeq', () => {
    let s = applyEvent(emptyChat(), text(3, 'c'));
    expect(s.lastSeq).toBe(3);
    s = applyEvent(s, text(5, 'e'));
    expect(s.lastSeq).toBe(5);
  });
});

describe('applyEvent · 用户消息回显', () => {
  test('promotes pending user row on echo without duplicating', () => {
    let s = applyLocalUser(emptyChat(), 'hi');
    expect(s.rows).toHaveLength(1);
    expect(s.rows[0]).toMatchObject({ kind: 'user', content: 'hi', pending: true });
    expect(s.running).toBe(true);

    s = applyEvent(s, { kind: 'text', seq: 1, role: 'user', content: 'hi' });
    expect(s.rows).toHaveLength(1);
    expect(s.rows[0]).toMatchObject({ kind: 'user', content: 'hi', pending: false });
  });

  test('appends user row when no pending matches', () => {
    const s = applyEvent(emptyChat(), { kind: 'text', seq: 1, role: 'user', content: 'hi' });
    expect(s.rows).toHaveLength(1);
    expect(s.rows[0]).toMatchObject({ kind: 'user', pending: false });
  });
});

describe('applyEvent · 流式与文本', () => {
  test('accumulates stream_delta into streamingText and sets running', () => {
    let s = applyEvent(emptyChat(), { kind: 'stream_delta', content: 'he' });
    s = applyEvent(s, { kind: 'stream_delta', content: 'llo' });
    expect(s.streamingText).toBe('hello');
    expect(s.running).toBe(true);
  });

  test('accumulates thinking_delta into streamingThinking', () => {
    let s = applyEvent(emptyChat(), { kind: 'thinking_delta', content: '思' });
    s = applyEvent(s, { kind: 'thinking_delta', content: '考' });
    expect(s.streamingThinking).toBe('思考');
  });

  test('assistant text appends TextRow and clears streamingText', () => {
    let s = applyEvent(emptyChat(), { kind: 'stream_delta', content: 'partial' });
    s = applyEvent(s, text(1, 'final'));
    expect(s.streamingText).toBeUndefined();
    expect(s.rows.at(-1)).toMatchObject({ kind: 'text', content: 'final' });
  });

  test('thinking event appends ThinkingRow and clears streamingThinking', () => {
    let s = applyEvent(emptyChat(), { kind: 'thinking_delta', content: 't' });
    s = applyEvent(s, { kind: 'thinking', seq: 1, content: 'full thought' });
    expect(s.streamingThinking).toBeUndefined();
    expect(s.rows.at(-1)).toMatchObject({ kind: 'thinking', content: 'full thought' });
  });
});

describe('applyEvent · 工具卡', () => {
  const toolUse = { kind: 'tool_use', seq: 1, toolId: 't1', toolName: 'Bash', toolInput: { command: 'ls' } };

  test('tool_use appends ToolRow with input and startedAt', () => {
    const s = applyEvent(emptyChat(), toolUse);
    expect(s.rows).toHaveLength(1);
    expect(s.rows[0]).toMatchObject({ kind: 'tool', toolId: 't1', toolName: 'Bash' });
    expect(typeof (s.rows[0] as { startedAt?: number }).startedAt).toBe('number');
  });

  test('tool_result attaches to matching open tool row', () => {
    let s = applyEvent(emptyChat(), toolUse);
    s = applyEvent(s, { kind: 'tool_result', seq: 2, toolId: 't1', content: 'out', isError: false });
    expect(s.rows[0]).toMatchObject({ kind: 'tool', result: { content: 'out', isError: false } });
  });

  test('tool_result for unknown toolId keeps rows unchanged', () => {
    const s = applyEvent(emptyChat(), { kind: 'tool_result', seq: 1, toolId: 'nope', content: 'x', isError: false });
    expect(s.rows).toHaveLength(0);
    expect(s.lastSeq).toBe(1);
  });
});

describe('applyEvent · complete 与悬空工具收尾', () => {
  test('complete stops running, clears streams and permission, closes dangling tools', () => {
    let s = applyLocalUser(emptyChat(), 'go');
    s = applyEvent(s, { kind: 'tool_use', seq: 1, toolId: 't1', toolName: 'Bash', toolInput: {} });
    s = applyEvent(s, { kind: 'permission_request', toolName: 'Bash', input: {} });
    s = applyEvent(s, { kind: 'complete', seq: 2, exitCode: 0, aborted: false });
    expect(s.running).toBe(false);
    expect(s.pendingPermission).toBeUndefined();
    const tool = s.rows.find((r) => r.kind === 'tool');
    expect(tool).toMatchObject({ kind: 'tool', result: { content: K_INTERRUPTED, isError: true } });
  });

  test('late real tool_result overwrites interrupted mark', () => {
    let s = applyEvent(emptyChat(), { kind: 'tool_use', seq: 1, toolId: 't1', toolName: 'Bash', toolInput: {} });
    s = applyEvent(s, { kind: 'complete', seq: 2, exitCode: 0, aborted: false });
    s = applyEvent(s, { kind: 'tool_result', seq: 3, toolId: 't1', content: 'real out', isError: false });
    expect(s.rows[0]).toMatchObject({ kind: 'tool', result: { content: 'real out', isError: false } });
  });
});

describe('applyEvent · 权限审批', () => {
  test('permission_request sets pendingPermission and bypasses seq dedupe', () => {
    let s = applyEvent(emptyChat(), text(5, 'a'));
    s = applyEvent(s, { kind: 'permission_request', seq: 2, requestId: 'r1', toolName: 'Bash', input: { command: 'rm' } });
    expect(s.pendingPermission).toMatchObject({ requestId: 'r1', toolName: 'Bash' });
  });

  test('applyPermissionAnswer clears pending permission', () => {
    let s = applyEvent(emptyChat(), { kind: 'permission_request', requestId: 'r1', toolName: 'Bash', input: {} });
    s = applyPermissionAnswer(s);
    expect(s.pendingPermission).toBeUndefined();
  });
});

describe('applyEvent · 错误路径', () => {
  test('RUN_IN_PROGRESS rolls back pending row, keeps running, appends hint error', () => {
    let s = applyEvent(emptyChat(), text(1, 'old'));
    s = applyLocalUser(s, 'new');
    s = applyEvent(s, { kind: 'error', seq: 2, content: 'RUN_IN_PROGRESS' });
    expect(s.rows.filter((r) => r.kind === 'user')).toHaveLength(0);
    expect(s.running).toBe(true);
    expect(s.rows.at(-1)?.kind).toBe('error');
    expect((s.rows.at(-1) as { content: string }).content).toContain('上一轮仍在运行');
  });

  test('generic error stops running and appends ErrorRow', () => {
    let s = applyLocalUser(emptyChat(), 'x');
    s = applyEvent(s, { kind: 'error', seq: 1, content: 'boom' });
    expect(s.running).toBe(false);
    expect(s.rows.at(-1)).toMatchObject({ kind: 'error', content: 'boom' });
  });
});

describe('applyEvent · subscribed / usage', () => {
  test('subscribed sets running from isProcessing without raising lastSeq', () => {
    let s = applyEvent(emptyChat(), text(7, 'a'));
    s = applyEvent(s, { kind: 'subscribed', sessionId: 'x', isProcessing: true, lastSeq: 99 });
    expect(s.running).toBe(true);
    expect(s.lastSeq).toBe(7); // 不抬:防 replay 被去重整批丢弃
    s = applyEvent(s, { kind: 'subscribed', sessionId: 'x', isProcessing: false });
    expect(s.running).toBe(false);
  });

  test('subscribed(false) closes dangling tools', () => {
    let s = applyEvent(emptyChat(), { kind: 'tool_use', seq: 1, toolId: 't1', toolName: 'Bash', toolInput: {} });
    s = applyEvent(s, { kind: 'subscribed', isProcessing: false });
    expect(s.rows[0]).toMatchObject({ kind: 'tool', result: { content: K_INTERRUPTED, isError: true } });
  });

  test('usage event stores usage info', () => {
    const s = applyEvent(emptyChat(), {
      kind: 'usage', seq: 1, inputTokens: 10, outputTokens: 5,
      cacheReadInputTokens: 100, cacheCreationInputTokens: 0,
      totalCostUsd: 0.01, durationMs: 800, numTurns: 1, contextWindow: 200000, maxOutputTokens: 8192,
    });
    expect(s.usage).toMatchObject({ inputTokens: 10 });
    expect(contextTokens(s.usage!)).toBe(110);
  });
});

describe('组合函数', () => {
  test('applyReplay applies events in order', () => {
    const s = applyReplay(emptyChat(), [text(1, 'a'), text(2, 'b')]);
    expect(s.rows).toHaveLength(2);
    expect(s.lastSeq).toBe(2);
  });

  test('rollbackLocalUser removes trailing pending row only', () => {
    let s = applyEvent(emptyChat(), text(1, 'kept'));
    s = applyLocalUser(s, 'pending-1');
    s = applyLocalUser(s, 'pending-2');
    s = rollbackLocalUser(s);
    expect(s.rows).toHaveLength(2);
    expect(s.rows.at(-1)).toMatchObject({ kind: 'user', content: 'pending-1', pending: true });
  });

  test('unknown kind with seq advances lastSeq only', () => {
    const s = applyEvent(emptyChat(), { kind: 'sessions_dirty' });
    expect(s).toEqual(emptyChat());
    const s2 = applyEvent(emptyChat(), { kind: 'mystery', seq: 4 });
    expect(s2.lastSeq).toBe(4);
    expect(s2.rows).toHaveLength(0);
  });
  test('createdAt: 本地乐观行记录时刻,回显保留,助手行取事件值', () => {
    let s = applyLocalUser(emptyChat(), '你好');
    const u0 = s.rows[0];
    if (u0.kind !== 'user') throw new Error('expect user row');
    expect(typeof u0.createdAt).toBe('string');
    const before = u0.createdAt;
    // 服务器回显不带 createdAt:沿用本地时刻
    s = applyEvent(s, { kind: 'text', role: 'user', content: '你好', seq: 1 });
    const u1 = s.rows[0];
    if (u1.kind !== 'user') throw new Error('expect user row');
    expect(u1.pending).toBe(false);
    expect(u1.createdAt).toBe(before);
    // 助手行:取事件里的 createdAt(有则显,无则不显)
    s = applyEvent(s, { kind: 'text', content: '回复', seq: 2, createdAt: '2026-09-13T08:30:00Z' });
    const t = s.rows[1];
    if (t.kind !== 'text') throw new Error('expect text row');
    expect(t.createdAt).toBe('2026-09-13T08:30:00Z');
    s = applyEvent(s, { kind: 'text', content: '回复2', seq: 3 });
    const t2 = s.rows[2];
    if (t2.kind !== 'text') throw new Error('expect text row');
    expect(t2.createdAt).toBeUndefined();
  });
});
