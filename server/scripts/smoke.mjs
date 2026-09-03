// 一次性冒烟客户端:node scripts/smoke.mjs <sessionId>
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';

const config = JSON.parse(readFileSync(path.join(os.homedir(), '.zcode-server', 'config.json'), 'utf8'));
const sessionId = process.argv[2];
if (!sessionId) { console.error('usage: node scripts/smoke.mjs <sessionId>'); process.exit(1); }

const ws = new WebSocket(`ws://127.0.0.1:${config.port ?? 5190}`);
const seen = [];
const timeout = setTimeout(() => { console.error('SMOKE TIMEOUT (120s)'); process.exit(1); }, 120000);

ws.on('open', () => ws.send(JSON.stringify({ type: 'auth', token: config.token })));
ws.on('message', (raw) => {
  const msg = JSON.parse(String(raw));
  if (msg.kind === 'error') { console.error('SERVER ERROR:', JSON.stringify(msg)); process.exit(1); }
  if (msg.kind === 'authenticated') {
    ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId, lastSeq: 0 }] }));
    return;
  }
  if (msg.kind === 'subscribed') {
    ws.send(JSON.stringify({ type: 'chat.send', sessionId, content: '用一句话自我介绍,不要调用任何工具。' }));
    return;
  }
  seen.push(msg);
  if (msg.kind === 'complete') {
    clearTimeout(timeout);
    const kinds = seen.map((m) => m.kind);
    const text = seen.filter((m) => m.kind === 'text').map((m) => m.content).join('');
    const usage = seen.find((m) => m.kind === 'usage');
    console.log('EVENTS:', JSON.stringify(kinds));
    console.log('TEXT:', text.slice(0, 300));
    console.log('USAGE:', JSON.stringify(usage ?? null));
    const ok = kinds.includes('text') && kinds.includes('usage') && msg.exitCode === 0 && !msg.aborted;
    console.log(ok ? 'SMOKE OK' : 'SMOKE FAIL');
    process.exit(ok ? 0 : 1);
  }
});
ws.on('error', (e) => { console.error('WS ERROR:', e.message); process.exit(1); });
