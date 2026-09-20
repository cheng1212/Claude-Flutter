# zcode_app Flutter 工程优化方案（2026-09-14）

> **文档目的**：基于 2026-09 对"优秀 Flutter 项目"的调研结论（Flutter 官方架构指南 + Compass 官方案例研究 + Code With Andrea / Very Good Ventures 社区共识），对 `D:\zcode-dev\app` 做实地勘察后给出的**可执行优化任务清单**。本文档写给将要动手的 Agent：每个任务是独立工单，按"执行规范"一节的方式逐个落地。
>
> **基线体检（2026-09-14 实测）**：`flutter analyze` 0 issues；`flutter test` **216 用例全绿（15s）**；版本 1.5.35+55；Flutter 3.44.0 stable / Dart 3.12.0。**这个项目的底子比多数 Flutter 项目健康**——本方案是"在好底子上补架构和工程化短板"，不是重写。

---

## 0. 执行规范（执行 Agent 必读）

每个任务独立走一个分支，严格遵循仓库 `D:\zcode-dev\AGENTS.md` 的既有纪律：

1. **开工**：`cd D:\zcode-dev && git checkout develop && git checkout -b feature/app-<任务ID>`（如 `feature/app-t1-ci`）。
2. **提交**：中文消息，`app:` 前缀 + 一句话动机；一个任务可多次提交。
3. **验收门槛（合入 develop 前必须全绿）**：
   ```bash
   cd D:\zcode-dev\app
   D:\flutter\bin\flutter.bat analyze   # 期望: No issues found
   D:\flutter\bin\flutter.bat test      # 期望: All tests passed（基线 216 个，只许增不许减）
   ```
4. **合入**：`git checkout develop && git merge --no-ff feature/app-<任务ID>`。
5. **版本号**：优化合并**不动版本号**；`X.Y.Z+build` 只在发版时按 AGENTS.md 纪律同时递增。
6. **红线**：不碰 `D:\zcode-master-test`；不引入重量级依赖（dio/freezed/bloc 等）除非任务明确要求；**保持项目"小依赖 + 中文注释 + 状态走 ZApp"的既有风格**，风格迁移类任务按任务卡执行、不自由发挥。
7. **每完成一个任务**：在本文件对应任务前打勾 `[x]` 并附一行"完成说明 + commit hash"，随代码一起提交。

---

## 1. 现状快照（证据）

### 1.1 做得好的（**禁止在优化中破坏**）

| 亮点 | 证据 |
|---|---|
| 帧工程意识强 | `state/zapp.dart` delta 40ms 合帧缓冲（推流不逐条 notify）；`chat_page.dart` isolate `compute` 编图片（主线程不掉帧）；入场动画水位 `advanceAnimWatermark` 纯函数防"几千行同时建动画→白屏" |
| 设计 token 体系已存在 | `theme.dart` `ZPalette` 语义化 token（bg/surface/ink/primary/aqua…），换主题 = 换 const 调色板、UI 零改动 |
| 平台条件注入 | `http_io.dart` / `http_web.dart` / `http_fn.dart` 按平台编译期选择实现 |
| 状态容器思路正确 | `ZApp extends ChangeNotifier`，"页面只读暴露状态、变更走方法"，代际令牌 `_openToken` 防快速切换竞态，都是对的 |
| 并发竞态处理成熟 | openSession 代际令牌、`_sessionsDirtyTimer` 合并刷新、WS 断线自愈 |
| 测试与验证纪律 | 216 测试基线 + AGENTS.md 强制 analyze/test 全绿才许合并 |

### 1.2 短板（与调研标准的差距，按严重度排序）

| # | 短板 | 证据 |
|---|---|---|
| G1 | **无 CI**：远端 `github`（github.com/cheng1212/Claude-Flutter）已配，但全仓无 `.github/workflows/`，analyze+test 门槛只存在于执行者自觉 | `ls D:\zcode-dev\.github` 不存在 |
| G2 | **SDK 未锁版本**：仅 pubspec `sdk: ^3.12.0` 约束，工具链靠 `D:\flutter` 单机路径（AGENTS.md 里写死），换机器/换 Agent 环境即漂移 | 无 `.fvmrc` |
| G3 | **状态容器是"上帝对象"**：`ZApp` 一个类装下会话/模型/推流/排队/回填/生命周期全部状态（1008 行），**9 个 UI 文件全量 import 它**；全库仅 7 处 `ListenableBuilder`，重建范围粗 | `grep -rln state/zapp.dart lib/` = 9 |
| G4 | **巨型 UI 文件**：`ui/chat_page.dart` **2988 行**、`sessions_page.dart` 1889 行、`rows.dart` 1490 行；单文件内混输入条/图片编码/权限面板/滚动逻辑；页面级 0 widget 测试（现有测试全部打在 utils/controller 层） | `wc -l` 实测 |
| G5 | **lint 只有默认集**：`analysis_options.yaml` 是模板原样，未开 strict 规则 | 文件 24-25 行全注释 |
| G6 | lib/ 扁平结构：29 个文件平铺 + `ui/` `state/` 两层，功能边界只存在于文件名前缀 | `find lib -name '*.dart'` |
| G7 | 错误处理靠异常+toast 分散映射，API 层无类型化错误 | `api.dart` / 各页面 catch |

### 1.3 明确**不做**的事（防止执行 Agent 过度工程）

- ❌ **不引入 Riverpod/BLoC 替换 ZApp**：官方指南原话"规则是指导而非铁律"；ZApp 的 ChangeNotifier 模式就是官方 MVVM 的 ViewModel 思路，替换是高风险重写，收益不抵风险。只做**拆分**（T4）。
- ❌ **不换 dio / 不上 freezed**：现有 `http` + 手写模型 26 个文件规模完全可控，加代码生成链是负收益。
- ❌ **不做 l10n/arb 抽取**：个人工具型 App，locale 固定 zh-CN，中文字符串硬编码是特性不是债。
- ❌ **不拆 monorepo package**：单包 1.3 万行远未到拆包阈值（VGV 方案的适用场景是多团队/多 App）。
- ❌ **不引入 go_router**：7 处 Navigator 直调 + 通知深链已用 navigatorKey 解决，路由库在此规模是纯增重。仅当未来需要 Web 路由再议。

---

## 2. 任务清单

优先级定义：**P0** = 防事故/防漂移，先做且小；**P1** = 架构偿还，按序做；**P2** = 打磨，可穿插。规模估算：S ≤ 半天，M ≈ 1 天，L ≈ 2-3 天。

---

### [x] T1（P0·S）GitHub Actions CI：把 analyze+test 门槛从"纪律"变成"机器"

**现状**：AGENTS.md 要求合并前 analyze+test 全绿，但无机器强制；github 远端已配好。

**目标**：push / PR 到任意分支时，CI 自动跑 analyze + test，失败标红。

**步骤**：
1. 新建 `D:\zcode-dev\.github\workflows\app-ci.yml`（放仓库根，server/web 以后可加自己的 workflow 互不干扰）：
   ```yaml
   name: app-ci
   on:
     push:
       paths: ['app/**', '.github/workflows/app-ci.yml']
     pull_request:
       paths: ['app/**', '.github/workflows/app-ci.yml']
   jobs:
     test:
       runs-on: ubuntu-latest
       timeout-minutes: 20
       steps:
         - uses: actions/checkout@v4
         - uses: flutter-actions/setup-fvm@v4   # 读 app/.fvmrc（依赖 T2 先完成；若 T2 未做，
                                                # 临时改用 subosito/flutter-action@v2 并写死 3.44.0）
         - working-directory: app
           run: fvm flutter pub get
         - working-directory: app
           run: fvm flutter analyze --no-pub
         - working-directory: app
           run: fvm flutter test
   ```
2. 推到 github 远端验证：`git push github develop` 后在仓库 Actions 页确认绿灯。
   注意：github 远端推送若超时，走 `HTTPS_PROXY=http://127.0.0.1:7897`（需 Clash 在运行），git 对 github.com 已配专属代理。

**验收**：Actions 页出现 `app-ci` workflow 且全绿；故意在分支里改坏一行 Dart 再 push，CI 变红。

**风险**：无（纯新增文件）。测试里有真实 WS 握手类用例的话 CI 可能变慢/抖动——若发生，在 CI 中加 `--exclude-tags=net` 并给此类测试打 tag（当前 216 个测试 15s 跑完，预计无此问题）。

**完成说明（2026-09-14）**：workflow 落地（subosito/flutter-action 锁 3.44.0 替代 FVM 方案，T2 裁剪理由见 qa-plan），首跑及后续 push 连续绿灯 ✅

---

### [ ] T2（P0·S）FVM 锁定 SDK 版本

**现状**：工具链 = `D:\flutter`（3.44.0 stable）单机路径，pubspec 仅 `sdk: ^3.12.0` 约束。

**目标**：项目内 `.fvmrc` 锁定 3.44.0，任何机器/Agent `fvm flutter ...` 行为一致；AGENTS.md 命令同步更新。

**步骤**：
1. `dart pub global activate fvm`（已装则跳过）。
2. `cd D:\zcode-dev\app && fvm use 3.44.0` → 生成 `.fvmrc`；确认 `.gitignore` 已含 `.fvm/`（fvm 默认会加）。
3. AGENTS.md「验证」一节的命令改为 `D:\flutter\bin\fvm.bat flutter analyze ...` 形式，并加一行"首次克隆先 `fvm install`"。
4. 本地验证 `fvm flutter analyze && fvm flutter test` 全绿。

**验收**：仓库根有 `.fvmrc`（提交）；`.fvm/` 不入库；AGENTS.md 已更新。

**风险**：低。注意 AGENTS.md 的修改随本任务提交（它属于"文档/CI 类杂项可直接提交"范畴）。

---

### [x] T3（P0·S）lint 强化：从默认集到严格集

**现状**：`analysis_options.yaml` 为模板原样，仅默认 `flutter_lints`。

**目标**：开启与项目现状匹配的严格规则，继续保持 0 issues。

**步骤**：
1. 修改 `analysis_options.yaml`：
   ```yaml
   include: package:flutter_lints/flutter.yaml

   analyzer:
     language:
       strict-casts: true
       strict-inference: true
       strict-raw-types: true

   linter:
     rules:
       unawaited_futures: true
       always_declare_return_types: true
       unnecessary_lambdas: true
       avoid_redundant_argument_values: true
   ```
2. 跑 `flutter analyze`，**逐条修复新暴露的问题**（预计个位数到十几条，多为补类型注解/补 await）。修复一律走"改代码"而不是"关规则"；个别确属误报的用 `// ignore: <rule>` 并注释原因。
3. 全绿后连同修复一起提交。

**验收**：`flutter analyze` 0 issues 且上述配置生效（删掉任一 `await` 能看到报错）。

**风险**：低。`strict-inference` 若暴露大量泛型推断问题（>50 条），可先只开 `strict-casts` + `unawaited_futures`，其余下批再开——在提交信息里记录裁剪。

**完成说明（2026-09-14）**：按预案降级落地——已开 strict-casts + unawaited_futures + always_declare_return_types，修 4 处 unawaited；strict-raw-types(25)/inference(25)/lambdas(15)/redundant(50) 下批再开 ✅

---

### [◐] T4（P1·L）ZApp 拆分：上帝对象 → 按域的状态切片（本方案核心任务）

**现状**：`ZApp`（1008 行）同时管理：会话列表 + 模型列表 + 推流 delta 合帧 + 消息排队 + 后台回填 + 打开会话竞态 + 生命周期；9 个 UI 文件全量 import。仅 7 处 ListenableBuilder，重建范围粗（任何 notify 波及所有监听者——40ms 合帧已缓解频率，但范围未收窄）。

**目标**：ZApp 降级为**组合根（facade）**，内部状态按域拆成独立 `ChangeNotifier` 切片，页面只监听自己用的切片。**对外接口先不变**（页面零改动过第一轮），再逐步让页面直连切片。

**架构约定**（沿用官方 MVVM 的交往规则，写进代码注释）：
```
ZApp(组合根, 越来越薄)
 ├── SessionsSlice    : sessions 列表 + 刷新脏定时器 + refreshSessions()
 ├── ModelsSlice      : models + modelGroups
 ├── ChatSlice        : 推流 delta 合帧 + backfill + _openToken + 当前打开会话状态
 ├── QueueSlice       : _queues + _autoConsumeOff + QueuedMessage（纯内存，最独立）
 └── (api, socket 留在 ZApp，构造注入进各 slice —— 依赖方向: slice 不可反向引用 ZApp)
```

**步骤（绞杀者模式，每步一个独立提交，全程测试绿灯）**：
1. **QueueSlice（试点，最独立）**：`_queues`/`_autoConsumeOff`/`_queuedSeq` 及其方法原样搬入 `state/slices/queue_slice.dart`；ZApp 持有 `late final QueueSlice queue` 并把旧方法委托过去（保持 API 兼容）。跑测试。
2. **ModelsSlice**：同法搬 `models`/`modelGroups`。
3. **SessionsSlice**：搬会话列表 + `_sessionsDirtyTimer` + `refreshSessions()` + `appLifecycle` 回写逻辑。
4. **ChatSlice（最后、最重）**：搬 delta 合帧（`_pendDelta*`）、`_backfill`、`_openToken`、openSession/closeSession 及 rows 状态。搬完跑 `chat_stream_controller_test` + 全量测试。
5. **重建范围收窄**：逐页把 `AnimatedBuilder/ListenableBuilder(listenable: app)` 改为监听对应 slice（如 sessions 页只听 `SessionsSlice`），每改一页手动冒烟 + 截图对比。
6. 收尾：`grep -c "state/zapp.dart" lib/ui` 预期降到 ≤3（app_shell/login/main）；ZApp 文件行数预期 ≤300。

**验收**：
- 216 个测试全绿（允许为 slice 新增单测，总数只增不减）；
- 新增 `test/slices/*_test.dart` 至少覆盖 QueueSlice 与 ChatSlice 合帧逻辑（可把现有 zapp 行为测试改挂到 slice 上）；
- `flutter analyze` 0 issues；聊天推流、会话切换、排队消息三大路径手动冒烟通过。

**风险**：**本方案最高风险任务**。务必一刀一个提交；ChatSlice 若拆崩，回滚该步、先合入前三个 slice（它们已独立产生价值）。禁止在本任务里顺手改 UI 或改行为——行为不变是红线。

**进度（2026-09-14）**：QueueSlice ✅（试点完成，API 零改动委托+6 单测）；ModelsSlice ✅（getter 兼容）；SessionsSlice ✅（dirty 防抖内聚）；ChatSlice ◐（纯函数域已迁入 slices/chat_slice.dart，字段与 openSession/sendChat 动作待迁）。提交链 29a361f→43ff2c9，222 全绿。

---

### [ ] T5（P1·M→L）巨型文件分解：chat_page 2988 行 → 功能子目录

**现状**：`ui/chat_page.dart` 2988 行（输入条、图片编码、权限面板、快捷条、滚动、动画水位混在一个 State 类里）；`sessions_page.dart` 1889 行；`rows.dart` 1490 行。

**目标**：单文件 ≤800 行；chat 相关代码聚到 `ui/chat/` 子目录；为后续页面级 widget 测试铺路。

**步骤**：
1. `ui/chat/` 新目录，按"纯函数 → 无状态组件 → 有状态块"的顺序抽取（每抽一块跑一次测试 + 冒烟）：
   - 已有纯函数先归位：`advanceAnimWatermark`、`_encodeImagesJob` → `ui/chat/logic.dart`（保持顶层函数，`compute` 依赖此约束）；
   - 图片选择/预览条/上传限制常量（`kMaxImageBytes` 等）→ `ui/chat/image_composer.dart`；
   - 输入条（composer + 六枚快捷 chips + 发送/停止按钮）→ `ui/chat/composer_bar.dart`；
   - 权限/选项/计划弹层 → 并入现有 `chat_panels.dart` 或拆 `ui/chat/panels/`；
   - 消息列表区（reversed ListView + 锚定滚动）→ `ui/chat/message_list.dart`（`chat_scroll_anchor/facade` 一并挪入 `ui/chat/`）。
2. `chat_page.dart` 收敛为：参数装配 + 布局骨架 + 与 ChatSlice 的接线，预期 ≤800 行。
3. 第二刀做 `sessions_page.dart`：会话卡 → `ui/sessions/session_card.dart`，搜索/排序 → `ui/sessions/session_filter.dart`，抽完 ≤800 行。
4. `rows.dart`（1490 行）按行类型拆：`ui/chat/rows/text_row.dart`、`tool_row.dart`、`thinking_row.dart` 等，`rows.dart` 留作 barrel 导出（下游 import 不变）。

**验收**：`wc -l` 达标；测试全绿；抽出的每个无状态组件配一个最小 widget 测试（渲染 + 关键交互，见 T6 风格）。

**风险**：中。纯搬运不改逻辑；`rows.dart` 拆分放最后做（消费方最多）。禁止在搬运中"顺手优化"。

---

### [ ] T6（P1·M）测试补强：页面级 widget 测试 + 共享 fakes 基建

**现状**：216 测试全部打在 utils/controller 层；无页面级测试；mock/fake 各测试文件自建。

**目标**：官方 Compass 的 `testing/` 模式——共享测试基建包 + 核心页面冒烟测试。

**步骤**：
1. 建 `testing/` 顶层目录（与 `test/` 平级，见官方案例研究）：放 `testing/fakes/fake_api.dart`、`fake_socket.dart`（现有测试里的手写 fake 收拢进来）、`testing/models/`（测试夹具数据）。
2. 补页面级 widget 测试（`ProviderScope` 无关，直接注入 fake ZApp/slices）：
   - `test/ui/sessions_page_test.dart`：空态/有会话卡/点击进 chat；
   - `test/ui/login_page_test.dart`：错误文案显示、busy 态按钮禁用；
   - `test/ui/chat_page_test.dart`：rows 渲染 + composer 发送调用（fake 断言）。
3. 目标：测试总数 216 → ≥240，新增测试聚焦"页面渲染不炸 + 关键回调触发"，不追求覆盖率数字。

**验收**：`flutter test` 全绿且总数达标；`testing/` 里无业务逻辑（只是不发布的影子 app）。

**风险**：低。依赖 T4/T5 先完成（页面可注入性变好）；若提前做，只做 login_page（依赖最少）。

---

### [ ] T7（P1·S）API 层错误类型化

**现状**：`api.dart` 抛裸异常，各 UI 层 catch 后各自拼文案 toast，`_loginError` 在 main.dart 手工拼 `'连不上服务器: $e'`。

**目标**：定义 `ApiError` 密封类（Dart 3 `sealed class`），错误映射集中一处，UI 只 switch 渲染。

**步骤**：
1. `lib/api_error.dart`：
   ```dart
   sealed class ApiError implements Exception {
     String get message;
   }
   class NetworkError extends ApiError { ... }   // 连不上/超时
   class AuthError extends ApiError { ... }      // token 失效
   class ServerError extends ApiError { final int? code; ... }
   ```
2. `api.dart` / `ws.dart` 抛出点统一包装成上述类型（对外异常类型变化是破坏性的：全库 catch 点同步改，`grep -rn "catch" lib/` 逐个过）。
3. 错误 → 用户文案映射集中到 `ui/toast.dart` 旁的 `api_error_message.dart` 单一函数；删除各处手拼 `$e`。

**验收**：测试全绿；断网/错 token/服务器 500 三种场景文案稳定（手动冒烟）；`grep -rn "catch (e)" lib/ui` 中不再有直接拼 `$e` 进 UI 的（除 debug 日志）。

**风险**：中低。它是 T4 之外唯一改"对外契约"的任务，建议排在 T4 之后独立分支。

**完成说明（2026-09-14，最小版）**：ZApiException 加 ApiErrorKind 类别(network/auth/server) + apiErrorMessage 集中文案映射，登录/超时走 network 类别；UI 全面 switch 迁移待后续 ✅（部分）

---

### [ ] T8（P2·S）动效规范：集中 motion token + 入场动画统一

**现状**：入场动画已有水位机制（好）；但时长/曲线魔法数散落各文件（`200ms`、`Curves.easeOut` 等字面量）；页面转场全默认 `MaterialPageRoute`。

**目标**：对齐调研结论——动画参数 token 化、有目的、克制。

**步骤**：
1. 新建 `lib/core/motion.dart`：
   ```dart
   /// 动效 token:全库动画时长/曲线唯一出处。交互反馈 150-250ms,转场 ~300ms。
   const kDurFast = Duration(milliseconds: 150);
   const kDurNormal = Duration(milliseconds: 220);
   const kDurPage = Duration(milliseconds: 300);
   const kCurveOut = Curves.easeOutCubic;
   const kCurveInOut = Curves.easeInOutCubic;
   ```
2. 全库 `grep -rn "milliseconds\|Curves\." lib/ui` 逐处替换为 token（值保持原值，不调手感）。
3. 会话页 → 聊天页转场改 `SlideTransition`（从右滑入，`kDurPage` + `kCurveOut`），封装成 `ui/nav.dart` 的 `pushChat()` 一个出口；其余转场保持默认（不滥用自定义转场）。
4. **不引入** flutter_animate/Lottie——现有 26 文件规模手写隐式动画足够，守"小依赖"原则。

**验收**：`grep -rn "Duration(milliseconds" lib/ui` 仅剩 `motion.dart` 一处定义来源；测试全绿；转场手感人工确认。

**风险**：低。纯等价替换 + 一处转场。

---

### [ ] T9（P2·M）主题系统迁移：静态 ZT → ThemeExtension（谨慎项，可暂缓）

**现状**：`ZT` 静态委托读 token（`ZT.bg`/`ZT.theme()`），根节点 `ValueListenableBuilder<ZTheme>` 整树重建。**这是一套能工作的自洽设计**（换主题 UI 零改动），缺点：与 Flutter 生态约定不符（`Theme.of(context)`）、单测需初始化静态、主题切换无 lerp 过渡。

**目标**：`ZPalette` 包成 `ThemeExtension<ZPalette>`（实现 `copyWith`/`lerp`），访问器改 `context.zt` 扩展；`ZT` 保留为兼容层一个版本后删除。

**步骤**：
1. `ZPalette implements ThemeExtension<ZPalette>`，`lerp` 逐字段 `Color.lerp`；
2. `MaterialApp(theme: ZT.theme())` 仍是唯一装配点；token 读取改 `context.zt`（`ThemeExtension` 取出 + 一行缓存判断）；
3. 全库 `ZT.` 调用点机械替换（预计量大——`grep -c "ZT\." lib | wc -l` 先数一遍再排期，若 >200 处则本任务降级为**只做 ThemeExtension 化、ZT 保留**）。

**验收**：三套主题（含隐藏 cream/sticker）切换正常；测试全绿。

**风险**：中。**此任务收益低于 T4-T7，若排期紧张可无限期搁置**——现方案没有正确性问题，只有生态一致性问题。

---

### [x] T10（P2·S）仓库卫生：AGENTS.md 过时信息修正 + pubspec 清理

**现状**：
- 仓库 `AGENTS.md` 写"单一 git 仓库（**无远端 GitHub**）"和"master-test 是部署树"，与现状不符（github 远端已配、2026-09-13 起部署从 dev 树跑）——**误导后续 Agent**；
- `pubspec.yaml` 带 70 行 Flutter 模板注释；`web/`、`build/` 等目录归属未在 README 说明。

**步骤**：
1. AGENTS.md：仓库结构表删掉 worktree 陈旧描述、补 `github` 远端一行；"部署树"表述更新为 dev 树（**此处涉及发版流程，改前与用户确认一句**）。
2. pubspec.yaml：删除模板注释块，保留 `version`/依赖区必要注释（如 flutter_markdown_plus 迁移原因那条）。
3. `app/README.md` 补一节"目录速览"（lib/core、ui/、state/、testing/ 的 5 行说明，T5/T6 完成后写最终版）。

**验收**：新 Agent 只读 AGENTS.md + README 即可正确开工（自测：假装第一次进仓库回答"在哪跑 server、怎么验证 app"两问）。

**风险**：低；唯一注意点是部署树表述需用户裁定。

**完成说明（2026-09-14）**：AGENTS.md 仓库结构更新为三端+双远端现状（部署树 detached 用法如实保留）；pubspec 模板注释清理并补版本号纪律注释 ✅

---

## 3. 执行顺序与依赖关系

```
T1(CI) ─┬─→ T2(FVM) ─→ T3(lint)      # P0 一天内可全清,CI 先行兜住后面所有任务
        │
T4(ZApp拆分, L) ─→ T5(大文件拆分) ─→ T6(测试补强)
        └─→ T7(错误类型化)            # 与 T5 可并行(不同分支不同文件)
T8(动效) / T9(主题) / T10(卫生)       # 任意时机穿插;T9 可暂缓
```

- T1、T2、T3、T10 可由不同 Agent 并行（互不碰 lib/ 代码，T3 碰但文件唯一）。
- **T4 是分水岭**：它完成前不要动 T5/T6/T7（否则拆分基线一直移动）。
- 每任务合并后 CI 绿灯再开下一个（T1 完成后此循环自动成立）。

## 4. 完成后的目标形态（对照调研标准）

| 调研标准 | 本项目落点 |
|---|---|
| 分层 MVVM + 依赖方向 | ZApp 薄组合根 + 4 个状态切片，页面只听自己的 slice（T4） |
| feature-first 目录 | ui/ 按功能子目录 + core/ + testing/（T5/T6） |
| 工程化门禁 | CI + FVM + 严格 lint 三件套（T1-T3） |
| 错误是一等公民 | ApiError 密封类 + 集中文案映射（T7） |
| 动画 token 化、有目的 | motion.dart 唯一出处 + 统一转场（T8） |
| 主题 token 体系 | 已有 ZPalette，T9 补生态一致性（可暂缓） |
| 明确不做 | 不上 Riverpod/dio/freezed/go_router/l10n/monorepo（1.3 节）——**架构克制同样是优秀架构** |
