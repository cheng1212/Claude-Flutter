import fs from 'node:fs';

export type RouteEntry = {
  baseUrl?: string;
  authToken?: string;
  model?: string;
  label?: string;
  relayTo?: string;
  /** 子代理/Claude Code 内部别名(haiku·sonnet·opus)落到哪个真实模型;缺省 = 本条路由自己的 model。
   *  填的值必须是**本条路由 baseUrl 那个端点**服务得起的名字,否则子代理会收到"模型不存在"。 */
  subagentModel?: string;
};
export type RouteConfig = { defaultRoute?: RouteEntry; routes?: Record<string, RouteEntry> };
export type ResolvedModel = {
  id: string;
  upstreamModel: string;
  settings: {
    env: {
      ANTHROPIC_BASE_URL: string;
      ANTHROPIC_AUTH_TOKEN: string;
      ANTHROPIC_DEFAULT_HAIKU_MODEL?: string;
      ANTHROPIC_DEFAULT_SONNET_MODEL?: string;
      ANTHROPIC_DEFAULT_OPUS_MODEL?: string;
    };
    model: string;
  } | null;
};

/** `[1m]` 是 Claude Code 的上下文窗口提示,发请求前会被剥掉;任何要交给上游或别名槽的值都不该带它。 */
export const strip1m = (m: string) => m.replace(/\[1m\]$/, '');

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
  const upstream = entry.model || modelId;
  // 子代理换模型只能走这三个别名槽:Agent 工具的 model 是枚举(sonnet|opus|haiku|inherit),
  // 往里写真实 id 会让整次派发过不了 schema 校验。见 sdk-client.ts 的 SUBAGENT_MODEL_ALIASES。
  const subagent = strip1m(entry.subagentModel || upstream);
  return {
    id: modelId,
    upstreamModel: upstream,
    settings: {
      env: {
        ANTHROPIC_BASE_URL: entry.baseUrl,
        ANTHROPIC_AUTH_TOKEN: entry.authToken ?? '',
        ANTHROPIC_DEFAULT_HAIKU_MODEL: subagent,
        ANTHROPIC_DEFAULT_SONNET_MODEL: subagent,
        ANTHROPIC_DEFAULT_OPUS_MODEL: subagent,
      },
      model: upstream,
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
  // "ar-" 前缀 = 通过第三方中转接入的模型(AgentRouter / New API 等),
  // 要在 deepseek 前判,不然 ar-deepseek-* 会被 includes('deepseek') 抢进深度求索组。
  if (id.startsWith('ar-')) return { id: 'thirdparty', label: '第三方中转' };
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
