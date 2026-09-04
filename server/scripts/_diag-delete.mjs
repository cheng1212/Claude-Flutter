// 一次性诊断:模拟删除 source=local + provider_session_id 的会话,复现报错。
import Database from 'better-sqlite3';
import os from 'node:os';
import path from 'node:path';

const dbFile = path.join(os.homedir(), '.zcode-server', 'zcode.db');
const db = new Database(dbFile);
const id = 'test-del-' + Date.now();
db.prepare(`INSERT INTO sessions(id,title,cwd,model,source,provider_session_id,created_at,updated_at)
  VALUES(?,?,?,?,?,?,?,?)`).run(id, 'del-本地测试', null, null, 'local', 'fake-provider-xyz', new Date().toISOString(), new Date().toISOString());
db.close();
console.log(`planted: ${id}`);

const h = { Authorization: 'Bearer 123456' };
try {
  const d = await fetch(`http://127.0.0.1:5190/api/sessions/${id}`, { method: 'DELETE', headers: h });
  const text = await d.text();
  console.log(`DELETE status=${d.status} body=${text.slice(0, 400)}`);
} catch (e) {
  console.log(`DELETE FAIL: ${e.message}`);
}

// 清理墓碑(测试数据)
const db2 = new Database(dbFile);
db2.prepare('DELETE FROM session_tombstones WHERE provider_session_id=?').run('fake-provider-xyz');
db2.close();
console.log('tombstone cleaned');
