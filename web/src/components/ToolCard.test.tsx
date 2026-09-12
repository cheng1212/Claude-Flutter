import { describe, test, expect } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { ToolCard } from './ToolCard';
import type { ToolRow } from '../lib/chatState';

const row = (result?: { content: string; isError: boolean }): ToolRow => ({
  kind: 'tool', toolId: 't1', toolName: 'Bash',
  toolInput: { command: 'ls -la', file_path: '/tmp' },
  startedAt: Date.now(),
  ...(result ? { result } : {}),
});

describe('ToolCard', () => {
  test('running state shows spinner label and input summary', () => {
    render(<ToolCard row={row()} />);
    expect(screen.getByText('Bash')).toBeTruthy();
    expect(screen.getByText(/运行中/)).toBeTruthy();
    expect(screen.getByText(/ls -la/)).toBeTruthy(); // 输入摘要
  });

  test('done state shows success mark; expand reveals output', async () => {
    render(<ToolCard row={row({ content: 'file1\nfile2', isError: false })} />);
    expect(screen.getByText('✓')).toBeTruthy();
    expect(screen.queryByText('file1')).toBeNull(); // 折叠时不见输出
    await userEvent.click(screen.getByRole('button', { name: /Bash/ }));
    expect(screen.getByText(/file2/)).toBeTruthy();
  });

  test('failed state shows error mark', () => {
    render(<ToolCard row={row({ content: 'boom', isError: true })} />);
    expect(screen.getByText('✗')).toBeTruthy();
  });
});
