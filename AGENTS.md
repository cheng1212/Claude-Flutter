# zCode 开发规范（AGENTS）

## 仓库结构

三端单仓库（2026-09-13 起 web/ 入库），远端两个：

- **github** → `https://github.com/cheng1212/Claude-Flutter`（公开，develop 为默认分支，推 tag 同步发版）
- **backup** → `D:\git-remotes\zcode.git`（bare 本地备份）

| 路径 | 用途 |
|---|---|
| `D:\WorkSpace\Claude Code Flutter` | **唯一工作树**（2026-10-03 由 `zcode-dev` 改名而来）：app/ + server/ + web/ 三端日常开发都在这里，server(5190/5191) 也从这里跑 |
| ~~`D:\WorkSpace\zcode-dev`~~ / ~~`D:\WorkSpace\zcode-master-test`~~ | 已消失：前者 2026-10-03 改名成上面的树；后者（旧部署树）2026-10-03 删除，其独有提交已推 backup 远端（`rescue/master-test-*`） |
| `D:\cheng\zcode` | 遗留旧树（含旧 web/），已全面接管，**待清理，别动** |

## 分支模型（git-flow 简化版）

- `master`：发布线。只接受 develop 的 `--no-ff` 合并 + 版本 tag `vX.Y.Z`（版本号取 `app/pubspec.yaml`）。部署/发版只从 master。
- `develop`：集成线。功能验证通过后合入。
- `feature/<主题>`：从 develop 切出，一个主题一个分支，做完即合即删。
- 例外：文档/CI 类杂项可直接提交 master。

## 日常流程

1. **开工**：`cd "D:\WorkSpace\Claude Code Flutter" && git checkout -b feature/<主题>`（若 master 有新提交如文档/热修复，先 `git merge master`）
2. **提交**：中文消息，对齐现有风格：`server:` / `app:` / `server+app:` 前缀 + 一句话讲清动机
3. **验证**（合入 develop 前必须全绿，三端都要；CI 同款门禁见 `.github/workflows/ci.yml`）：
   - server：`cd "D:\WorkSpace\Claude Code Flutter\server" && npx tsc --noEmit && npx vitest run`
   - app：`cd "D:\WorkSpace\Claude Code Flutter\app" && D:\flutter\bin\flutter.bat analyze && D:\flutter\bin\flutter.bat test`
   - web：`cd "D:\WorkSpace\Claude Code Flutter\web" && npx tsc --noEmit && npx vitest run`（2026-10-03 起入门禁，此前只有 app 有 CI）
4. **合入**：`git checkout develop && git merge --no-ff feature/<主题>`
5. **发布**：`git checkout master && git merge --no-ff develop` → 打 tag `v<版本>` → 重启 server（5190/5191）→ 需要时构建 APK 发布（见交接文档）
   - **版本号纪律**：每次发版 `app/pubspec.yaml` 的 `version: X.Y.Z+build` 必须**同时递增**（语义化 X.Y.Z + 递增 build 号），不允许同版本号重复发包；版本号在 app 汉堡菜单底部可见（package_info_plus 读取）
6. **备份**：`git push backup --all --tags`

## 禁止

- master-test 旧树已删除，不存在"部署树"；一律在 `D:\WorkSpace\Claude Code Flutter` 单树内开发、发布
- 动 `D:\cheng\zcode` 的未提交 WIP；`feature/agent-panels`、`feature/session-management` 已全部并入 master，勿再合并
- force push / 改写 master 与已打 tag 的历史

## 其他约定

- 路由配置 `C:\Users\chengge\litellm\claude-routes.json`、litellm 配置不在 git 内，改动需手动同步两份（4000/4001）
- 项目背景与部署命令见《zCode 项目交接文档》
