// 模拟手机 WS 客户端:auth → subscribe(lastSeq=0) → 打印收到的一切 90 秒
import WebSocket from 'ws';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.zcode-server', 'config.json'), 'utf8'));
const ws = new WebSocket(`ws://127.0.0.1:${cfg.port ?? 5190}`);
const sid = process.argv[2] ?? '495fa515-9c50-48c4-98ab-a5e813b0a5b6';
let n = 0;

ws.on('open', () => {
  console.log('[open] → auth');
  ws.send(JSON.stringify({ type: 'auth', token: cfg.token }));
});
ws.on('message', (raw) => {
  const m = JSON.parse(String(raw));
  if (m.kind === 'authenticated') {
    console.log('[authed] → subscribe lastSeq=0');
    ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId: sid, lastSeq: 0 }] }));
    return;
  }
  n++;
  if (m.kind === 'subscribed') console.log(`#${n} subscribed isProcessing=${m.isProcessing} serverLastSeq=${m.lastSeq}`);
  else if (m.kind === 'replay') console.log(`#${n} replay ${m.events.length}条 [${m.events[0]?.seq}..${m.events.at(-1)?.seq}] kinds=${[...new Set(m.events.map((e) => e.kind))].join(',')}`);
  else {
    const c = String(m.content ?? '').replace(/\s+/g, ' ').slice(0, 80);
    console.log(`#${n} ${m.kind}${m.role ? '/' + m.role : ''} seq=${m.seq ?? '-'} :: ${c}`);
  }
});
ws.on('close', (c, r) => console.log(`[close] code=${c} reason=${r}`));
ws.on('error', (e) => console.log('[error]', e.message));
setTimeout(() => { console.log(`--- 90s 到,共收 ${n} 条 ---`); ws.close(); process.exit(0); }, 90_000);
