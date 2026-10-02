// 鉴权失败限速:同一来源短窗口内反复失败 → 临时封禁,堵"无限重试爆破弱令牌"这条路。
// 纯内存态(重启即清零):个人局域网服务,持久化封禁名单是过度设计;单进程内存即权威。
export type AuthThrottle = {
  /** 记一次鉴权失败 */
  fail(key: string): void;
  /** 该来源当前是否已被封禁 */
  blocked(key: string): boolean;
  /** 鉴权成功后清零:正常用户偶尔手滑不至于积累到封禁 */
  reset(key: string): void;
};

export function createAuthThrottle(opts?: { maxFails?: number; windowMs?: number; blockMs?: number }): AuthThrottle {
  const maxFails = opts?.maxFails ?? 10;
  const windowMs = opts?.windowMs ?? 10 * 60_000;
  const blockMs = opts?.blockMs ?? 10 * 60_000;
  const fails = new Map<string, { count: number; first: number }>();
  const banned = new Map<string, number>(); // key → 解封时刻(ms)
  let lastSweep = 0;

  const sweep = (now: number) => {
    if (now - lastSweep < 60_000) return; // 低频清理:别每个请求都扫表
    lastSweep = now;
    for (const [k, until] of banned) if (until <= now) banned.delete(k);
    for (const [k, v] of fails) if (now - v.first > windowMs) fails.delete(k);
  };

  return {
    fail(key) {
      const now = Date.now();
      sweep(now);
      const cur = fails.get(key);
      if (!cur || now - cur.first > windowMs) {
        fails.set(key, { count: 1, first: now });
        return;
      }
      if (++cur.count >= maxFails) {
        fails.delete(key);
        banned.set(key, now + blockMs);
      }
    },
    blocked(key) {
      const until = banned.get(key);
      if (until == null) return false;
      if (until <= Date.now()) {
        banned.delete(key);
        return false;
      }
      return true;
    },
    reset(key) {
      fails.delete(key);
      banned.delete(key);
    },
  };
}
