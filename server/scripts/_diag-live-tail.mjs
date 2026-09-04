// 诊断:库尾实时状态(我的当前回合事件有没有在落库)
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const sid = '495fa515-9c50-48c4-98ab-a5e813b0a5b6';
const rows = db.prepare('SELECT seq, kind, role, substr(content,1,60) AS c, created_at FROM messages WHERE session_id=? AND seq>280 ORDER BY seq').all(sid);
for (const r of rows) console.log(`#${r.seq} [${r.kind}/${r.role ?? '-'}] ${String(r.c).replace(/\n/g, ' ')} @${r.created_at}`);
db.close();
