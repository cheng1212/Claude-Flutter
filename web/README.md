# zCode Web

zcode-server 的网页客户端,与 Flutter App(`D:\cheng\zcode\app`)共用同一个后端协议:
REST(`/api/*`,Bearer token)+ WebSocket(鉴权、订阅、seq 续传、心跳、指数退避重连)。

视觉方向:**黑金终端(Obsidian & Gold)**——深炭黑底、焦金主色、Cinzel 石刻衬线标题、
art-deco 四角括号卡片、金粒噪点质感。

## 技术栈

Vite 5 · React 18 · TypeScript · zustand · react-markdown · vitest + @testing-library/react

## 启动

```powershell
cd D:\cheng\zcode\web
npm install          # 首次
npm run dev          # 开发: http://localhost:5173
npm run build        # 产物: dist/
npm run preview      # 预览构建产物: http://localhost:4173
npm test             # vitest 全量单测
```

打开页面后填 zcode-server 的地址(如 `http://192.168.31.194:5190`)和启动时打印的 token,
凭据存在浏览器 localStorage,下次自动登录。

## 功能

- 登录(地址自动补 `http://`、连接反馈)
- 会话列表:新建(标题+分组模型)、置顶、删除、管理模式批量置顶/删除、运行中徽章(sessions_dirty 防抖驱动)
- 聊天:REST 历史重建(DB 行号为 seq 权威锚)→ WS 订阅续传;发送乐观气泡(发送中→回显转正)、
  静默期「已送达 · 正在思考」骨架行(含秒数)、流式正文/思考、工具卡(运行中走秒/✓/✗)、
  权限审批卡(可附留言)、执行计划面板(TodoWrite/ExitPlanMode 推导)、模型二级选择、权限模式切换
- 断线:指数退避自动重连,重连后按 lastSeq 补发缺口
- 中断恢复:服务重启后悬空工具卡就地落定,迟到的真结果可覆盖占位标记

## 架构

```
src/lib/protocol.ts   协议类型(镜像 server/src/protocol/types.ts)
src/lib/chatState.ts  纯函数 reducer:WS 事件 → ChatState(seq 去重、乐观行、悬空工具收尾)
src/lib/api.ts        REST 客户端(fetch 可注入)
src/lib/socket.ts     WS 客户端(通道抽象可注入假件)
src/lib/store.ts      zustand 组合层(login/openSession/sendChat/事件路由/防抖刷新)
src/lib/planSteps.ts  计划推导
src/pages/ src/components/  UI(只读 store 渲染)
src/styles/           黑金主题 token + 组件样式
```

设计文档:`docs/superpowers/plans/2026-09-05-zcode-web.md`(Superpowers 工作流产物)。

## 已知边界

- 图片发送暂未做(协议已支持,`chat.send` 的 images 字段)
- 用量面板、深色以外的主题未做
- Google Fonts(Cinzel / IBM Plex)离线时回退系统字体
