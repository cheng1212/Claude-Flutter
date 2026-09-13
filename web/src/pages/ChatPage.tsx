import { useEffect, useMemo, useRef, useState } from 'react';
import { useStore } from 'zustand';
import { loadCreds, type ZStore } from '../lib/store';
import { ZApi } from '../lib/api';
import { ChatRowView } from '../components/rows';
import { StreamingArea } from '../components/StreamingArea';
import { PermissionCard } from '../components/PermissionCard';
import { PlanPanel } from '../components/PlanPanel';
import { TasksPanel } from '../components/TasksPanel';
import { derivePlanSteps } from '../lib/planSteps';

const MODES = [
  { value: 'default', label: '每次确认' },
  { value: 'acceptEdits', label: '自动接受编辑' },
  { value: 'bypassPermissions', label: '跳过确认' },
  { value: 'plan', label: '计划模式' },
];

/** 聊天页:历史 + 流式 + 权限 + 发送。正序渲染 + 贴底跟随(阈值 80px,对齐 Flutter),进入会话/历史就绪强制钉到最新。 */
export function ChatPage({ store, sessionId }: {
  store: ZStore; sessionId: string;
}) {
  useEffect(() => { void store.getState().openSession(sessionId); }, [store, sessionId]);

  const chat = useStore(store, (s) => s.chat);
  const historyLoading = useStore(store, (s) => s.historyLoading);
  const sessions = useStore(store, (s) => s.sessions);
  const modelGroups = useStore(store, (s) => s.modelGroups);
  const [input, setInput] = useState('');
  const [picker, setPicker] = useState<'none' | 'model' | 'mode' | 'tasks'>('none');
  const [uploadPct, setUploadPct] = useState<number | null>(null);
  const [uploadErr, setUploadErr] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const stickRef = useRef(true);
  const [showJump, setShowJump] = useState(false);

  // 面板/上传用轻量 REST 客户端:凭据登录时已持久化,不必经 store 转发。
  const api = useMemo(() => {
    const c = loadCreds();
    return c ? new ZApi(c.baseUrl, c.token) : null;
  }, []);

  const scrollToEnd = (smooth = false) => {
    const el = listRef.current;
    if (!el) return;
    // jsdom(单测)没有 scrollTo:兜底 scrollTop 赋值
    if (typeof el.scrollTo === 'function') el.scrollTo({ top: el.scrollHeight, behavior: smooth ? 'smooth' : 'auto' });
    else el.scrollTop = el.scrollHeight;
  };

  const onScroll = () => {
    const el = listRef.current;
    if (!el) return;
    const gap = el.scrollHeight - el.scrollTop - el.clientHeight;
    stickRef.current = gap < 80; // 贴底阈值,对齐 Flutter kAtBottomThreshold
    setShowJump(gap >= 80);
  };

  // 进入会话/历史加载完成:强制钉到最新一条(用户上来先看到的是现在,不是过去)。
  useEffect(() => {
    stickRef.current = true;
    setShowJump(false);
    scrollToEnd();
  }, [sessionId, historyLoading]);

  // 新行与流式增长:仅在贴底时跟随,用户上翻看历史就不打扰。
  useEffect(() => {
    if (stickRef.current) scrollToEnd();
  }, [chat.rows.length, chat.streamingText, chat.streamingThinking]);

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

  const send = () => {
    if (!input.trim()) return;
    store.getState().sendChat(input);
    setInput('');
  };

  /** 上传:分块+进度在 api 层;完成后把电脑上的路径追加进输入框,发不发由用户定。 */
  const handleFiles = async (files: FileList | null) => {
    if (!files?.length || !api) return;
    setUploadErr(null);
    for (const f of files) {
      try {
        setUploadPct(0);
        const bytes = new Uint8Array(await f.arrayBuffer());
        const res = await api.uploadFile(sessionId, f.name, bytes, (p) => setUploadPct(p));
        setInput((prev) => (prev ? `${prev}\n[附件] ${res.path}` : `[附件] ${res.path}`));
      } catch (e) {
        setUploadErr(`上传失败(${f.name}): ${e instanceof Error ? e.message : String(e)}`);
        break; // 一旦失败就停,避免连环报错
      } finally {
        setUploadPct(null);
      }
    }
    if (fileRef.current) fileRef.current.value = '';
  };

  return (
    <div className="chat">
      <div className="chat-list" ref={listRef} onScroll={onScroll}>
        <div className="chat-list__inner">
          <div className="chat__headtail">
            {session && <span className="mono chat__headmeta">{model} · {MODES.find((m) => m.value === mode)?.label ?? mode}</span>}
          </div>
          {plan && <PlanPanel steps={plan} />}
          {chat.rows.map((row, i) => (
            <ChatRowView key={`${row.kind}-${i}`} row={row} />
          ))}
          <StreamingArea running={chat.running} streamingText={chat.streamingText} streamingThinking={chat.streamingThinking} />
        </div>
      </div>

      {showJump && (
        <button
          type="button"
          className="jump-latest"
          onClick={() => { stickRef.current = true; setShowJump(false); scrollToEnd(true); }}
        >
          ↓ 回到最新
        </button>
      )}

      {chat.pendingPermission && (
        <PermissionCard
          req={chat.pendingPermission}
          onAnswer={(allow, message) => store.getState().answerPermission(chat.pendingPermission!.requestId, allow, message)}
        />
      )}

      {uploadErr && <div className="strip strip--error">{uploadErr}</div>}
      {uploadPct !== null && (
        <div className="strip strip--warn">正在上传 {Math.round(uploadPct * 100)}%…</div>
      )}

      {picker === 'tasks' && api && (
        <TasksPanel api={api} sessionId={sessionId} onClose={() => setPicker('none')} />
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
            <button type="button" className="chip" onClick={() => setPicker(picker === 'tasks' ? 'none' : 'tasks')}>
              ☑ 任务
            </button>
            <button
              type="button"
              className="chip"
              disabled={uploadPct !== null}
              onClick={() => fileRef.current?.click()}
            >
              {uploadPct !== null ? `上传 ${Math.round(uploadPct * 100)}%` : '＋ 附件'}
            </button>
            <input
              ref={fileRef}
              type="file"
              multiple
              hidden
              aria-label="选择要上传的文件"
              onChange={(e) => void handleFiles(e.target.files)}
            />
          </div>
          {chat.running
            ? <button type="button" className="btn-stop" aria-label="停止" onClick={() => store.getState().abort()}>■ 停止</button>
            : <button type="button" className="btn-gold" aria-label="发送" disabled={!input.trim()} onClick={send}>发送 ▸</button>}
        </div>
      </footer>
    </div>
  );
}
