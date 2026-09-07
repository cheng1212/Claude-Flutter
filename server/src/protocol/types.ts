export type ProtocolEvent =
  | { kind: 'session_created'; providerSessionId: string; parentToolUseId?: string }
  | { kind: 'text'; role: 'assistant' | 'user'; content: string; images?: string[]; parentToolUseId?: string }
  | { kind: 'stream_delta'; content: string; parentToolUseId?: string }
  | { kind: 'thinking'; content: string; parentToolUseId?: string }
  | { kind: 'thinking_delta'; content: string; parentToolUseId?: string }
  | { kind: 'tool_use'; toolId: string; toolName: string; toolInput: unknown; parentToolUseId?: string }
  | { kind: 'tool_result'; toolId: string; content: string; isError: boolean; parentToolUseId?: string }
  | { kind: 'permission_request'; requestId: string; toolName: string; input: unknown; parentToolUseId?: string }
  | {
    kind: 'task_started'; taskId: string; description: string; taskType?: string;
    toolUseId?: string; subagentType?: string; isBackgrounded?: boolean; spawnDepth?: number;
    parentToolUseId?: string;
  }
  | {
    kind: 'task_updated'; taskId: string;
    status?: 'pending' | 'running' | 'completed' | 'failed' | 'killed' | 'paused';
    isBackgrounded?: boolean;
    parentToolUseId?: string;
  }
  | { kind: 'task_complete'; taskId: string; status: 'completed' | 'failed' | 'stopped'; summary: string; outputFile?: string; parentToolUseId?: string }
  | {
    kind: 'usage';
    inputTokens: number;
    outputTokens: number;
    cacheReadInputTokens: number;
    cacheCreationInputTokens: number;
    totalCostUsd: number;
    durationMs: number;
    numTurns: number;
    /** 主模型上下文窗口大小(tokens);SDK 未给时为 0 */
    contextWindow: number;
    maxOutputTokens: number;
    parentToolUseId?: string;
  }
  | { kind: 'complete'; exitCode: number; aborted: boolean; parentToolUseId?: string }
  | { kind: 'error'; content: string; parentToolUseId?: string };

/** 后台保活判定:这些工具会把工作留到 result 之后。 */
export const DEFERRED_WORK_TOOLS = new Set(['Monitor', 'ScheduleWakeup', 'CronCreate', 'TaskCreate']);

export function startsBackgroundWork(events: ProtocolEvent[]): boolean {
  return events.some((e) => {
    if (e.kind !== 'tool_use') return false;
    if (e.toolName === 'Bash') {
      return (e.toolInput as { run_in_background?: boolean } | null)?.run_in_background === true;
    }
    return DEFERRED_WORK_TOOLS.has(e.toolName);
  });
}
