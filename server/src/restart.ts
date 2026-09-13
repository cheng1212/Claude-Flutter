// 自我重启:app 点「重启服务器」→ 先应答 → 拉起一个**脱离当前进程树**的新实例 → 自己退出。
// 关键点是新进程必须 detached + unref:否则旧进程一退,Windows 会把子进程一起带走。
import { spawn } from 'node:child_process';
import fs from 'node:fs';

export type RestartPlan = {
  /** 可执行文件(node) */
  cmd: string;
  /** 复现启动用的参数(tsx 加载器 + 入口脚本) */
  args: string[];
  /** 工作目录:argv 里的相对入口(src/index.ts)靠它解析 */
  cwd: string;
  /** 新进程 stdout/stderr 追加到这里 */
  logFile: string;
};

/**
 * 由当前进程的启动信息推出重启命令。
 * 直接复现 `process.argv`(node + tsx 加载器 + src/index.ts),比硬编码 npm start 稳:
 * 换启动方式(tsx/编译产物/其他加载器)都不用改这里。
 */
export function restartPlan(opts: {
  execPath: string;
  argv: string[];
  cwd: string;
  logFile: string;
}): RestartPlan {
  return {
    cmd: opts.execPath,
    args: opts.argv.slice(1),
    cwd: opts.cwd,
    logFile: opts.logFile,
  };
}

/** 拉起新实例并立即脱钩。返回新进程 pid(仅用于日志)。 */
export function spawnRestart(plan: RestartPlan): number | undefined {
  const fd = fs.openSync(plan.logFile, 'a');
  try {
    const child = spawn(plan.cmd, plan.args, {
      cwd: plan.cwd,
      detached: true, // 独立进程组:父进程退出不牵连
      stdio: ['ignore', fd, fd],
      windowsHide: true,
      env: { ...process.env },
    });
    child.unref();
    return child.pid;
  } finally {
    fs.closeSync(fd); // 关掉父进程这侧的句柄副本,别拽着新进程的输出
  }
}
