import { useEffect, useState } from 'react';

/**
 * 流式区(列表底部):
 * - running 且无任何流式内容 → 「已送达 · 正在思考」骨架行(静默期反馈)
 * - 有 thinking → 深度思考卡;有 text → 正在回复
 */
export function StreamingArea({ running, streamingText, streamingThinking }: {
  running: boolean; streamingText?: string; streamingThinking?: string;
}) {
  const [since, setSince] = useState(Date.now());
  const [now, setNow] = useState(Date.now());

  useEffect(() => {
    if (!running) return;
    setSince(Date.now());
    setNow(Date.now());
    const t = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(t);
  }, [running]);

  if (!running) return null;
  const secs = Math.max(0, Math.floor((now - since) / 1000));

  if (!streamingText && !streamingThinking) {
    return (
      <div className="stream-skeleton">
        <span className="dot dot--pulse" />
        <span>已送达 · 正在思考</span>
        <span className="mono stream-skeleton__secs">{secs}s</span>
        {secs >= 5 && <span className="stream-skeleton__hint">模型唤醒中,冷启动可能较慢</span>}
      </div>
    );
  }
  return (
    <div className="stream-area">
      {streamingThinking && (
        <div className="stream-thinking">
          <span className="dot dot--pulse" /> 深度思考中
          <span className="stream-thinking__text">{streamingThinking.at(-1)}</span>
        </div>
      )}
      {streamingText && (
        <div className="stream-text">
          <div className="stream-text__label"><span className="dot dot--pulse" /> 正在回复</div>
          <div className="stream-text__body mono">{streamingText}</div>
        </div>
      )}
    </div>
  );
}
