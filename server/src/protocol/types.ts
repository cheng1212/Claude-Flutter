export type ProtocolEvent =
  | { kind: 'session_created'; providerSessionId: string; parentToolUseId?: string }
  | { kind: 'text'; role: 'assistant' | 'user'; content: string; images?: string[]; createdAt?: string; parentToolUseId?: string }
  | { kind: 'stream_delta'; content: string; parentToolUseId?: string }
  | { kind: 'thinking'; content: string; createdAt?: string; parentToolUseId?: string }
  | { kind: 'thinking_delta'; content: string; parentToolUseId?: string }
  | { kind: 'tool_use'; toolId: string; toolName: string; toolInput: unknown; createdAt?: string; parentToolUseId?: string }
  | { kind: 'tool_result'; toolId: string; content: string; isError: boolean; createdAt?: string; parentToolUseId?: string }
  | { kind: 'permission_request'; requestId: string; toolName: string; input: unknown; parentToolUseId?: string }
  | { kind: 'permission_resolved'; requestId: string; parentToolUseId?: string }
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
    /**
     * **真实上下文占用** = 本轮最后一次 API 调用的 prompt 大小
     * (input + cache_read + cache_creation)。上面那几个 inputTokens 是整轮累计
     * (一轮内多次工具调用会相加),拿它当上下文会算出 601% 这种越界值。
     */
    contextTokens?: number;
    parentToolUseId?: string;
  }
  /**
   * 每次 API 请求的真实 prompt 大小(流式 message_start 带),瞬态事件:
   * 不占 seq、不落库,只用于回复途中实时显示上下文占用涨到多少。
   */
  | { kind: 'context_usage'; contextTokens: number; parentToolUseId?: string }
  /** 上下文压缩完成(CLI 的 compact_boundary):manual = 用户点按钮,auto = CLI 自动 */
  | {
    kind: 'context_compacted';
    trigger: 'manual' | 'auto';
    preTokens: number;
    postTokens: number;
    parentToolUseId?: string;
  }
  | { kind: 'complete'; exitCode: number; aborted: boolean; parentToolUseId?: string }
  | { kind: 'error'; content: string; createdAt?: string; parentToolUseId?: string };

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
