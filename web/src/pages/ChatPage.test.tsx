import { describe, test, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createZStore, type ZStore } from '../lib/store';
import { ChatPage } from './ChatPage';

class FakeSocket {
  state = 'open' as const;
  sent: unknown[] = [];
  private cbs = new Set<(ev: Record<string, unknown>) => void>();
  connect = vi.fn(async () => {});
  close = vi.fn();
  onEvent = vi.fn((cb: (ev: Record<string, unknown>) => void) => { this.cbs.add(cb); return () => this.cbs.delete(cb); });
  onStateChange = vi.fn(() => () => {});
  seedLastSeq = vi.fn();
  subscribeSession = vi.fn();
  sendChat = vi.fn();
  abort = vi.fn();
  answerPermission = vi.fn();
  emit(ev: Record<string, unknown>): void { this.cbs.forEach((cb) => cb(ev)); }
}

async function setup() {
  const api = {
    models: async () => ['default'],
    modelGroups: async () => [{ id: 'zhipu', label: '智谱 GLM', models: [{ id: 'glm-5.3-flash', label: 'GLM 5.3 Flash' }] }],
    sessions: async () => [
      { id: 's1', title: '测试会话', model: null, permissionMode: 'default', isPinned: 0, source: 'app', isRunning: false, createdAt: '', updatedAt: '' },
    ],
    createSession: async () => ({ id: 'x', title: '', model: null, permissionMode: '', isPinned: 0, source: '', isRunning: false, createdAt: '', updatedAt: '' }),
    patchSession: vi.fn(async () => {}),
    deleteSession: async () => {},
    deleteSessions: async () => ({ deleted: 0, missing: [] }),
    messages: vi.fn(async () => ({
      total: 2,
      messages: [
        { id: 'm1', sessionId: 's1', seq: 1, kind: 'text', role: 'user', content: '你好', meta: JSON.stringify({ kind: 'text', seq: 1, role: 'user', content: '你好' }), createdAt: '' },
        { id: 'm2', sessionId: 's1', seq: 2, kind: 'text', role: 'assistant', content: '你好!有什么可以帮你?', meta: JSON.stringify({ kind: 'text', seq: 2, role: 'assistant', content: '你好!有什么可以帮你?' }), createdAt: '' },
      ],
    })),
    sessionUsage: async () => null,
  };
  const socket = new FakeSocket();
  const store: ZStore = createZStore({
    makeApi: () => api as never,
    makeSocket: () => socket as never,
  });
  // 先 login:store 的 api 赋值与 WS 事件路由绑定都发生在 login 里
  await store.getState().login('http://x:5190', 'tk');
  return { api, socket, store };
}

describe('ChatPage', () => {
  test('renders history rows', async () => {
    const { store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByText('你好!有什么可以帮你?')).toBeTruthy());
    expect(screen.getByText('你好')).toBeTruthy();
  });

  test('Ctrl+Enter sends message; optimistic bubble shows 发送中', async () => {
    const { socket, store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByLabelText('消息输入')).toBeTruthy());
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('消息输入'), '帮我看看{Control>}{Enter}{/Control}');
    expect(socket.sendChat).toHaveBeenCalledWith('s1', '帮我看看', undefined);
    expect(screen.getByText('发送中')).toBeTruthy();
  });

  test('running state shows stop button; click aborts', async () => {
    const { socket, store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByLabelText('消息输入')).toBeTruthy());
    store.getState().sendChat('跑一个任务');
    const stop = await screen.findByRole('button', { name: '停止' });
    await userEvent.click(stop);
    expect(socket.abort).toHaveBeenCalledWith('s1');
  });

  test('silent period skeleton appears while running without stream', async () => {
    const { store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByLabelText('消息输入')).toBeTruthy());
    store.getState().sendChat('安静的任务');
    expect(await screen.findByText(/已送达/)).toBeTruthy();
    expect(screen.getByText(/正在思考/)).toBeTruthy();
  });

  test('stream delta replaces skeleton with streaming text', async () => {
    const { socket, store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByLabelText('消息输入')).toBeTruthy());
    store.getState().sendChat('流式任务');
    socket.emit({ kind: 'stream_delta', sessionId: 's1', content: '部分回答' });
    expect(await screen.findByText('部分回答')).toBeTruthy();
    expect(screen.queryByText(/已送达/)).toBeNull();
  });

  test('permission card allows answering with message', async () => {
    const { socket, store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByLabelText('消息输入')).toBeTruthy());
    socket.emit({ kind: 'permission_request', sessionId: 's1', requestId: 'r1', toolName: 'Bash', input: { command: 'rm -rf /tmp/x' } });
    expect(await screen.findByText(/权限请求 · Bash/)).toBeTruthy();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('留言'), '同意这个操作');
    await user.click(screen.getByRole('button', { name: '允许' }));
    expect(socket.answerPermission).toHaveBeenCalledWith('s1', 'r1', true, '同意这个操作');
  });

  test('model picker patches session model', async () => {
    const { api, store } = await setup();
    render(<ChatPage store={store} sessionId="s1" />);
    await vi.waitFor(() => expect(screen.getByRole('button', { name: /模型/ })).toBeTruthy());
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: /模型/ }));
    await user.click(await screen.findByText('GLM 5.3 Flash'));
    await vi.waitFor(() => expect((api as unknown as { patchSession: ReturnType<typeof vi.fn> }).patchSession).toHaveBeenCalledWith('s1', { model: 'glm-5.3-flash' }));
  });
});
