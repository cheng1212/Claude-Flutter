import fs from 'node:fs';

export type RouteEntry = { baseUrl?: string; authToken?: string; model?: string; label?: string; relayTo?: string };
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

export type ModelEntry = { id: string; label: string };
export type ModelGroup = { id: string; label: string; models: ModelEntry[] };

/** modelId → 供应商分组(对齐 CloudCLI deriveModelSourceGroup:厂商 API 独立分组,代理端口归 NVIDIA)。 */
export function modelGroupOf(modelId: string): { id: string; label: string } {
  const id = modelId.toLowerCase();
  if (id === 'default') return { id: 'default', label: 'Claude 默认' };
  // zcode- 前缀 = zcode 自家中转模型(请求经本地代理转发,见 proxy/upstream-proxy.ts),
  // 要在 glm/deepseek 之前判,不然 zcode-glm-* 会被 includes('glm') 抢进智谱组。
  if (id.startsWith('zcode-')) return { id: 'zcode', label: 'ZCode 中转' };
  if (id.startsWith('go-') || id.startsWith('anthropic/go-')) return { id: 'opencode', label: 'OpenCode' };
  if (id.includes('glm')) return { id: 'zhipu', label: '智谱 GLM' };
  // -nim 结尾是 NVIDIA 托管,要在 deepseek 之前判;nv- 前缀 = 4002 轮询代理模型(nv-gpt-oss-20b 不含 nemotron)
  if (/^nv-|nvidia|nemotron|minimax|-nim$/.test(id)) return { id: 'nvidia', label: '英伟达' };
  if (id.includes('deepseek')) return { id: 'deepseek', label: '深度求索' };
  return { id: 'other', label: '其他' };
}

/** /api/models 的分组结构:一级供应商、二级模型。 */
export function listModelGroups(config: RouteConfig | null): ModelGroup[] {
  const groups = new Map<string, ModelGroup>();
  const push = (group: { id: string; label: string }, entry: ModelEntry) => {
    let g = groups.get(group.id);
    if (!g) {
      g = { id: group.id, label: group.label, models: [] };
      groups.set(group.id, g);
    }
    g.models.push(entry);
  };
  push({ id: 'default', label: 'Claude 默认' }, { id: 'default', label: '默认 (Claude 官方)' });
  for (const [id, entry] of Object.entries(config?.routes ?? {})) {
    push(modelGroupOf(id), { id, label: entry.label ?? id });
  }
  return [...groups.values()];
}
