import { useEffect, useMemo, useState } from 'react';
import { useStore } from 'zustand';
import type { ZStore } from '../lib/store';
import type { SessionRow } from '../lib/protocol';

function timeLabel(iso: string): string {
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return '';
  const d = Date.now() - t.getTime();
  const min = Math.floor(d / 60000);
  if (min < 1) return '刚刚';
  if (min < 60) return `${min} 分钟前`;
  if (min < 1440) return `${Math.floor(min / 60)} 小时前`;
  if (min < 43200) return `${Math.floor(min / 1440)} 天前`;
  return `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, '0')}-${String(t.getDate()).padStart(2, '0')}`;
}

/** 会话列表:搜索/项目过滤 + 普通模式点开即聊 + 管理模式多选批量置顶/删除。 */
export function SessionsPage({ store, onOpen, onNewSession }: {
  store: ZStore; onOpen: (id: string) => void; onNewSession?: () => void;
}) {
  const sessions = useStore(store, (s) => s.sessions);
  const wsState = useStore(store, (s) => s.wsState);
  const projects = useStore(store, (s) => s.projects);
  const [manage, setManage] = useState(false);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [query, setQuery] = useState('');
  const [proj, setProj] = useState('');
  const [renaming, setRenaming] = useState<{ id: string; title: string } | null>(null);

  useEffect(() => { void store.getState().loadProjects(); }, [store]);

  /** 会话所属项目:cwd 在项目总目录下取首段;不在总目录/无 cwd = 未分类。 */
  const projectOf = useMemo(() => {
    const root = projects.root.replace(/[\\/]+$/, '');
    return (s: SessionRow): string => {
      if (!root || !s.cwd) return '__none__';
      const norm = s.cwd.replaceAll('/', '\\').toLowerCase();
      const normRoot = root.replaceAll('/', '\\').toLowerCase();
      if (!norm.startsWith(normRoot.toLowerCase() + '\\')) return '__none__';
      const rest = norm.slice(normRoot.length + 1);
      const first = rest.split('\\')[0];
      return projects.names.some((n) => n.toLowerCase() === first) ? first : '__none__';
    };
  }, [projects]);

  const visible = useMemo(() => {
    const q = query.trim().toLowerCase();
    return sessions.filter((s) => {
      if (q && !s.title.toLowerCase().includes(q)) return false;
      if (proj && projectOf(s) !== proj) return false;
      return true;
    });
  }, [sessions, query, proj, projectOf]);

  const togglePick = (id: string) => {
    const next = new Set(picked);
    if (next.has(id)) next.delete(id); else next.add(id);
    setPicked(next);
  };

  const batchDelete = async () => {
    await store.getState().deleteSessions([...picked]);
    setPicked(new Set());
  };

  const batchPin = async () => {
    for (const id of picked) await store.getState().patchSession(id, { isPinned: true });
    setPicked(new Set());
  };

  return (
    <div className="sessions">
      {wsState !== 'open' && (
        <button type="button" className="strip strip--warn" onClick={() => void store.getState().refreshSessions()}>
          <span className="dot dot--pulse" /> 未连接({wsState})—— 正在自动重连,也可点击刷新
        </button>
      )}
      <header className="sessions__head">
        <h2 className="page-title">会话</h2>
        <div className="sessions__actions">
          <button
            type="button"
            className="btn-ghost"
            onClick={() => { setManage((m) => !m); setPicked(new Set()); }}
          >
            {manage ? '完成' : '管理'}
          </button>
        </div>
      </header>

      <div className="sessions__tools">
        <input
          aria-label="搜索会话"
          className="field__input"
          placeholder="搜索标题…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        <select aria-label="项目过滤" className="field__input sessions__proj" value={proj} onChange={(e) => setProj(e.target.value)}>
          <option value="">全部项目</option>
          <option value="__none__">未分类</option>
          {projects.names.map((n) => <option key={n} value={n}>{n}</option>)}
        </select>
      </div>

      <ul className="session-list">
        {visible.map((s) => {
          const id = s.id;
          const pickedRow = picked.has(id);
          return (
            <li key={id} className={`card session-row${pickedRow ? ' is-picked' : ''}`}>
              {manage && (
                <input
                  type="checkbox"
                  aria-label={`选择 ${s.title}`}
                  className="session-row__check"
                  checked={pickedRow}
                  onChange={() => togglePick(id)}
                />
              )}
              <button
                type="button"
                className="session-row__main"
                onClick={() => { if (!manage) onOpen(id); else togglePick(id); }}
              >
                <span className="session-row__title">
                  {Number(s.isPinned) === 1 || s.isPinned === true ? <span className="pin">◆ </span> : null}
                  {s.title}
                </span>
                <span className="session-row__meta">
                  {s.source === 'local' && <em className="tag tag--local">本地</em>}
                  {s.model && s.model !== 'default' && <em className="tag tag--model mono">{s.model}</em>}
                  {s.isRunning && <em className="tag tag--running"><span className="dot dot--pulse" /> 运行中</em>}
                  <span className="session-row__time">{timeLabel(s.updatedAt)}</span>
                </span>
              </button>
              {!manage && (
                <span className="session-row__ops">
                  <button
                    type="button"
                    className="btn-ghost btn-ghost--sm"
                    aria-label={`重命名 ${id}`}
                    onClick={() => setRenaming({ id, title: s.title })}
                  >
                    改名
                  </button>
                  <button
                    type="button"
                    className="btn-ghost btn-ghost--sm"
                    aria-label={`置顶 ${id}`}
                    onClick={() => void store.getState().patchSession(id, { isPinned: !(Number(s.isPinned) === 1 || s.isPinned === true) })}
                  >
                    置顶
                  </button>
                  <button
                    type="button"
                    className="btn-ghost btn-ghost--sm danger"
                    aria-label={`删除 ${id}`}
                    onClick={() => void store.getState().deleteSession(id)}
                  >
                    删除
                  </button>
                </span>
              )}
            </li>
          );
        })}
        {visible.length === 0 && sessions.length > 0 && <li className="session-empty">没有匹配的会话。</li>}
        {sessions.length === 0 && (
          <li className="session-empty">
            <span className="session-empty__glyph" aria-hidden>◆</span>
            <p>还没有会话</p>
            {onNewSession && (
              <button type="button" className="btn-gold" onClick={onNewSession}>＋ 新建第一个会话</button>
            )}
          </li>
        )}
      </ul>

      {manage && picked.size > 0 && (
        <footer className="manage-bar">
          <button type="button" className="btn-ghost" onClick={() => void batchPin()}>置顶所选</button>
          <button type="button" className="btn-danger" onClick={() => void batchDelete()}>删除所选</button>
        </footer>
      )}

      {renaming && (
        <div
          className="dialog-mask"
          role="presentation"
          onClick={(e) => { if (e.target === e.currentTarget) setRenaming(null); }}
          onKeyDown={(e) => { if (e.key === 'Escape') setRenaming(null); }}
        >
          <div className="dialog" role="dialog" aria-modal="true" aria-label="重命名会话">
            <h3 className="dialog__title">重命名会话</h3>
            <label className="field">
              <span className="field__label">标题</span>
              <input
                autoFocus
                aria-label="新标题"
                className="field__input"
                value={renaming.title}
                onChange={(e) => setRenaming({ ...renaming, title: e.target.value })}
              />
            </label>
            <div className="dialog__ops">
              <button type="button" className="btn-ghost" onClick={() => setRenaming(null)}>取消</button>
              <button
                type="button"
                className="btn-gold"
                onClick={() => {
                  void store.getState().patchSession(renaming.id, { title: renaming.title }).then(() => setRenaming(null));
                }}
              >
                保存
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
