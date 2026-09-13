import { randomUUID } from 'node:crypto';
import { query as defaultQuery } from '@anthropic-ai/claude-agent-sdk';
import type { ThinkingConfig } from '@anthropic-ai/claude-agent-sdk';
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

export type QueryInstance = AsyncIterable<AnyRecord> & {
  interrupt?: () => Promise<void>;
  setPermissionMode?: (mode: string) => Promise<void>;
  setModel?: (model?: string) => Promise<void>;
};
export type QueryFn = (args: { prompt: AsyncIterable<unknown>; options: AnyRecord }) => QueryInstance;

export type PermissionDecision = { allow: boolean; message?: string; updatedInput?: unknown; rememberTool?: boolean };
type CanUseToolResult = { behavior: 'allow' | 'deny'; message?: string; updatedInput?: unknown };

/** 在等用户审批的请求:resolve 之外保留详情,App 重启后经 subscribed 带回重建审批卡。 */
type PendingEntry = {
  resolve: (d: PermissionDecision | null) => void;
  toolName: string;
  input: unknown;
};

/** 看门狗"忙碌续期"上限:每次续期间隔 = approvalTimeoutMs,默认 10min × 6 = 1 小时。
 *  覆盖正常的长构建/长测试;真僵死(工具结果永远不回)最终仍会被裁。 */
const BUSY_REARM_LIMIT = 6;

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
  /** interrupt 回执超时:CLI 控制通道挂死时最多等这么久就放行后续 release/强裁 */
  interruptAckMs?: number;
  /** 复制会话:providerSessionId 为 fork 起点,首轮 init 回传的独立新 id 会回填并发 session_created */
  forkSession?: boolean;
  /** 子代理模型约束:配置后,本会话派 Agent/Task 一律强制用此模型(防挑贵模型) */
  subagentModel?: string;
  /** 思考等级:off/low/medium/high;on 或未设置 = 不注入(模型默认) */
  thinkingLevel?: string;
};

/**
 * 子代理模型约束决策:Agent/Task 派发且配置了强制模型 → allow 并改写 input.model
 * (updatedInput 对模型透明,它以为是自己选的);未配置/非派发工具 → null 走正常审批。
 */
export function subagentModelDecision(
  toolName: string,
  input: unknown,
  forcedModel: string | undefined | null,
): { behavior: 'allow'; updatedInput: Record<string, unknown> } | null {
  if (!forcedModel) return null;
  if (toolName !== 'Agent' && toolName !== 'Task') return null;
  const inp = (input ?? {}) as Record<string, unknown>;
  return { behavior: 'allow', updatedInput: { ...inp, model: forcedModel } };
}

/**
 * 思考等级 → SDK thinking 配置(标准 Anthropic thinking 协议)。
 * 实测:DeepSeek 端点 disabled 真实生效,预算分级弱响应;GLM 忽略此参数(永远思考)。
 * 'on'/未设置 → undefined:不注入,维持各模型自己的默认行为(qwen3.8 默认开)。
 */
export function thinkingConfigOf(level: string | undefined | null): ThinkingConfig | undefined {
  switch (level) {
    case 'off': return { type: 'disabled' };
    case 'low': return { type: 'enabled', budgetTokens: 4096 };
    case 'medium': return { type: 'enabled', budgetTokens: 16384 };
    case 'high': return { type: 'enabled', budgetTokens: 31999 };
    default: return undefined;
  }
}

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
  private pending = new Map<string, PendingEntry>();
  /** 本会话「总是允许」的工具:审批卡勾选后免弹,内存态,重启/删会话即清。 */
  private sessionAllowed = new Set<string>();
  /** 已发 tool_use 还没等到 tool_result 的工具:看门狗判"忙碌"的依据(静默 ≠ 卡死)。 */
  private openTools = new Set<string>();
  private providerSessionId: string | null;
  private forkPending: boolean; // fork 只发生在首轮(init 采纳新 id 后清零),否则缓存 runtime 每轮 resume 都会再分叉
  private aborted = false;
  private turnGen = 0; // 回合代数:强裁定时器不误伤下一轮
  private forceTurnFinish: (() => void) | null = null;
  /** 最近一次 API 请求的 prompt 大小 = 真实上下文占用(压缩后会自己变小) */
  private lastContextTokens = 0;

  constructor(private opts: RuntimeOptions) {
    this.queryFn = opts.queryFn ?? (defaultQuery as unknown as QueryFn);
    this.providerSessionId = opts.providerSessionId ?? null;
    this.forkPending = opts.forkSession === true;
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

  /** 当前在等用户审批的请求快照(gateway 经 subscribed 带给重连的客户端,重建审批卡)。 */
  pendingPermissions(): { requestId: string; toolName: string; input: unknown }[] {
    return [...this.pending.entries()].map(([requestId, p]) => ({ requestId, toolName: p.toolName, input: p.input }));
  }

  /** 中止当前回合 / 掐断后台挂着的流。CLI 僵死时延时强裁,保证回合一定落定。 */
  async abort(): Promise<void> {
    this.aborted = true;
    for (const p of this.pending.values()) p.resolve({ allow: false, message: 'aborted' });
    this.pending.clear();
    try {
      // interrupt 的回执走 CLI 控制通道:CLI 僵死时这个 await 会挂起——
      // 绝不能让它堵死后面的 release/强裁(那才是保证回合落定的两步)。
      await Promise.race([
        this.currentInstance?.interrupt?.(),
        new Promise<void>((r) => setTimeout(r, this.opts.interruptAckMs ?? 2000)),
      ]);
    } catch {
      // 进程已退出/中断被拒,忽略
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
    const entry = this.pending.get(requestId);
    if (!entry) return;
    this.pending.delete(requestId);
    // 「本会话总是允许」:记住工具名,同工具后续调用直接放行(canUseTool 头部短路)
    if (decision.allow && decision.rememberTool) this.sessionAllowed.add(entry.toolName);
    entry.resolve(decision);
  }

  /**
   * 会话级配置热更新(权限模式/模型/路由)。只影响后续回合的 buildOptions,
   * 已拉起的 CLI 进程不重启;下一条 send 起生效。
   */
  update(cfg: { model?: string | null; permissionMode?: string; routeSettings?: AnyRecord | null; thinkingLevel?: string | null }): void {
    this.opts = { ...this.opts, ...cfg, thinkingLevel: cfg.thinkingLevel ?? undefined };
  }

  /** 对在跑的 CLI 实例热设权限模式:本回合内后续工具调用立即生效(下一轮 buildOptions 也带,双保险)。 */
  async setPermissionModeLive(mode: string): Promise<void> {
    try {
      await this.currentInstance?.setPermissionMode?.(mode);
    } catch {
      // 实例已退出/不支持:opts 已随 update() 改,下一轮照新值走
    }
  }

  /** 对在跑的 CLI 实例热切模型(裸模型名才值得现场切;路由别名/ default 由下一轮生效)。 */
  async setModelLive(model: string): Promise<void> {
    try {
      await this.currentInstance?.setModel?.(model);
    } catch {
      // 同上
    }
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
    const thinking = thinkingConfigOf(this.opts.thinkingLevel);
    if (thinking) options.thinking = thinking;
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
    if (this.forkPending && this.providerSessionId) options.forkSession = true;
    return options;
  }

  private canUseTool = async (toolName: string, input: unknown): Promise<CanUseToolResult> => {
    // 子代理模型约束:配置了强制模型时,派子代理不经审批直接改写派发参数(对模型透明)
    const forced = subagentModelDecision(toolName, input, this.opts.subagentModel);
    if (forced) return forced;
    // 会话级记住的工具直接放行:审批疲劳是手机端最大的日常摩擦,用户显式勾选过就是授权
    if (this.sessionAllowed.has(toolName)) {
      return { behavior: 'allow', updatedInput: input };
    }
    const requestId = randomUUID();
    this.opts.emit({ kind: 'permission_request', requestId, toolName, input });
    const decision = await new Promise<PermissionDecision | null>((resolve) => {
      const timer = INTERACTIVE_TOOLS.has(toolName)
        ? null
        : setTimeout(() => resolve(null), this.opts.approvalTimeoutMs ?? 10 * 60 * 1000);
      this.pending.set(requestId, {
        resolve: (d) => {
          if (timer) clearTimeout(timer);
          resolve(d);
        },
        toolName,
        input,
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

      // 静默看门狗:整整 approvalTimeoutMs 没有任何 CLI 输出且不在等审批 → 检查是否
      // "忙碌静默"(还有没回结果的 tool_use,比如十几分钟的构建)——合法,续期而非误杀;
      // 连续 BUSY_REARM_LIMIT 个周期仍无任何输出才判真卡死。等审批期间同样续期。
      const stallMs = this.opts.approvalTimeoutMs ?? 10 * 60 * 1000;
      let busyRears = 0;
      const armStall = () => {
        if (stallTimer) clearTimeout(stallTimer);
        stallTimer = setTimeout(() => {
          if (turnDone) return;
          if (this.pending.size > 0) {
            armStall(); // 在等用户审批,再给一个周期
            return;
          }
          if (this.openTools.size > 0 && busyRears < BUSY_REARM_LIMIT) {
            busyRears += 1; // 工具还在跑:前台长命令静默是常态,不是卡死
            armStall();
            return;
          }
          this.opts.emit({
            kind: 'error',
            content: `回合超过 ${Math.round((stallMs * (1 + Math.min(busyRears, BUSY_REARM_LIMIT))) / 60000)} 分钟没有任何输出,已自动中断;请重发`,
          });
          void this.abort();
        }, stallMs);
        stallTimer.unref?.();
      };
      armStall();

      void (async () => {
        try {
          for await (const raw of instance) {
            armStall(); // 有输出就续期(忙碌计数也归零)
            busyRears = 0;
            if (raw.type === 'system' && raw.subtype === 'init') {
              const sessionId = raw.session_id;
              if (typeof sessionId === 'string' && sessionId) {
                // 新会话首捕;或 fork 分叉(init 回传 id ≠ resume 起点)→ 回填并发 session_created
                if (!this.providerSessionId
                  || (this.forkPending && sessionId !== this.providerSessionId)) {
                  this.providerSessionId = sessionId;
                  this.opts.emit({ kind: 'session_created', providerSessionId: sessionId });
                  this.forkPending = false; // 分叉已落地:后续轮恢复普通 resume,不再重复分叉
                }
              }
              continue;
            }
            if (this.aborted) {
              // 中断后继续消费:CLI 收到 interrupt 会把已生成的部分内容作为
              // assistant 消息发出来,丢掉等于让用户白等半天的生成蒸发。
              // 仅拦新工具启动(马上要停了),result(complete) 到达后自然收尾;
              // CLI 僵死由强裁兜底。原实现此处直接 break,partial 全部蒸发。
              for (const event of transformMessage(raw)) {
                if (event.kind === 'tool_use') continue;
                // 实时上下文占用照记(中断路径同样需要:实测漏了这步 → 被中断的回合
                // 落库的 usage 没有 contextTokens,面板显示回退到旧口径的越界值)
                if (event.kind === 'context_usage') this.lastContextTokens = event.contextTokens;
                if (event.kind === 'complete') {
                  emitTerminal(event.exitCode, true);
                  continue;
                }
                if (event.kind === 'usage' && this.lastContextTokens > 0) {
                  (event as { contextTokens?: number }).contextTokens = this.lastContextTokens;
                }
                this.opts.emit(event);
              }
              continue;
            }
            const events = transformMessage(raw);
            for (const event of events) {
              if (event.kind === 'tool_use') this.openTools.add(event.toolId);
              else if (event.kind === 'tool_result') this.openTools.delete(event.toolId);
              // 记下真实上下文占用(每次 API 请求的 prompt 大小),回合末随 usage 落库
              if (event.kind === 'context_usage') this.lastContextTokens = event.contextTokens;
              // 手机端气泡显示时间用:发射时刻即内容产生时刻(近似)
              if (['text', 'thinking', 'tool_use', 'tool_result', 'error'].includes(event.kind)) {
                (event as { createdAt?: string }).createdAt = new Date().toISOString();
              }
              if (event.kind === 'usage' && this.lastContextTokens > 0) {
                (event as { contextTokens?: number }).contextTokens = this.lastContextTokens;
              }
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
