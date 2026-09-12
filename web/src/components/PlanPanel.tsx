import { useState } from 'react';
import type { PlanStep } from '../lib/planSteps';

/** 执行计划面板:进度条 + 勾选列表。 */
export function PlanPanel({ steps }: { steps: PlanStep[] }) {
  const [open, setOpen] = useState(true);
  const done = steps.filter((s) => s.completed).length;
  const active = steps.find((s) => s.inProgress);

  return (
    <div className="plan deco-corners">
      <button type="button" className="plan__head" onClick={() => setOpen((o) => !o)}>
        <span className="plan__title">✦ 执行计划 · {done}/{steps.length}</span>
        <span className="toolcard__chev">{open ? '▾' : '▸'}</span>
      </button>
      <div className="plan__bar"><div className="plan__bar-fill" style={{ width: `${steps.length ? (done / steps.length) * 100 : 0}%` }} /></div>
      {!open && active && <div className="plan__current">▶ {active.content}</div>}
      {open && (
        <ul className="plan__list">
          {steps.map((s, i) => (
            <li key={i} className={`plan__step${s.completed ? ' is-done' : ''}${s.inProgress ? ' is-active' : ''}`}>
              <span className="plan__mark">{s.completed ? '☑' : s.inProgress ? '▤' : '☐'}</span>
              {s.content}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
