// 一次性诊断:走真实 server 链路发一张本地生成的图给指定模型,原样打印事件(尤其 error)。
// 用法: node scripts/_diag-image.mjs <model>
import { readFileSync } from 'node:fs';
import zlib from 'node:zlib';
import os from 'node:os';
import path from 'node:path';
import { WebSocket } from 'ws';

const model = process.argv[2];
if (!model) { console.error('usage: node scripts/_diag-image.mjs <model>'); process.exit(1); }

const config = JSON.parse(readFileSync(path.join(os.homedir(), '.zcode-server', 'config.json'), 'utf8'));
const port = config.port ?? 5190;
const token = config.token;
const base = `http://127.0.0.1:${port}`;

// —— 本地生成 96x96 PNG:上半绿(rgb 0,180,80)、下半蓝(0,80,220),识图应能答出——
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
  ihdr[8] = 8; ihdr[9] = 2; // 8-bit RGB
  const raw = Buffer.alloc(h * (1 + w * 3));
  for (let y = 0; y < h; y++) {
    const row = y * (1 + w * 3);
    raw[row] = 0; // filter none
    for (let x = 0; x < w; x++) {
      const [r, g, b] = y < h / 2 ? [0, 180, 80] : [0, 80, 220];
      const o = row + 1 + x * 3;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  return Buffer.concat([
    sig,
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

const buf = makePng(96, 96);
const dataUri = `data:image/png;base64,${buf.toString('base64')}`;
console.log(`[diag] model=${model} image bytes=${buf.length} (96x96 上绿下蓝)`);

const ws = new WebSocket(`ws://127.0.0.1:${port}`);
const timer = setTimeout(() => { console.log('\nTIMEOUT 150s'); process.exit(2); }, 150000);

ws.on('open', () => ws.send(JSON.stringify({ type: 'auth', token })));
ws.on('message', (raw) => {
  const msg = JSON.parse(String(raw));
  if (msg.kind === 'authenticated') { console.log('[authed]'); createAndSend(); return; }
  if (msg.kind === 'error') { console.log(`\n>>> ERROR EVENT: ${JSON.stringify(msg)}`); return; }
  if (msg.kind === 'text' && msg.role === 'assistant') { process.stdout.write(msg.content); return; }
  if (msg.kind === 'usage') console.log(`\n[evt] ${JSON.stringify(msg).slice(0, 400)}`);
  if (msg.kind === 'complete') {
    console.log(`\n[evt] ${JSON.stringify(msg)}`);
    clearTimeout(timer);
    process.exit(msg.exitCode === 0 && !msg.aborted ? 0 : 1);
  }
});

async function createAndSend() {
  const s = await fetch(`${base}/api/sessions`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ title: `diag-image-${model}`, cwd: 'D:/cheng/zcode/server' }),
  }).then((r) => r.json());
  console.log(`[session] ${s.id}`);
  ws.send(JSON.stringify({ type: 'chat.send', sessionId: s.id, content: '这张图里是什么?请直接描述。', options: { model }, images: [dataUri] }));
}

ws.on('error', (e) => { console.error(`\nWS FAIL: ${e.message}`); clearTimeout(timer); process.exit(1); });
ws.on('close', () => { clearTimeout(timer); });
