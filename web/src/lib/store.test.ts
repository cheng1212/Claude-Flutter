import { describe, test, expect, vi, beforeEach, afterEach } from 'vitest';
import { createZStore, loadCreds, wsUriOf, type ApiLike, type SocketLike } from './store';
import { emptyChat } from './chatState';

function makeFakeApi(): ApiLike & { calls: Record<string, number> } {
  const calls: Record<string, number> = {};
  const count = (k: string) => { calls[k] = (calls[k] ?? 0) + 1; };
  return {
    calls,
    models: vi.fn(async () => { count('models'); return ['default']; }),
    modelGroups: vi.fn(async () => { count('modelGroups'); return [{ id: 'g', label: 'G', models: [{ id: 'm1', label: 'M1' }] }]; }),
    sessions: vi.fn(async () => { count('sessions'); return [
      { id: 's1', title: '会话一', cwd: null, model: null, permissionMode: 'default', isPinned: 0, source: 'app', isRunning: false, createdAt: '', updatedAt: '2026-09-05T01:00:00Z' },
      { id: 's2', title: '会话二', cwd: null, model: 'glm-5.3-flash', permissionMode: 'default', isPinned: 1, source: 'local', isRunning: true, createdAt: '', updatedAt: '2026-09-05T02:00:00Z' },
    ]; }),
    createSession: vi.fn(async (input: { title?: string }) => { count('createSession'); return { id: 'new-1', title: input.title ?? '新会话', cwd: null, model: null, permissionMode: 'default', isPinned: 0, source: 'app', isRunning: false, createdAt: '', updatedAt: '' }; }),
    patchSession: vi.fn(async () => { count('patchSession'); }),
    deleteSession: vi.fn(async () => { count('deleteSession'); }),
    deleteSessions: vi.fn(async () => { count('deleteSessions'); return { deleted: 1, missing: [] }; }),
    messages: vi.fn(async (_id: string) => {
      count('messages');
      return {
        total: 2,
        messages: [
          { id: 'm2', sessionId: 's1', seq: 2, kind: 'text', role: 'assistant', content: '回答', meta: JSON.stringify({ kind: 'text', seq: 2, role: 'assistant', content: '回答' }), createdAt: '' },
          { id: 'm1', sessionId: 's1', seq: 1, kind: 'text', role: 'user', content: '提问', meta: JSON.stringify({ kind: 'text', seq: 1, role: 'user', content: '提问' }), createdAt: '' },
        ],
      };
    }),
    sessionUsage: vi.fn(async () => null),
  };
}

class FakeSocket implements SocketLike {
  state = 'idle' as 'idle' | 'connecting' | 'open' | 'reconnecting' | 'closed';
  sent: unknown[] = [];
  private eventCbs = new Set<(ev: Record<string, unknown>) => void>();
  stateCbs = new Set<() => void>();
  connect = vi.fn(async () => { this.state = 'open'; this.stateCbs.forEach((cb) => cb()); });
  close = vi.fn(() => { this.state = 'closed'; });
  onEvent = vi.fn((cb: (ev: Record<string, unknown>) => void) => {
    this.eventCbs.add(cb);
    return () => this.eventCbs.delete(cb);
  });
  onStateChange = vi.fn((cb: () => void) => { this.stateCbs.add(cb); return () => this.stateCbs.delete(cb); });
  seedLastSeq = vi.fn();
  subscribeSession = vi.fn((id: string) => { this.sent.push({ type: 'chat.subscribe', sessionId: id }); });
  sendChat = vi.fn((id: string, content: string) => { this.sent.push({ type: 'chat.send', id, content }); });
  abort = vi.fn((id: string) => { this.sent.push({ type: 'chat.abort', id }); });
  answerPermission = vi.fn((id: string, requestId: string, allow: boolean, message?: string) => {
    this.sent.push({ type: 'chat.permission-response', id, requestId, allow, message });
  });
  poke = vi.fn();
  emit(ev: Record<string, unknown>): void { this.eventCbs.forEach((cb) => cb(ev)); }
  setState(s: 'open' | 'reconnecting' | 'closed'): void {
    this.state = s;
    this.stateCbs.forEach((cb) => cb());
  }
}

function setup() {
  const api = makeFakeApi();
  const socket = new FakeSocket();
  const store = createZStore({
    makeApi: () => api as unknown as ApiLike,
    makeSocket: () => socket,
  });
  return { api, socket, store };
}

describe('wsUriOf / creds', () => {
  test('http→ws, https→wss', () => {
    expect(wsUriOf('http://192.168.1.5:5190')).toBe('ws://192.168.1.5:5190');
    expect(wsUriOf('https://example.com')).toBe('wss://example.com');
  });
});

describe('createZStore', () => {
  beforeEach(() => vi.useFakeTimers());
  afterEach(() => { vi.useRealTimers(); localStorage.clear(); });

  test('login loads models and sessions, phase becomes ready', async () => {
    const { api, store } = setup();
    await store.getState().login('http://192.168.1.5:5190', 'tk');
    expect(store.getState().phase).toBe('ready');
    expect(store.getState().models).toEqual(['default']);
    expect(store.getState().sessions).toHaveLength(2);
    expect(api.calls.models).toBe(2); // 1 次=登录探针校验 token,1 次=loadModels
    expect(api.calls.sessions).toBe(1);
  });

  test('wrong token (401): stays on login, creds not saved, friendly error', async () => {
    const { api, store } = setup();
    api.models = vi.fn(async () => {
      throw Object.assign(new Error('Unauthorized'), { status: 401 });
    });
    await expect(store.getState().login('http://x:5190', 'bad'))
      .rejects.toThrow('访问令牌不正确');
    expect(store.getState().phase).toBe('login');
    expect(loadCreds()).toBeNull();
  });

  test('server unreachable: stays on login with connection error', async () => {
    const { api, store } = setup();
    api.models = vi.fn(async () => { throw new Error('网络错误: fetch failed'); });
    await expect(store.getState().login('http://x:5190', 'tk'))
      .rejects.toThrow('连不上服务器');
    expect(store.getState().phase).toBe('login');
    expect(loadCreds()).toBeNull();
  });

  test('in-session 401 auto-logs out back to login with notice', async () => {
    const { api, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    expect(store.getState().phase).toBe('ready');
    api.sessions = vi.fn(async () => {
      throw Object.assign(new Error('Unauthorized'), { status: 401 });
    });
    await store.getState().refreshSessions();
    expect(store.getState().phase).toBe('login');
    expect(loadCreds()).toBeNull();
    expect(store.getState().notice).toContain('登录已失效');
  });

  test('manual logout returns to clean login state (notice cleared)', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    store.getState().logout();
    expect(store.getState().phase).toBe('login');
    expect(loadCreds()).toBeNull();
    expect(store.getState().notice).toBeNull();
  });

  test('abort while socket down sets honest error instead of silent swallow', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    socket.abort = vi.fn(() => { throw new Error('未连接'); });
    store.getState().abort();
    expect(store.getState().error).toContain('停止失败');
  });

  test('connect failure sets error and retries until success', async () => {
    const { socket, store } = setup();
    let attempts = 0;
    socket.connect = vi.fn(async () => {
      attempts++;
      if (attempts < 3) throw new Error('net down');
      socket.state = 'open';
      socket.stateCbs.forEach((cb) => cb());
    });
    await store.getState().login('http://x:5190', 'tk');
    expect(store.getState().error).toContain('net down');
    await vi.advanceTimersByTimeAsync(2000); // 第 2 次仍失败
    expect(store.getState().error).toContain('net down');
    await vi.advanceTimersByTimeAsync(2000); // 第 3 次成功
    expect(store.getState().error).toBeNull();
    expect(attempts).toBe(3);
  });

  test('openSession rebuilds rows by row-seq order, seeds and subscribes', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    const st = store.getState();
    expect(st.currentSessionId).toBe('s1');
    expect(st.historyLoading).toBe(false);
    expect(st.chat.rows.map((r) => (r as { content: string }).content)).toEqual(['提问', '回答']);
    expect(st.chat.lastSeq).toBe(2);
    expect(socket.seedLastSeq).toHaveBeenCalledWith('s1', 2);
    expect(socket.subscribeSession).toHaveBeenCalledWith('s1');
  });

  test('sendChat optimistic row, socket send, echo promotes', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    store.getState().sendChat('  你好  ');
    expect(socket.sendChat).toHaveBeenCalledWith('s1', '你好', undefined);
    expect(store.getState().chat.rows.at(-1)).toMatchObject({ kind: 'user', content: '你好', pending: true });
    socket.emit({ kind: 'text', seq: 3, role: 'user', content: '你好', sessionId: 's1' });
    expect(store.getState().chat.rows.at(-1)).toMatchObject({ kind: 'user', pending: false });
  });

  test('sendChat socket failure rolls back and sets error', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    socket.sendChat = vi.fn(() => { throw new Error('未连接'); });
    store.getState().sendChat('x');
    expect(store.getState().chat.rows.filter((r) => r.kind === 'user' && r.pending)).toHaveLength(0);
    expect(store.getState().error).toContain('发送失败');
  });

  test('events for other sessions are ignored', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    const before = store.getState().chat;
    socket.emit({ kind: 'text', seq: 9, role: 'assistant', content: '别的会话', sessionId: 's2' });
    expect(store.getState().chat).toBe(before);
  });

  test('sessions_dirty debounce collapses to one sessions call', async () => {
    const { api, socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    const before = api.calls.sessions;
    socket.emit({ kind: 'sessions_dirty', sessionId: 's1' });
    socket.emit({ kind: 'sessions_dirty', sessionId: 's1' });
    socket.emit({ kind: 'sessions_dirty', sessionId: 's2' });
    await vi.advanceTimersByTimeAsync(250);
    expect(api.calls.sessions).toBe(before + 1);
  });

  test('complete triggers sessions refresh', async () => {
    const { api, socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    const before = api.calls.sessions;
    socket.emit({ kind: 'complete', seq: 10, sessionId: 's1', exitCode: 0, aborted: false });
    await vi.advanceTimersByTimeAsync(300);
    expect(api.calls.sessions).toBeGreaterThan(before);
  });

  test('RUN_IN_PROGRESS rolls back optimistic row and keeps running', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    store.getState().sendChat('x');
    socket.emit({ kind: 'error', seq: 99, content: 'RUN_IN_PROGRESS', sessionId: 's1' });
    const s = store.getState().chat;
    expect(s.rows.filter((r) => r.kind === 'user' && r.pending)).toHaveLength(0); // 历史里已确认的用户行不算
    expect(s.running).toBe(true);
  });

  test('deleteSessions clears chat when current session deleted', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    await store.getState().deleteSessions(['s1']);
    expect(store.getState().currentSessionId).toBeNull();
    expect(store.getState().chat).toEqual(emptyChat());
  });

  test('answerPermission delegates with cleared panel', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().openSession('s1');
    socket.emit({ kind: 'permission_request', requestId: 'r1', toolName: 'Bash', input: {}, sessionId: 's1' });
    expect(store.getState().chat.pendingPermission).toBeTruthy();
    store.getState().answerPermission('r1', true, 'go');
    expect(socket.answerPermission).toHaveBeenCalledWith('s1', 'r1', true, 'go');
    expect(store.getState().chat.pendingPermission).toBeUndefined();
  });

  test('wsState mirrors socket state changes', async () => {
    const { socket, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    socket.setState('reconnecting');
    expect(store.getState().wsState).toBe('reconnecting');
    socket.setState('open');
    expect(store.getState().wsState).toBe('open');
  });
});
