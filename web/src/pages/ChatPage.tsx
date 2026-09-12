import { useEffect, useMemo, useState } from 'react';
import { useStore } from 'zustand';
import type { ZStore } from '../lib/store';
import { ChatRowView } from '../components/rows';
import { StreamingArea } from '../components/StreamingArea';
import { PermissionCard } from '../components/PermissionCard';
import { PlanPanel } from '../components/PlanPanel';
import { derivePlanSteps } from '../lib/planSteps';

const MODES = [
  { value: 'default', label: '每次确认' },
  { value: 'acceptEdits', label: '自动接受编辑' },
  { value: 'bypassPermissions', label: '跳过确认' },
  { value: 'plan', label: '计划模式' },
];

/** 聊天页:历史 + 流式 + 权限 + 发送。column-reverse 列表天然钉在最新。 */
export function ChatPage({ store, sessionId, onBack }: {
  store: ZStore; sessionId: string; onBack: () => void;
}) {
  useEffect(() => { void store.getState().openSession(sessionId); }, [store, sessionId]);

  const chat = useStore(store, (s) => s.chat);
  const sessions = useStore(store, (s) => s.sessions);
  const modelGroups = useStore(store, (s) => s.modelGroups);
  const [input, setInput] = useState('');
  const [picker, setPicker] = useState<'none' | 'model' | 'mode'>('none');

  const session = sessions.find((s) => s.id === sessionId);
  const model = session?.model ?? 'default';
  const mode = session?.permissionMode ?? 'default';
  const modelLabel = useMemo(() => {
    if (model === 'default') return '默认模型';
    for (const g of modelGroups) {
      const m = g.models.find((x) => x.id === model);
      if (m) return m.label;
    }
    return model;
  }, [model, modelGroups]);

  const plan = derivePlanSteps(chat.rows);
  const phase = chat.pendingPermission ? 'permission' : chat.running ? 'running' : 'idle';

  const send = () => {
    if (!input.trim()) return;
    store.getState().sendChat(input);
    setInput('');
  };

  return (
    <div className="chat">
      <header className="chat__head">
        <button type="button" className="btn-ghost" aria-label="返回" onClick={onBack}>‹ 返回</button>
        <span className="chat__title">{session?.title ?? '会话'}</span>
        <StatusChip phase={phase} />
      </header>

      <div className="chat-list">
        <div className="chat-list__inner">
          <div className="chat__headtail">
            {session && <span className="mono chat__headmeta">{model} · {MODES.find((m) => m.value === mode)?.label ?? mode}</span>}
          </div>
          {plan && <PlanPanel steps={plan} />}
          {[...chat.rows].reverse().map((row, i) => (
            <ChatRowView key={`${row.kind}-${i}`} row={row} />
          ))}
          <StreamingArea running={chat.running} streamingText={chat.streamingText} streamingThinking={chat.streamingThinking} />
        </div>
      </div>

      {chat.pendingPermission && (
        <PermissionCard
          req={chat.pendingPermission}
          onAnswer={(allow, message) => store.getState().answerPermission(chat.pendingPermission!.requestId, allow, message)}
        />
      )}

      {picker === 'model' && (
        <div className="picker">
          <div className="picker__title">选择模型</div>
          {modelGroups.map((g) => (
            <div key={g.id}>
              <div className="picker__group">{g.label}</div>
              {g.models.map((m) => (
                <button key={m.id} type="button" className={`picker__item${m.id === model ? ' is-current' : ''}`} onClick={() => {
                  setPicker('none');
                  if (m.id !== model) void store.getState().patchSession(sessionId, { model: m.id });
                }}>
                  {m.label}{m.id === model ? ' ✓' : ''}
                </button>
              ))}
            </div>
          ))}
        </div>
      )}
      {picker === 'mode' && (
        <div className="picker">
          <div className="picker__title">权限模式</div>
          {MODES.map((m) => (
            <button key={m.value} type="button" className={`picker__item${m.value === mode ? ' is-current' : ''}`} onClick={() => {
              setPicker('none');
              if (m.value !== mode) void store.getState().patchSession(sessionId, { permissionMode: m.value });
            }}>
              {m.label}{m.value === mode ? ' ✓' : ''}
            </button>
          ))}
        </div>
      )}

      <footer className="composer">
        <textarea
          aria-label="消息输入"
          className="composer__input"
          placeholder="让它干活…(Ctrl+Enter 发送)"
          value={input}
          onChange={(e) => setInput(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
              e.preventDefault();
              send();
            }
          }}
        />
        <div className="composer__side">
          <div className="composer__chips">
            <button type="button" className="chip mono" onClick={() => setPicker(picker === 'model' ? 'none' : 'model')}>
              模型 · {modelLabel}
            </button>
            <button type="button" className="chip" onClick={() => setPicker(picker === 'mode' ? 'none' : 'mode')}>
              ⛨ {MODES.find((m) => m.value === mode)?.label ?? mode}
            </button>
          </div>
          {chat.running
            ? <button type="button" className="btn-stop" aria-label="停止" onClick={() => store.getState().abort()}>■ 停止</button>
            : <button type="button" className="btn-gold" aria-label="发送" disabled={!input.trim()} onClick={send}>发送 ▸</button>}
        </div>
      </footer>
    </div>
  );
}

function StatusChip({ phase }: { phase: string }) {
  const map: Record<string, { label: string; cls: string }> = {
    running: { label: '运行中', cls: 'is-running' },
    permission: { label: '待确认', cls: 'is-permission' },
    idle: { label: '空闲', cls: 'is-idle' },
  };
  const it = map[phase] ?? map.idle;
  return <span className={`status-chip ${it.cls}`}>{phase === 'idle' ? '' : <span className="dot dot--pulse" />}{it.label}</span>;
}
