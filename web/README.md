# zCode Web（比对副本）

浏览器端 zCode 客户端 —— 与 `app/`（Flutter 安卓客户端）**一比一对比**用的 Vue3 + TS 实现。

目标是验证：同一套设计 token 与同一份服务端协议，在 Web 技术栈下能否还原到与 Flutter 端
一致的观感与行为，并沉淀成可复用的 Web 版客户端。

## 技术栈

| 项 | 选型 | 说明 |
|---|---|---|
| 框架 | Vue 3.5 + TypeScript | `<script setup>` 单文件组件 |
| 构建 | Vite 6 | 开发端口 `5273` |
| 状态 | Pinia | 对应 app 的 `ZApp`(ChangeNotifier) |
| 路由 | vue-router（hash 模式） | 纯静态托管无需服务端改写 |
| 渲染 | marked + DOMPurify + highlight.js | 对应 `flutter_markdown_plus` |

## 目录结构

```
web/
├─ src/
│  ├─ theme/
│  │  ├─ palettes.ts      # 从 app/lib/theme.dart 1:1 移植的调色板 + CSS 变量注入
│  │  └─ controller.ts    # 主题切换 / 持久化,对应 ZThemeController
│  ├─ styles/base.css     # 全局原语(.z-card / .z-btn / .z-pill …),全部读 var(--z-*)
│  ├─ views/
│  │  ├─ ThemePicker.vue  # 主题选择器(起始页)
│  │  └─ StylePreview.vue # 单主题整页预览
│  ├─ App.vue
│  └─ main.ts
├─ index.html
├─ vite.config.ts
└─ tsconfig.json
```

## 与 Flutter 端的对应关系

| Flutter | Web | 备注 |
|---|---|---|
| `app/lib/theme.dart` `ZPalette` | `src/theme/palettes.ts` `ZPalette` | 字段一一对应，色值逐字相同 |
| `ZT` 静态门面 | `:root` 上的 `--z-*` CSS 变量 | 组件不持有色值，换主题零重建 |
| `ZThemeController` + SharedPreferences | `controller.ts` + `localStorage` | 同一个 key `zcode.theme` |
| `HardCard` / `BigButton` / `StatusChip` | `.z-card` / `.z-btn` / `.z-pill` | 视觉参数对齐 |

## 主题

内置 5 套风格，可用选择器即时切换（选择结果持久化）：

| id | 名称 | 方向 |
|---|---|---|
| `citrus` | 柑橘晨光 | **与 app 现役主题一致**：墨线粗框 + 纯墨硬阴影 |
| `sticker` | 墨线贴纸 | 柑橘加大号：更深底色 + 圆点纹理 + 2px 墨线 |
| `cream` | 原版奶油 | 奶油底 + 焦糖橙，柔和阴影、无框软卡 |
| `phosphor` | 磷光终端 | 深色磷绿 + 扫描线（新增方向） |
| `editorial` | 编辑部 | 高对比衬线 + 细金线 + 大留白（新增方向） |

## 开发

```bash
npm install
npm run dev        # http://127.0.0.1:5273
npm run typecheck  # vue-tsc --noEmit
npm run build      # 类型检查 + 产物构建
```

开发服务器把 `/api` 与 `/ws` 代理到本机 `zcode-server`（默认 `127.0.0.1:5190`），
避免浏览器跨域与混合内容限制。服务端已开 `Access-Control-Allow-Origin: *`，
也可把 `vite.config.ts` 里的 `server.proxy` 去掉，直接让客户端请求服务器的绝对地址。

## 状态

- [x] 工程骨架（Vue3 + TS + Vite + Pinia + Router）
- [x] 主题 token 系统（5 套调色板 + CSS 变量 + 持久化）
- [x] 主题选择器 / 整页预览
- [ ] REST + WS 客户端，Pinia store
- [ ] 页面还原：登录 / 会话列表 / 对话 / 项目 / 我的 / 用量 / 定时任务
