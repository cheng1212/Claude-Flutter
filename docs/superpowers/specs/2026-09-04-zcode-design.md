# zCode 设计文档

日期:2026-09-04
状态:已与用户对齐(对话中逐节确认)

## 目标

手机上远程驾驭 Claude Code:在安卓手机上看到会话流、批准工具调用、收到完成推送、随时中止——人不在电脑前,agent 不卡住。

**只做 Claude Code 一个 provider**,不做多智能体抽象(YAGNI)。

## 架构

```
Flutter (Android APK, 磷光终端风)
   │ WS: 流式/审批/重连补发     REST: 会话/历史/模型列表
   ▼
zcode-server (Node 20 + TS + tsx, Fastify + ws, 端口 5190)
 ├─ ProtocolClient ── @anthropic-ai/claude-agent-sdk query()
 │                      └─ spawn 真 claude CLI 子进程(每活跃会话一个)
 ├─ ModelRouter ────── 只读复用 C:\Users\chengge\litellm\claude-routes.json
 ├─ RunRegistry ────── 每会话运行状态 + seq 环形缓冲(断线补发)
 └─ SQLite (better-sqlite3) ── sessions / messages / runs
```

**协议层决策**:v1 用 SDK 做协议引擎(第一天能跑、CLI 升级自动跟进),但隔离在自有的 `ProtocolClient` 接口后面;自研 stdin/stdout 解析作为可替换实现留后门。理由:用户以使用效果为优先。

## 后端组件

| 单元 | 职责 | 关键接口 |
|---|---|---|
| `protocol/sdk-client.ts` | 包装 SDK query():发消息、收事件、审批应答、中断;SDK 消息 → 内部 ProtocolEvent | `start/send/answerPermission/interrupt/on` |
| `protocol/process-manager.ts` | 每会话实例注册表;后台工作检测时保活 stdin(上限 30min);空闲回收 | `getOrCreate/release` |
| `router/model-routes.ts` | 读 claude-routes.json,`resolve(model) → {settings, env}`;无路由 = CLI 自带端点 | `resolve/listModels` |
| `runs/run-registry.ts` | 每会话当前 run;事件编号 seq;环形缓冲补发;exactly-once complete | `begin/push/replay/finish` |
| `gateway/ws-gateway.ts` | auth、chat.send/abort/subscribe/permission-response 四种消息 | — |
| `gateway/http-routes.ts` | sessions CRUD、history、models、health | — |
| `db/` | better-sqlite3,三张表,WAL 模式 | `repo.ts` |

**Windows 要点**(从 cloudcli 验证过的经验移植):
- SDK 的 `pathToClaudeCodeExecutable` 必须在 spawn 前解析成真 exe(`where.exe claude` → .exe,或解析 npm wrapper 指向的 `claude-code/bin/claude.exe`)——raw spawn 不跟 `.cmd` wrapper
- SDK 0.2.113+ 的 `env` 是**替换**而非叠加 process.env:传 `{...process.env, ...routeEnv}` 并 `delete ANTHROPIC_API_KEY`
- 路由注入双保险:`settings`(flag 层,压过用户 settings.json)+ env 双带
- 中文/长参数经 env 传递,不走命令行

**会话保活**:流式输入(streaming input)模式,turn 结束后默认立即释放 stdin;检测到 `Bash(run_in_background)` / `Monitor` / `ScheduleWakeup` / `CronCreate` / `TaskCreate` 则保活最多 `BG_WAIT_CEILING_MS`(默认 30min),让后台任务的后续轮次能推进来。

**审批超时**:普通工具 10 分钟(手机场景,比 cloudcli 的 55s 宽);AskUserQuestion / ExitPlanMode 无限等。超时 = deny。

## WS 协议(client → server)

```jsonc
{type:"auth", token}                                       // 连上第一条
{type:"chat.send", sessionId, content, options?{model?, permissionMode?}}
{type:"chat.abort", sessionId}
{type:"chat.subscribe", sessions:[{sessionId, lastSeq?}]}  // 重连补发
{type:"chat.permission-response", requestId, allow, updatedInput?, rememberEntry?}
{type:"ping"}
```

## WS 协议(server → client,除 replay 外均带 seq/sessionId)

```jsonc
{kind:"subscribed", sessionId, isProcessing, lastSeq}
{kind:"replay", events:[...]}                    // seq > lastSeq 的事件
{kind:"session_created", providerSessionId}      // 新会话首轮
{kind:"text", role:"assistant", content}         // 完整文本块
{kind:"stream_delta", content}                   // 打字机增量
{kind:"thinking", content} / {kind:"thinking_delta", content}
{kind:"tool_use", toolId, toolName, toolInput}
{kind:"tool_result", toolId, content, isError}
{kind:"permission_request", requestId, toolName, input}
{kind:"usage", inputTokens, outputTokens, totalCostUsd, durationMs}  // 来自 result
{kind:"complete", exitCode, aborted}
{kind:"error", content}
{kind:"model", model, endpoint}                  // 实际路由落地
{kind:"pong"}
```

## REST API

```
GET  /api/health
GET  /api/models                      # claude-routes.json keys + "default"
GET  /api/sessions                    # 列表(置顶优先,按 last_message_at 倒序)
POST /api/sessions                    # {title?, cwd?}
GET  /api/sessions/:id/messages       # 历史(分页 limit/offset)
PATCH /api/sessions/:id               # {title?, isPinned?}
DELETE /api/sessions/:id
```

**Auth**:单一 Bearer token。首次启动生成随机 token 存 `<data>/config.json` 并打印到控制台;WS 首条消息或 HTTP header 二选一验证。

## 数据模型(SQLite)

```sql
sessions(id TEXT PK, title TEXT, cwd TEXT, provider_session_id TEXT,
         model TEXT, permission_mode TEXT DEFAULT 'default',
         is_pinned INTEGER DEFAULT 0, created_at TEXT, updated_at TEXT)
messages(id TEXT PK, session_id TEXT, seq INTEGER, kind TEXT, role TEXT,
         content TEXT, meta TEXT, created_at TEXT)   -- kind: text|thinking|tool_use|tool_result|error|notice
runs(id TEXT PK, session_id TEXT, status TEXT, model TEXT,
     total_cost_usd REAL, usage TEXT, started_at TEXT, ended_at TEXT)
```

## 手机端功能优先级

**MVP(本期)**:
1. 远程审批——permission_request → 系统通知 + 底部面板 允许/拒绝(可记住本次会话)
2. 完成推送——complete/error 时本地通知带回复摘要(app 存活时;被杀后的推送 v2 用 ntfy)
3. 流式回复 + thinking 折叠 + 工具单行折叠(点开看输入/输出)
4. 断线重连 + seq 补发 + 历史拉取
5. 中止按钮常驻
6. 会话列表/新建/继续(resume)+ 模型选择器
7. 顶栏 token/成本仪表

**明确推迟(YAGNI)**:图片上传、排队消息、上下文占用条、后台任务面板、子代理树、语音输入、ntfy/FCM、多 provider。

## 前端架构(参考 D:\tools\zremote 的成熟模式)

复用 zremote 验证过的结构,只换主题皮肤:
- **状态管理**:单一 `ChangeNotifier` App 脑(`ZCodeApp`),根组件 `addListener + setState`,不用 Riverpod(比原方案更简,且与参考实现一致)
- **主题**:`abstract final class ZT` 静态色值常量 + `theme()` 构建器 + 共享质感组件(对应 zremote 的 HardCard/StatusChip/PulseDot/BigButton → 本项目 TerminalPanel/StatusChip/PulseDot/TerminalButton)
- **聊天行渲染**:统一入口 `buildRowCard` 按 kind 分发;`MemoMarkdown` 记忆化包装(流式 append 只重排当前行,不重排全列表);代码块 = 语言标签 + 复制按钮 + 横向滚动;thinking/工具行可折叠
- **依赖对齐**:web_socket_channel + flutter_markdown + shared_preferences,轻依赖

## 前端设计:磷光终端风

- **配色**:背景 `#0A0E0A` 近黑 / 磷光绿 `#33FF66` / 琥珀 `#FFB000` / 面板 `#111711` / 边框 `#1E2A1E` / 暗灰绿正文 `#9FB39F`
- **字体**:JetBrains Mono(代码/工具行/token 数)+ Noto Sans SC(中文正文 fallback,打包进 APK 不依赖网络);标题用等宽加字重
- **质感**:文字微光晕(仅状态色)、扫描线纹理(2px 周期,极淡)、直角边框(SquareBorder 1px)、ASCII 风分隔线
- **动效**:stream_delta 打字机、工具行完成时 ✓ 闪一下、审批面板从底部滑入;不做花哨转场
- **布局**:单栏聊天流;顶栏 = 会话名 + CTX/token + 菜单;底栏 = 输入行 + 发送/停止;会话列表是首屏抽屉式(左滑出)

## 测试策略

- 后端 vitest + TDD(RED-GREEN-REFACTOR):SDK 用注入的 fake query 测 transform;WS 网关用真实 fastify listen 随机端口 + ws 客户端集成测试;DB 用内存 sqlite
- Flutter:ws_client 重连/seq 逻辑单测;核心 widget 冒烟测试;UI 以真机手测为准
- 端到端:PC 上 curl/wscat 验证协议 → APK 装手机连 PC 局域网实测

## 里程碑

- **M1 后端 MVP**:REST + WS + SDK 全链路,PC 上 wscat 能跑通一轮对话 + 审批 + 补发
- **M2 Flutter P0**:APK 装机,局域网可用,以上 7 个功能全通
- **M3**(另立 spec):图片上传、排队消息、ntfy 推送
