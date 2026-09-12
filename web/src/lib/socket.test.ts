import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { ZSocket, ZSocketError, type ZChannel } from './socket';

class FakeChannel implements ZChannel {
  sent: unknown[] = [];
  closed = false;
  private dataCbs = new Set<(m: Record<string, unknown>) => void>();
  private closeCbs = new Set<() => void>();

  send(data: unknown): void { this.sent.push(data); }
  close(): void { this.closed = true; }
  onData(cb: (m: Record<string, unknown>) => void): () => void {
    this.dataCbs.add(cb); return () => this.dataCbs.delete(cb);
  }
  onClose(cb: () => void): () => void {
    this.closeCbs.add(cb); return () => this.closeCbs.delete(cb);
  }
  receive(msg: Record<string, unknown>): void { this.dataCbs.forEach((cb) => cb(msg)); }
  simulateClose(): void { this.closeCbs.forEach((cb) => cb()); }
}

function lastSent(ch: FakeChannel): Record<string, unknown> {
  return ch.sent.at(-1) as Record<string, unknown>;
}

/** 连接并等 auth 帧发出(fake timers 下微任务需显式推进),再回 authenticated。 */
async function connectOpen(ch: FakeChannel, sock: ZSocket): Promise<void> {
  const p = sock.connect();
  await vi.advanceTimersByTimeAsync(0);
  expect(ch.sent[0]).toEqual({ type: 'auth', token: 'tk' });
  ch.receive({ kind: 'authenticated' });
  await p;
  expect(sock.state).toBe('open');
}

describe('ZSocket', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => vi.useRealTimers());

  test('sends auth with token first and resolves on authenticated', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    await connectOpen(ch, sock);
  });

  test('rejects and closes channel on non-authenticated reply', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    const p = sock.connect().catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    ch.receive({ kind: 'error', content: 'unauthorized' });
    const err = await p;
    expect(err).toBeInstanceOf(ZSocketError);
    expect(ch.closed).toBe(true);
  });

  test('handshake times out after 8s', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    const p = sock.connect().catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(0);
    await vi.advanceTimersByTimeAsync(8001);
    expect(await p).toBeInstanceOf(ZSocketError);
    expect(ch.closed).toBe(true);
  });

  test('resubscribes sessions with lastSeq after open and forwards events', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    sock.seedLastSeq('s1', 7);
    sock.subscribeSession('s1');
    await connectOpen(ch, sock);
    expect(lastSent(ch)).toEqual({
      type: 'chat.subscribe',
      sessions: [{ sessionId: 's1', lastSeq: 7 }],
    });
    const seen: Record<string, unknown>[] = [];
    sock.onEvent((e) => seen.push(e));
    ch.receive({ kind: 'text', sessionId: 's1', seq: 8 });
    expect(seen).toHaveLength(1);
  });

  test('tracks seq from events and replay members, never regresses', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    await connectOpen(ch, sock);
    ch.receive({ kind: 'replay', sessionId: 's1', events: [{ kind: 'text', seq: 3 }, { kind: 'text', seq: 4 }] });
    ch.receive({ kind: 'text', sessionId: 's1', seq: 2 }); // 旧 seq 不回退
    sock.subscribeSession('s1'); // 触发 resubscribe,验证 lastSeq=4
    expect(lastSent(ch)).toEqual({ type: 'chat.subscribe', sessions: [{ sessionId: 's1', lastSeq: 4 }] });
  });

  test('seedLastSeq only moves forward', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    sock.seedLastSeq('s1', 5);
    sock.seedLastSeq('s1', 3);
    sock.subscribeSession('s1');
    await connectOpen(ch, sock);
    expect(lastSent(ch)).toEqual({ type: 'chat.subscribe', sessions: [{ sessionId: 's1', lastSeq: 5 }] });
  });

  test('sendChat omits default model/permissionMode from options', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    await connectOpen(ch, sock);
    sock.sendChat('s1', '你好', { model: 'default', permissionMode: 'bypassPermissions' });
    expect(lastSent(ch)).toEqual({
      type: 'chat.send', sessionId: 's1', content: '你好',
      options: { permissionMode: 'bypassPermissions' },
    });
    sock.sendChat('s1', '无选项');
    expect(lastSent(ch)).toEqual({ type: 'chat.send', sessionId: 's1', content: '无选项' });
  });

  test('answerPermission and abort send sessionId', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    await connectOpen(ch, sock);
    sock.answerPermission('s1', 'r1', true, 'ok');
    expect(lastSent(ch)).toMatchObject({ type: 'chat.permission-response', sessionId: 's1', requestId: 'r1', allow: true, message: 'ok' });
    sock.abort('s1');
    expect(lastSent(ch)).toEqual({ type: 'chat.abort', sessionId: 's1' });
  });

  test('sends ping periodically while open', async () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch, pingEveryMs: 1000 });
    await connectOpen(ch, sock);
    await vi.advanceTimersByTimeAsync(3500);
    const pings = ch.sent.filter((m) => (m as { type: string }).type === 'ping');
    expect(pings.length).toBe(3);
  });

  test('reconnects with exponential backoff capped at max', async () => {
    const ch0 = new FakeChannel();
    let calls = 0;
    const factory = async (): Promise<ZChannel> => {
      calls++;
      if (calls === 1) return ch0;
      throw new Error('net down');
    };
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory, backoffBaseMs: 1000, maxBackoffMs: 4000 });
    await connectOpen(ch0, sock);

    ch0.simulateClose(); // 断线:退避 1s → 2s → 4s(封顶)→ 4s …
    expect(sock.state).toBe('reconnecting');

    await vi.advanceTimersByTimeAsync(999);
    expect(calls).toBe(1);
    await vi.advanceTimersByTimeAsync(1);
    expect(calls).toBe(2);

    await vi.advanceTimersByTimeAsync(1999);
    expect(calls).toBe(2);
    await vi.advanceTimersByTimeAsync(1);
    expect(calls).toBe(3);

    await vi.advanceTimersByTimeAsync(3999);
    expect(calls).toBe(3);
    await vi.advanceTimersByTimeAsync(1);
    expect(calls).toBe(4);

    await vi.advanceTimersByTimeAsync(3999);
    expect(calls).toBe(4);
    await vi.advanceTimersByTimeAsync(1);
    expect(calls).toBe(5); // 已封顶 4s
  });

  test('dial times out after 10s when the factory hangs', async () => {
    const sock = new ZSocket({
      uri: 'ws://x:5190', token: 'tk',
      factory: () => new Promise<ZChannel>(() => { /* 永不 settle:模拟 TCP 悬挂 */ }),
    });
    const p = sock.connect().catch((e: unknown) => e);
    await vi.advanceTimersByTimeAsync(9_999);
    expect(sock.state).toBe('connecting');
    await vi.advanceTimersByTimeAsync(1);
    const err = await p;
    expect(err).toBeInstanceOf(ZSocketError);
    expect(sock.failure).toContain('连接超时');
  });

  test('poke() during backoff skips the wait and dials immediately', async () => {
    const ch0 = new FakeChannel();
    let calls = 0;
    const factory = async (): Promise<ZChannel> => {
      calls++;
      if (calls === 1) return ch0;
      throw new Error('net down');
    };
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory, backoffBaseMs: 1000 });
    await connectOpen(ch0, sock);

    ch0.simulateClose(); // 进入 1s 退避
    expect(sock.state).toBe('reconnecting');

    sock.poke(); // 睡眠唤醒:跳过剩余退避立即拨号
    await vi.advanceTimersByTimeAsync(0);
    expect(calls).toBe(2);

    await vi.advanceTimersByTimeAsync(999); // 原 1s 退避计时器已被清掉
    expect(calls).toBe(2);

    await vi.advanceTimersByTimeAsync(1001); // poke 后 onDown 重新按 2s 退避接管
    expect(calls).toBe(3);
  });

  test('close() stops reconnection permanently', async () => {
    const ch0 = new FakeChannel();
    let calls = 0;
    const factory = async (): Promise<ZChannel> => {
      calls++;
      if (calls === 1) return ch0;
      throw new Error('net down');
    };
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory });
    await connectOpen(ch0, sock);
    sock.close();
    expect(sock.state).toBe('closed');
    ch0.simulateClose();
    await vi.advanceTimersByTimeAsync(60000);
    expect(calls).toBe(1);
  });

  test('send throws ZSocketError when not open', () => {
    const ch = new FakeChannel();
    const sock = new ZSocket({ uri: 'ws://x:5190', token: 'tk', factory: async () => ch });
    expect(() => sock.abort('s1')).toThrow(ZSocketError);
  });
});
