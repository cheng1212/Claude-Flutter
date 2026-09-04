import { randomUUID } from 'node:crypto';
import { query as defaultQuery } from '@anthropic-ai/claude-agent-sdk';
import { transformMessage } from './transform.js';
import { startsBackgroundWork, type ProtocolEvent } from './types.js';
import { resolveClaudeExecutable } from './cli-path.js';

type AnyRecord = Record<string, unknown>;

const IMAGE_MEDIA_TYPES = new Set(['image/png', 'image/jpeg', 'image/gif', 'image/webp']);

/**
 * 组 SDK 用户消息 content:纯文本 → string;带图 → Anthropic content blocks
 * (text + base64 image)。图片 data URI(`data:image/png;base64,xxx`)解不开就丢弃,
 * 不让坏图拖垮整轮。
 */
function buildUserContent(text: string, images?: string[]): string | AnyRecord[] {
  if (!images || images.length === 0) return text;
  const blocks: AnyRecord[] = [];
  if (text.trim()) blocks.push({ type: 'text', text });
  for (const uri of images) {
    const match = /^data:(image\/(?:png|jpeg|gif|webp));base64,([A-Za-z0-9+/=]+)$/.exec(uri.trim());
    if (match && IMAGE_MEDIA_TYPES.has(match[1])) {
      blocks.push({ type: 'image', source: { type: 'base64', media_type: match[1], data: match[2] } });
    }
  }
  return blocks.length > 0 ? blocks : text;
}

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
  /** abort 强裁延迟:CLI 僵死时 interrupt/release 都解冻不了回合,等这么久后强判终态 */
  abortForceDelayMs?: number;
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
  private turnGen = 0; // 回合代数:强裁定时器不误伤下一轮
  private forceTurnFinish: (() => void) | null = null;

  constructor(private opts: RuntimeOptions) {
    this.queryFn = opts.queryFn ?? (defaultQuery as unknown as QueryFn);
    this.providerSessionId = opts.providerSessionId ?? null;
  }

  currentProviderSessionId(): string | null {
    return this.providerSessionId;
  }

  /** 发一条消息;等本轮终态(result/错误/中止)返回。images = base64 data URI(可选)。 */
  send(text: string, images?: string[]): Promise<void> {
    const run = this.turnChain.then(() => this.runTurnExclusive(text, images));
    this.turnChain = run.catch(() => {}); // 链不断
    return run;
  }

  /** 中止当前回合 / 掐断后台挂着的流。CLI 僵死时延时强裁,保证回合一定落定。 */
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
    // 强裁兜底:若 interrupt/release 都没能让回合结束(进程僵死),runtime.send 的
    // Promise 永不落定 → 网关清不了 running → 之后所有消息被 RUN_IN_PROGRESS 拒掉。
    const force = this.forceTurnFinish;
    if (force) {
      const delay = this.opts.abortForceDelayMs ?? 6000;
      setTimeout(force, delay).unref?.();
    }
  }

  answerPermission(requestId: string, decision: PermissionDecision): void {
    const resolve = this.pending.get(requestId);
    if (!resolve) return;
    this.pending.delete(requestId);
    resolve(decision);
  }

  /**
   * 会话级配置热更新(权限模式/模型/路由)。只影响后续回合的 buildOptions,
   * 已拉起的 CLI 进程不重启;下一条 send 起生效。
   */
  update(cfg: { model?: string | null; permissionMode?: string; routeSettings?: AnyRecord | null }): void {
    this.opts = { ...this.opts, ...cfg };
  }

  private async runTurnExclusive(text: string, images?: string[]): Promise<void> {
    this.aborted = false;
    this.release?.(); // 取代上一个仍挂着的 held 流
    this.release = null;
    await this.runTurn(text, images);
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
    const permissionMode = this.opts.permissionMode;
    if (permissionMode && permissionMode !== 'default') {
      options.permissionMode = permissionMode;
    }
    if (permissionMode === 'bypassPermissions') {
      // SDK 安全设计:bypass 模式必须显式 allow,否则 CLI 会拒绝
      options.allowDangerouslySkipPermissions = true;
    }
    if (route?.env) {
      // 路由 env 走 flag 层 settings:用户 ~/.claude/settings.json 的 env(全局
      // DeepSeek 直连)优先级高于进程 env,必须用 flag 层才能压过去
      options.settings = { env: route.env };
    }
    if (route?.settings) {
      options.settings = route.settings; // 路由 settings 显式给出时整体覆盖
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

  private runTurn(text: string, images?: string[]): Promise<void> {
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

    // stdin 流:先给用户消息(带图时是 content blocks 数组),然后一直挂到 release。
    const userContent = buildUserContent(text, images);
    const stream = (async function* () {
      yield { type: 'user', message: { role: 'user', content: userContent }, parent_tool_use_id: null };
      await held;
    })();

    const instance = this.queryFn({ prompt: stream, options: this.buildOptions() });
    this.currentInstance = instance;
    const gen = ++this.turnGen;

    return new Promise<void>((resolveTurn) => {
      let turnDone = false;
      let stallTimer: NodeJS.Timeout | null = null;
      const finishTurn = () => {
        if (turnDone) return;
        turnDone = true;
        if (stallTimer) clearTimeout(stallTimer);
        if (this.forceTurnFinish === forceFinish) this.forceTurnFinish = null;
        resolveTurn();
      };
      // 强裁:僵死回合的终态兜底(abort 延时调用)。代数不符说明本轮已被新回合取代,不碰。
      const forceFinish = () => {
        if (turnDone || this.turnGen !== gen) return;
        emitTerminal(1, true);
        finishTurn();
      };
      this.forceTurnFinish = forceFinish;

      // 静默看门狗:整整 approvalTimeoutMs 没有任何 CLI 输出且不在等审批 → 判卡死,
      // 发 error 并自动 abort(abort 内部还有强裁兜底)。等审批期间重新武装。
      const stallMs = this.opts.approvalTimeoutMs ?? 10 * 60 * 1000;
      const armStall = () => {
        if (stallTimer) clearTimeout(stallTimer);
        stallTimer = setTimeout(() => {
          if (turnDone) return;
          if (this.pending.size > 0) {
            armStall(); // 在等用户审批,再给一个周期
            return;
          }
          this.opts.emit({
            kind: 'error',
            content: `回合超过 ${Math.round(stallMs / 60000)} 分钟没有任何输出,已自动中断;请重发`,
          });
          void this.abort();
        }, stallMs);
        stallTimer.unref?.();
      };
      armStall();

      void (async () => {
        try {
          for await (const raw of instance) {
            armStall(); // 有输出就续期
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
          if (stallTimer) clearTimeout(stallTimer);
          release();
          finishTurn();
        }
      })();
    });
  }
}
