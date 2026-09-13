import { describe, test, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { createZStore, type ZStore } from '../lib/store';
import { TopBar } from './TopBar';

function setup() {
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
    poke: vi.fn(),
  };
  const store: ZStore = createZStore({
    makeApi: () => ({ models: async () => ['default'], modelGroups: async () => [] }) as never,
    makeSocket: () => socket as never,
  });
  return { store };
}

describe('TopBar(全局导航栏)', () => {
  test('新建会话/用量按钮触发回调', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    const onNewSession = vi.fn();
    const onUsage = vi.fn();
    render(<TopBar store={store} view="sessions" onBack={() => {}} onNewSession={onNewSession} onUsage={onUsage} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: '＋ 新建' }));
    await user.click(screen.getByRole('button', { name: '用量' }));
    expect(onNewSession).toHaveBeenCalledTimes(1);
    expect(onUsage).toHaveBeenCalledTimes(1);
  });

  test('登出回到登录态', async () => {
    const { store } = setup();
    await store.getState().login('http://x:5190', 'tk');
    render(<TopBar store={store} view="sessions" onBack={() => {}} onNewSession={() => {}} onUsage={() => {}} />);
    await userEvent.click(screen.getByRole('button', { name: '登出' }));
    expect(store.getState().phase).toBe('login');
  });

  test('聊天视图显示返回按钮,列表视图不显示', () => {
    const { store } = setup();
    const { rerender } = render(
      <TopBar store={store} view="chat" onBack={() => {}} onNewSession={() => {}} onUsage={() => {}} />,
    );
    expect(screen.getByRole('button', { name: '‹ 会话' })).toBeTruthy();
    rerender(<TopBar store={store} view="sessions" onBack={() => {}} onNewSession={() => {}} onUsage={() => {}} />);
    expect(screen.queryByRole('button', { name: '‹ 会话' })).toBeNull();
  });
});
