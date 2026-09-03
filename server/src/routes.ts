import fs from 'node:fs';

export type RouteEntry = { baseUrl?: string; authToken?: string; model?: string };
export type RouteConfig = { defaultRoute?: RouteEntry; routes?: Record<string, RouteEntry> };
export type ResolvedModel = {
  id: string;
  upstreamModel: string;
  settings: {
    env: { ANTHROPIC_BASE_URL: string; ANTHROPIC_AUTH_TOKEN: string };
    model: string;
  } | null;
};

export function loadRoutes(path: string): RouteConfig | null {
  try {
    return JSON.parse(fs.readFileSync(path, 'utf8')) as RouteConfig;
  } catch {
    return null;
  }
}

// 只有显式列出的自定义模型才注入路由;default/未列出 → null,
// CLI 用自己配置的端点。defaultRoute 不隐式生效,防止劫持官方模型。
export function resolveModel(config: RouteConfig | null, modelId: string | undefined | null): ResolvedModel | null {
  if (!modelId || modelId === 'default') return null;
  const entry = config?.routes?.[modelId];
  if (!entry?.baseUrl) return null;
  return {
    id: modelId,
    upstreamModel: entry.model || modelId,
    settings: {
      env: { ANTHROPIC_BASE_URL: entry.baseUrl, ANTHROPIC_AUTH_TOKEN: entry.authToken ?? '' },
      model: entry.model || modelId,
    },
  };
}

export function listModels(config: RouteConfig | null): string[] {
  return ['default', ...Object.keys(config?.routes ?? {})];
}
