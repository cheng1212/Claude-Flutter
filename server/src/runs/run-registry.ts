import type { ProtocolEvent } from '../protocol/types.js';

export type OutboundEvent = { seq: number } & ProtocolEvent;
type Listener = (event: OutboundEvent) => void;

const BUFFER_CAP = 1000;

/** 每会话事件编号 + 环形缓冲。seq 跨 run 单调递增,重连按 afterSeq 补发。 */
export class RunRegistry {
  private seq = new Map<string, number>();
  private buffer = new Map<string, OutboundEvent[]>();
  private running = new Set<string>();
  private listeners = new Map<string, Set<Listener>>();

  begin(sessionId: string): void {
    this.running.add(sessionId);
  }

  isRunning(sessionId: string): boolean {
    return this.running.has(sessionId);
  }

  /** 发终态事件并结束 run;返回带 seq 的 complete 事件。 */
  finish(sessionId: string, exitCode: number, aborted: boolean): OutboundEvent {
    const event = this.push(sessionId, { kind: 'complete', exitCode, aborted });
    this.running.delete(sessionId);
    return event;
  }

  push(sessionId: string, event: ProtocolEvent): OutboundEvent {
    const next = (this.seq.get(sessionId) ?? 0) + 1;
    this.seq.set(sessionId, next);
    const outbound = { ...event, seq: next } as OutboundEvent;
    const buf = this.buffer.get(sessionId) ?? [];
    buf.push(outbound);
    if (buf.length > BUFFER_CAP) buf.splice(0, buf.length - BUFFER_CAP);
    this.buffer.set(sessionId, buf);
    for (const fn of this.listeners.get(sessionId) ?? []) fn(outbound);
    return outbound;
  }

  subscribe(sessionId: string, fn: Listener): () => void {
    const set = this.listeners.get(sessionId) ?? new Set();
    set.add(fn);
    this.listeners.set(sessionId, set);
    return () => { set.delete(fn); };
  }

  replay(sessionId: string, afterSeq: number): OutboundEvent[] {
    return (this.buffer.get(sessionId) ?? []).filter((e) => e.seq > afterSeq);
  }

  lastSeq(sessionId: string): number {
    return this.seq.get(sessionId) ?? 0;
  }
}
