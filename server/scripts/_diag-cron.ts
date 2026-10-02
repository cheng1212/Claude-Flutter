import { openDb, listCrons } from '../src/db.js';
const db = openDb('C:/Users/chengge/.zcode-server/zcode.db');
const rows = listCrons(db);
const now = new Date();
console.log('now:', now.toISOString());
for (const r of rows) {
  const fire = r.next_fire ? new Date(r.next_fire) : null;
  const due = fire ? fire.getTime() <= now.getTime() : false;
  console.log(JSON.stringify({ id: r.id.slice(0, 8), cron: r.cron, status: r.status, next_fire: r.next_fire, due }));
}
