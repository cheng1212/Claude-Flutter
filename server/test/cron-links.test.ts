// cron 双 id 绑定:CronCreate 的 toolUseId → CLI job id → 镜像行。
// 修复"删除失明":CronDelete 只带 CLI job id,旧镜像按表达式+提示词匹配永远失配。
import { beforeEach, describe, expect, it } from 'vitest';
import { openDb, createSession, recordCronToolUse, listCrons } from '../src/db.js';
import { cronExpectCreate, cronResolveCreate, cronResolveDelete } from '../src/cron-links.js';
import type { Db } from '../src/db.js';

let db: Db;
let sid: string;

beforeEach(() => {
  db = openDb(':memory:');
  sid = createSession(db, { title: 'cron绑定' }).id;
  recordCronToolUse(db, sid, {
    toolName: 'CronCreate',
    toolInput: { cron: '*/5 * * * *', prompt: '检查构建' },
  });
  cronExpectCreate(sid, 'tool-1');
});

describe('cron-links', () => {
  it('结果带回 CLI job id → 绑定;CronDelete 按 id 命中镜像行', () => {
    cronResolveCreate(db, sid, 'tool-1', '{"id":"cron-abc","humanSchedule":"每 5 分钟","recurring":true}');
    expect(listCrons(db, sid).length).toBe(1);

    expect(cronResolveDelete(db, sid, 'cron-abc')).toBe(true);
    expect(listCrons(db, sid).length).toBe(0); // 镜像行已标删
    expect(cronResolveDelete(db, sid, 'cron-abc')).toBe(false); // 幂等
  });

  it('结果是非 JSON 的自然语言,里面的 job id 也能抓到', () => {
    cronResolveCreate(db, sid, 'tool-1', '定时任务已创建:cron-xyz-7Qd2,每 5 分钟触发');
    expect(cronResolveDelete(db, sid, 'cron-xyz-7Qd2')).toBe(true);
    expect(listCrons(db, sid).length).toBe(0);
  });

  it('没 expect 过的 toolResult 不误绑;未知 id 的删除返回 false', () => {
    cronResolveCreate(db, sid, 'tool-其他', '{"id":"cron-nope"}');
    expect(cronResolveDelete(db, sid, 'cron-nope')).toBe(false);
    expect(listCrons(db, sid).length).toBe(1); // 没误删
  });
});
