import { describe, expect, it } from 'vitest';
import { restartPlan } from '../src/restart.js';

describe('restartPlan · 自我重启命令推导', () => {
  it('复现当前启动方式:execPath + argv[1..] + 原 cwd', () => {
    const plan = restartPlan({
      execPath: 'C:\\node\\node.exe',
      argv: [
        'C:\\node\\node.exe',
        '--require', 'D:\\zcode-dev\\server\\node_modules\\tsx\\dist\\preflight.cjs',
        '--import', 'file:///D:/zcode-dev/server/node_modules/tsx/dist/loader.mjs',
        'src/index.ts',
      ],
      cwd: 'D:\\zcode-dev\\server',
      logFile: 'C:\\Users\\x\\.zcode-server\\server.out.log',
    });
    expect(plan.cmd).toBe('C:\\node\\node.exe');
    // 去掉 argv[0](node 自身),其余参数原样保留——相对入口 src/index.ts 靠 cwd 解析
    expect(plan.args).toEqual([
      '--require', 'D:\\zcode-dev\\server\\node_modules\\tsx\\dist\\preflight.cjs',
      '--import', 'file:///D:/zcode-dev/server/node_modules/tsx/dist/loader.mjs',
      'src/index.ts',
    ]);
    expect(plan.args).not.toContain('C:\\node\\node.exe');
    expect(plan.cwd).toBe('D:\\zcode-dev\\server');
    expect(plan.logFile).toContain('server.out.log');
  });

  it('编译产物启动(node dist/index.js)同样复现', () => {
    const plan = restartPlan({
      execPath: 'C:\\node\\node.exe',
      argv: ['C:\\node\\node.exe', 'dist/index.js'],
      cwd: 'D:\\zcode-dev\\server',
      logFile: 'log.txt',
    });
    expect(plan.args).toEqual(['dist/index.js']);
  });
});
