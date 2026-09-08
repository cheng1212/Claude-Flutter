# zCode 开发规范（AGENTS）

## 仓库结构

单一 git 仓库（无远端 GitHub），两个 worktree + 一个 bare 备份：

| 路径 | 常驻分支 | 用途 |
|---|---|---|
| `D:\zcode-master-test` | `master` | **部署树**：zCode Server(5190/5191) 从这里跑，APK 从这里构建。禁止在这里切分支开发 |
| `D:\zcode-dev` | `develop` | **开发树**：日常功能开发都在这里 |
| `D:\cheng\zcode` | `feature/agent-panels` | 遗留 worktree：对端未提交 WIP（`server/src/db.ts` 等），**别动、别提交** |

备份 remote：`backup` → `D:\git-remotes\zcode.git`（bare 仓库）。

## 分支模型（git-flow 简化版）

- `master`：发布线。只接受 develop 的 `--no-ff` 合并 + 版本 tag `vX.Y.Z`（版本号取 `app/pubspec.yaml`）。部署/发版只从 master。
- `develop`：集成线。功能验证通过后合入。
- `feature/<主题>`：从 develop 切出，一个主题一个分支，做完即合即删。
- 例外：文档/CI 类杂项可直接提交 master。

## 日常流程

1. **开工**：`cd D:\zcode-dev && git checkout -b feature/<主题>`（若 master 有新提交如文档/热修复，先 `git merge master`）
2. **提交**：中文消息，对齐现有风格：`server:` / `app:` / `server+app:` 前缀 + 一句话讲清动机
3. **验证**（合入 develop 前必须全绿）：
   - server：`cd D:\zcode-dev\server && npx tsc --noEmit && npx vitest run`
   - app：`cd D:\zcode-dev\app && D:\flutter\bin\flutter.bat analyze && D:\flutter\bin\flutter.bat test`
4. **合入**：`git checkout develop && git merge --no-ff feature/<主题>`
5. **发布**：`git checkout master && git merge --no-ff develop` → 打 tag `v<版本>` → 重启 server（5190/5191）→ 需要时构建 APK 发布（见交接文档）
6. **备份**：`git push backup --all --tags`

## 禁止

- 在 `D:\zcode-master-test`（部署树）开发或切分支
- 动 `D:\cheng\zcode` 的未提交 WIP；`feature/agent-panels`、`feature/session-management` 已全部并入 master，勿再合并
- force push / 改写 master 与已打 tag 的历史

## 其他约定

- 路由配置 `C:\Users\chengge\litellm\claude-routes.json`、litellm 配置不在 git 内，改动需手动同步两份（4000/4001）
- 项目背景与部署命令见《zCode 项目交接文档》
