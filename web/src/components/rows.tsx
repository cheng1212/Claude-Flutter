import Markdown from 'react-markdown';
import remarkGfm from 'remark-gfm';
import { memo, useState } from 'react';
import type { ChatRow, ErrorRow, TextRow, ThinkingRow, UserRow } from '../lib/chatState';
import { ToolCard } from './ToolCard';

/** 本地时刻 → HH:mm(历史消息无 createdAt 就不显示,与 Flutter 行为一致)。 */
function hhmm(iso?: string): string {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  return `${String(d.getHours()).padStart(2, '0')}:${String(d.getMinutes()).padStart(2, '0')}`;
}

/** 用户消息:右对齐;pending 半透明 + 发送中。 */
export function UserBubble({ row }: { row: UserRow }) {
  const t = hhmm(row.createdAt);
  return (
    <div className={`bubble-user${row.pending ? ' is-pending' : ''}`}>
      <div className="bubble-user__text">{row.content}</div>
      {row.pending ? (
        <div className="bubble-user__pending">
          <span className="toolcard__spinner" aria-hidden /> 发送中
        </div>
      ) : t ? <span className="row-time mono">{t}</span> : null}
    </div>
  );
}

/** 助手回复:markdown 渲染。 */
export function AssistantBlock({ row }: { row: TextRow }) {
  if (!row.content.trim()) return null;
  const t = hhmm(row.createdAt);
  return (
    <div className="md md--assistant">
      <Markdown remarkPlugins={[remarkGfm]}>{row.content}</Markdown>
      {t ? <span className="row-time mono">{t}</span> : null}
    </div>
  );
}

/** 思考过程:折叠卡。 */
export function ThinkingCard({ row }: { row: ThinkingRow }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="thinking">
      <button type="button" className="thinking__head" onClick={() => setOpen((o) => !o)}>
        <span className="thinking__mark">✦ 思考过程</span>
        <span className="toolcard__chev">{open ? '▾' : '▸'}</span>
      </button>
      {open
        ? <div className="thinking__body">{row.content}</div>
        : <div className="thinking__preview">{row.content}</div>}
    </div>
  );
}

/** 错误行。 */
export function ErrorBlock({ row }: { row: ErrorRow }) {
  return <div className="error-block">{row.content}</div>;
}

/** 行分发。memo:流式期间 rows 数组引用不变,已渲染的行不随每次 delta 重渲(业界共识,对齐 GetStream 虚拟化实践)。 */
export const ChatRowView = memo(function ChatRowView({ row }: { row: ChatRow }) {
  switch (row.kind) {
    case 'user': return <UserBubble row={row} />;
    case 'text': return <AssistantBlock row={row} />;
    case 'thinking': return <ThinkingCard row={row} />;
    case 'tool': return <ToolCard row={row} />;
    case 'error': return <ErrorBlock row={row} />;
  }
});
