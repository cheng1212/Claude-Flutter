import { describe, test, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createZStore, type ZStore, type ApiLike } from '../lib/store';
import { SessionsPage } from './SessionsPage';

function setup() {
  const api = {
    models: async () => ['default', 'glm-5.3-flash'],
    modelGroups: async () => [{ id: 'zhipu', label: '智谱 GLM', models: [{ id: 'glm-5.3-flash', label: 'GLM 5.3 Flash' }] }],
    sessions: async () => [
      { id: 's1', title: '普通会话', model: null, permissionMode: 'default', isPinned: 0, source: 'app', isRunning: false, createdAt: '2026-09-05T01:00:00Z', updatedAt: '2026-09-05T01:00:00Z' },
      { id: 's2', title: '运行中的会话', model: 'glm-5.3-flash', permissionMode: 'default', isPinned: 0, source: 'local', isRunning: true, createdAt: '', updatedAt: '2026-09-05T02:00:00Z' },
    ],
    createSession: vi.fn(async (input: { title?: string; model?: string }) => ({
      id: 'new', title: input.title ?? '新会话', cwd: null, model: input.model ?? null, permissionMode: 'default',
      isPinned: 0, source: 'app', isRunning: false, createdAt: '', updatedAt: '',
    })),
    patchSession: vi.fn(async () => {}),
    deleteSession: vi.fn(async () => {}),
    deleteSessions: vi.fn(async () => ({ deleted: 1, missing: [] })),
    messages: async () => ({ total: 0, messages: [] }),
    sessionUsage: async () => null,
  };
  const socket = {
    state: 'open' as const,
    connect: async () => {},
    close: () => {},
    onEvent: () => () => {},
    onStateChange: () => () => {},
    seedLastSeq: () => {},
    subscribeSession: () => {},
    sendChat: () => {},
    abort: () => {},
    answerPermission: () => {},
  };
  const store: ZStore = createZStore({
    makeApi: () => api as unknown as ApiLike,
    makeSocket: () => socket as never,
  });
  return { api, store };
}

describe('SessionsPage', () => {
  test('renders sessions with badges and calls onOpen on click', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().refreshSessions();
    const onOpen = vi.fn();
    render(<SessionsPage store={store} onOpen={onOpen} />);
    expect(screen.getByText('普通会话')).toBeTruthy();
    expect(screen.getByText('运行中')).toBeTruthy();
    expect(screen.getByText('本地')).toBeTruthy();
    await userEvent.click(screen.getByText('普通会话'));
    expect(onOpen).toHaveBeenCalledWith('s1');
  });

  test('creates session via dialog and opens it', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().refreshSessions();
    const onOpen = vi.fn();
    render(<SessionsPage store={store} onOpen={onOpen} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: '新建会话' }));
    await user.type(screen.getByLabelText('标题'), '建站计划');
    await user.click(screen.getByRole('button', { name: '开始' }));
    await vi.waitFor(() => expect(onOpen).toHaveBeenCalledWith('new'));
  });

  test('pin action calls patchSession', async () => {
    const { api, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().refreshSessions();
    render(<SessionsPage store={store} onOpen={() => {}} />);
    await userEvent.click(screen.getByRole('button', { name: '置顶 s1' }));
    await vi.waitFor(() => expect((api as unknown as { patchSession: ReturnType<typeof vi.fn> }).patchSession).toHaveBeenCalledWith('s1', { isPinned: true }));
  });

  test('manage mode batch delete calls deleteSessions', async () => {
    const { api, store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().refreshSessions();
    render(<SessionsPage store={store} onOpen={() => {}} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: '管理' }));
    await user.click(screen.getByRole('checkbox', { name: '选择 普通会话' }));
    await user.click(screen.getByRole('button', { name: '删除所选' }));
    await vi.waitFor(() => expect((api as unknown as { deleteSessions: ReturnType<typeof vi.fn> }).deleteSessions).toHaveBeenCalledWith(['s1']));
  });

  test('shows reconnect strip when socket is not open', () => {
    const { store } = setup();
    render(<SessionsPage store={store} onOpen={() => {}} />);
    // 初始 state idle(未 login)
    expect(screen.getByText(/未连接/)).toBeTruthy();
  });

  test('logout button returns to login phase', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    await store.getState().refreshSessions();
    render(<SessionsPage store={store} onOpen={() => {}} />);
    await userEvent.click(screen.getByRole('button', { name: '登出' }));
    expect(store.getState().phase).toBe('login');
  });
});
