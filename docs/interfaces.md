# zcode 接口清单与 Claude Code 能力对照

> 生成:2026-09-05(对应提交 `407c4fe` 之后)
> SDK:`@anthropic-ai/claude-agent-sdk` **0.3.259**(类型面扫描自 `node_modules/@anthropic-ai/claude-agent-sdk/sdk.d.ts` / `sdk-tools.d.ts`)
> 扫描范围:`server/src/**`、`app/lib/api.dart`、`app/lib/ws.dart`、SDK 类型定义
> 用途:①接口契约速查 ②与 Claude Code 官方能力对照,排后续功能(新增接口后**更新本文件**)

---

## 1. 总览拓扑

```
手机 App(Flutter)                 zcode-server(:5190)                 Claude Code CLI
┌──────────────────┐   REST   ┌────────────────────────┐   stdio/stream-json  ┌─────────────┐
│ api.dart         │─────────▶│ Fastify + Bearer 鉴权   │                      │ claude.exe  │
│ ws.dart          │   WS     │ ws-gateway → registry   │◀────────────────────▶│ (SDK query) │
│ reducer.dart     │─────────▶│ → SessionRuntime×会话   │   canUseTool 审批桥  └─────────────┘
└──────────────────┘          │ better-sqlite3 落库     │
                              └────────────────────────┘
同一对话可被多端订阅:PC 端 CloudCLI(:3005)/ 手机 app 共用 provider session
```

服务端核心链路:`ws-gateway`(协议)→ `run-registry`(发号+环形缓冲+运行态)→ `sdk-client.SessionRuntime`(SDK 包装)→ `protocol/transform`(SDK 消息→内部事件,唯一映射点)

---

## 2. HTTP REST API(除 /download 外均需 `Authorization: Bearer <token>`)

| Method | Path | 用途 | 备注 |
|---|---|---|---|
| GET | `/api/health` | 健康检查 | **免鉴权** |
| GET | `/api/models` | 模型列表(routes.json) | |
| GET | `/api/models/grouped` | 分组模型 `[{id,label,models:[{id,label}]}]` | app 模型选择器数据源 |
| GET | `/api/sessions` | 会话列表 | 附 `isRunning`/`awaitingApproval`(等审批)/`last_message`(最后一条文本截 120 字,副标题);排序 `is_pinned DESC, updated_at DESC` |
| POST | `/api/sessions` | 建会话 `{title?,cwd?,model?}` | |
| GET | `/api/sessions/:id` | 会话详情 | 404 = 不存在 |
| PATCH | `/api/sessions/:id` | 改 `{title?,isPinned?,providerSessionId?,model?,permissionMode?,cwd?}` | **热切换数据源**:改后下一条 send 生效 |
| DELETE | `/api/sessions/:id` | 删会话(幂等,不存在也 `{ok:true}`) | 顺带 abort runtime + registry.forget |
| POST | `/api/sessions/batch-delete` | `{ids:[...]}` 批量删,cap 500 | 返回 `{ok,deleted,missing}` |
| GET | `/api/sessions/:id/messages?limit=&offset=` | 历史消息 | 最新在前;limit≤500 |
| GET | `/api/sessions/:id/usage` | 用量聚合 | 累计 token/费用 + 最近一轮上下文 + 消息构成 + 工具排行 |
| POST | `/api/sessions/import-local` | `{projectsDir?}` 导入本机 Claude Code 真会话 | 启动时也会自动跑(幂等) |
| GET | `/download/:name` | 静态分发(APK 等) | **免鉴权**;文件名白名单正则防穿越 |

CORS:全放开(`*`),OPTIONS 204 短路(Flutter Web 调试用)。

## 3. WebSocket 协议(ws://host:5190)

### 3.1 客户端 → 服务端

| type | 载荷 | 说明 |
|---|---|---|
| `auth` | `{token}` | 首帧必发;错→`error/unauthorized` 并断开 |
| `ping` | — | →`pong` 心跳 |
| `chat.subscribe` | `{sessions:[{sessionId,lastSeq?}]}` | 订阅+补发;返回 `subscribed` +(有差时)`replay`;`lastSeq` 只进不退(seekSeq 抬指针) |
| `chat.send` | `{sessionId,content,images?[≤4 dataURI],options?{model?,permissionMode?}}` | 开跑;已在跑→`error/RUN_IN_PROGRESS` |
| `chat.permission-response` | `{sessionId,requestId,allow,updatedInput?,message?,rememberTool?}` | 审批应答;`rememberTool:true` = 本会话记住该工具,同工具后续 canUseTool 直接放行(内存态,重启/删会话清) |
| `chat.abort` | `{sessionId}` | 中止当前回合 |

### 3.2 服务端 → 客户端

| kind | seq | 落库 | 说明 |
|---|---|---|---|
| `authenticated` / `pong` | 无 | 否 | 控制帧 |
| `subscribed` | 无 | 否 | `{sessionId,isProcessing,lastSeq}`;**客户端不得拿 lastSeq 抬去重门槛**(replay 在后) |
| `replay` | 无(内含) | 否 | `{sessionId,events[]}` 断线补发(环形缓冲 cap 1000) |
| `sessions_dirty` | 无 | 否 | 控制帧:任一会话开跑/跑完/弹审批广播,app 防抖 250ms 静默刷列表(徽章数据源) |
| `session_created` | 有 | 是 | `{providerSessionId}`,回填 sessions 表 |
| `text` | 有 | 是 | `role:'assistant'|'user'`;用户消息由服务端回显(乐观行转正) |
| `stream_delta` / `thinking_delta` | **无** | 否 | 瞬态实时流,前端不去重 |
| `thinking` | 有 | 是 | |
| `tool_use` | 有 | 是 | `{toolId,toolName,toolInput}` |
| `tool_result` | 有 | 是 | `{toolId,content,isError}`;数组 content 逐块取文本,image 块只留 `[image]` 占位 |
| `permission_request` | **有但不落库** | 否 | `{requestId,toolName,input}`;占号 → DB seq 有洞(锁步不受影响);app 端不做 seq 去重 |
| `task_started` / `task_complete` | **有但不落库** | 否 | `{taskId,description,taskType?}` / `{taskId,status,summary}`;同 permission_request 先例:占号进环形缓冲、不落库;app 端复用工具卡展示后台任务/子任务 |
| `usage` | 有 | 是 | token/费用/时长/上下文窗口 |
| `complete` | 有 | 是 | `{exitCode,aborted}`;终态,app 端顺手收尾无结果工具卡 |
| `error` | 有 | 是 | 含特判值 `RUN_IN_PROGRESS`(app 撤回乐观行+恢复停止按钮) |

### 3.3 seq 单一空间约定(红线,改动前必读)

1. registry 只给**可持久化事件**发号(delta 不占号;`permission_request` 占号但不落库,DB 稀疏);
2. DB 存事件**自带**的 seq(不是落库时重排),REST 重建的 lastSeq 与实时事件同一空间;
3. `seedSeq` **只进不退**;
4. `subscribed.lastSeq` 是服务器指针,**不得**抬客户端去重门槛。

---

## 4. SDK 使用面(当前实际接入)

### 4.1 `query()` options 实传(`sdk-client.buildOptions()`)

| Option | 值 | 说明 |
|---|---|---|
| `cwd` | 会话 cwd | |
| `env` | `{...process.env, ...route.env}`,删 `ANTHROPIC_API_KEY` | 路由层 litellm 端点 |
| `pathToClaudeCodeExecutable` | `resolveClaudeExecutable()` | |
| `includePartialMessages` | `true` | 文本/思考流式 |
| `settingSources` | `['project','user','local']` | 含 CLAUDE.md |
| `systemPrompt` | `{type:'preset',preset:'claude_code'}` | |
| `canUseTool` | 手机审批桥 | 非交互工具 10min 超时自动 deny;`AskUserQuestion`/`ExitPlanMode` 无限等 |
| `model` | 会话模型(路由命中时省略,交 route.settings) | 每轮重算 → 热切换 |
| `permissionMode` | ≠default 才传;bypass 加 `allowDangerouslySkipPermissions` | 每轮重算 → 热切换 |
| `settings` | 路由 env/settings(flag 层,压过用户全局) | |
| `resume` | providerSessionId(第二轮起) | 跨进程续会话 |

### 4.2 SDK 消息消费情况

| SDK 消息 | 处理 |
|---|---|
| `system/init` | 取 `session_id` 发 `session_created`;**其余字段全忽略**(见 §5 缺口) |
| `assistant`(text/thinking/tool_use 块) | 映射 text/thinking/tool_use |
| `user`(tool_result 块) | 映射 tool_result |
| `stream_event`(text/thinking delta) | 映射流式;**其余 delta 类型忽略** |
| `result` | success→usage+complete;error→error+complete;**modelUsage 只取最贵条目做 contextWindow** |
| 其余 `system/*` 全部 | 忽略;例外:`task_started`/`task_notification` 已映射(§3.2 增量);`task_progress/task_updated`、`compact_boundary`、`status`、`commands_changed`、`background_tasks_changed`、`api_retry`、`session_state_changed`、`thinking_tokens`、`prompt_suggestion` 等仍忽略 |
| `parent_tool_use_id` | **未区分** → 子代理的 tool_use/tool_result 与主对话混排 |

### 4.3 Query 实例方法使用情况

| 方法 | 状态 |
|---|---|
| `interrupt()` | ✅ abort 用 |
| 迭代消息流 | ✅ |
| `setModel` / `setPermissionMode` | ✅ 2026-09-05 起:PATCH 回调 `onSessionPatched` → `setPermissionModeLive`/`setModelLive`(裸模型名才现场切;路由别名/default 由下一轮 buildOptions 生效) |
| `applyFlagSettings` / `setMaxThinkingTokens` | ❌ 未用 |
| `initializationResult` / `supportedCommands` / `supportedModels` / `supportedAgents` | ❌ 未用 |
| `mcpServerStatus` / `setMcpServers` / `reconnectMcpServer` / `toggleMcpServer` | ❌ 未用 |
| `rewindFiles`(文件检查点回滚) | ❌ 未用(`enableFileCheckpointing` 也未开) |
| `getContextUsage` / `usage_EXPERIMENTAL...` / `accountInfo` | ❌ 未用 |
| `readFile`(远程文件查看)/ `reloadPlugins` / `reloadSkills` / `renameSession` | ❌ 未用 |
| `forkSession`+`resumeSessionAt`(从中间分叉/截断重放) | ❌ 未用 |
| `stop_task`(逐后台任务停止) | ❌ 未用 |

---

## 5. Claude Code 能力对照与缺口(功能排期素材)

> SDK Options 共 50+ 项,当前实传 11 项。下表按价值排序;“现状”列全部指 2026-09-05 时点。

### P1 高价值(直接提升手机端体验)

| 能力 | SDK 面 | 现状 | 建议做法 |
|---|---|---|---|
| **斜杠命令/Skills** | `supportedCommands()` 返回可用 /命令;Options.`skills:'all'` | 无。app 无法用 /compact、/review 等 | chat.send 支持 `content` 以 `/` 开头时原样透传(CLI 本就识别)+ 启动时拉 supportedCommands 做补全面板 |
| **Plan 模式** | `permissionMode:'plan'` + `planModeInstructions`;`ExitPlanMode` 审批已在 INTERACTIVE_TOOLS 白名单 | ✅ 已补:dontAsk/auto/plan 全进选择器(chat_page `_pickMode`);ExitPlanMode 卡仍是 JSON dump(后补) | ~~补三个选项~~ 完成;剩余:plan 卡渲染 plan 内容 |
| **AskUserQuestion 结构化渲染** | canUseTool 已桥;input 里有 options/多问题结构 | ✅ 已落地:chat_page 识别 toolName==AskUserQuestion,FilterChip 多/单选,`updatedInput.answers` 回传(ws.answerPermission 全链路) | 完成 |
| **任务/待办系统** | 工具 TaskCreate/TaskList/TaskUpdate…;系统消息 `task_notification/task_started/task_progress` | ✅ 部分落地:transform 透传 task_started/task_notification(→app task_complete),ambient/skip_transcript 过滤,task_progress 故意不透传(走秒卡已示活);事件不落库(同 permission_request 先例,占号进环形缓冲) | 完成(工具卡状态徽章暂不做) |
| **子代理透视** | `parent_tool_use_id` 区分嵌套;Options.`forwardSubagentText`、`agentProgressSummaries` | 子代理事件与主对话混排,看不出“正在跑子任务” | transform 带 parentToolUseId → app 嵌套工具卡 + 进度摘要 |
| **真·热切换(setModel/setPermissionMode)** | Query 实例方法,进程内即时生效 | ✅ 已落地:PATCH → `onSessionPatched` → `runtime.setPermissionModeLive()`/`setModelLive()`(转发 currentInstance,异常吞掉只留 opts 已改的兜底);裸模型名才现场切,路由别名/default 靠下一轮 buildOptions | 完成 |
| **上下文占用真值** | `getContextUsage({detail:'summary'})` 按类别(系统提示/工具/消息/MCP/记忆) | usage 面板用 `LENGTH(content)` 估算构成 | 每轮 complete 后调一次,usage 事件加分类明细 |
| **后台任务通知** | `background_tasks_changed`、`task_notification`、Options.`perTaskStopAffordance`+`stop_task` | 忽略;后台任务结束 app 无感知 | 事件透传 + app 系统通知(PushNotification 思路);停止按钮逐任务化 |

### P2 中价值(锦上添花/安全护栏)

| 能力 | SDK 面 | 现状 | 建议做法 |
|---|---|---|---|
| 文件检查点/回滚 | `enableFileCheckpointing:true` + `rewindFiles(userMessageId,{dryRun})` | 无,改坏了只能 git | 开启检查点;消息长按“回档到此”,先 dryRun 预览 |
| 从中间重放 | `resume`+`resumeSessionAt`+`forkSession`(fork 分叉不污染原会话) | 无,只能整会话续 | “编辑后重发”:`resumeSessionAt` 截断 + forkSession 分叉 |
| MCP 管理 | Options.`mcpServers`;`mcpServerStatus/setMcpServers/reconnectMcpServer/toggleMcpServer` | 无(靠 CLI 自己读 .mcp.json) | 设置页加 MCP 状态列表(连接/失败/重连) |
| Hooks | Options.`hooks`(34 种 HookEvent)+ `includeHookEvents` | 无 | 先接 `Notification`/`Stop` → 手机推送;`PreToolUse` 自动放行规则 |
| 护栏 | `maxTurns` / `maxBudgetUsd` / `fallbackModel` / `taskBudget` | 无,一轮跑飞只能手停 | 会话级设置:预算上限、超限自动停 |
| 思考深度/effort | Options.`thinking{adaptive/enabled/disabled}`、`effort:'low'~'max'` | 无(app 底栏已有模型/权限两磁贴,可加第三) | 磁贴循环切 effort |
| 下一问建议 | Options.`promptSuggestions` → `prompt_suggestion` 消息(result 后到,**需继续迭代流**) | 忽略;注意 SDK 说 result 后仍要保持迭代——我们 held 流模式天然满足 | 透传 → 输入框上方建议气泡 |
| 官方模型列表 | `supportedModels()` / `accountInfo()` | 模型列表来自自维护 routes.json | 设置页“官方模型”对照,校验 routes 配置拼写 |
| compact 感知 | `compact_boundary` 系统消息 + PreCompact/PostCompact hook | 忽略;长会话压缩后 app 无感 | 透传 → 时间线里插“已压缩”分隔行 |

### P3 低优先/暂缓

| 能力 | SDK 面 | 备注 |
|---|---|---|
| 结构化输出 | `outputFormat:{type:'json_schema'}` | 适合以后做“自动报告”类一键任务 |
| 自定义系统提示 | `systemPrompt:{type:'preset',append}` / `{type:'custom',snapshot}` / `excludeDynamicSections`(跨用户缓存) | 会话级“人格”设置 |
| 自定义子代理 | Options.`agents`、`agent`(主线程套 agent 人设)、`supportedAgents()` | |
| 插件 | Options.`plugins`、`reloadPlugins()` | 本地插件目录 |
| 沙箱 | Options.`sandbox`(enabled/autoAllow/network) | Windows 支持有限,暂缓 |
| 托管策略 | `managedSettings`(restrictive-only 合并) | 企业场景 |
| 工具裁剪 | `allowedTools`/`disallowedTools`/`tools`/`toolAliases` | 做会话模板时用 |
| 额外目录 | `additionalDirectories` | 会话级“可访问目录”编辑 |
| 1M 上下文 | `betas:['context-1m-2025-08-07']`(Sonnet 4/4.5) | 走路由时取决于上游 |
| 不落盘会话 | `persistSession:false` | 一次性问询会话 |
| 会话镜像 | `sessionStore`(双写外部存储)+`listSessions({sessionStore})` | 以后云端同步的口子 |
| 自定义 spawn | `spawnClaudeCodeProcess`(VM/容器/远程执行) | 远程沙箱方案 |
| 审批面关闭 | `permissionPrompts:'none'` | 全自动无人值守跑批 |
| MCP elicitation | `onElicitation`(MCP 服务器要用户填表/URL 授权) | 接了 MCP 再说 |
| 用户对话框 | `onUserDialog`+`supportedDialogKinds` | 拒答兜底提示等 |
| 隐藏工具 | sdk-tools.d.ts 还有 `Workflow/Monitor/ScheduleWakeup/Cron*/SendMessage/PushNotification/ReportFindings/EnterWorktree` 等 | 运行时由宿主注入与否决定,手机端透传渲染即可 |

---

## 6. 已知技术债(接口相关,顺手修)

1. **用户图片 base64 全量广播**:gateway 注释说“meta 只存引用、不发大 base64 给其他端”,实际 `{...event}` 原样带 `images[]`(完整 data URI)落库+广播。→ 广播前剥成 `[image×n]` 占位,meta 里留完整版(或落对象存储)。
2. **`ProtocolEvent` 的 `model` kind 是死类型**:types.ts 定义了、transform 从不发、app 不消费 → 删或实现(轮次开头报当前模型,切换可见)。
3. **tool_result 无长度上限**:超大 stdout 整段落库(只有 image 有占位保护)。→ 超阈值截断 + `[...截断 N 字节]` 尾注。
4. ~~**热切换靠重建进程**~~ → 2026-09-05 已缓解:`onSessionPatched` 现场调 `setModel/setPermissionMode`(§5 P1);仍有残余:路由别名/default 模型、已退出实例仍走下一轮重建。
5. **`runtimeFor` 只在 chat.send 时调**:PATCH 后若无 send,runtime 里还是旧值——已被 `onSessionPatched` 兜住(runtime.update 即时生效),仅剩实例不在时的空窗(可接受)。

## 7. 维护约定

- 新增/修改 REST 端点、WS 事件、SDK options 接入 → **同步更新本文档对应表**;
- SDK 升级时先对拍 `transform.ts`(唯一映射点)+ 本文件 §4.2/4.3;
- seq 约定(§3.3)是唯一红线,动它必须先跑 `server` 全量测试 + 真机重连验证。
