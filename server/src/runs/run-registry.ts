import type { ProtocolEvent } from '../protocol/types.js';

export type OutboundEvent = { seq?: number } & ProtocolEvent;
type Listener = (event: OutboundEvent) => void;

const BUFFER_CAP = 1000;

// 瞬态事件:只做实时画面,不占 seq、不进环形缓冲。
// seq 只发给可持久化事件,保证 registry seq 与 messages 表 seq 严格同步——
// 否则海量 delta 会把 seq 灌到天文数字,与 REST 重建出的 DB 行号分家,
// 前端按 seq 去重会把新事件全部静默丢弃(界面冻结在旧内容)。
const EPHEMERAL_KINDS = new Set(['stream_delta', 'thinking_delta', 'context_usage']);

/** 每会话事件编号 + 环形缓冲。seq 跨 run 单调递增,重连按 afterSeq 补发。 */
export class RunRegistry {
  private seq = new Map<string, number>();
  private buffer = new Map<string, OutboundEvent[]>();
  private running = new Set<string>();
  private listeners = new Map<string, Set<Listener>>();

  begin(sessionId: string): void {
    this.running.add(sessionId);
  }

  /** 对齐 seq 指针(send 前对齐 messages 表 maxSeq;订阅时吸收客户端水位)。
   *  只进不退:倒卷会让已发出的 seq 重新发号,前端按 seq 去重会把新事件当旧事件整批丢弃。 */
  seedSeq(sessionId: string, value: number): void {
    const cur = this.seq.get(sessionId) ?? 0;
    if (value > cur) this.seq.set(sessionId, value);
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
    if (EPHEMERAL_KINDS.has(event.kind)) {
      const live = { ...event } as OutboundEvent; // 无 seq:前端不去重,只画实时流
      for (const fn of this.listeners.get(sessionId) ?? []) fn(live);
      return live;
    }
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
    return (this.buffer.get(sessionId) ?? []).filter((e) => (e.seq ?? 0) > afterSeq);
  }

  lastSeq(sessionId: string): number {
    return this.seq.get(sessionId) ?? 0;
  }

  /** 只清 running 不发事件:runtime 已自己发过 complete 时用。 */
  clearRunning(sessionId: string): void {
    this.running.delete(sessionId);
  }

  /** 会话已删除:清掉 seq/缓冲/运行态/监听,防止后续事件继续给幽灵会话发号落库。 */
  forget(sessionId: string): void {
    this.seq.delete(sessionId);
    this.buffer.delete(sessionId);
    this.running.delete(sessionId);
    this.listeners.delete(sessionId);
  }

  lastEvent(sessionId: string): OutboundEvent | null {
    const buf = this.buffer.get(sessionId);
    return buf && buf.length ? buf[buf.length - 1] : null;
  }
}
