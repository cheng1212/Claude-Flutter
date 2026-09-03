# zCode Flutter 前端 MVP 计划(磷光终端风)

日期:2026-09-04 · 前置:后端 MVP 已完成(server/ 全绿 + 真机冒烟通过)
风格:**磷光终端风**(用户选定)——深黑绿底 #0A0E0A、磷光绿 #33FF66、琥珀 #FFB000、全等宽、方角、辉光文字。
架构参照:`D:\tools\zremote` 前端(ChangeNotifier 单脑 + ZT 常量 + MemoMarkdown + 折叠卡),换皮不换骨。

## 里程碑

- **F1** 脚手架 + 主题 + 状态归约逻辑(TDD)
- **F2** REST + WS 客户端(断线重连 + seq 补发)
- **F3** 登录 / 会话列表 / 聊天三屏
- **F4** 审批底部弹层 + 完成通知 + token/费用条
- **F5** Web 验证(flutter run -d web-server --web-port=8090)
- **F6** Android APK(脱离会话进程构建;kotlin.incremental=false)

## 任务分解

### Task F1:脚手架 + 主题 + 归约器(TDD)
- `flutter create` 组织 `com.zcode`,平台 web/android
- 依赖:`web_socket_channel` `flutter_markdown` `markdown` `shared_preferences`
- `lib/theme.dart`:`abstract final class ZT`(色值/字号/间距常量)+ `zTheme()`(方角、等宽、辉光阴影、深色 schemes)
- `lib/state/reducer.dart`:**纯函数** `applyEvent(ChatState, OutboundEvent) -> ChatState` —— 单测覆盖:
  - stream_delta 追加到当前流缓冲;text 落定冲掉流缓冲
  - thinking/thinking_delta 同理
  - tool_use/tool_result 按 toolId 配对成卡
  - usage 更新 tokens/cost;complete 置 runIdle 并保留 usage
  - permission_request 记 pending;error 追加错误行
  - **seq 去重**:event.seq <= state.lastSeq 丢弃;否则前进 lastSeq
  - replay 批量:过滤旧 seq 后逐条 apply
- 测试:`test/reducer_test.dart`(flutter_test 纯 Dart,不起 UI)

### Task F2:传输层
- `lib/api.dart`:REST 客户端(BaseUrl + Bearer;sessions CRUD/messages/models)
- `lib/ws.dart`:ZSocket
  - 连接 `ws://host:5190` → auth → authenticated
  - `subscribe(sessions, lastSeq)`:重连/切会话时带本地 lastSeq → replay 事件灌进归约器
  - 断线自动重连(指数退避 1s/2s/4s/…上限 30s),重连成功后重新 auth+subscribe
  - send/answerPermission/abort 封装;ping 每 25s
- 单测:用 `WSClient` 接口假件测归约入口(不连真网);真网联调留冒烟

### Task F3:三屏 + 单脑
- `lib/state/zapp.dart`:`ZApp extends ChangeNotifier`
  - 状态:connState、sessions、currentSessionId、ChatState(per session)、pendingPermission、usage 汇总
  - 动作:login/saveConfig、loadSessions、createSession、openSession(拉 REST 历史 + WS subscribe)、sendMessage、abort、answerPermission
- `lib/main.dart`:MaterialApp(theme: zTheme) + ZApp.addListener(setState);路由 login→sessions→chat
- `lib/ui/sessions_screen.dart`:磷光列表卡(标题/最近时间/置顶钉),新建会话(可选 cwd 预设)、长按 pin/delete
- `lib/ui/chat_screen.dart`:
  - 消息行 `buildRow(kind)` 分发:user 气泡(右,绿框)、assistant Markdown(MemoMarkdown 只重排变动行)、ReasoningCard/ToolCallCard 折叠卡、错误行(琥珀)
  - 流式:底部流缓冲行 + 闪烁块光标 `▮`
  - 输入区:多行 TextField + 发送/停止(运行中换停止)按钮
  - 顶部:连接状态 PulseDot + 会话名 + usage 条(tokens/cost)

### Task F4:审批 + 通知
- `lib/ui/permission_sheet.dart`:permission_request → showModalBottomSheet(工具名 + 输入 JSON + 允许/拒绝),应答 chat.permission-response
- 完成通知:app 后台化时收到 complete → 本地通知(flutter_local_notifications,Android 13+ 权限);前台仅横幅内提示
- Web 端通知降级为标题闪烁(不阻塞 MVP)

### Task F5:Web 验证
- `flutter run -d web-server --web-port=8090`,真连 5190:登录 → 建会话 → 一轮流式 → 审批 → 中止 → 刷新页面 replay 恢复
- Android Chrome 真机同验

### Task F6:APK
- `android/gradle.properties`:+`kotlin.incremental=false`(历史坑)
- **用 Start-Process 独立 cmd 构建**(会话连杀教训),产物 `build/app/outputs/flutter-apk/app-release.apk`
- `flutter build apk --release`

## 非目标(本期不做)
图片上传、队列消息、上下文占比条、任务面板、FCM/ntfy、多 provider。

## 验证口径
1. `flutter test` 全绿(reducer/传输逻辑)
2. F5 手动清单全过(流式/审批/中止/重连补发/断网恢复)
3. APK 装机可用
