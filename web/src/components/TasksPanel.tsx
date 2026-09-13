import { useCallback, useEffect, useState } from 'react';
import type { ZApi } from '../lib/api';

type Row = Record<string, unknown>;

const s = (v: unknown): string => (v == null ? '' : String(v));

function timeLabel(iso: string): string {
  const t = new Date(iso);
  if (Number.isNaN(t.getTime())) return '';
  const min = Math.floor((Date.now() - t.getTime()) / 60000);
  if (min < 1) return '刚刚';
  if (min < 1440) return `${Math.floor(min / 60)} 小时前`;
  return `${t.getMonth() + 1}/${t.getDate()}`;
}

/** 任务面板:子代理 / 后台任务 / 定时任务 三区(对齐 Flutter tasks_sheet);子代理可展开只读转录。 */
export function TasksPanel({ api, sessionId, onClose }: {
  api: ZApi; sessionId: string; onClose: () => void;
}) {
  const [subs, setSubs] = useState<Row[]>([]);
  const [bgs, setBgs] = useState<Row[]>([]);
  const [crons, setCrons] = useState<Row[]>([]);
  const [loading, setLoading] = useState(false);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [transcript, setTranscript] = useState<Row[]>([]);
  const [loadingT, setLoadingT] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      const [a, b, c] = await Promise.all([
        api.subagents(sessionId).catch(() => []),
        api.backgrounds(sessionId).catch(() => []),
        api.crons(sessionId).catch(() => []),
      ]);
      setSubs(a); setBgs(b); setCrons(c);
    } finally {
      setLoading(false);
    }
  }, [api, sessionId]);

  useEffect(() => { void reload(); }, [reload]);

  const delCron = async (id: string) => {
    await api.deleteCron(id).catch(() => undefined);
    void reload();
  };

  /** 展开/收起子代理只读转录(点击同名行收起)。 */
  const toggleTranscript = async (agentId: string) => {
    if (expanded === agentId) { setExpanded(null); setTranscript([]); return; }
    setExpanded(agentId);
    setTranscript([]);
    setLoadingT(true);
    try {
      setTranscript(await api.subagentMessages(sessionId, agentId).catch(() => []));
    } finally {
      setLoadingT(false);
    }
  };

  return (
    <div className="picker tasks" role="region" aria-label="任务面板">
      <div className="tasks__bar">
        <div className="picker__title">任务面板</div>
        <span className="tasks__ops">
          <button type="button" className="btn-ghost btn-ghost--sm" onClick={() => void reload()}>{loading ? '刷新中…' : '刷新'}</button>
          <button type="button" className="btn-ghost btn-ghost--sm" onClick={onClose}>收起</button>
        </span>
      </div>

      <div className="picker__group">子代理({subs.length})</div>
      {subs.length === 0 && <div className="tasks__empty">本会话还没有子代理</div>}
      {subs.map((a, i) => {
        const agentId = s(a.agentId) || String(i);
        return (
          <div key={agentId}>
            <button
              type="button"
              className={`tasks__row tasks__row--clickable${expanded === agentId ? ' is-open' : ''}`}
              onClick={() => void toggleTranscript(agentId)}
              title="点击查看只读转录"
            >
              <span className="tasks__name">{s(a.description) || s(a.agentId) || '子代理'}</span>
              {s(a.agentType) && <em className="tag tag--model mono">{s(a.agentType)}</em>}
              <span className="session-row__time">{timeLabel(s(a.updatedAt))}</span>
              <span className="toolcard__chev">{expanded === agentId ? '▾' : '▸'}</span>
            </button>
            {expanded === agentId && (
              <div className="tasks__transcript">
                {loadingT && <div className="tasks__empty">转录加载中…</div>}
                {!loadingT && transcript.length === 0 && <div className="tasks__empty">转录为空或不可读</div>}
                {transcript.map((m, j) => (
                  <div key={j} className="tasks__msg">
                    <em className={`tag ${s(m.role) === 'user' ? 'tag--local' : 'tag--model'}`}>{s(m.role) || s(m.kind)}</em>
                    <span className="tasks__msg-text">{s(m.content).slice(0, 400) || '(空)'}</span>
                  </div>
                ))}
              </div>
            )}
          </div>
        );
      })}

      <div className="picker__group">后台任务({bgs.length})</div>
      {bgs.length === 0 && <div className="tasks__empty">没有后台任务</div>}
      {bgs.map((b, i) => {
        const running = s(b.status) === 'running';
        return (
          <div key={s(b.taskId ?? b.shell) || i} className="tasks__row">
            <span className={`dot${running ? ' dot--pulse' : ''}`} style={running ? undefined : { background: 'var(--z-aqua)' }} />
            <span className="tasks__name">{s(b.description) || s(b.prompt) || '后台任务'}</span>
            <span className="session-row__time">{s(b.status)}</span>
          </div>
        );
      })}

      <div className="picker__group">定时任务({crons.length})</div>
      {crons.length === 0 && <div className="tasks__empty">没有定时任务</div>}
      {crons.map((c) => {
        const id = s(c.id);
        const nf = s(c.next_fire);
        return (
          <div key={id} className="tasks__row">
            <span className="tasks__name">{s(c.name) || s(c.session_title) || '定时任务'}</span>
            <em className="tag tag--local mono">{s(c.cron)}</em>
            {nf && <span className="session-row__time">下次 {new Date(nf).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' })}</span>}
            <button type="button" className="btn-ghost btn-ghost--sm danger" aria-label={`删除定时任务 ${id}`} onClick={() => void delCron(id)}>删</button>
          </div>
        );
      })}
    </div>
  );
}
