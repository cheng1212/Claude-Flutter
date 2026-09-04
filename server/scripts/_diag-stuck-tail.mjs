// 诊断:长命令卡住后,尾部事件到底落库没有。
// 看 tool_use(运行中卡点)之后有没有 tool_result / text / complete;时间差多大。
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const sessions = db.prepare("SELECT id, title FROM sessions ORDER BY updated_at DESC LIMIT 5").all();
console.log('--- 最近会话 ---');
for (const s of sessions) console.log(`${s.id}  ${s.title}`);

// 取最新活跃的会话
const sid = sessions[0].id;
console.log(`\n=== 会话 ${sid} 尾部 40 行 ===`);
const rows = db.prepare('SELECT seq, kind, role, created_at, LENGTH(content) AS len, substr(content,1,60) AS c FROM messages WHERE session_id=? ORDER BY seq DESC LIMIT 40').all(sid).reverse();
for (const x of rows) {
  console.log(`#${x.seq} ${x.created_at} ${x.kind}${x.role ? '/' + x.role : ''} ${x.len}B  ${String(x.c).replace(/\n/g, ' ')}`);
}

const runs = db.prepare('SELECT id, session_id, status, started_at, ended_at FROM runs ORDER BY started_at DESC LIMIT 6').all();
console.log('\n--- 最近 runs ---');
for (const r of runs) console.log(`${r.session_id.substring(0, 8)} ${r.status} ${r.started_at} → ${r.ended_at ?? '…'}`);
db.close();
