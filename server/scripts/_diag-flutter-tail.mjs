// 诊断:消息体量 + 尾部 text 行 + REST 排序方式
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const sid = '495fa515-9c50-48c4-98ab-a5e813b0a5b6';

const r = db.prepare('SELECT COUNT(*) AS n, SUM(LENGTH(meta)) AS bytes, MAX(LENGTH(meta)) AS mx FROM messages WHERE session_id=?').get(sid);
console.log(`rows=${r.n}  totalMeta=${(r.bytes / 1048576).toFixed(1)}MB  maxRow=${(r.mx / 1024).toFixed(0)}KB`);

const texts = db.prepare("SELECT seq, role, LENGTH(content) AS len, substr(content,1,70) AS c FROM messages WHERE session_id=? AND kind='text' AND seq>=255 ORDER BY seq").all(sid);
console.log('\n--- seq>=255 的 text 行 ---');
for (const x of texts) console.log(`#${x.seq} [${x.role}] ${x.len}B  ${String(x.c).replace(/\n/g, ' ')}`);

// 每种 kind 的行数与体量
const kinds = db.prepare('SELECT kind, COUNT(*) AS n, SUM(LENGTH(meta)) AS b FROM messages WHERE session_id=? GROUP BY kind ORDER BY b DESC').all(sid);
console.log('\n--- kind 分布 ---');
for (const k of kinds) console.log(`${k.kind}: ${k.n} 行, ${(k.b / 1048576).toFixed(1)}MB`);
db.close();
