// 一次性诊断:翻 DB 里真实发过图的会话,看 session.model + 助手当时的回复。
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import Database from 'better-sqlite3';

const dbFile = path.join(os.homedir(), '.zcode-server', 'zcode.db');
const db = new Database(dbFile, { readonly: true });

const sessions = db.prepare(
  "SELECT id, title, model, source, updated_at FROM sessions ORDER BY updated_at DESC LIMIT 25",
).all();
console.log('=== 最近 25 个会话 ===');
for (const s of sessions) console.log(`${s.updated_at}  model=${(s.model ?? 'default').padEnd(35)} ${s.source.padEnd(5)}  ${s.title.slice(0, 30)}  ${s.id.slice(0, 8)}`);

// 找 meta 里带 images 的用户消息
const rows = db.prepare(`
  SELECT m.session_id, m.seq, m.kind, m.role, m.content, m.meta, m.created_at, s.model, s.title
  FROM messages m JOIN sessions s ON s.id = m.session_id
  WHERE m.role='user' AND m.meta LIKE '%"images"%'
  ORDER BY m.created_at DESC LIMIT 10
`).all();
console.log(`\n=== 带图用户消息(最近 ${rows.length} 条)===`);
for (const r of rows) {
  const meta = JSON.parse(r.meta ?? '{}');
  const imgs = Array.isArray(meta.images) ? meta.images : [];
  console.log(`\n[${r.created_at}] session=${r.session_id.slice(0, 8)} model=${r.model ?? 'default'} title=${r.title.slice(0, 25)}`);
  console.log(`  图片 ${imgs.length} 张:`);
  for (const uri of imgs) {
    const m = /^data:([^;]+);base64,([A-Za-z0-9+/=]{0,24})/.exec(uri);
    console.log(`    - mime=${m ? m[1] : '?'} head=${m ? m[2] : '?'} totalLen=${uri.length}`);
  }
  console.log(`  文本: ${String(r.content).slice(0, 120)}`);
  // 找其后同会话 seq 更大的第一条 assistant/error
  const after = db.prepare(`
    SELECT seq, kind, role, content FROM messages
    WHERE session_id=? AND seq>? AND (role='assistant' OR kind='error')
    ORDER BY seq LIMIT 1
  `).get(r.session_id, r.seq);
  if (after) console.log(`  随后[seq=${after.seq} ${after.kind}]: ${String(after.content).slice(0, 200)}`);
}
if (rows.length === 0) console.log('(一条都没有 → 手机 App 发的图根本没到服务端,或 App 版本没带 images 字段)');
