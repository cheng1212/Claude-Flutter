// zcode-server REST 客户端。fetch 可注入(测试),错误统一包 ApiError。
import type { ModelGroup, SessionRow, MessageRow, UsageSummary } from './protocol';
import { normalizeSession } from './protocol';

export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export class ApiError extends Error {
  constructor(message: string, public status?: number) {
    super(message);
    this.name = 'ApiError';
  }
}

export interface SessionRow2 extends SessionRow {}

export class ZApi {
  readonly baseUrl: string;
  readonly token: string;
  private readonly f: FetchFn;

  constructor(baseUrl: string, token: string, fetchImpl: FetchFn = fetch.bind(globalThis)) {
    this.baseUrl = baseUrl.replace(/\/+$/, '');
    this.token = token;
    this.f = fetchImpl;
  }

  private async call<T>(method: string, path: string, body?: unknown): Promise<T> {
    let res: Response;
    try {
      res = await this.f(`${this.baseUrl}${path}`, {
        method,
        headers: {
          Authorization: `Bearer ${this.token}`,
          ...(body !== undefined ? { 'Content-Type': 'application/json' } : {}),
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
      });
    } catch (e) {
      throw new ApiError(`网络错误: ${e instanceof Error ? e.message : String(e)}`);
    }
    const text = await res.text();
    if (!res.ok) {
      let msg = text || res.statusText;
      try { msg = JSON.parse(text).error ?? msg; } catch { /* 保留原文 */ }
      throw new ApiError(msg, res.status);
    }
    return (text ? JSON.parse(text) : null) as T;
  }

  private static omitNull<T extends object>(o: T): Partial<T> {
    return Object.fromEntries(Object.entries(o).filter(([, v]) => v !== undefined)) as Partial<T>;
  }

  models(): Promise<string[]> {
    return this.call<string[]>('GET', '/api/models');
  }

  async modelGroups(): Promise<ModelGroup[]> {
    const res = await this.call<{ groups: ModelGroup[] }>('GET', '/api/models/grouped');
    return res.groups ?? [];
  }

  async sessions(): Promise<SessionRow[]> {
    const rows = await this.call<Record<string, unknown>[]>('GET', '/api/sessions');
    return rows.map(normalizeSession);
  }

  createSession(input: { title?: string; model?: string } = {}): Promise<SessionRow> {
    return this.call('POST', '/api/sessions', ZApi.omitNull(input));
  }

  patchSession(id: string, patch: { title?: string; isPinned?: boolean; model?: string; permissionMode?: string }): Promise<void> {
    return this.call('PATCH', `/api/sessions/${id}`, ZApi.omitNull(patch));
  }

  async deleteSession(id: string): Promise<void> {
    await this.call('DELETE', `/api/sessions/${id}`);
  }

  async deleteSessions(ids: string[]): Promise<{ deleted: number; missing: string[] }> {
    const res = await this.call<{ deleted?: number; missing?: string[] }>('POST', '/api/sessions/batch-delete', { ids });
    return { deleted: res.deleted ?? 0, missing: res.missing ?? [] };
  }

  async messages(id: string, limit = 500, beforeSeq?: number): Promise<{ messages: MessageRow[]; total: number }> {
    const q = beforeSeq ? `&beforeSeq=${beforeSeq}` : '';
    const res = await this.call<{ messages: MessageRow[]; total: number }>(
      'GET', `/api/sessions/${id}/messages?limit=${limit}${q}`);
    return { messages: res.messages ?? [], total: res.total ?? 0 };
  }

  async sessionUsage(id: string): Promise<UsageSummary | null> {
    try {
      return await this.call<UsageSummary>('GET', `/api/sessions/${id}/usage`);
    } catch {
      return null;
    }
  }

  /** 项目列表:总目录 + 子文件夹名。 */
  async projects(): Promise<{ root: string; names: string[] }> {
    const res = await this.call<{ root: string; projects: { name: string }[] }>('GET', '/api/projects');
    return { root: res.root ?? '', names: (res.projects ?? []).map((p) => p.name) };
  }

  /** 会话定时任务(带 next_fire 预估);传 sessionId 只看该会话。 */
  async crons(sessionId?: string): Promise<Record<string, unknown>[]> {
    const q = sessionId ? `?session=${encodeURIComponent(sessionId)}` : '';
    const res = await this.call<{ crons: Record<string, unknown>[] }>('GET', `/api/crons${q}`);
    return res.crons ?? [];
  }

  async deleteCron(id: string): Promise<void> {
    await this.call('DELETE', `/api/crons/${encodeURIComponent(id)}`);
  }

  /** 后台任务(含 outputTail 输出尾)。 */
  async backgrounds(id: string): Promise<Record<string, unknown>[]> {
    const res = await this.call<{ backgrounds: Record<string, unknown>[] }>('GET', `/api/sessions/${id}/backgrounds`);
    return res.backgrounds ?? [];
  }

  /** 子代理虚拟会话列表(meta)。 */
  async subagents(id: string): Promise<Record<string, unknown>[]> {
    const res = await this.call<{ subagents: Record<string, unknown>[] }>('GET', `/api/sessions/${id}/subagents`);
    return res.subagents ?? [];
  }

  /** 子代理只读转录。 */
  async subagentMessages(id: string, agentId: string): Promise<Record<string, unknown>[]> {
    const res = await this.call<{ messages: Record<string, unknown>[] }>(
      'GET', `/api/sessions/${id}/subagents/${encodeURIComponent(agentId)}/messages`);
    return res.messages ?? [];
  }

  /** 全局用量聚合:?range=7d|30d|all。 */
  async usageStats(range = '7d'): Promise<Record<string, unknown> | null> {
    try {
      return await this.call<Record<string, unknown>>('GET', `/api/usage?range=${encodeURIComponent(range)}`);
    } catch {
      return null;
    }
  }

  /**
   * 上传文件到会话(cwd/uploads/):分块 base64 + 进度(0~1)。
   * 块长必须是 3 的倍数:base64 按 3 字节对齐,各块独立编码拼接才不会错位。
   */
  async uploadFile(
    sessionId: string, fileName: string, bytes: Uint8Array, onProgress?: (p: number) => void,
  ): Promise<{ path: string; fileName: string }> {
    const chunk = 3 * 256 * 1024; // 768KB 原始字节/块,与 app/lib/api.dart 同参
    let done = 0;
    let dataB64 = '';
    while (done < bytes.length) {
      const end = Math.min(done + chunk, bytes.length);
      dataB64 += bytesToB64(bytes.subarray(done, end));
      done = end;
      onProgress?.(done / bytes.length);
    }
    return this.call('POST', `/api/sessions/${sessionId}/files`, { fileName, dataB64 });
  }
}

function bytesToB64(bytes: Uint8Array): string {
  let s = '';
  const step = 0x8000; // 小片转字符串,避免 fromCharCode 参数爆栈
  for (let i = 0; i < bytes.length; i += step) {
    s += String.fromCharCode(...bytes.subarray(i, i + step));
  }
  return btoa(s);
}
