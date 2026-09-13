// 后台任务登记(内存态,随进程生死):
// - 旧行为:Bash(run_in_background)→ shell;BashOutput 结果回写;KillShell → killed。
// - 新增:SDK task_*(task_started/updated/notification)事件 → 统一状态机,
//   与旧行为按 tool_use_id 合并为同一条(同一物理任务),完成通知带 output_file。
// 供面板与 GET /backgrounds 使用;输出尾可由 readOutputTail 从落盘文件现读。
import fs from 'node:fs';

type TaskStatus = 'running' | 'killed' | 'pending' | 'completed' | 'failed' | 'stopped' | 'paused';

type TaskEntry = {
  id: string;
  command: string;
  startedAt: number;
  status: TaskStatus;
  lastOutput: string;
  /** SDK 任务系统的 id(task_started.task_id);旧行为合并时与本条互为别名 */
  taskId?: string;
  taskType?: string;
  subagentType?: string;
  description?: string;
  /** 完成通知带的落盘输出文件:面板可用 readOutputTail 现读最新输出 */
  outputFile?: string;
  summary?: string;
  endAt?: number;
};

const OUTPUT_INPUT_KEYS = ['bash_id', 'shell_id', 'background_task_id'];
const TAIL = 2000;

export class BackgroundRegistry {
  private bySession = new Map<string, Map<string, TaskEntry>>();
  /** BashOutput 调用 id → 目标 shell id */
  private outputCall = new Map<string, string>();

  private sessionMap(sessionId: string): Map<string, TaskEntry> {
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

  /** SDK task_* 协议事件 → 登记/打补丁。toolUseId 命中旧行为条目时合并为同一条(别名键)。 */
  onTaskEvent(sessionId: string, ev: { kind: string; taskId?: string; toolUseId?: string; description?: string; taskType?: string; subagentType?: string; isBackgrounded?: boolean; status?: string; summary?: string; outputFile?: string }): void {
    const taskId = ev.taskId;
    if (!taskId) return;
    const map = this.sessionMap(sessionId);

    if (ev.kind === 'task_started') {
      const existing = ev.toolUseId ? map.get(ev.toolUseId) : undefined;
      if (existing) {
        // 同一物理任务:Bash 工具行先登记,SDK 任务事件补齐元数据; taskId 作为别名键指向同一条
        existing.taskId = taskId;
        existing.description = ev.description || existing.description;
        existing.taskType = ev.taskType ?? existing.taskType;
        existing.subagentType = ev.subagentType ?? existing.subagentType;
        map.set(taskId, existing);
        return;
      }
      map.set(taskId, {
        id: taskId,
        command: '',
        startedAt: Date.now(),
        status: 'running',
        lastOutput: '',
        taskId,
        taskType: ev.taskType,
        subagentType: ev.subagentType,
        description: ev.description,
      });
      return;
    }

    if (ev.kind === 'task_updated') {
      const entry = map.get(taskId);
      if (!entry) return;
      if (ev.status) entry.status = ev.status as TaskStatus;
      return;
    }

    if (ev.kind === 'task_complete') {
      const entry = map.get(taskId);
      if (!entry) return;
      entry.status = (ev.status ?? 'failed') as TaskStatus;
      entry.summary = ev.summary || entry.summary;
      entry.outputFile = ev.outputFile ?? entry.outputFile;
      entry.endAt = Date.now();
      // 有任务收尾就顺手收口一次内存表(运行中的不会被清),避免长会话无限增长
      this.prune(sessionId);
      return;
    }
  }

  /**
   * 去重后的任务列表:合并过的条目有两个键指向同一对象,按对象身份去重。
   * 返回前顺手**按时间倒序**(新→旧),让面板不必依赖 Map 插入序。
   */
  list(sessionId: string): TaskEntry[] {
    const map = this.sessionMap(sessionId);
    const seen = new Set<TaskEntry>();
    const out: TaskEntry[] = [];
    for (const entry of map.values()) {
      if (seen.has(entry)) continue;
      seen.add(entry);
      out.push(entry);
    }
    return out.sort((a, b) => b.startedAt - a.startedAt);
  }

  /**
   * 内存收口:长会话跑几百个后台任务时,登记表只增不减会一直占内存。
   * 每会话保留最近 [keep] 条,**运行中的一条不删**(面板还要靠它显示当前状态)。
   * CLI 自己的输出文件与转录不受影响,这里只清本进程的内存登记。
   */
  prune(sessionId: string, keep = 200): number {
    const map = this.sessionMap(sessionId);
    const all = this.list(sessionId); // 已按时间倒序
    let removed = 0;
    for (let i = keep; i < all.length; i++) {
      const e = all[i];
      if (e.status === 'running' || e.status === 'pending' || e.status === 'paused') continue;
      // 合并过的条目有两个键指向同一对象,两个键都要摘
      map.delete(e.id);
      if (e.taskId) map.delete(e.taskId);
      removed += 1;
    }
    return removed;
  }

  clear(sessionId: string): void {
    this.bySession.delete(sessionId);
  }
}

/** 从落盘输出文件现读最新输出尾;文件不存在/不可读返回空串(GET 时调,别在事件回调里做 IO)。 */
export async function readOutputTail(filePath: string, max = TAIL): Promise<string> {
  try {
    const stat = await fs.promises.stat(filePath);
    if (!stat.isFile()) return '';
    const size = Math.min(stat.size, max);
    const buffer = Buffer.alloc(size);
    const fh = await fs.promises.open(filePath, 'r');
    try {
      await fh.read(buffer, 0, size, stat.size - size);
    } finally {
      await fh.close();
    }
    return buffer.toString('utf8');
  } catch {
    return '';
  }
}
