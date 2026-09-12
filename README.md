# Claude Flutter (zCode)

把电脑上正在运行的编程 CLI（Claude Code / ZCode 等）装进手机：在手机上看流式输出、批权限、传文件、设定时任务、查用量。本仓库包含 **Flutter 安卓客户端**（`app/`）与 **Node.js 服务端**（`server/`）两部分。

## 功能一览

- **多会话管理**：会话列表 / 置顶 / 归档 / 批量操作 / 按项目过滤，手机与电脑端实时同步
- **流式对话**：text / thinking 增量渲染（200ms 攒批节流）、工具调用卡片、plan / 子代理 / 后台任务面板
- **权限审批**：CLI 请求权限时手机弹卡，多端同批；审批超时可配置（默认 10 分钟）
- **定时任务（cron）**：会话级定时触发，服务端 30s 扫描调度，一次性任务触发即焚
- **文件上传**：手机相册/文件 → 电脑项目目录，分块 base64 + 进度回调 + 失败自动重试
- **用量统计**：按会话 / 全局的 token 与费用图表
- **通知**：息屏/锁屏全屏弹出（fullScreenIntent），亮屏顶部 heads-up 下拉
- **渲染细节**：Markdown、Diff 行级着色、大图 `compute()` isolate 编码不卡 UI

## 架构要点

```
app (Flutter)  ←─ WebSocket + REST ─→  server (Fastify + ws + SQLite)  ─→  Claude Agent SDK
```

- **seq 锁步**：服务端事件序号与 SQLite 严格一致，客户端按 `lastSeq` 去重；断线重连后由 1000 条环形缓冲 replay 补齐，大空洞场景 REST 全量兜底
- **纯函数 Reducer**：对话状态机 = `（状态, 事件）→ 状态`，无副作用、全路径可单测
- **代际令牌**：会话切换/回溯时作废旧请求，杜绝异步竞态串台

## 快速开始

### 1. 启动服务端（电脑上）

要求 Node.js ≥ 20。

```bash
cd server
npm install
npm start
```

首次启动会在数据目录生成随机访问令牌（`~/.zcode-server/config.json`），并打印监听地址。手机登录时需要 **电脑局域网 IP + 该令牌**。

常用环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `ZCODE_PORT` | `5190` | HTTP + WebSocket 主端口 |
| `ZCODE_RELAY_PORT` | `5191` | 中继端口 |
| `ZCODE_TOKEN` | 自动生成 | 访问令牌（显式指定优先） |
| `ZCODE_DATA_DIR` | `~/.zcode-server` | 数据/配置目录 |
| `ZCODE_PROJECTS_ROOT` | `~/zcode-projects` | 可操作的项目根目录 |
| `ZCODE_PUBLIC_DIR` | `<data>/public` | 免鉴权静态分发目录（`/download/*`） |

### 2. 安装手机客户端

自行构建 APK（需 Flutter SDK）：

```bash
cd app
flutter build apk --release
```

安装后在本客户端登录页填入 `http://<电脑IP>:5190` 与令牌即可。

## 开发与验证

合入 develop 前三件套必须全绿：

```bash
# server
cd server && npx tsc --noEmit && npx vitest run

# app
cd app && flutter analyze && flutter test
```

分支模型（git-flow 简化版）：`master` 发布线（只收 develop 的 `--no-ff` 合并 + `vX.Y.Z` tag）、`develop` 集成线、`feature/<主题>` 一个主题一个分支。

## ⚠️ 安全提醒

访问令牌是唯一凭证：持有令牌 = 可通过 CLI 在你的电脑上执行任意命令。服务默认监听 `0.0.0.0`，**请只在可信局域网使用，不要裸暴露到公网**；如需公网访问，请套反向代理 + TLS 并更换强令牌。

## License

[MIT](LICENSE)
