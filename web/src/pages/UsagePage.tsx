import { useCallback, useEffect, useState } from 'react';
import { ZApi } from '../lib/api';

type Row = Record<string, unknown>;
const n = (v: unknown): number => (typeof v === 'number' ? v : 0);
const s = (v: unknown): string => (v == null ? '' : String(v));

function fmtTok(v: number): string {
  if (v >= 1_000_000) return `${(v / 1_000_000).toFixed(1)}M`;
  if (v >= 1_000) return `${(v / 1_000).toFixed(1)}K`;
  return String(v);
}

const RANGES = [
  { value: '7d', label: '7 天' },
  { value: '30d', label: '30 天' },
  { value: 'all', label: '全部' },
] as const;

/** 用量页:总览 + 按日柱状 + 按模型明细(数据 = GET /api/usage?range=7d|30d|all)。 */
export function UsagePage({ api, onBack }: { api: ZApi; onBack: () => void }) {
  const [range, setRange] = useState<'7d' | '30d' | 'all'>('7d');
  const [data, setData] = useState<Row | null>(null);
  const [loading, setLoading] = useState(false);

  const reload = useCallback(async () => {
    setLoading(true);
    try {
      setData(await api.usageStats(range));
    } finally {
      setLoading(false);
    }
  }, [api, range]);

  useEffect(() => { void reload(); }, [reload]);

  const models = (data?.models as Row[] | undefined) ?? [];
  const daily = (data?.daily as Row[] | undefined) ?? [];
  const dayTotals = daily.map((d) => {
    const ms = (d.models as Row[] | undefined) ?? [];
    return { date: s(d.date), total: ms.reduce((acc, m) => acc + n(m.totalTokens), 0) };
  });
  const maxDay = Math.max(1, ...dayTotals.map((d) => d.total));

  return (
    <div className="usage">
      <header className="sessions__head">
        <button type="button" className="btn-ghost" aria-label="返回" onClick={onBack}>‹ 返回</button>
        <h2 className="page-title">用 量</h2>
        <div className="sessions__actions">
          {RANGES.map((r) => (
            <button
              key={r.value}
              type="button"
              className={`chip${range === r.value ? ' chip--on' : ''}`}
              onClick={() => setRange(r.value)}
            >
              {r.label}
            </button>
          ))}
        </div>
      </header>

      <div className="usage__body">
        <div className="usage__cards">
          <div className="card usage__card usage__card--main">
            <span className="usage__num mono">{loading ? '…' : fmtTok(n(data?.totalTokens))}</span>
            <span className="usage__cap">总 tokens</span>
          </div>
          <div className="card usage__card"><span className="usage__num mono">{fmtTok(n(data?.inputTokens))}</span><span className="usage__cap">输入(含缓存)</span></div>
          <div className="card usage__card"><span className="usage__num mono">{fmtTok(n(data?.outputTokens))}</span><span className="usage__cap">输出</span></div>
          <div className="card usage__card"><span className="usage__num mono">{n(data?.totalTurns)}</span><span className="usage__cap">轮次</span></div>
          <div className="card usage__card"><span className="usage__num mono">{n(data?.sessions)}</span><span className="usage__cap">会话</span></div>
        </div>

        <div className="card usage__block">
          <div className="picker__title">每日用量</div>
          {dayTotals.length === 0 && <div className="tasks__empty">这个时间段没有记录</div>}
          <div className="usage__bars">
            {dayTotals.map((d) => (
              <div key={d.date} className="usage__bar-col" title={`${d.date} · ${d.total} tokens`}>
                <div className="usage__bar-track">
                  <div className="usage__bar" style={{ height: `${Math.max(4, (d.total / maxDay) * 100)}%` }} />
                </div>
                <span className="usage__bar-day mono">{d.date.slice(5)}</span>
              </div>
            ))}
          </div>
        </div>

        <div className="card usage__block">
          <div className="picker__title">按模型</div>
          {models.length === 0 && <div className="tasks__empty">这个时间段没有记录</div>}
          {models.map((m) => (
            <div key={s(m.modelId)} className="usage__model">
              <span className="usage__model-name mono">{s(m.modelId)}</span>
              <span className="usage__model-track">
                <span className="usage__bar-fill" style={{ width: `${Math.round(n(m.share) * 100)}%` }} />
              </span>
              <span className="usage__model-num mono">{fmtTok(n(m.totalTokens))} · {Math.round(n(m.share) * 100)}%</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
