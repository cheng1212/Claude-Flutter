import { useEffect, useState } from 'react';
import type { ToolRow } from '../lib/chatState';

/** 这些工具的输出是补丁/diff 文本:按行前缀着色(对齐 Flutter _DiffView)。 */
const DIFF_TOOLS = new Set(['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);

/** diff 行着色:+青 / -玫红 / @@橘 / +++--- 元信息淡化。 */
function DiffLines({ text }: { text: string }) {
  return (
    <>
      {text.split('\n').map((l, i) => {
        const cls = l.startsWith('+++') || l.startsWith('---') ? 'diff-meta'
          : l.startsWith('@@') ? 'diff-hunk'
          : l.startsWith('+') ? 'diff-add'
          : l.startsWith('-') ? 'diff-del' : '';
        return <span key={i} className={`diff-line${cls ? ` ${cls}` : ''}`}>{l}</span>;
      })}
    </>
  );
}

function prettyInput(input: Record<string, unknown>): string {
  const one = input.command ?? input.file_path ?? input.path ?? input.pattern ?? input.prompt;
  if (typeof one === 'string' && one) return one;
  try { return JSON.stringify(input, null, 2); } catch { return String(input); }
}

/** 工具调用卡:折叠;运行中转圈+走秒,失败 ✗,完成 ✓。 */
export function ToolCard({ row }: { row: ToolRow }) {
  const [open, setOpen] = useState(false);
  const [now, setNow] = useState(Date.now());
  const streaming = !row.result;

  useEffect(() => {
    if (!streaming) return;
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [streaming]);

  const secs = Math.max(0, Math.floor((now - row.startedAt) / 1000));
  const input = prettyInput(row.toolInput);
  const cls = row.result ? (row.result.isError ? 'is-fail' : 'is-done') : 'is-running';

  return (
    <div className={`toolcard ${cls}`}>
      <button type="button" className="toolcard__head" onClick={() => setOpen((o) => !o)}>
        {streaming ? <span className="toolcard__spinner" aria-hidden /> : <span className="toolcard__mark">{row.result?.isError ? '✗' : '✓'}</span>}
        <span className="toolcard__name mono">{row.toolName || '工具'}</span>
        {streaming && <span className="toolcard__elapsed mono">{secs}s · 运行中</span>}
        <span className="toolcard__chev">{open ? '▾' : '▸'}</span>
      </button>
      {!open && input.trim() && <div className="toolcard__summary mono">{input.split('\n')[0]}</div>}
      {open && (
        <div className="toolcard__body">
          {input.trim() && (
            <>
              <div className="toolcard__label">输入</div>
              <pre className="toolcard__pre mono">{input}</pre>
            </>
          )}
          {row.result?.content && (
            <>
              <div className="toolcard__label">输出</div>
              <pre className={`toolcard__pre mono${row.result.isError ? ' is-err' : ''}`}>
                {DIFF_TOOLS.has(row.toolName) ? <DiffLines text={row.result.content} /> : row.result.content}
              </pre>
            </>
          )}
        </div>
      )}
    </div>
  );
}
