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
