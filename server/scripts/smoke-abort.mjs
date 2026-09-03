// 中止冒烟:发一个会长任务,2 秒后 chat.abort,期望 complete(aborted:true)
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';

const config = JSON.parse(readFileSync(path.join(os.homedir(), '.zcode-server', 'config.json'), 'utf8'));
const sessionId = process.argv[2];
const ws = new WebSocket(`ws://127.0.0.1:${config.port ?? 5190}`);
const timeout = setTimeout(() => { console.error('ABORT SMOKE TIMEOUT'); process.exit(1); }, 120000);

ws.on('open', () => ws.send(JSON.stringify({ type: 'auth', token: config.token })));
ws.on('message', (raw) => {
  const msg = JSON.parse(String(raw));
  if (msg.kind === 'error') { console.error('SERVER ERROR:', JSON.stringify(msg)); process.exit(1); }
  if (msg.kind === 'authenticated') { ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId, lastSeq: 0 }] })); return; }
  if (msg.kind === 'subscribed') {
    ws.send(JSON.stringify({ type: 'chat.send', sessionId, content: '从 1 数到 50,每个数字单独一行,不要调用工具。' }));
    setTimeout(() => ws.send(JSON.stringify({ type: 'chat.abort', sessionId })), 2000);
    return;
  }
  if (msg.kind === 'complete') {
    clearTimeout(timeout);
    console.log('COMPLETE:', JSON.stringify({ exitCode: msg.exitCode, aborted: msg.aborted }));
    console.log(msg.aborted ? 'ABORT SMOKE OK' : 'ABORT SMOKE FAIL (not aborted)');
    process.exit(msg.aborted ? 0 : 1);
  }
});
ws.on('error', (e) => { console.error('WS ERROR:', e.message); process.exit(1); });
