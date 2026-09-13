// cron 调度器(架构级新功能):server 常驻循环,扫描到点的任务,
// 程序化触发对应会话(与 ws chat.send 同管线,由 gateway.triggerSession 提供)。
//
// 语义:
// - 到点判定 = now >= next_fire(简表逐分钟扫描的 next_fire 已在 listCrons 现算);
// - recurring=false 触发后标记 done;recurring 触发后自然推进(下次 next_fire 现算);
// - 会话正在运行 → 跳过本轮(下轮扫描再试,避免打断当前回合);
// - 扫描周期 30s:分钟粒度的 cron 语义下足够及时,且开销可忽略。
import type { Db } from './db.js';
import { listCrons, markCronDeleted, recordCronRun } from './db.js';
import { nextFire } from './cron.js';

export type CronTrigger = (sessionId: string, prompt: string) => boolean;

export function startCronScheduler(db: Db, trigger: CronTrigger, tickMs = 30_000): { stop(): void } {
  const firedUntil = new Map<string, number>(); // cronId → 已触发的 next_fire(ms),防同一分钟重复触发
  const timer = setInterval(() => {
    try {
      const now = Date.now();
      for (const r of listCrons(db)) {
        if (!r.next_fire) continue;
        const fire = new Date(r.next_fire).getTime();
        if (Number.isNaN(fire) || fire > now) continue;
        const last = firedUntil.get(r.id) ?? 0;
        if (last >= fire) continue; // 这一分钟已触发过
        firedUntil.set(r.id, fire);
        if (trigger(r.session_id, r.prompt)) {
          recordCronRun(db, r.id, r.session_id, 'success');
          console.log(`[zcode-server] cron fired: session=${r.session_id.slice(0, 8)} ${r.cron}`);
          if (r.recurring === 0) markCronDeleted(db, r.id); // 一次性任务触发即完成
        } else {
          // 会话在跑(不打断当前回合)或会话不可用:记一笔但不计入"已跑次数"
          recordCronRun(db, r.id, r.session_id, 'skipped', '会话在运行或不可用,本轮跳过');
          console.log(`[zcode-server] cron skipped: session=${r.session_id.slice(0, 8)} ${r.cron}`);
        }
      }
    } catch (e) {
      console.warn('[zcode-server] cron scheduler tick failed:', e instanceof Error ? e.message : e);
    }
  }, tickMs);
  timer.unref?.();
  return { stop: () => clearInterval(timer) };
}
