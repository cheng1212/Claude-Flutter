// 直连 ws 发一轮消息,验证指定模型真的走通(等 complete 或 error)。
// 用法: node test-model.mjs <model> [text]
import WebSocket from 'ws';

const model = process.argv[2] || 'nemotron-3-ultra';
const text = process.argv[3] || '用一句话介绍你自己';

const ws = new WebSocket('ws://127.0.0.1:5190/ws?token=123456');
let sessionId = null;
let sawError = null;
let replyLen = 0;

const timer = setTimeout(() => {
  console.log(`TIMEOUT after 120s (replyLen=${replyLen})`);
  process.exit(2);
}, 120000);

ws.on('open', () => {
  console.log(`[ws open] sending model=${model} text=${text}`);
  ws.send(JSON.stringify({ type: 'auth', token: '123456' }));
});

function doSend() {
  // 新会话走 REST 建会话,再 chat.send
  fetch('http://127.0.0.1:5190/api/sessions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer 123456' },
    body: JSON.stringify({ title: '模型链路测试', cwd: 'D:/cheng/zcode/server' }),
  }).then((r) => r.json()).then((s) => {
    sessionId = s.id;
    console.log(`[session] ${sessionId}`);
    ws.send(JSON.stringify({ type: 'chat.subscribe', sessions: [{ sessionId, lastSeq: 0 }] }));
    ws.send(JSON.stringify({ type: 'chat.send', sessionId, content: text, options: { model } }));
  }).catch((e) => { console.log(`REST FAIL: ${e.message}`); process.exit(1); });
}

ws.on('message', (raw) => {
  const msg = JSON.parse(raw.toString());
  if (msg.kind === 'authenticated') { console.log('[authed]'); doSend(); return; }
  if (msg.kind === 'error') { console.log(`\nWS ERROR: ${JSON.stringify(msg).slice(0, 300)}`); return; }
  // fanout 直接广播事件本体({...event, sessionId})
  const ev = msg;
  if (ev.kind === 'text' && ev.role === 'assistant') {
    replyLen += (ev.content ?? '').length;
    process.stdout.write(ev.content ?? '');
  } else if (ev.kind === 'error') {
    sawError = ev.content;
    console.log(`\nERROR: ${ev.content}`);
  } else if (ev.kind === 'complete') {
    console.log(`\nCOMPLETE exit=${ev.exitCode} replyLen=${replyLen}`);
    clearTimeout(timer);
    ws.close();
    process.exit(sawError || replyLen === 0 ? 1 : 0);
  }
});

ws.on('error', (e) => { console.log(`WS FAIL: ${e.message}`); process.exit(1); });
ws.on('close', () => { clearTimeout(timer); });
