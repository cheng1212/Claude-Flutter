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

  async messages(id: string, limit = 500): Promise<{ messages: MessageRow[]; total: number }> {
    const res = await this.call<{ messages: MessageRow[]; total: number }>(
      'GET', `/api/sessions/${id}/messages?limit=${limit}`);
    return { messages: res.messages ?? [], total: res.total ?? 0 };
  }

  async sessionUsage(id: string): Promise<UsageSummary | null> {
    try {
      return await this.call<UsageSummary>('GET', `/api/sessions/${id}/usage`);
    } catch {
      return null;
    }
  }
}
