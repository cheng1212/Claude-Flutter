import { describe, test, expect, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { LoginPage } from './LoginPage';

describe('LoginPage', () => {
  test('renders with initial credentials', () => {
    render(<LoginPage initial={{ baseUrl: 'http://a:5190', token: 'tk' }} onLogin={() => {}} />);
    expect((screen.getByLabelText('服务器地址') as HTMLInputElement).value).toBe('http://a:5190');
    expect((screen.getByLabelText('访问令牌') as HTMLInputElement).value).toBe('tk');
  });

  test('button is ALWAYS enabled (no dead button)', () => {
    render(<LoginPage onLogin={() => {}} />);
    expect(screen.getByRole('button', { name: '连接' })).toBeEnabled();
  });

  test('empty submit shows hint and does not call onLogin', async () => {
    const onLogin = vi.fn();
    render(<LoginPage initial={{ baseUrl: '', token: '' }} onLogin={onLogin} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: '连接' }));
    expect(onLogin).not.toHaveBeenCalled();
    expect(screen.getByText(/请填写/)).toBeTruthy();
  });

  test('auto-prefixes http:// and calls onLogin', async () => {
    const onLogin = vi.fn();
    render(<LoginPage onLogin={onLogin} />);
    const user = userEvent.setup();
    const addr = screen.getByLabelText('服务器地址');
    const tok = screen.getByLabelText('访问令牌');
    await user.clear(addr);
    await user.type(addr, '192.168.1.5:5190');
    await user.clear(tok);
    await user.type(tok, 'tk1');
    await user.click(screen.getByRole('button', { name: '连接' }));
    expect(onLogin).toHaveBeenCalledWith('http://192.168.1.5:5190', 'tk1');
  });

  test('does not double-prefix existing scheme', async () => {
    const onLogin = vi.fn();
    render(<LoginPage initial={{ baseUrl: 'https://x.example', token: 't' }} onLogin={onLogin} />);
    const user = userEvent.setup();
    await user.click(screen.getByRole('button', { name: '连接' }));
    expect(onLogin).toHaveBeenCalledWith('https://x.example', 't');
  });

  test('reads NATIVE input values (autofill-proof): value set without React onChange still submits', async () => {
    const onLogin = vi.fn();
    render(<LoginPage onLogin={onLogin} />);
    const user = userEvent.setup();
    // 模拟浏览器自动填充:直接改 DOM value + 冒泡 input 事件之外,连事件都不给
    const addr = screen.getByLabelText('服务器地址') as HTMLInputElement;
    const tok = screen.getByLabelText('访问令牌') as HTMLInputElement;
    addr.value = 'http://192.168.31.194:5190';
    tok.value = 'autofilled-token';
    await user.click(screen.getByRole('button', { name: '连接' }));
    expect(onLogin).toHaveBeenCalledWith('http://192.168.31.194:5190', 'autofilled-token');
  });
});

import { DEFAULT_BASE_URL, DEFAULT_TOKEN } from '../lib/store';

describe('LoginPage · 默认凭据', () => {
  test('prefills default server address and token when no saved creds', () => {
    render(<LoginPage onLogin={() => {}} />);
    expect((screen.getByLabelText('服务器地址') as HTMLInputElement).value).toBe(DEFAULT_BASE_URL);
    expect((screen.getByLabelText('访问令牌') as HTMLInputElement).value).toBe(DEFAULT_TOKEN);
  });

  test('saved creds win over defaults', () => {
    render(<LoginPage initial={{ baseUrl: 'http://other:1234', token: 'abc' }} onLogin={() => {}} />);
    expect((screen.getByLabelText('服务器地址') as HTMLInputElement).value).toBe('http://other:1234');
  });
});
