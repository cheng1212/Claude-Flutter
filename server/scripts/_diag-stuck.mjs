// 诊断:REST messages 端点实际行为——行数、字节数、最大单行,以及 runs 表状态
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const id = '495fa515-9c50-48c4-98ab-a5e813b0a5b6';

console.log('== runs schema ==');
console.log(db.prepare('PRAGMA table_info(runs)').all().map((c) => c.name).join(', '));

console.log('\n== runs ==');
const runs = db.prepare('SELECT * FROM runs WHERE session_id=? ORDER BY rowid DESC LIMIT 5').all(id);
for (const r of runs) console.log(JSON.stringify(r).slice(0, 300));

console.log('\n== messages 尺寸分布 ==');
const rows = db.prepare('SELECT seq, kind, role, LENGTH(meta) mlen, LENGTH(content) clen FROM messages WHERE session_id=? ORDER BY seq').all(id);
const totalMeta = rows.reduce((a, r) => a + (r.mlen ?? 0), 0);
const totalContent = rows.reduce((a, r) => a + (r.clen ?? 0), 0);
console.log(`rows=${rows.length} meta总字节=${totalMeta} content总字节=${totalContent} 合计≈${((totalMeta + totalContent) / 1048576).toFixed(1)}MB`);
const top = [...rows].sort((a, b) => (b.mlen ?? 0) - (a.mlen ?? 0)).slice(0, 5);
for (const r of top) console.log(`  最大: #${r.seq} ${r.kind}/${r.role ?? '-'} meta=${(r.mlen / 1048576).toFixed(2)}MB`);

// 模拟端点排序:seq DESC LIMIT 500 → 前端再反转
const desc = db.prepare('SELECT seq FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT 500').all(id);
console.log(`\n端点返回首行 seq=${desc[0]?.seq} 末行 seq=${desc.at(-1)?.seq} (共${desc.length}行)`);
