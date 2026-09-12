// zcode-server WS 协议类型(镜像 server/src/protocol/types.ts,camelCase 直传)。
export interface ProtocolEvent {
  kind:
    | 'session_created'
    | 'text'
    | 'stream_delta'
    | 'thinking'
    | 'thinking_delta'
    | 'tool_use'
    | 'tool_result'
    | 'permission_request'
    | 'model'
    | 'usage'
    | 'complete'
    | 'error'
    | 'subscribed'
    | 'authenticated'
    | 'pong'
    | 'replay'
    | 'sessions_dirty';
  seq?: number;
  sessionId?: string;
  [key: string]: unknown;
}

/** 客户端 → 服务端消息。 */
export type ClientMessage =
  | { type: 'auth'; token: string }
  | { type: 'ping' }
  | { type: 'chat.subscribe'; sessions: { sessionId: string; lastSeq: number }[] }
  | { type: 'chat.send'; sessionId: string; content: string; images?: string[]; options?: { model?: string; permissionMode?: string } }
  | { type: 'chat.permission-response'; sessionId: string; requestId: string; allow: boolean; message: string }
  | { type: 'chat.abort'; sessionId: string };

export interface ModelEntry { id: string; label: string }
export interface ModelGroup { id: string; label: string; models: ModelEntry[] }

export interface SessionRow {
  id: string;
  title: string;
  cwd: string | null;
  model: string | null;
  permissionMode: string;
  isPinned: number | boolean;
  source: string;
  isRunning: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface MessageRow {
  id: string;
  sessionId: string;
  seq: number;
  kind: string;
  role: string | null;
  content: string;
  meta: string | null;
  createdAt: string;
}

export interface UsageSummary {
  runs: number;
  totals: Record<string, number>;
  last: { contextTokens: number; contextWindow: number; maxOutputTokens: number; endedAt: string | null } | null;
  composition: { kind: string; count: number; bytes: number }[];
  tools: { toolName: string; count: number }[];
}

/** server 端 sessions 行是 snake_case,这里归一为 camelCase。 */
export function normalizeSession(raw: Record<string, unknown>): SessionRow {
  return {
    id: String(raw.id ?? ''),
    title: String(raw.title ?? '未命名会话'),
    cwd: (raw.cwd as string | null) ?? null,
    model: (raw.model as string | null) ?? null,
    permissionMode: String(raw.permissionMode ?? raw.permission_mode ?? 'default'),
    isPinned: (raw.isPinned ?? raw.is_pinned ?? 0) as number | boolean,
    source: String(raw.source ?? 'app'),
    isRunning: raw.isRunning === true,
    createdAt: String(raw.createdAt ?? raw.created_at ?? ''),
    updatedAt: String(raw.updatedAt ?? raw.updated_at ?? raw.createdAt ?? raw.created_at ?? ''),
  };
}
