// 诊断:glm 实例回合是否已收尾(库尾状态)
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const sid = '495fa515-9c50-48c4-98ab-a5e813b0a5b6';
const rows = db.prepare('SELECT seq, kind, role, substr(content,1,70) AS c, created_at FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT 6').all(sid);
for (const r of rows) console.log(`#${r.seq} [${r.kind}/${r.role ?? '-'}] ${String(r.c).replace(/\n/g, ' ')} @${r.created_at}`);
db.close();
