import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { randomBytes } from 'node:crypto';

export type ServerConfig = {
  token: string;
  port: number;
  dataDir: string;
  routesPath: string;
  publicDir: string;
  bgCeilingMs: number;
  approvalTimeoutMs: number;
};

export function defaultDataDir(): string {
  return process.env.ZCODE_DATA_DIR ?? path.join(os.homedir(), '.zcode-server');
}

export function loadOrCreateConfig(dataDir = defaultDataDir()): ServerConfig {
  fs.mkdirSync(dataDir, { recursive: true });
  // 静态分发目录(/download/*):放 APK 等给手机直接下载的文件,免鉴权
  const publicDir = process.env.ZCODE_PUBLIC_DIR ?? path.join(dataDir, 'public');
  fs.mkdirSync(publicDir, { recursive: true });
  const file = path.join(dataDir, 'config.json');
  let stored: { token?: string } = {};
  try {
    stored = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    // 首次运行,文件不存在
  }
  // token 不再兜底 '123456':0.0.0.0 + 弱令牌 = 局域网内任何设备可驱动 CLI 执行任意命令。
  // 首启随机生成;发现遗留弱令牌一次性升级。env 显式指定永远最优先(自部署覆盖)。
  const legacy = stored.token === '123456';
  const token = process.env.ZCODE_TOKEN ?? (stored.token && !legacy ? stored.token : randomBytes(18).toString('base64url'));
  if (stored.token !== token) {
    fs.writeFileSync(file, JSON.stringify({ token }, null, 2));
  }
  return {
    token,
    port: Number(process.env.ZCODE_PORT) || 5190,
    dataDir,
    routesPath: process.env.ZCODE_CLAUDE_ROUTES_PATH
      ?? path.join(os.homedir(), 'litellm', 'claude-routes.json'),
    publicDir,
    bgCeilingMs: Number(process.env.ZCODE_BG_CEILING_MS) || 30 * 60 * 1000,
    approvalTimeoutMs: Number(process.env.ZCODE_APPROVAL_TIMEOUT_MS) || 10 * 60 * 1000,
  };
}
