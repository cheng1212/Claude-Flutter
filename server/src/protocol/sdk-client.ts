import { randomUUID } from 'node:crypto';
import { query as defaultQuery } from '@anthropic-ai/claude-agent-sdk';
import { transformMessage } from './transform.js';
import { startsBackgroundWork, type ProtocolEvent } from './types.js';
import { resolveClaudeExecutable } from './cli-path.js';

type AnyRecord = Record<string, unknown>;

export type QueryInstance = AsyncIterable<AnyRecord> & { interrupt?: () => Promise<void> };
export type QueryFn = (args: { prompt: AsyncIterable<unknown>; options: AnyRecord }) => QueryInstance;

export type PermissionDecision = { allow: boolean; message?: string; updatedInput?: unknown };
type CanUseToolResult = { behavior: 'allow' | 'deny'; message?: string; updatedInput?: unknown };

export type RuntimeOptions = {
  appSessionId: string;
  providerSessionId?: string | null;
  cwd: string;
  model?: string | null;
  permissionMode?: string;
  routeSettings?: AnyRecord | null;
  emit: (event: ProtocolEvent) => void;
  queryFn?: QueryFn;
  bgCeilingMs?: number;
  approvalTimeoutMs?: number;
};

// 这些工具的审批在等用户交互,超时无意义 → 一直等
const INTERACTIVE_TOOLS = new Set(['AskUserQuestion', 'ExitPlanMode']);

/**
 * 单会话运行时:包装 SDK query(),把 CLI 消息流翻译成 ProtocolEvent。
 * - 串行回合(turn 链),新 send 取代仍挂着的后台 held 流
 * - canUseTool 桥接手机审批,带超时自动 deny
 * - result 发出后:有后台工作 → 保持 stdin 挂起等后续轮(ceiling 兜底);否则关闭
 */
export class SessionRuntime {
  private readonly queryFn: QueryFn;
  private turnChain: Promise<void> = Promise.resolve();
  private release: (() => void) | null = null;
  private currentInstance: QueryInstance | null = null;
  private pending = new Map<string, (d: PermissionDecision | null) => void>();
  private providerSessionId: string | null;
  private aborted = false;

  constructor(private readonly opts: RuntimeOptions) {
    this.queryFn = opts.queryFn ?? (defaultQuery as unknown as QueryFn);
    this.providerSessionId = opts.providerSessionId ?? null;
  }

  currentProviderSessionId(): string | null {
    return this.providerSessionId;
  }

  /** 发一条消息;等本轮终态(result/错误/中止)返回。 */
  send(text: string): Promise<void> {
    const run = this.turnChain.then(() => this.runTurnExclusive(text));
    this.turnChain = run.catch(() => {}); // 链不断
    return run;
  }

  /** 中止当前回合 / 掐断后台挂着的流。 */
  async abort(): Promise<void> {
    this.aborted = true;
    for (const resolve of this.pending.values()) resolve({ allow: false, message: 'aborted' });
    this.pending.clear();
    try {
      await this.currentInstance?.interrupt?.();
    } catch {
      // 进程已退出,忽略
    }
    this.release?.();
  }

  answerPermission(requestId: string, decision: PermissionDecision): void {
    const resolve = this.pending.get(requestId);
    if (!resolve) return;
    this.pending.delete(requestId);
    resolve(decision);
  }

  private async runTurnExclusive(text: string): Promise<void> {
    this.aborted = false;
    this.release?.(); // 取代上一个仍挂着的 held 流
    this.release = null;
    await this.runTurn(text);
  }

  private buildOptions(): AnyRecord {
    const route = this.opts.routeSettings as { env?: AnyRecord; model?: string; settings?: AnyRecord } | null | undefined;
    const env: AnyRecord = { ...process.env, ...(route?.env ?? {}) };
    delete env.ANTHROPIC_API_KEY; // 只认 AUTH_TOKEN,避免双 key 打架
    const options: AnyRecord = {
      cwd: this.opts.cwd,
      env,
      pathToClaudeCodeExecutable: resolveClaudeExecutable(),
      includePartialMessages: true,
      settingSources: ['project', 'user', 'local'],
      systemPrompt: { type: 'preset', preset: 'claude_code' },
      canUseTool: this.canUseTool,
    };
    const model = route?.model ?? this.opts.model ?? undefined;
    if (model) options.model = model;
    if (this.opts.permissionMode && this.opts.permissionMode !== 'default') {
      options.permissionMode = this.opts.permissionMode;
    }
    if (route?.env) {
      options.settings = route.settings; // 路由 settings 作 flag 层,压过用户 settings.json
    }
    if (this.providerSessionId) options.resume = this.providerSessionId;
    return options;
  }

  private canUseTool = async (toolName: string, input: unknown): Promise<CanUseToolResult> => {
    const requestId = randomUUID();
    this.opts.emit({ kind: 'permission_request', requestId, toolName, input });
    const decision = await new Promise<PermissionDecision | null>((resolve) => {
      const timer = INTERACTIVE_TOOLS.has(toolName)
        ? null
        : setTimeout(() => resolve(null), this.opts.approvalTimeoutMs ?? 10 * 60 * 1000);
      this.pending.set(requestId, (d) => {
        if (timer) clearTimeout(timer);
        resolve(d);
      });
    });
    this.pending.delete(requestId);
    if (decision === null) return { behavior: 'deny', message: 'approval timeout' };
    if (!decision.allow) return { behavior: 'deny', message: decision.message ?? 'user denied' };
    return { behavior: 'allow', updatedInput: decision.updatedInput ?? input };
  };

  private runTurn(text: string): Promise<void> {
    const bgCeilingMs = this.opts.bgCeilingMs ?? 30 * 60 * 1000;
    let ceilingTimer: NodeJS.Timeout | null = null;
    let terminalSent = false; // 本轮是否已发终态 complete(去重)
    let backgroundWorkPending = false;
    let heldForBackground = false;

    let releaseHeld!: () => void;
    const held = new Promise<void>((resolve) => { releaseHeld = resolve; });
    const release = () => releaseHeld();
    this.release = release;

    const emitTerminal = (exitCode: number, aborted: boolean) => {
      if (terminalSent) return;
      terminalSent = true;
      this.opts.emit({ kind: 'complete', exitCode, aborted });
    };

    // stdin 流:先给用户消息,然后一直挂到 release(release 即关闭输入 → CLI 退出)
    const stream = (async function* () {
      yield { type: 'user', message: { role: 'user', content: text }, parent_tool_use_id: null };
      await held;
    })();

    const instance = this.queryFn({ prompt: stream, options: this.buildOptions() });
    this.currentInstance = instance;

    return new Promise<void>((resolveTurn) => {
      let turnDone = false;
      const finishTurn = () => {
        if (turnDone) return;
        turnDone = true;
        resolveTurn();
      };

      void (async () => {
        try {
          for await (const raw of instance) {
            if (raw.type === 'system' && raw.subtype === 'init') {
              const sessionId = raw.session_id;
              if (!this.providerSessionId && typeof sessionId === 'string' && sessionId) {
                this.providerSessionId = sessionId;
                this.opts.emit({ kind: 'session_created', providerSessionId: sessionId });
              }
              continue;
            }
            if (this.aborted) break;
            const events = transformMessage(raw);
            for (const event of events) {
              if (event.kind === 'complete') emitTerminal(event.exitCode, event.aborted);
              else this.opts.emit(event);
            }
            if (startsBackgroundWork(events)) backgroundWorkPending = true;
            if (raw.type === 'result') {
              if (backgroundWorkPending && !heldForBackground) {
                // 有后台工作:保持 stdin 挂起等后续轮,ceiling 兜底
                heldForBackground = true;
                ceilingTimer = setTimeout(release, bgCeilingMs);
                ceilingTimer.unref?.();
              } else {
                release(); // 正常结束 / 后台后续轮已回 → 关输入
              }
              finishTurn(); // 客户端视角本轮已完;后续轮事件继续推给订阅者
            }
            if (this.aborted) break;
          }
          if (this.aborted) {
            emitTerminal(1, true);
          } else if (!terminalSent) {
            this.opts.emit({ kind: 'error', content: 'Claude Code 进程在回合结束前退出' });
            emitTerminal(1, false);
          }
        } catch (error) {
          if (this.aborted) {
            emitTerminal(1, true);
          } else if (!terminalSent) {
            const message = error instanceof Error ? error.message : String(error);
            this.opts.emit({ kind: 'error', content: message });
            emitTerminal(1, false);
          }
        } finally {
          if (ceilingTimer) clearTimeout(ceilingTimer);
          release();
          finishTurn();
        }
      })();
    });
  }
}
