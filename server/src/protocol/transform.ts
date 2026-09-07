import type { ProtocolEvent } from './types.js';

type AnyRecord = Record<string, unknown>;

// SDK 消息 → 内部事件的唯一映射点。纯函数,SDK 升级时对拍这里。
export function transformMessage(msg: AnyRecord): ProtocolEvent[] {
  const type = msg.type as string;
  // 子代理帧标记:SDK 在子代理的消息顶层带 parent_tool_use_id;主线程帧没有。
  const parentToolUseId = typeof msg.parent_tool_use_id === 'string' && msg.parent_tool_use_id
    ? msg.parent_tool_use_id
    : undefined;

  if (type === 'assistant') {
    const content = (msg.message as AnyRecord | undefined)?.content;
    if (!Array.isArray(content)) return [];
    const out: ProtocolEvent[] = [];
    for (const block of content) {
      const b = block as AnyRecord;
      if (b.type === 'text' && typeof b.text === 'string' && b.text) {
        out.push({ kind: 'text', role: 'assistant', content: b.text, ...(parentToolUseId ? { parentToolUseId } : {}) });
      } else if (b.type === 'thinking' && typeof b.thinking === 'string' && b.thinking) {
        out.push({ kind: 'thinking', content: b.thinking, ...(parentToolUseId ? { parentToolUseId } : {}) });
      } else if (b.type === 'tool_use') {
        out.push({
          kind: 'tool_use',
          toolId: String(b.id ?? ''),
          toolName: String(b.name ?? ''),
          toolInput: b.input ?? {},
          ...(parentToolUseId ? { parentToolUseId } : {}),
        });
      }
    }
    return out;
  }

  if (type === 'user') {
    const content = (msg.message as AnyRecord | undefined)?.content;
    if (!Array.isArray(content)) return [];
    const out: ProtocolEvent[] = [];
    for (const block of content) {
      const b = block as AnyRecord;
      if (b.type === 'tool_result') {
        const inner = b.content;
        // 数组内容逐块取文本;image 块的 base64 只换成占位符——整块 stringify 会把
        // 巨型 base64 灌进 messages 表,一次读图就撑爆几 MB 落库。
        const text = typeof inner === 'string'
          ? inner
          : Array.isArray(inner)
            ? inner.map((blk) => {
                const x = blk as AnyRecord;
                if (x?.type === 'text' && typeof x.text === 'string') return x.text;
                if (x?.type === 'image') return '[image]';
                return JSON.stringify(x ?? '');
              }).join('\n')
            : JSON.stringify(inner ?? '');
        out.push({
          kind: 'tool_result',
          toolId: String(b.tool_use_id ?? ''),
          content: text,
          isError: Boolean(b.is_error),
          ...(parentToolUseId ? { parentToolUseId } : {}),
        });
      }
    }
    return out;
  }

  if (type === 'system') {
    const subtype = msg.subtype as string;
    // 房间清理/自动监视等 CLI 内部任务不当成用户工作上报
    const ambient = msg.ambient === true || msg.skip_transcript === true;
    if (subtype === 'task_started' && !ambient && typeof msg.task_id === 'string') {
      const ev: ProtocolEvent = {
        kind: 'task_started',
        taskId: msg.task_id,
        description: String(msg.description ?? ''),
        taskType: typeof msg.task_type === 'string' ? msg.task_type : undefined,
      };
      // 富字段(后台面板/子代理面板用):字段缺省时不加键,保持落库 meta 紧凑
      if (typeof msg.tool_use_id === 'string' && msg.tool_use_id) ev.toolUseId = msg.tool_use_id;
      if (typeof msg.subagent_type === 'string' && msg.subagent_type) ev.subagentType = msg.subagent_type;
      if (typeof msg.is_backgrounded === 'boolean') ev.isBackgrounded = msg.is_backgrounded;
      if (typeof msg.spawn_depth === 'number') ev.spawnDepth = msg.spawn_depth;
      return [ev];
    }
    if (subtype === 'task_updated' && !ambient && typeof msg.task_id === 'string') {
      const patch = (msg.patch ?? {}) as AnyRecord;
      const ev: ProtocolEvent = { kind: 'task_updated', taskId: msg.task_id };
      if (typeof patch.status === 'string') ev.status = patch.status as 'pending' | 'running' | 'completed' | 'failed' | 'killed' | 'paused';
      if (typeof patch.is_backgrounded === 'boolean') ev.isBackgrounded = patch.is_backgrounded;
      return [ev];
    }
    if (subtype === 'task_notification' && !ambient && typeof msg.task_id === 'string') {
      const status = msg.status;
      const ev: ProtocolEvent = {
        kind: 'task_complete',
        taskId: msg.task_id,
        status: status === 'completed' || status === 'failed' || status === 'stopped' ? status : 'failed',
        summary: String(msg.summary ?? ''),
      };
      if (typeof msg.output_file === 'string' && msg.output_file) ev.outputFile = msg.output_file;
      return [ev];
    }
    // task_progress 频率高且卡片走秒已表达活性,先不透传;init/compact 等其余 subtype 不消费
    return [];
  }

  if (type === 'stream_event') {
    const event = msg.event as AnyRecord | undefined;
    if ((event?.type as string) !== 'content_block_delta') return [];
    const delta = event?.delta as AnyRecord | undefined;
    if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
      return [{ kind: 'stream_delta', content: delta.text }];
    }
    if (delta?.type === 'thinking_delta' && typeof delta.thinking === 'string') {
      return [{ kind: 'thinking_delta', content: delta.thinking }];
    }
    return [];
  }

  if (type === 'result') {
    const out: ProtocolEvent[] = [];
    const usage = msg.usage as AnyRecord | undefined;
    // contextWindow/分模型费用在 modelUsage 里;主模型取花费最高的条目
    const modelUsage = msg.modelUsage as Record<string, AnyRecord> | undefined;
    let primary: AnyRecord | null = null;
    if (modelUsage) {
      for (const entry of Object.values(modelUsage)) {
        if (!primary || Number(entry?.costUSD ?? 0) > Number(primary.costUSD ?? 0)) primary = entry;
      }
    }
    if (msg.subtype === 'success') {
      out.push({
        kind: 'usage',
        inputTokens: Number(usage?.input_tokens ?? 0),
        outputTokens: Number(usage?.output_tokens ?? 0),
        cacheReadInputTokens: Number(usage?.cache_read_input_tokens ?? 0),
        cacheCreationInputTokens: Number(usage?.cache_creation_input_tokens ?? 0),
        totalCostUsd: Number(msg.total_cost_usd ?? 0),
        durationMs: Number(msg.duration_ms ?? 0),
        numTurns: Number(msg.num_turns ?? 0),
        contextWindow: Number(primary?.contextWindow ?? 0),
        maxOutputTokens: Number(primary?.maxOutputTokens ?? 0),
      });
    } else {
      const errors = Array.isArray(msg.errors) ? msg.errors.join('; ') : '';
      out.push({ kind: 'error', content: errors || String(msg.subtype ?? 'error') });
    }
    out.push({ kind: 'complete', exitCode: msg.subtype === 'success' ? 0 : 1, aborted: false });
    return out;
  }

  return [];
}
