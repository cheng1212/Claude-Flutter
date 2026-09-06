// 极简 5 字段 cron 解析(本地时区):分 时 日 月 周。
// 支持:*、数字、范围 a-b、步进 */n、列表 a,b,c(可组合,如 1-5,0)。
// nextFire 从 from 的下一分钟开始逐分钟扫描,上限 366 天。

const RANGES: [number, number][] = [
  [0, 59], // 分
  [0, 23], // 时
  [1, 31], // 日
  [1, 12], // 月
  [0, 6], // 周(0=周日)
];

/** 单字段表达式是否匹配值。expr: 星号 / 步进(星号斜杠n) / 范围 a-b / 列表 a,b,c 及组合。 */
export function cronPartsMatch(expr: string, value: number, min: number, max: number): boolean {
  for (const part of expr.split(',')) {
    const p = part.trim();
    if (!p) continue;
    if (p.startsWith('*/')) {
      const step = Number(p.slice(2));
      if (!Number.isInteger(step) || step <= 0) continue;
      if (value >= min && (value - min) % step === 0) return true;
    } else if (p.includes('-') && !p.startsWith('-')) {
      const [a, b] = p.split('-').map(Number);
      if (Number.isInteger(a) && Number.isInteger(b) && value >= a && value <= b) return true;
    } else if (p === '*' || Number(p) === value) {
      return true;
    }
  }
  return false;
}

function fieldMatch(expr: string, value: number, idx: number): boolean {
  const [min, max] = RANGES[idx];
  if (expr === '*') return true;
  return cronPartsMatch(expr, value, min, max);
}

/** 下一触发时刻(秒取 0);一年内无匹配或表达式非法 → null。 */
export function nextFire(cron: string, from: Date): Date | null {
  const fields = cron.trim().split(/\s+/);
  if (fields.length !== 5) return null;
  // 合法性预检:每个字段至少能匹配域内一个值
  for (let i = 0; i < 5; i++) {
    const [min, max] = RANGES[i];
    let ok = false;
    for (let v = min; v <= max && !ok; v++) ok = fieldMatch(fields[i], v, i);
    if (!ok) return null;
  }
  const cursor = new Date(from.getTime());
  cursor.setSeconds(0, 0);
  cursor.setMinutes(cursor.getMinutes() + 1); // 从下一分钟起算
  const limit = 366 * 24 * 60;
  for (let i = 0; i < limit; i++) {
    if (
      fieldMatch(fields[0], cursor.getMinutes(), 0) &&
      fieldMatch(fields[1], cursor.getHours(), 1) &&
      fieldMatch(fields[2], cursor.getDate(), 2) &&
      fieldMatch(fields[3], cursor.getMonth() + 1, 3) &&
      fieldMatch(fields[4], cursor.getDay(), 4)
    ) {
      return new Date(cursor.getTime());
    }
    cursor.setMinutes(cursor.getMinutes() + 1);
  }
  return null;
}
