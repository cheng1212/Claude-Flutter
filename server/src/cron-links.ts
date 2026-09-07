// cron 双 id 绑定(内存态):CronCreate 的 toolUseId → CLI job id → 镜像行 id。
// 修复"删除失明":CronDelete 只带 CLI 的 job id,而镜像行是自己的 UUID,
// 没有这层绑定,模型发起的删除在镜像里永远匹配不上(旧实现按表达式+提示词,
// 但 CronDelete 的入参只有 id)。server 重启丢绑定:重启后镜像里也没有历史任务上下文,可接受。
import type { Db } from './db.js';
import { listCrons, markCronDeleted } from './db.js';

const pending = new Set<string>(); // `${sessionId}|${toolUseId}`:已发起 CronCreate、等结果
const byCli = new Map<string, string>(); // `${sessionId}|${cliId}` → 镜像行 id

/** 拦截到 CronCreate tool_use:登记"等结果"的 toolUseId。 */
export function cronExpectCreate(sessionId: string, toolUseId: string): void {
  pending.add(sessionId + '|' + toolUseId);
}

/**
 * CronCreate 的 tool_result 回来:从内容解析 CLI job id,绑定到该会话最新的
 * 未绑定 active 镜像行。内容格式不挑(JSON 或自然语言里的 id 都能抓)。
 */
export function cronResolveCreate(db: Db, sessionId: string, toolUseId: string, content: string): void {
  if (!pending.delete(sessionId + '|' + toolUseId)) return;
  const cliId = content.match(/"id"\s*:\s*"([^"]+)"/)?.[1]
    ?? content.match(/\bcron-[A-Za-z0-9_-]+\b/)?.[0]
    ?? content.match(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/)?.[0];
  if (!cliId) return;
  const taken = new Set(
    [...byCli.entries()].filter(([k]) => k.startsWith(sessionId + '|')).map(([, v]) => v),
  );
  const row = listCrons(db, sessionId).find((r) => !taken.has(r.id));
  if (row) byCli.set(sessionId + '|' + cliId, row.id);
}

/** CronDelete 拦截:CLI job id → 镜像行;命中即标删并解绑(二次删返回 false)。 */
export function cronResolveDelete(db: Db, sessionId: string, cliId: string): boolean {
  const key = sessionId + '|' + cliId;
  const rowId = byCli.get(key);
  if (!rowId) return false;
  markCronDeleted(db, rowId);
  byCli.delete(key);
  return true;
}
