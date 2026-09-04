export type ProtocolEvent =
  | { kind: 'session_created'; providerSessionId: string }
  | { kind: 'text'; role: 'assistant' | 'user'; content: string; images?: string[] }
  | { kind: 'stream_delta'; content: string }
  | { kind: 'thinking'; content: string }
  | { kind: 'thinking_delta'; content: string }
  | { kind: 'tool_use'; toolId: string; toolName: string; toolInput: unknown }
  | { kind: 'tool_result'; toolId: string; content: string; isError: boolean }
  | { kind: 'permission_request'; requestId: string; toolName: string; input: unknown }
  | { kind: 'model'; model: string; endpoint: string | null }
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
  }
  | { kind: 'complete'; exitCode: number; aborted: boolean }
  | { kind: 'error'; content: string };

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
