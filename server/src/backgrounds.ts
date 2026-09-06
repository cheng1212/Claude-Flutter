// 后台任务登记:Bash(run_in_background)→ shell;BashOutput 结果回写;KillShell → killed。
// 内存态(后台任务本就随进程生死),按会话隔离,供面板与 GET /backgrounds 使用。

type ShellStatus = 'running' | 'killed';

type Shell = {
  id: string;
  command: string;
  startedAt: number;
  status: ShellStatus;
  lastOutput: string;
};

const OUTPUT_INPUT_KEYS = ['bash_id', 'shell_id', 'background_task_id'];
const TAIL = 2000;

export class BackgroundRegistry {
  private bySession = new Map<string, Map<string, Shell>>();
  /** BashOutput 调用 id → 目标 shell id */
  private outputCall = new Map<string, string>();

  private sessionMap(sessionId: string): Map<string, Shell> {
    let m = this.bySession.get(sessionId);
    if (!m) {
      m = new Map();
      this.bySession.set(sessionId, m);
    }
    return m;
  }

  onToolUse(sessionId: string, toolName: string, toolId: string, input: unknown): void {
    const inp = (input ?? {}) as Record<string, unknown>;
    if (toolName === 'Bash' && inp.run_in_background === true) {
      this.sessionMap(sessionId).set(toolId, {
        id: toolId,
        command: String(inp.command ?? ''),
        startedAt: Date.now(),
        status: 'running',
        lastOutput: '',
      });
      return;
    }
    if (toolName === 'BashOutput') {
      for (const key of OUTPUT_INPUT_KEYS) {
        const v = inp[key];
        if (typeof v === 'string' && v) {
          this.outputCall.set(toolId, v);
          return;
        }
      }
      return;
    }
    if (toolName === 'KillShell') {
      for (const key of OUTPUT_INPUT_KEYS) {
        const v = inp[key];
        if (typeof v === 'string' && v) {
          const shell = this.sessionMap(sessionId).get(v);
          if (shell) shell.status = 'killed';
          return;
        }
      }
    }
  }

  onToolResult(sessionId: string, toolId: string, content: string, _isError: boolean): void {
    const mapped = this.outputCall.get(toolId);
    if (!mapped) return;
    const shell = this.sessionMap(sessionId).get(mapped);
    if (!shell) return;
    shell.lastOutput = content.length > TAIL ? content.slice(-TAIL) : content;
  }

  list(sessionId: string): Shell[] {
    return [...this.sessionMap(sessionId).values()];
  }

  clear(sessionId: string): void {
    this.bySession.delete(sessionId);
  }
}
