// 诊断:全会话扫描"孤儿 tool_use"(没有配对 tool_result 的)——区分"重启自杀"与"系统性丢失"
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const db = new Database(path.join(os.homedir(), '.zcode-server', 'zcode.db'), { readonly: true });
const sid = '495fa515-9c50-48c4-98ab-a5e813b0a5b6';

const uses = db.prepare("SELECT seq, meta FROM messages WHERE session_id=? AND kind='tool_use' ORDER BY seq").all(sid);
const results = new Set(
  db.prepare("SELECT meta FROM messages WHERE session_id=? AND kind='tool_result'").all(sid)
    .map((r) => { try { return JSON.parse(r.meta).toolId; } catch { return ''; } })
);
console.log(`tool_use=${uses.length}  tool_result(去重 toolId)=${results.size}`);
let orphans = 0;
for (const u of uses) {
  let id = '', name = '', cmd = '';
  try { const m = JSON.parse(u.meta); id = m.toolId; name = m.toolName; cmd = JSON.stringify(m.toolInput).substring(0, 80); } catch {}
  if (id && !results.has(id)) {
    orphans++;
    console.log(`孤儿 #${u.seq} [${name}] ${cmd}`);
  }
}
if (orphans === 0) console.log('无孤儿:每个 tool_use 都有 tool_result(除上述扫描外)');
db.close();
