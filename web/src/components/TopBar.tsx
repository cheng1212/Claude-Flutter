import { useMemo, useState } from 'react';
import { useStore } from 'zustand';
import { loadCreds, type ZStore } from '../lib/store';
import { ZApi } from '../lib/api';
import { PALETTES, useTheme, setTheme } from '../theme';

const DARK_ID = PALETTES.find((p) => p.isDark)?.id ?? 'graphite';
const LIGHT_ID = PALETTES.find((p) => !p.isDark)?.id ?? 'citrus';

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
  const [notifyOn, setNotifyOn] = useState(() => localStorage.getItem('zcode.notify') === 'on');
  const api = useMemo(() => {
    const c = loadCreds();
    return c ? new ZApi(c.baseUrl, c.token) : null;
  }, []);

  /** 通知开关:首次开启请求浏览器授权(仅页面隐藏时弹,不打扰前台)。 */
  const toggleNotify = async () => {
    if (notifyOn) { localStorage.setItem('zcode.notify', 'off'); setNotifyOn(false); return; }
    let granted = false;
    if (typeof Notification !== 'undefined') {
      const p = Notification.permission === 'granted' ? 'granted' : await Notification.requestPermission();
      granted = p === 'granted';
    }
    localStorage.setItem('zcode.notify', granted ? 'on' : 'off');
    setNotifyOn(granted);
  };

  /** 导出当前会话为 markdown(Blob 下载,对齐 app 导出)。 */
  const doExport = async () => {
    if (!api || !currentSessionId) return;
    const out = await api.sessionExport(currentSessionId);
    if (!out?.markdown) return;
    const url = URL.createObjectURL(new Blob([out.markdown], { type: 'text/markdown' }));
    const a = document.createElement('a');
    a.href = url;
    a.download = out.filename || `session-${currentSessionId}.md`;
    a.click();
    URL.revokeObjectURL(url);
  };

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
        {view === 'chat' && (
          <button type="button" className="btn-ghost btn-ghost--sm" onClick={() => void doExport()}>导出</button>
        )}
        <button
          type="button"
          className="btn-ghost btn-ghost--sm"
          aria-label="后台通知开关"
          title={notifyOn ? '通知:开(仅页面隐藏时提醒)' : '通知:关'}
          onClick={() => void toggleNotify()}
        >
          {notifyOn ? '🔔' : '🔕'}
        </button>
        {view !== 'usage' && (
          <button type="button" className="btn-gold btn-gold--sm" onClick={onNewSession}>＋ 新建</button>
        )}
        {view !== 'usage' && (
          <button type="button" className="btn-ghost btn-ghost--sm" onClick={onUsage}>用量</button>
        )}
        <div className="theme-toggle" role="group" aria-label="亮暗主题切换">
          <button
            type="button"
            className={theme.id === LIGHT_ID ? 'is-on' : ''}
            aria-pressed={theme.id === LIGHT_ID}
            aria-label="亮色主题"
            title={`亮色 · ${LIGHT_ID === 'citrus' ? '柑橘晨光' : LIGHT_ID}`}
            onClick={() => setTheme(LIGHT_ID)}
          >
            ☀
          </button>
          <button
            type="button"
            className={theme.id === DARK_ID ? 'is-on' : ''}
            aria-pressed={theme.id === DARK_ID}
            aria-label="暗色主题"
            title={`暗色 · ${PALETTES.find((p) => p.isDark)?.label ?? DARK_ID}`}
            onClick={() => setTheme(DARK_ID)}
          >
            🌙
          </button>
        </div>
        <button type="button" className="btn-ghost btn-ghost--sm" onClick={() => store.getState().logout()}>登出</button>
      </div>
    </header>
  );
}
