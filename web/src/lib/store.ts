// 组合层:REST + WS → zustand store。页面只读状态、调 action。
// 语义对齐 Flutter zapp.dart;deps 注入便于测试。
import { create, type StoreApi, type UseBoundStore } from 'zustand';
import { ZApi } from './api';
import { ZSocket } from './socket';
import {
  emptyChat, applyEvent, applyReplay, applyLocalUser,
  applyPermissionAnswer, rollbackLocalUser, type ChatState,
} from './chatState';
import type { MessageRow, ModelGroup, SessionRow } from './protocol';

export type WsState = 'idle' | 'connecting' | 'open' | 'reconnecting' | 'closed';

export interface ApiLike {
  models(): Promise<string[]>;
  modelGroups(): Promise<ModelGroup[]>;
  sessions(): Promise<SessionRow[]>;
  createSession(input?: { title?: string; model?: string }): Promise<SessionRow>;
  patchSession(id: string, patch: { title?: string; isPinned?: boolean; model?: string; permissionMode?: string }): Promise<void>;
  deleteSession(id: string): Promise<void>;
  deleteSessions(ids: string[]): Promise<{ deleted: number; missing: string[] }>;
  messages(id: string, limit?: number): Promise<{ messages: MessageRow[]; total: number }>;
  sessionUsage(id: string): Promise<unknown>;
  /** 项目列表(可选:测试假件可不实现)。 */
  projects?(): Promise<{ root: string; names: string[] }>;
}

export interface SocketLike {
  state: WsState;
  connect(): Promise<void>;
  close(): void;
  onEvent(cb: (ev: Record<string, unknown>) => void): () => void;
  onStateChange(cb: () => void): () => void;
  seedLastSeq(id: string, seq: number): void;
  subscribeSession(id: string): void;
  sendChat(id: string, content: string, opts?: { model?: string; permissionMode?: string }): void;
  abort(id: string): void;
  answerPermission(id: string, requestId: string, allow: boolean, message?: string): void;
  /** 回前台/获得焦点时跳过重连退避立即拨号;内部自判状态,乱调无害。 */
  poke(): void;
}

export function wsUriOf(baseUrl: string): string {
  return baseUrl.replace(/^http/i, 'ws').replace(/\/+$/, '');
}

const K_BASE = 'zcode.baseUrl';
const K_TOKEN = 'zcode.token';

export function loadCreds(): { baseUrl: string; token: string } | null {
  const baseUrl = localStorage.getItem(K_BASE);
  const token = localStorage.getItem(K_TOKEN);
  return baseUrl && token ? { baseUrl, token } : null;
}

export function saveCreds(c: { baseUrl: string; token: string } | null): void {
  if (c) {
    localStorage.setItem(K_BASE, c.baseUrl);
    localStorage.setItem(K_TOKEN, c.token);
  } else {
    localStorage.removeItem(K_BASE);
    localStorage.removeItem(K_TOKEN);
  }
}

export interface ZState {
  phase: 'login' | 'ready';
  baseUrl: string;
  models: string[];
  modelGroups: ModelGroup[];
  /** 项目总目录 + 子文件夹名(会话页项目过滤数据源)。 */
  projects: { root: string; names: string[] };
  sessions: SessionRow[];
  currentSessionId: string | null;
  chat: ChatState;
  historyLoading: boolean;
  error: string | null;
  wsState: WsState;
  /** 登录页一次性提示(如「登录已失效,请重新登录」),登录成功即清。 */
  notice: string | null;

  login(baseUrl: string, token: string): Promise<void>;
  logout(reason?: string): void;
  refreshSessions(): Promise<void>;
  loadProjects(): Promise<void>;
  openSession(id: string): Promise<void>;
  createSession(input?: { title?: string; model?: string }): Promise<SessionRow>;
  patchSession(id: string, patch: { title?: string; isPinned?: boolean; model?: string; permissionMode?: string }): Promise<void>;
  deleteSession(id: string): Promise<void>;
  deleteSessions(ids: string[]): Promise<void>;
  sendChat(text: string, opts?: { model?: string; permissionMode?: string }): void;
  abort(): void;
  answerPermission(requestId: string, allow: boolean, message?: string): void;
  clearError(): void;
}

export type ZStore = UseBoundStore<StoreApi<ZState>>;

/** 服务器 401 = 令牌错误/失效:清凭据弹回登录页,不让用户停在「处处未授权」的死界面里。 */
function isAuthError(e: unknown): boolean {
  return typeof e === 'object' && e !== null && (e as { status?: unknown }).status === 401;
}

/** 消息行 meta → 出站事件;行号 row.seq 是权威锚(覆写 meta 里的旧进程 seq)。 */
function rowEvent(row: MessageRow): Record<string, unknown> | null {
  let ev: Record<string, unknown> | null = null;
  if (row.meta) {
    try {
      const v: unknown = JSON.parse(row.meta);
      if (v && typeof v === 'object' && !Array.isArray(v)) ev = v as Record<string, unknown>;
    } catch { /* 坏 meta 忽略,退回行字段 */ }
  }
  if (!ev) ev = { kind: row.kind, role: row.role ?? undefined, content: row.content };
  ev.seq = row.seq;
  return ev;
}

export function createZStore(deps: {
  makeApi: (baseUrl: string, token: string) => ApiLike;
  makeSocket: (wsUri: string, token: string) => SocketLike;
}): ZStore {
  let api: ApiLike;
  let socket: SocketLike;
  let retryTimer: ReturnType<typeof setTimeout> | undefined;
  let dirtyTimer: ReturnType<typeof setTimeout> | undefined;

  // 睡眠唤醒/切回标签页时跳过剩余退避立即重连;poke 内部自判状态,连接正常时是空操作。
  const onVisible = (): void => { if (document.visibilityState === 'visible') socket?.poke(); };
  const onFocus = (): void => { socket?.poke(); };
  function wireWake(on: boolean): void {
    if (typeof document === 'undefined') return; // 非浏览器环境(单测)无此事件
    if (on) {
      document.addEventListener('visibilitychange', onVisible);
      window.addEventListener('focus', onFocus);
    } else {
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('focus', onFocus);
    }
  }

  const store = create<ZState>((set, get) => {
    async function loadModels(): Promise<void> {
      try {
        set({ models: await api.models(), modelGroups: await api.modelGroups() });
      } catch (e) {
        if (isAuthError(e)) { get().logout('登录已失效,请重新登录'); return; }
        set({ error: String(e instanceof Error ? e.message : e) });
      }
    }

    async function loadSessions(silent = false): Promise<void> {
      try {
        set({ sessions: await api.sessions() });
      } catch (e) {
        if (isAuthError(e)) { get().logout('登录已失效,请重新登录'); return; }
        // 后台静默刷新失败不弹错误条:一次 REST 抖动不值得打扰
        if (!silent) set({ error: String(e instanceof Error ? e.message : e) });
      }
    }

    async function loadProjects(): Promise<void> {
      try {
        set({ projects: await api.projects?.() ?? { root: '', names: [] } });
      } catch {
        /* 项目列表失败不打扰:过滤退化为"全部/未分类" */
      }
    }

    async function bootstrap(): Promise<void> {
      try {
        await socket.connect();
        set({ error: null });
      } catch (e) {
        set({ error: `连接失败: ${e instanceof Error ? e.message : e}` });
        if (retryTimer) clearTimeout(retryTimer);
        retryTimer = setTimeout(() => { void bootstrap(); }, 2000);
      }
      await loadModels();
      await loadSessions();
    }

    function route(ev: Record<string, unknown>): void {
      const kind = String(ev.kind ?? '');
      if (kind === 'authenticated') { set({ error: null }); return; }
      if (kind === 'replay') {
        if (ev.sessionId === get().currentSessionId && Array.isArray(ev.events)) {
          set({ chat: applyReplay(get().chat, ev.events as Record<string, unknown>[]) });
        }
        return;
      }
      if (kind === 'session_created') { void loadSessions(true); return; }
      if (kind === 'sessions_dirty') {
        // 防抖合并成一次 REST;控制事件,无 seq,不进 reducer。
        if (dirtyTimer) clearTimeout(dirtyTimer);
        dirtyTimer = setTimeout(() => { void loadSessions(true); }, 250);
        return;
      }
      const sid = ev.sessionId as string | undefined;
      if (!sid || sid !== get().currentSessionId) return;
      set({ chat: applyEvent(get().chat, ev) });
      if (kind === 'complete') void loadSessions(true);
    }

    return {
      phase: 'login',
      baseUrl: '',
      models: [],
      modelGroups: [],
      projects: { root: '', names: [] },
      sessions: [],
      currentSessionId: null,
      chat: emptyChat(),
      historyLoading: false,
      error: null,
      wsState: 'idle',
      notice: null,

      async login(baseUrl, token) {
        // 先拿 token 真刀真枪问一次服务器:错了就留在登录页报错,
        // 不再「假进主界面 → 处处未授权 → 退不出去」。
        const probe = deps.makeApi(baseUrl, token);
        try {
          await probe.models();
        } catch (e) {
          const err = e as { status?: number; message?: string };
          if (isAuthError(e)) throw new Error('访问令牌不正确:请核对后重试');
          if (typeof err?.message === 'string' && err.message.startsWith('网络错误')) {
            throw new Error(`连不上服务器:${err.message}`);
          }
          throw new Error(`服务器没有通过校验:${err?.message ?? String(e)}`);
        }
        saveCreds({ baseUrl, token });
        api = probe;
        socket = deps.makeSocket(wsUriOf(baseUrl), token);
        socket.onEvent(route);
        socket.onStateChange(() => set({ wsState: socket.state }));
        wireWake(true);
        set({ phase: 'ready', baseUrl, wsState: socket.state, notice: null });
        await bootstrap();
      },

      logout(reason?: string) {
        saveCreds(null);
        if (retryTimer) clearTimeout(retryTimer);
        if (dirtyTimer) clearTimeout(dirtyTimer);
        socket?.close();
        wireWake(false);
        set({
          phase: 'login', baseUrl: '', models: [], modelGroups: [], sessions: [],
          currentSessionId: null, chat: emptyChat(), historyLoading: false, error: null, wsState: 'idle',
          notice: reason ?? null,
        });
      },

      async refreshSessions() {
        await loadSessions();
      },

      async loadProjects() {
        await loadProjects();
      },

      async openSession(id) {
        // 同会话重开保留待审批卡:审批不落库,REST 重建不出来;丢了没人能批,会话卡死。
        const keepPermission = get().currentSessionId === id ? get().chat.pendingPermission : undefined;
        set({ currentSessionId: id, chat: emptyChat(), historyLoading: true, error: null });
        try {
          const hist = await api.messages(id, 500);
          const events: Record<string, unknown>[] = [];
          let maxSeq = 0;
          for (const row of hist.messages) {
            const ev = rowEvent(row);
            if (ev) events.push(ev);
            if (row.seq > maxSeq) maxSeq = row.seq;
          }
          events.sort((a, b) => (Number(a.seq) || 0) - (Number(b.seq) || 0));
          let chat = emptyChat();
          for (const ev of events) chat = applyEvent(chat, ev);
          if (keepPermission && !chat.pendingPermission) {
            chat = { ...chat, pendingPermission: keepPermission };
          }
          set({ chat, historyLoading: false });
          socket.seedLastSeq(id, maxSeq > chat.lastSeq ? maxSeq : chat.lastSeq);
          socket.subscribeSession(id);
        } catch (e) {
          if (isAuthError(e)) { get().logout('登录已失效,请重新登录'); return; }
          set({ historyLoading: false, error: String(e instanceof Error ? e.message : e) });
        }
      },

      async createSession(input = {}) {
        const row = await api.createSession(input);
        await loadSessions();
        return row;
      },

      async patchSession(id, patch) {
        await api.patchSession(id, patch);
        await loadSessions();
      },

      async deleteSession(id) {
        await api.deleteSession(id);
        if (get().currentSessionId === id) set({ currentSessionId: null, chat: emptyChat() });
        await loadSessions();
      },

      async deleteSessions(ids) {
        await api.deleteSessions(ids);
        const cur = get().currentSessionId;
        if (cur && ids.includes(cur)) set({ currentSessionId: null, chat: emptyChat() });
        await loadSessions();
      },

      sendChat(text, opts) {
        const sid = get().currentSessionId;
        const trimmed = text.trim();
        if (!sid || !trimmed) return;
        set({ chat: applyLocalUser(get().chat, trimmed) });
        try {
          socket.sendChat(sid, trimmed, opts);
        } catch (e) {
          set({
            chat: rollbackLocalUser(get().chat),
            error: `发送失败: ${e instanceof Error ? e.message : e}`,
          });
        }
      },

      abort() {
        const sid = get().currentSessionId;
        if (!sid) return;
        try { socket.abort(sid); } catch { /* 未连接:重连后再说 */ }
      },

      answerPermission(requestId, allow, message = '') {
        const sid = get().currentSessionId;
        if (!sid) return;
        set({ chat: applyPermissionAnswer(get().chat) });
        try { socket.answerPermission(sid, requestId, allow, message); } catch { /* 未连接 */ }
      },

      clearError() {
        set({ error: null });
      },
    };
  });

  return store;
}

/** 生产装配:真实 Api/Socket + 本地凭据自动登录。 */
export function createDefaultStore(): ZStore {
  return createZStore({
    makeApi: (baseUrl, token) => new ZApi(baseUrl, token),
    makeSocket: (wsUri, token) => new ZSocket({ uri: wsUri, token }),
  });
}

export async function autoLogin(store: ZStore): Promise<boolean> {
  const creds = loadCreds();
  if (!creds) return false;
  try {
    await store.getState().login(creds.baseUrl, creds.token);
    return true;
  } catch {
    return false; // 凭据缺失/失效:留在登录页
  }
}

/** 登录页默认值:家里局域网的 server 地址与当前令牌,变了用户自己改。 */
export const DEFAULT_BASE_URL = 'http://192.168.31.194:5190';
export const DEFAULT_TOKEN = 'O4wRud_d6qcYUBhKWuZm5dkH';
