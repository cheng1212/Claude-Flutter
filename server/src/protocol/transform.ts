import type { ProtocolEvent } from './types.js';

type AnyRecord = Record<string, unknown>;

// SDK 消息 → 内部事件的唯一映射点。纯函数,SDK 升级时对拍这里。
export function transformMessage(msg: AnyRecord): ProtocolEvent[] {
  const type = msg.type as string;

  if (type === 'assistant') {
    const content = (msg.message as AnyRecord | undefined)?.content;
    if (!Array.isArray(content)) return [];
    const out: ProtocolEvent[] = [];
    for (const block of content) {
      const b = block as AnyRecord;
      if (b.type === 'text' && typeof b.text === 'string' && b.text) {
        out.push({ kind: 'text', role: 'assistant', content: b.text });
      } else if (b.type === 'thinking' && typeof b.thinking === 'string' && b.thinking) {
        out.push({ kind: 'thinking', content: b.thinking });
      } else if (b.type === 'tool_use') {
        out.push({
          kind: 'tool_use',
          toolId: String(b.id ?? ''),
          toolName: String(b.name ?? ''),
          toolInput: b.input ?? {},
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
        const text = typeof inner === 'string' ? inner : JSON.stringify(inner ?? '');
        out.push({
          kind: 'tool_result',
          toolId: String(b.tool_use_id ?? ''),
          content: text,
          isError: Boolean(b.is_error),
        });
      }
    }
    return out;
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
    if (msg.subtype === 'success') {
      out.push({
        kind: 'usage',
        inputTokens: Number(usage?.input_tokens ?? 0),
        outputTokens: Number(usage?.output_tokens ?? 0),
        totalCostUsd: Number(msg.total_cost_usd ?? 0),
        durationMs: Number(msg.duration_ms ?? 0),
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
