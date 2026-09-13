import { useDeferredValue, useEffect, useMemo, useRef, useState } from 'react';
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

// ── 滚动稳定性阈值(对齐 zremote composer_logic 纯函数常量)──
const FOLLOW_EXIT_PX = 180;   // 离底超过它 → 锁存「在看历史」(AnchorThresholds.exitPx)
const FOLLOW_ENTER_PX = 100;  // 距底小于它 → 回到贴底(AnchorThresholds.enterPx)
const FOLLOW_RELEASE_PX = 40; // 锁存解锁阈值,与 enter 制造死区防临界横跳(FollowLock.releasePx)

/** 聊天页:历史 + 流式 + 权限 + 发送。正序渲染 + 贴底跟随(阈值 80px,对齐 Flutter),进入会话/历史就绪强制钉到最新。 */
export function ChatPage({ store, sessionId }: {
  store: ZStore; sessionId: string;
}) {
  useEffect(() => { void store.getState().openSession(sessionId); }, [store, sessionId]);

  const chat = useStore(store, (s) => s.chat);
  const historyLoading = useStore(store, (s) => s.historyLoading);
  const loadingOlder = useStore(store, (s) => s.loadingOlder);
  const sessions = useStore(store, (s) => s.sessions);
  const modelGroups = useStore(store, (s) => s.modelGroups);
  const [input, setInput] = useState('');
  const [picker, setPicker] = useState<'none' | 'model' | 'mode' | 'tasks' | 'files'>('none');
  const [uploadPct, setUploadPct] = useState<number | null>(null);
  const [uploadErr, setUploadErr] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const albumRef = useRef<HTMLInputElement>(null);
  const cameraRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const pendingInitRef = useRef(false);
  const prevHeightRef = useRef(0);
  const loadLockRef = useRef(false);
  // ── 滚动稳定性(对齐 zremote chat_page/composer_logic 的纯函数架构)──
  // atBottom:双阈值滞回(enter 100/exit 180)——流式期间内容每 tick 长高,
  // 单阈值会让贴底判定在临界带反复横跳(zremote AnchorThresholds.resolve 同源)。
  const atBottomRef = useRef(true);
  // followLocked:「在看历史」意图锁存——主动滚离(>180)上锁,滚回 ≤40(releasePx
  // 死区设计)解锁;锁存期间内容再长也不拽人。只靠位置判定挡不住流式追加。
  const followLockedRef = useRef(false);
  const prevRowsRef = useRef(0);
  const [unread, setUnread] = useState(0); // 锁存期间错过的新消息数(回底按钮徽标)

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

  const [showJump, setShowJump] = useState(false);

  const onScroll = () => {
    const el = listRef.current;
    if (!el) return;
    const gap = el.scrollHeight - el.scrollTop - el.clientHeight;
    const maxScroll = el.scrollHeight - el.clientHeight;
    // 双阈值滞回(AnchorThresholds.resolve web 版):流式期间内容每 tick 长高,
    // 单阈值会让贴底判定在临界带反复横跳。
    atBottomRef.current = maxScroll <= 0
      ? true
      : (atBottomRef.current ? gap <= FOLLOW_EXIT_PX : gap <= FOLLOW_ENTER_PX);
    // FollowLock(对齐 zremote):主动滚离(>exit)上锁,锁存中滚回 ≤release(死区)解锁。
    if (!followLockedRef.current && maxScroll > 0 && gap > FOLLOW_EXIT_PX) followLockedRef.current = true;
    else if (followLockedRef.current && gap <= FOLLOW_RELEASE_PX) {
      followLockedRef.current = false;
      setUnread(0); // 回到最新端:徽标清零
    }
    const jump = !atBottomRef.current || (followLockedRef.current && unread > 0);
    setShowJump(jump); // 同值 setState 会被 React 去重,scroll 高频触发无渲染风暴
    // 滚到顶自动加载更早(CloudCLI 同款:scrollTop<100 触发;lock 防重入,完成 400ms 后解锁)
    if (el.scrollTop < 100 && chat.hasMoreOlder && !loadingOlder && !loadLockRef.current) {
      loadLockRef.current = true;
      void store.getState().loadOlder().finally(() => { setTimeout(() => { loadLockRef.current = false; }, 400); });
    }
  };

  // 初始钉底(照 CloudCLI 的 robust 方案):逐帧 scrollTop=scrollHeight,直到 scrollHeight
  // 连续 3 帧不再增长 —— markdown/代码高亮/图片异步渲染完才停;60 帧(~1s)封顶防死循环。
  // 之前"固定时间点补滚"的版本输在这里:内容在补滚窗口之后才长完,视口又被顶离底部。
  useEffect(() => {
    if (historyLoading) return;
    if (chat.rows.length === 0) return;
    const el = listRef.current;
    if (!el) return;
    pendingInitRef.current = true;
    atBottomRef.current = true;
    followLockedRef.current = false;
    setUnread(0);
    let frame = 0;
    let lastHeight = 0;
    let stable = 0;
    let raf = 0;
    const tick = () => {
      if (!pendingInitRef.current || !listRef.current) return;
      const box = listRef.current;
      box.scrollTop = box.scrollHeight;
      if (box.scrollHeight === lastHeight) stable++;
      else { stable = 0; lastHeight = box.scrollHeight; }
      frame++;
      if (stable < 3 && frame < 60) raf = requestAnimationFrame(tick);
      else pendingInitRef.current = false;
    };
    raf = requestAnimationFrame(tick);
    // 兜底帧:某些环境(无头/测试)不驱动 rAF,至少补滚一次
    const fb = setTimeout(() => { if (pendingInitRef.current) tick(); }, 400);
    return () => { if (raf) cancelAnimationFrame(raf); clearTimeout(fb); };
  }, [sessionId, historyLoading, chat.rows.length > 0]);

  // 加载更早:前插后按高度差补偿 scrollTop,视口锚在原内容上不跳(CloudCLI 同款兜底公式)。
  useEffect(() => {
    const el = listRef.current;
    if (!el) return;
    if (loadingOlder) { prevHeightRef.current = el.scrollHeight; return; }
    if (prevHeightRef.current) {
      el.scrollTop += el.scrollHeight - prevHeightRef.current;
      prevHeightRef.current = 0;
    }
  }, [loadingOlder]);

  // 新行与流式增长:跟随闸门 = atBottom(滞回) && 未锁存(对齐 zremote「每 tick 重判」);
  // 锁存期间错过的新行进未读徽标,回底清零。初始钉底期间让位。
  useEffect(() => {
    if (pendingInitRef.current) { prevRowsRef.current = chat.rows.length; return; }
    const grew = chat.rows.length > prevRowsRef.current;
    if (followLockedRef.current) {
      if (grew) {
        setUnread((u) => u + (chat.rows.length - prevRowsRef.current));
        setShowJump(true); // 锁存期间来新消息:点亮回底按钮
      }
    } else if (atBottomRef.current) {
      scrollToEnd(); // 贴底跟随:新行与流式增高都跟
    }
    prevRowsRef.current = chat.rows.length;
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
  // 流式文本用 React 原生并发节流:紧急更新(交互)优先,流式正文延迟渲染,不拖垮列表
  const deferredText = useDeferredValue(chat.streamingText);
  const deferredThinking = useDeferredValue(chat.streamingThinking);

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
      <div
        className="chat-list"
        ref={listRef}
        onScroll={onScroll}
        onWheel={(e) => { if (e.deltaY < 0) followLockedRef.current = true; }}
      >
        <div className="chat-list__inner">
          {chat.hasMoreOlder && (
            <button
              type="button"
              className="load-older"
              disabled={loadingOlder}
              onClick={() => { followLockedRef.current = true; void store.getState().loadOlder(); }}
            >
              {loadingOlder ? '加载中…' : '加载更早的消息'}
            </button>
          )}
          <div className="chat__headtail">
            {session && <span className="mono chat__headmeta">{model} · {MODES.find((m) => m.value === mode)?.label ?? mode}</span>}
          </div>
          {plan && <PlanPanel steps={plan} />}
          {chat.rows.map((row, i) => (
            <ChatRowView key={`${row.kind}-${i}`} row={row} />
          ))}
          <StreamingArea running={chat.running} streamingText={deferredText} streamingThinking={deferredThinking} />
        </div>
      </div>

      {showJump && (
      <button
        type="button"
        className="jump-latest"
        aria-label="滑到最新消息"
        onClick={() => {
          pendingInitRef.current = false;
          atBottomRef.current = true;
          followLockedRef.current = false;
          setUnread(0);
          setShowJump(false);
          scrollToEnd(); // 不用 smooth:程序化平滑滚动在部分 Chromium 内嵌环境(IAB/WebView)静默失效
        }}
      >
        ↓ 最新{unread > 0 ? ` ·${unread}` : ''}
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

      {picker === 'files' && (
        <div className="picker" role="region" aria-label="上传附件">
          <div className="picker__title">上传附件</div>
          <button type="button" className="picker__item" onClick={() => { setPicker('none'); albumRef.current?.click(); }}>
            🖼 相册 · 选择图片
          </button>
          <button type="button" className="picker__item" onClick={() => { setPicker('none'); cameraRef.current?.click(); }}>
            📷 相机 · 拍照
          </button>
          <button type="button" className="picker__item" onClick={() => { setPicker('none'); fileRef.current?.click(); }}>
            📁 文件 · 任意类型
          </button>
        </div>
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
              onClick={() => setPicker(picker === 'files' ? 'none' : 'files')}
            >
              {uploadPct !== null ? `上传 ${Math.round(uploadPct * 100)}%` : '＋ 附件'}
            </button>
            {/* 三个入口分别调起相册/相机/文件(accept+capture 由移动端浏览器分派);桌面端均为文件选择器 */}
            <input
              ref={albumRef}
              type="file"
              accept="image/*"
              multiple
              hidden
              aria-label="从相册选择图片"
              onChange={(e) => void handleFiles(e.target.files)}
            />
            <input
              ref={cameraRef}
              type="file"
              accept="image/*"
              capture="environment"
              hidden
              aria-label="拍照上传"
              onChange={(e) => void handleFiles(e.target.files)}
            />
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
