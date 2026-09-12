// 从工具行推导执行计划(TodoWrite / update_plan / ExitPlanMode),取最近一次调用。
// 显式工具名列表(Flutter 版 'plan' 子串匹配过宽,这里修正)。
import type { ChatRow } from './chatState';
export type { ChatRow };

export interface PlanStep {
  content: string;
  status: string;
  completed: boolean;
  inProgress: boolean;
}

const PLAN_TOOLS = new Set(['todowrite', 'updateplan', 'exitplanmode']);

function step(content: string, status: string): PlanStep {
  const s = status.toLowerCase();
  return {
    content, status,
    completed: s === 'completed' || s === 'done',
    inProgress: s === 'in_progress' || s === 'active',
  };
}

function parseValue(value: unknown): PlanStep[] | null {
  let decoded: unknown = value;
  if (typeof decoded === 'string') {
    try {
      decoded = JSON.parse(decoded);
    } catch {
      // 非 JSON 字符串:按多行文本拆步骤(ExitPlanMode 的 plan 是纯文本)
      const lines = (decoded as string).split('\n').map((l) => l.trim()).filter(Boolean);
      return lines.length ? lines.map((l) => step(l, 'pending')) : null;
    }
  }
  if (Array.isArray(decoded)) {
    const steps: PlanStep[] = [];
    for (const item of decoded) {
      if (typeof item === 'string' && item.trim()) {
        steps.push(step(item.trim(), 'pending'));
      } else if (item && typeof item === 'object') {
        const o = item as Record<string, unknown>;
        const content = String(o.content ?? o.step ?? o.title ?? o.text ?? o.activeForm ?? o.label ?? '').trim();
        if (!content) continue;
        const status = o.status != null
          ? String(o.status)
          : (o.completed === true || o.done === true ? 'completed' : 'pending');
        steps.push(step(content, status));
      }
    }
    return steps.length ? steps : null;
  }
  if (decoded && typeof decoded === 'object') {
    const o = decoded as Record<string, unknown>;
    for (const key of ['todos', 'plan', 'plans', 'steps', 'items']) {
      if (o[key] !== undefined) {
        const r = parseValue(o[key]);
        if (r) return r;
      }
    }
    return null;
  }
  return null;
}

export function derivePlanSteps(rows: ChatRow[]): PlanStep[] | null {
  for (let i = rows.length - 1; i >= 0; i--) {
    const row = rows[i];
    if (row.kind !== 'tool') continue;
    if (!PLAN_TOOLS.has(row.toolName.toLowerCase().replace(/[_\s-]/g, ''))) continue;
    const parsed = parseValue(row.toolInput);
    if (parsed && parsed.length) return parsed;
  }
  return null;
}
