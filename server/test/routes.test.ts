import { describe, expect, it } from 'vitest';
import { loadRoutes, resolveModel, listModels } from '../src/routes.js';
import type { RouteConfig } from '../src/routes.js';

const fixture: RouteConfig = {
  defaultRoute: { baseUrl: 'http://127.0.0.1:4001', authToken: 'sk-d' },
  routes: {
    'glm-5.3-flash': { baseUrl: 'https://open.bigmodel.cn/api/anthropic', authToken: 'k', model: 'glm-5.3-flash' },
  },
};

describe('routes', () => {
  it('显式路由 → settings + env', () => {
    const r = resolveModel(fixture, 'glm-5.3-flash');
    expect(r?.settings?.env.ANTHROPIC_BASE_URL).toBe('https://open.bigmodel.cn/api/anthropic');
    expect(r?.settings?.env.ANTHROPIC_AUTH_TOKEN).toBe('k');
    expect(r?.upstreamModel).toBe('glm-5.3-flash');
  });
  it('子代理别名槽自动注入 = 本路由模型(剥掉 [1m]);主模型保留 [1m]', () => {
    const cfg: RouteConfig = {
      routes: { 'go-x': { baseUrl: 'http://127.0.0.1:4001', authToken: 'k', model: 'go-x[1m]' } },
    };
    const env = resolveModel(cfg, 'go-x')?.settings?.env;
    expect(env?.ANTHROPIC_DEFAULT_HAIKU_MODEL).toBe('go-x');
    expect(env?.ANTHROPIC_DEFAULT_SONNET_MODEL).toBe('go-x');
    expect(env?.ANTHROPIC_DEFAULT_OPUS_MODEL).toBe('go-x');
    // [1m] 是 CLI 的窗口提示，只有别名槽要剥；交给 CLI 的 model 必须保留
    expect(resolveModel(cfg, 'go-x')?.settings?.model).toBe('go-x[1m]');
  });
  it('subagentModel 显式给出时优先于本路由模型', () => {
    const cfg: RouteConfig = {
      routes: { 'go-y': { baseUrl: 'u', authToken: 'k', model: 'go-y[1m]', subagentModel: 'deepseek-v4-flash' } },
    };
    expect(resolveModel(cfg, 'go-y')?.settings?.env.ANTHROPIC_DEFAULT_SONNET_MODEL).toBe('deepseek-v4-flash');
  });
  it('default / 未知模型 → 无路由(CLI 用自己的端点)', () => {
    expect(resolveModel(fixture, 'default')).toBeNull();
    expect(resolveModel(fixture, 'sonnet')).toBeNull();
    expect(resolveModel(fixture, undefined)).toBeNull();
  });
  it('listModels = default + 显式 keys(defaultRoute 不隐式劫持)', () => {
    expect(listModels(fixture)).toEqual(['default', 'glm-5.3-flash']);
  });
  it('文件缺失/坏 JSON → 空路由不崩', () => {
    expect(loadRoutes('Z:/nope/nope.json')).toBeNull();
    expect(listModels(null)).toEqual(['default']);
    expect(resolveModel(null, 'glm-5.3-flash')).toBeNull();
  });
});
