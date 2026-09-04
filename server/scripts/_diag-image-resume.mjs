// 一次性诊断:同一会话先发纯文本(turn1),complete 后再发图(turn2,走 resume),
// 对比第 2 轮模型能否识图。用法: node scripts/_diag-image-resume.mjs <model>
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { WebSocket } from 'ws';

const model = process.argv[2] ?? 'nemotron-3-nano-omni';

const config = JSON.parse(readFileSync(path.join(os.homedir(), '.zcode-server', 'config.json'), 'utf8'));
const port = config.port ?? 5190;
const token = config.token;

function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xEDB88320 & -(c & 1));
  }
  return ~c >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function makePng(w, h) {
  const sig = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = 2;
  const raw = Buffer.alloc(h * (1 + w * 3));
  for (let y = 0; y < h; y++) {
    const row = y * (1 + w * 3);
    raw[row] = 0;
    for (let x = 0; x < w; x++) {
      const [r, g, b] = y < h / 2 ? [220, 40, 40] : [40, 40, 220]; // 上红下蓝
      const o = row + 1 + x * 3;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  return Buffer.concat([sig, chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}

const dataUri = `data:image/png;base64,${makePng(96, 96).toString('base64')}`;
console.log(`[diag] model=${model} 上红下蓝测试图`);

const ws = new WebSocket(`ws://127.0.0.1:${port}`);
let sessionId = null;
let turn = 0;
let buf = '';
const timer = setTimeout(() => { console.log('\nTIMEOUT 180s'); process.exit(2); }, 180000);

ws.on('open', () => ws.send(JSON.stringify({ type: 'auth', token })));
ws.on('message', (raw) => {
  const msg = JSON.parse(String(raw));
  if (msg.kind === 'authenticated') { createAndSend1(); return; }
  if (msg.kind === 'error') { console.log(`\n>>> ERROR: ${JSON.stringify(msg)}`); return; }
  if (msg.kind === 'text' && msg.role === 'assistant') { buf += msg.content; return; }
  if (msg.kind === 'complete') {
    turn += 1;
    console.log(`\n===== turn${turn} 回复 =====\n${buf.slice(0, 500) || '(无文本)'}`);
    buf = '';
    if (turn === 1) setTimeout(sendTurn2, 500);
    else { clearTimeout(timer); console.log('\n[done]'); process.exit(0); }
  }
});

async function createAndSend1() {
  const s = await fetch(`http://127.0.0.1:${port}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ title: `diag-resume-${model}`, cwd: 'D:/cheng/zcode/server' }),
  }).then((r) => r.json());
  sessionId = s.id;
  console.log(`[session] ${sessionId}`);
  ws.send(JSON.stringify({ type: 'chat.send', sessionId, content: '请只回复两个字:收到', options: { model } }));
}

function sendTurn2() {
  console.log(`\n----- turn2: 同会话(resume)发图 -----`);
  ws.send(JSON.stringify({ type: 'chat.send', sessionId, content: '这张图上下两半分别是什么颜色?只答颜色。', images: [dataUri] }));
}

ws.on('error', (e) => { console.error(`WS FAIL: ${e.message}`); process.exit(1); });
