// 纯函数状态归约:WS 事件 → ChatState。语义 1:1 移植 Flutter 版 reducer.dart
// (seq 去重、乐观行转正、悬空工具卡收尾、RUN_IN_PROGRESS 回滚),UI 只读。

export interface UserRow { kind: 'user'; content: string; pending: boolean; createdAt?: string }
export interface TextRow { kind: 'text'; content: string; createdAt?: string }
export interface ThinkingRow { kind: 'thinking'; content: string }
export interface ToolResult { content: string; isError: boolean }
export interface ToolRow {
  kind: 'tool'; toolId: string; toolName: string;
  toolInput: Record<string, unknown>; result?: ToolResult; startedAt: number;
}
export interface ErrorRow { kind: 'error'; content: string }
export type ChatRow = UserRow | TextRow | ThinkingRow | ToolRow | ErrorRow;

export interface UsageInfo {
  inputTokens: number; outputTokens: number;
  cacheReadInputTokens: number; cacheCreationInputTokens: number;
  totalCostUsd: number; durationMs: number; numTurns: number;
  contextWindow: number; maxOutputTokens: number;
}
/** 上一轮上下文占用 ≈ 输入 + 缓存读 + 缓存写。 */
export function contextTokens(u: UsageInfo): number {
  return u.inputTokens + u.cacheReadInputTokens + u.cacheCreationInputTokens;
}

export interface PermissionReq { requestId: string; toolName: string; input: Record<string, unknown> }

export interface ChatState {
  rows: ChatRow[];
  lastSeq: number;
  running: boolean;
  /** 已加载的最旧 seq(按需加载锚点);0 = 没有/未加载历史 */
  oldestSeq: number;
  /** 是否还有更旧的历史(滑到顶时"加载更早") */
  hasMoreOlder: boolean;
  streamingText?: string;
  streamingThinking?: string;
  usage?: UsageInfo;
  pendingPermission?: PermissionReq;
}

export function emptyChat(): ChatState {
  return { rows: [], lastSeq: 0, running: false, oldestSeq: 0, hasMoreOlder: false };
}

/** 被打断工具卡的占位结果:可辨识,迟到的真 tool_result 会覆盖它。 */
export const K_INTERRUPTED = '[中断] 命令被打断或服务重启,没有回传输出';

function withState(s: ChatState, patch: Partial<ChatState> & { clearStreamText?: boolean; clearStreamThinking?: boolean; clearPermission?: boolean }): ChatState {
  return {
    rows: patch.rows ?? s.rows,
    lastSeq: patch.lastSeq ?? s.lastSeq,
    running: patch.running ?? s.running,
    oldestSeq: patch.oldestSeq ?? s.oldestSeq,
    hasMoreOlder: patch.hasMoreOlder ?? s.hasMoreOlder,
    streamingText: patch.clearStreamText ? undefined : (patch.streamingText ?? s.streamingText),
    streamingThinking: patch.clearStreamThinking ? undefined : (patch.streamingThinking ?? s.streamingThinking),
    usage: patch.usage ?? s.usage,
    pendingPermission: patch.clearPermission ? undefined : (patch.pendingPermission ?? s.pendingPermission),
  };
}

/** 还没拿到结果的工具卡就地落定:中断的输出回不来了,别让卡片永远转圈。 */
function closeDanglingTools(rows: ChatRow[]): ChatRow[] {
  let changed = false;
  const next = rows.map<ChatRow>((r) => {
    if (r.kind === 'tool' && !r.result) {
      changed = true;
      return { ...r, result: { content: K_INTERRUPTED, isError: true } };
    }
    return r;
  });
  return changed ? next : rows;
}

const num = (v: unknown, d = 0): number => (typeof v === 'number' ? v : d);

/** 批量归约的行缓冲:传了 sink 就复用它(可变原地改),否则复制一份 —— 对齐 Flutter reducer 的 _rowsInto。 */
function rowsInto(s: ChatState, sink?: ChatRow[]): ChatRow[] {
  return sink ?? [...s.rows];
}

/** 按需加载的更旧一页:事件(升序)在独立缓冲里走完整 applyEvent 归约(所有 kind、
 *  页内工具配对、error 行都与首屏同一构造逻辑,对齐 Flutter 的 sink 用法),
 *  归约出的行整体前插;不改主 state 的 lastSeq —— 旧页 seq 全部 < lastSeq 是正常的。 */
export function prependHistory(s: ChatState, eventsAsc: Record<string, unknown>[]): ChatState {
  const sink: ChatRow[] = [];
  let tmp = emptyChat();
  for (const ev of eventsAsc) tmp = applyEvent(tmp, ev, sink);
  return withState(s, { rows: [...sink, ...s.rows] });
}

/** 单事件归约;seq <= lastSeq 的事件丢弃(重连去重),permission_request 豁免。
 *  sink 仅批量路径(prependHistory)传,见 rowsInto。 */
export function applyEvent(s: ChatState, ev: Record<string, unknown>, sink?: ChatRow[]): ChatState {
  const kind = typeof ev.kind === 'string' ? ev.kind : '';
  const seq = typeof ev.seq === 'number' ? ev.seq : undefined;
  if (seq !== undefined && seq <= s.lastSeq && kind !== 'permission_request') return s;
  const nextSeq = seq !== undefined && seq > s.lastSeq ? seq : s.lastSeq;

  switch (kind) {
    case 'stream_delta':
      return withState(s, {
        lastSeq: nextSeq, running: true,
        streamingText: (s.streamingText ?? '') + String(ev.content ?? ''),
      });
    case 'thinking_delta':
      return withState(s, {
        lastSeq: nextSeq, running: true,
        streamingThinking: (s.streamingThinking ?? '') + String(ev.content ?? ''),
      });
    case 'text': {
      const isUser = (ev.role as string | undefined ?? 'assistant') === 'user';
      if (isUser) {
        // 服务器回显用户消息:就地转正第一条同内容的 pending 行,不追加(防双气泡)。
        const content = String(ev.content ?? '');
        const rows = rowsInto(s, sink);
        const idx = rows.findIndex((r) => r.kind === 'user' && r.pending && r.content === content);
        if (idx >= 0) rows[idx] = { kind: 'user', content, pending: false, createdAt: (ev.createdAt as string | undefined) ?? (rows[idx] as UserRow).createdAt };
        else rows.push({ kind: 'user', content, pending: false, createdAt: ev.createdAt as string | undefined });
        return withState(s, { lastSeq: nextSeq, running: true, rows });
      }
      return withState(s, {
        lastSeq: nextSeq, running: true, clearStreamText: true,
        rows: rowsInto(s, sink).concat({ kind: 'text', content: String(ev.content ?? ''), createdAt: ev.createdAt as string | undefined }),
      });
    }
    case 'thinking':
      return withState(s, {
        lastSeq: nextSeq, running: true, clearStreamThinking: true,
        rows: rowsInto(s, sink).concat({ kind: 'thinking', content: String(ev.content ?? '') }),
      });
    case 'tool_use':
      return withState(s, {
        lastSeq: nextSeq, running: true,
        rows: rowsInto(s, sink).concat({
          kind: 'tool',
          toolId: String(ev.toolId ?? ''),
          toolName: String(ev.toolName ?? ''),
          toolInput: (ev.toolInput as Record<string, unknown> | undefined) ?? {},
          startedAt: Date.now(),
        }),
      });
    case 'tool_result': {
      const toolId = String(ev.toolId ?? '');
      const result: ToolResult = { content: String(ev.content ?? ''), isError: ev.isError === true };
      const rows = rowsInto(s, sink);
      // 也匹配被中断标记收尾的卡:重连时 subscribed(false) 先到、replay 后到,
      // 放宽匹配,迟到的真结果才能覆盖占位标记。
      const idx = rows.findLastIndex((r) =>
        r.kind === 'tool' && r.toolId === toolId && (!r.result || r.result.content === K_INTERRUPTED));
      if (idx >= 0) {
        const t = rows[idx] as ToolRow;
        rows[idx] = { ...t, result };
      }
      return withState(s, { lastSeq: nextSeq, running: true, rows });
    }
    case 'permission_request':
      return withState(s, {
        pendingPermission: {
          requestId: String(ev.requestId ?? ''),
          toolName: String(ev.toolName ?? ''),
          input: (ev.input as Record<string, unknown> | undefined) ?? {},
        },
      });
    case 'usage':
      return withState(s, {
        lastSeq: nextSeq,
        usage: {
          inputTokens: num(ev.inputTokens), outputTokens: num(ev.outputTokens),
          cacheReadInputTokens: num(ev.cacheReadInputTokens), cacheCreationInputTokens: num(ev.cacheCreationInputTokens),
          totalCostUsd: num(ev.totalCostUsd), durationMs: num(ev.durationMs), numTurns: num(ev.numTurns),
          contextWindow: num(ev.contextWindow), maxOutputTokens: num(ev.maxOutputTokens),
        },
      });
    case 'complete':
      // 收尾:没拿到结果的工具卡就地落定;清流式与待审批。
      return withState(s, {
        lastSeq: nextSeq, running: false,
        clearStreamText: true, clearStreamThinking: true, clearPermission: true,
        rows: closeDanglingTools(s.rows),
      });
    case 'error': {
      const content = String(ev.content ?? '');
      if (content === 'RUN_IN_PROGRESS') {
        // 上一轮仍在跑:撤回乐观行(否则一直挂假气泡)、保持 running 让停止键出现。
        const rolled = rollbackLocalUser(s);
        return withState(rolled, {
          lastSeq: nextSeq, running: true,
          rows: [...rolled.rows, { kind: 'error', content: '上一轮仍在运行(可能已卡住):点停止按钮 ■ 后再重发' }],
        });
      }
      return withState(s, { lastSeq: nextSeq, running: false, rows: rowsInto(s, sink).concat({ kind: 'error', content }) });
    }
    case 'subscribed': {
      // 只取运行态,不抬 lastSeq:服务器指针先于 replay 到达,先抬会把 replay 整批去重丢弃。
      const isProcessing = ev.isProcessing === true;
      return withState(s, {
        running: isProcessing,
        rows: isProcessing ? s.rows : closeDanglingTools(s.rows),
      });
    }
    default:
      return seq !== undefined ? withState(s, { lastSeq: nextSeq }) : s;
  }
}

/** 重连补发:一批事件按序灌入(applyEvent 自带 seq 去重)。 */
export function applyReplay(s: ChatState, events: Record<string, unknown>[]): ChatState {
  let cur = s;
  for (const ev of events) cur = applyEvent(cur, ev);
  return cur;
}

/** 本地乐观插入用户消息(不占 seq);createdAt 记本地时刻,对齐 Flutter 乐观行语义。 */
export function applyLocalUser(s: ChatState, content: string): ChatState {
  return withState(s, { running: true, rows: [...s.rows, { kind: 'user', content, pending: true, createdAt: new Date().toISOString() }] });
}

/** 应答权限后立即收起面板(complete 也会清,这里只为即时反馈)。 */
export function applyPermissionAnswer(s: ChatState): ChatState {
  return withState(s, { clearPermission: true });
}

/** 回滚末尾的乐观用户行(发送失败时)。 */
export function rollbackLocalUser(s: ChatState): ChatState {
  const idx = s.rows.findLastIndex((r) => r.kind === 'user' && r.pending);
  if (idx < 0) return s;
  const rows = [...s.rows];
  rows.splice(idx, 1);
  return withState(s, { rows });
}
