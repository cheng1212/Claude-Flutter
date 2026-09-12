import { describe, test, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createZStore, type ZStore } from './lib/store';
import { App } from './App';

function setup() {
  const api = {
    models: async () => ['default'],
    modelGroups: async () => [],
    sessions: async () => [
      { id: 's1', title: '列表里的会话', model: null, permissionMode: 'default', isPinned: 0, source: 'app', isRunning: false, createdAt: '', updatedAt: '' },
    ],
    createSession: async () => ({ id: 'x', title: '', model: null, permissionMode: '', isPinned: 0, source: '', isRunning: false, createdAt: '', updatedAt: '' }),
    patchSession: async () => {},
    deleteSession: async () => {},
    deleteSessions: async () => ({ deleted: 0, missing: [] }),
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
    sendChat: vi.fn(),
    abort: vi.fn(),
    answerPermission: vi.fn(),
  };
  const store: ZStore = createZStore({
    makeApi: () => api as never,
    makeSocket: () => socket as never,
  });
  return { store };
}

describe('App', () => {
  test('shows login when not authed; login reveals sessions; open reveals chat', async () => {
    const { store } = setup();
    render(<App store={store} />);
    expect(screen.getByText('黑金终端 · 连上你电脑上的 Claude Code')).toBeTruthy();
    const user = userEvent.setup();
    await user.type(screen.getByLabelText('服务器地址'), 'http://x:5190');
    await user.type(screen.getByLabelText('访问令牌'), 'tk');
    await user.click(screen.getByRole('button', { name: '连接' }));
    await vi.waitFor(() => expect(screen.getByText('列表里的会话')).toBeTruthy());
    await user.click(screen.getByText('列表里的会话'));
    await vi.waitFor(() => expect(screen.getByLabelText('消息输入')).toBeTruthy());
  });
});
