# zcode-server

手机上用 Claude Code 的本地后端:包装 `@anthropic-ai/claude-agent-sdk`,把 CLI 消息流翻译成 WebSocket 事件。

## 启动

```powershell
cd D:\cheng\zcode\server
npm install
npm start          # tsx src/index.ts,监听 0.0.0.0:5190
```

- Token:首次启动自动生成,存 `~/.zcode-server/config.json`(也可用 `ZCODE_TOKEN` 环境变量覆盖)
- 数据库:`~/.zcode-server/zcode.db`(WAL;会话/消息/run 三表)
- 模型路由:只读复用 `~/litellm/claude-routes.json`;只有显式列出的模型才路由,`default` 与未知模型走 CLI 自己的端点
- 端口:`ZCODE_PORT`(默认 5190);CLI 路径:`CLAUDE_CLI_PATH`(默认 where.exe 解析,兼容 npm `.cmd` wrapper)

## REST(Bearer token)

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | /api/health | 免鉴权 |
| GET | /api/models | `["default", ...自定义模型]` |
| GET/POST | /api/sessions | 列表(置顶优先/最近优先)/ 新建 `{title, cwd, model}` |
| GET/PATCH/DELETE | /api/sessions/:id | 详情 / 改(title,isPinned,model,permissionMode,cwd)/ 删除(级联) |
| GET | /api/sessions/:id/messages | `?limit=&offset=`,seq 倒序 |

## WebSocket 协议(ws://host:5190)

客户端 → 服务端:

```jsonc
{ "type": "auth", "token": "..." }
{ "type": "ping" }
{ "type": "chat.subscribe", "sessions": [{ "sessionId": "...", "lastSeq": 0 }] }
{ "type": "chat.send", "sessionId": "...", "content": "...", "options": { "model": "...", "permissionMode": "..." } }
{ "type": "chat.permission-response", "sessionId": "...", "requestId": "...", "allow": true, "message": "" }
{ "type": "chat.abort", "sessionId": "..." }
```

服务端 → 客户端事件(均带 `seq` 与 `sessionId`,seq 跨 run 单调递增):

| kind | 说明 |
|---|---|
| authenticated / pong / subscribed / replay | 握手与重连补发(replay.events 为环形缓冲最近 1000 条) |
| session_created | CLI 首轮返回 providerSessionId(自动落库,resume 用) |
| text / thinking / tool_use / tool_result / error | 消息体(持久化) |
| stream_delta / thinking_delta | 增量流(不持久化) |
| permission_request | 审批请求 `{requestId, toolName, input}`;普通工具 10 分钟超时自动 deny,AskUserQuestion/ExitPlanMode 无限等 |
| usage | `{inputTokens, outputTokens, totalCostUsd, durationMs}` |
| complete | 终态 `{exitCode, aborted}`;每 run 恰好一条 |

## 语义要点

- 后台工作保活:Bash(run_in_background)/Monitor/ScheduleWakeup/CronCreate/TaskCreate 触发时,result 后 stdin 保持挂起等后续轮,ceiling 30 分钟兜底;新 send 取代旧流
- 中止:chat.abort → CLI interrupt → `complete{aborted:true}`
- 会话恢复:重连后 `chat.subscribe{lastSeq}` 补发缺口;历史消息走 REST
