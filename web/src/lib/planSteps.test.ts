import { describe, test, expect } from 'vitest';
import { derivePlanSteps, type ChatRow } from './planSteps';

const tool = (name: string, input: Record<string, unknown>): ChatRow => ({
  kind: 'tool', toolId: 't', toolName: name, toolInput: input, startedAt: 0,
});

describe('derivePlanSteps', () => {
  test('parses TodoWrite todos array with status', () => {
    const rows = [
      tool('Read', { file_path: '/x' }),
      tool('TodoWrite', { todos: [
        { content: '搭骨架', status: 'completed' },
        { content: '写测试', status: 'in_progress' },
        { content: '跑通', status: 'pending' },
      ] }),
    ];
    const steps = derivePlanSteps(rows);
    expect(steps).toHaveLength(3);
    expect(steps?.[0]).toMatchObject({ content: '搭骨架', completed: true });
    expect(steps?.[1]).toMatchObject({ inProgress: true });
    expect(steps?.[2]).toMatchObject({ completed: false, inProgress: false });
  });

  test('accepts plain string arrays and update_plan input', () => {
    const steps = derivePlanSteps([tool('update_plan', { plan: ['a', 'b'] })]);
    expect(steps?.map((s) => s.content)).toEqual(['a', 'b']);
  });

  test('json-string input is decoded', () => {
    const steps = derivePlanSteps([tool('TodoWrite', { todos: JSON.stringify([{ content: 'x', status: 'done' }]) })]);
    expect(steps?.[0].completed).toBe(true);
  });

  test('ExitPlanMode is recognized as a plan tool', () => {
    const steps = derivePlanSteps([tool('ExitPlanMode', { plan: '步骤一\n步骤二' })]);
    expect(steps).toHaveLength(2);
  });

  test('non-plan tools are ignored even if input looks like a plan', () => {
    expect(derivePlanSteps([tool('Read', { todos: ['a'] })])).toBeNull();
  });

  test('returns latest matching tool only', () => {
    const rows = [
      tool('TodoWrite', { todos: ['旧'] }),
      tool('TodoWrite', { todos: ['新'] }),
    ];
    expect(derivePlanSteps(rows)?.map((s) => s.content)).toEqual(['新']);
  });

  test('no plan yields null', () => {
    expect(derivePlanSteps([tool('Bash', { command: 'ls' })])).toBeNull();
    expect(derivePlanSteps([])).toBeNull();
  });
});
