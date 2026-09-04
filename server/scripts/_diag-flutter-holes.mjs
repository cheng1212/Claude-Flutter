// 诊断:flutter 会话 seq 空洞 + error 分布
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const sid = '495fa515-9c50-48c4-98ab-a5e813b0a5b6';

const seqs = db.prepare('SELECT seq FROM messages WHERE session_id=? ORDER BY seq').all(sid).map((r) => r.seq);
const holes = [];
for (let i = 1; i < seqs.length; i++) if (seqs[i] - seqs[i - 1] > 1) holes.push(`${seqs[i - 1] + 1}..${seqs[i] - 1}`);
console.log('总行数', seqs.length, 'min', seqs[0], 'max', seqs[seqs.length - 1]);
console.log('空洞:', holes.length ? holes.join(', ') : '无');

const errs = db.prepare("SELECT seq, substr(content,1,60) AS c, created_at FROM messages WHERE session_id=? AND kind='error' ORDER BY seq").all(sid);
console.log('\nerror 事件:', errs.length);
for (const e of errs.slice(-6)) console.log(` #${e.seq} ${String(e.c).replace(/\n/g, ' ')} @${e.created_at}`);
db.close();
