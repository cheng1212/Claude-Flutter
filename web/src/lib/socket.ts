// zcode-server WS 客户端:auth → 订阅(seq 续传) → 心跳 → 断线指数退避重连。
// 移植 Flutter ws.dart;通道抽象 ZChannel 便于测试注入假件。

export type SocketState = 'idle' | 'connecting' | 'open' | 'reconnecting' | 'closed';

export class ZSocketError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ZSocketError';
  }
}

export interface ZChannel {
  send(data: unknown): void;
  close(): void;
  onData(cb: (msg: Record<string, unknown>) => void): () => void;
  onClose(cb: () => void): () => void;
}

export type ChannelFactory = (uri: string) => Promise<ZChannel>;

/** 真实通道:浏览器原生 WebSocket。 */
export function browserChannelFactory(uri: string): Promise<ZChannel> {
  return new Promise((resolve, reject) => {
    let ws: WebSocket;
    try {
      ws = new WebSocket(uri);
    } catch (e) {
      reject(new ZSocketError(`连接失败: ${e instanceof Error ? e.message : String(e)}`));
      return;
    }
    const cbs = new Set<(m: Record<string, unknown>) => void>();
    const closeCbs = new Set<() => void>();
    ws.onopen = () => resolve({
      send: (data) => ws.send(JSON.stringify(data)),
      close: () => ws.close(),
      onData: (cb) => { cbs.add(cb); return () => cbs.delete(cb); },
      onClose: (cb) => { closeCbs.add(cb); return () => closeCbs.delete(cb); },
    });
    ws.onmessage = (m) => {
      try {
        const obj = JSON.parse(String(m.data)) as Record<string, unknown>;
        cbs.forEach((cb) => cb(obj));
      } catch { /* 非 JSON 帧忽略 */ }
    };
    ws.onerror = () => { if (ws.readyState !== WebSocket.OPEN) reject(new ZSocketError('连接失败')); };
    ws.onclose = () => closeCbs.forEach((cb) => cb());
  });
}

interface ZSocketOptions {
  uri: string;
  token: string;
  factory?: ChannelFactory;
  backoffBaseMs?: number;
  maxBackoffMs?: number;
  pingEveryMs?: number;
}

export class ZSocket {
  state: SocketState = 'idle';
  failure?: string;
  attempts = 0;

  private readonly uri: string;
  private readonly token: string;
  private readonly factory: ChannelFactory;
  private readonly backoffBaseMs: number;
  private readonly maxBackoffMs: number;
  private readonly pingEveryMs: number;

  private eventCbs = new Set<(ev: Record<string, unknown>) => void>();
  private stateCbs = new Set<() => void>();

  private channel: ZChannel | null = null;
  private unData?: () => void;
  private unClose?: () => void;
  private retryTimer?: ReturnType<typeof setTimeout>;
  private pingTimer?: ReturnType<typeof setInterval>;
  private disposed = false;

  private readonly wantSubs = new Set<string>();
  private readonly lastSeq = new Map<string, number>();

  constructor(opts: ZSocketOptions) {
    this.uri = opts.uri;
    this.token = opts.token;
    this.factory = opts.factory ?? browserChannelFactory;
    this.backoffBaseMs = opts.backoffBaseMs ?? 1000;
    this.maxBackoffMs = opts.maxBackoffMs ?? 30000;
    this.pingEveryMs = opts.pingEveryMs ?? 25000;
  }

  onEvent(cb: (ev: Record<string, unknown>) => void): () => void {
    this.eventCbs.add(cb);
    return () => this.eventCbs.delete(cb);
  }

  onStateChange(cb: () => void): () => void {
    this.stateCbs.add(cb);
    return () => this.stateCbs.delete(cb);
  }

  private setState(s: SocketState): void {
    this.state = s;
    this.stateCbs.forEach((cb) => cb());
  }

  private emit(msg: Record<string, unknown>): void {
    this.eventCbs.forEach((cb) => cb(msg));
  }

  /** 连接并鉴权;失败抛 ZSocketError。 */
  async connect(): Promise<void> {
    this.disposed = false;
    this.attempts = 0;
    await this.dial();
  }

  private async dial(): Promise<void> {
    if (this.disposed) throw new ZSocketError('socket 已关闭');
    this.setState('connecting');
    let ch: ZChannel;
    try {
      // 10s 连接超时:TCP 悬挂(睡眠唤醒/网络切换)时不再永久卡在 connecting
      ch = await Promise.race([
        this.factory(this.uri),
        new Promise<never>((_, rej) =>
          setTimeout(() => rej(new Error('连接超时(10s)')), 10_000)),
      ]);
    } catch (e) {
      this.failure = e instanceof Error ? e.message : String(e);
      throw new ZSocketError(this.failure);
    }
    this.channel = ch;

    // 鉴权握手:等第一条消息,8 秒超时。
    const first = new Promise<Record<string, unknown>>((resolve, reject) => {
      const un = ch.onData((m) => { un(); resolve(m); });
      const unC = ch.onClose(() => { un(); unC(); reject(new ZSocketError('连接被关闭')); });
      setTimeout(() => {
        un(); unC();
        reject(new ZSocketError('鉴权超时'));
      }, 8000);
    });
    ch.send({ type: 'auth', token: this.token });
    let reply: Record<string, unknown>;
    try {
      reply = await first;
    } catch (e) {
      ch.close();
      this.channel = null;
      throw e instanceof ZSocketError ? e : new ZSocketError(String(e));
    }
    if (reply.kind !== 'authenticated') {
      ch.close();
      this.channel = null;
      throw new ZSocketError(String(reply.content ?? reply.kind ?? '鉴权失败'));
    }

    this.unData = ch.onData((m) => this.onData(m));
    this.unClose = ch.onClose(() => this.onDown());
    this.failure = undefined;
    this.attempts = 0;
    this.setState('open');
    this.startPing();
    this.resubscribe();
  }

  private onData(m: Record<string, unknown>): void {
    if (m.kind === 'replay') {
      const sessionId = m.sessionId as string | undefined;
      const list = Array.isArray(m.events) ? m.events as Record<string, unknown>[] : [];
      for (const e of list) {
        if (sessionId) this.track({ ...e, sessionId });
      }
    }
    this.track(m);
    this.emit(m);
  }

  private track(m: Record<string, unknown>): void {
    const sessionId = m.sessionId as string | undefined;
    const seq = m.seq as number | undefined;
    if (!sessionId || typeof seq !== 'number') return;
    if (seq > (this.lastSeq.get(sessionId) ?? 0)) this.lastSeq.set(sessionId, seq);
  }

  private onDown(): void {
    this.unData?.(); this.unData = undefined;
    this.unClose?.(); this.unClose = undefined;
    this.channel = null;
    if (this.pingTimer) { clearInterval(this.pingTimer); this.pingTimer = undefined; }
    if (this.disposed || this.state === 'closed') return;
    this.setState('reconnecting');
    const delay = Math.min(this.backoffBaseMs * 2 ** this.attempts, this.maxBackoffMs);
    this.attempts++;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = undefined;
      this.dial().catch(() => this.onDown());
    }, delay);
  }

  /** 回前台/获得焦点时:若在重连等待期,立即跳过剩余退避直接拨号(睡眠唤醒秒回)。 */
  poke(): void {
    if (this.disposed || this.state === 'open' || this.state === 'connecting') return;
    if (this.retryTimer) { clearTimeout(this.retryTimer); this.retryTimer = undefined; }
    this.dial().catch(() => this.onDown());
  }

  private startPing(): void {
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = setInterval(() => {
      try {
        this.channel?.send({ type: 'ping' });
      } catch { /* 发送失败交由 onDone/onClose 路径处理 */ }
    }, this.pingEveryMs);
  }

  private send(payload: Record<string, unknown>): void {
    if (this.state !== 'open' || !this.channel) throw new ZSocketError('未连接');
    this.channel.send(payload);
  }

  private resubscribe(): void {
    if (this.wantSubs.size === 0) return;
    this.send({
      type: 'chat.subscribe',
      sessions: [...this.wantSubs].map((id) => ({ sessionId: id, lastSeq: this.lastSeq.get(id) ?? 0 })),
    });
  }

  lastSeqOf(sessionId: string): number {
    return this.lastSeq.get(sessionId) ?? 0;
  }

  /** 用 REST 历史推到的 seq 播种(只前进);重连补订从这儿续。 */
  seedLastSeq(sessionId: string, seq: number): void {
    if (seq > (this.lastSeq.get(sessionId) ?? 0)) this.lastSeq.set(sessionId, seq);
  }

  /** 订阅会话;已连接时立即发送,否则等重连后统一补订。 */
  subscribeSession(sessionId: string): void {
    this.wantSubs.add(sessionId);
    if (this.state === 'open') this.resubscribe();
  }

  sendChat(sessionId: string, content: string, opts?: { model?: string; permissionMode?: string }): void {
    // default 不占 options:显式发 'default' 会在服务端压掉 DB 里 PATCH 过的模式。
    const options: Record<string, string> = {};
    if (opts?.model && opts.model !== 'default') options.model = opts.model;
    if (opts?.permissionMode && opts.permissionMode !== 'default') options.permissionMode = opts.permissionMode;
    this.send({
      type: 'chat.send', sessionId, content,
      ...(Object.keys(options).length ? { options } : {}),
    });
  }

  answerPermission(sessionId: string, requestId: string, allow: boolean, message = ''): void {
    this.send({ type: 'chat.permission-response', sessionId, requestId, allow, message });
  }

  abort(sessionId: string): void {
    this.send({ type: 'chat.abort', sessionId });
  }

  /** 断开且不再自动重连。 */
  close(): void {
    this.disposed = true;
    this.setState('closed');
    if (this.retryTimer) { clearTimeout(this.retryTimer); this.retryTimer = undefined; }
    if (this.pingTimer) { clearInterval(this.pingTimer); this.pingTimer = undefined; }
    this.unData?.(); this.unData = undefined;
    this.unClose?.(); this.unClose = undefined;
    this.channel?.close();
    this.channel = null;
  }
}
