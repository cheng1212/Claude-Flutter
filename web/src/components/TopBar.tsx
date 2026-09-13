import { useStore } from 'zustand';
import type { ZStore } from '../lib/store';
import { PALETTES, useTheme, setTheme } from '../theme';

export type TopView = 'sessions' | 'chat' | 'usage';

function StatusChip({ phase }: { phase: string }) {
  const map: Record<string, { label: string; cls: string }> = {
    running: { label: '运行中', cls: 'is-running' },
    permission: { label: '待确认', cls: 'is-permission' },
    idle: { label: '空闲', cls: 'is-idle' },
  };
  const it = map[phase] ?? map.idle;
  return <span className={`status-chip ${it.cls}`}>{phase === 'idle' ? '' : <span className="dot dot--pulse" />}{it.label}</span>;
}

/**
 * 全局固定导航栏:所有登录态页面常驻。
 * 返回/新建会话/用量/主题/登出 随时可用 —— 不必退回会话列表(用户反馈的体验问题)。
 */
export function TopBar({ store, view, onBack, onNewSession, onUsage }: {
  store: ZStore;
  view: TopView;
  onBack: () => void;
  onNewSession: () => void;
  onUsage: () => void;
}) {
  const sessions = useStore(store, (s) => s.sessions);
  const currentSessionId = useStore(store, (s) => s.currentSessionId);
  const chat = useStore(store, (s) => s.chat);
  const theme = useTheme();
  const session = sessions.find((x) => x.id === currentSessionId);
  const phase = chat.pendingPermission ? 'permission' : chat.running ? 'running' : 'idle';
  const title = view === 'usage' ? '用量统计' : view === 'chat' ? (session?.title ?? '会话') : 'zCode 终端';

  return (
    <header className="topbar">
      <div className="topbar__left">
        {view === 'chat' || view === 'usage' ? (
          <button type="button" className="btn-ghost" onClick={onBack}>‹ 会话</button>
        ) : (
          <button type="button" className="btn-ghost" aria-label="返回" onClick={() => window.history.back()}>‹ 返回</button>
        )}
        {view === 'sessions' && <span className="topbar__brand">⚡ zCode</span>}
      </div>
      <span className="topbar__title">
        {title}
        {view === 'chat' && <StatusChip phase={phase} />}
      </span>
      <div className="topbar__right">
        {view !== 'usage' && (
          <button type="button" className="btn-gold btn-gold--sm" onClick={onNewSession}>＋ 新建</button>
        )}
        {view !== 'usage' && (
          <button type="button" className="btn-ghost btn-ghost--sm" onClick={onUsage}>用量</button>
        )}
        <select
          aria-label="主题"
          className="field__input topbar__theme"
          value={theme.id}
          onChange={(e) => setTheme(e.target.value)}
        >
          {PALETTES.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
        </select>
        <button type="button" className="btn-ghost btn-ghost--sm" onClick={() => store.getState().logout()}>登出</button>
      </div>
    </header>
  );
}
