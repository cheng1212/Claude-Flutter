import { randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export type ServerConfig = {
  token: string;
  port: number;
  dataDir: string;
  routesPath: string;
  bgCeilingMs: number;
  approvalTimeoutMs: number;
};

export function defaultDataDir(): string {
  return process.env.ZCODE_DATA_DIR ?? path.join(os.homedir(), '.zcode-server');
}

export function loadOrCreateConfig(dataDir = defaultDataDir()): ServerConfig {
  fs.mkdirSync(dataDir, { recursive: true });
  const file = path.join(dataDir, 'config.json');
  let stored: { token?: string } = {};
  try {
    stored = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    // 首次运行,文件不存在
  }
  const token = process.env.ZCODE_TOKEN ?? stored.token ?? randomUUID();
  if (stored.token !== token) {
    fs.writeFileSync(file, JSON.stringify({ token }, null, 2));
  }
  return {
    token,
    port: Number(process.env.ZCODE_PORT) || 5190,
    dataDir,
    routesPath: process.env.ZCODE_CLAUDE_ROUTES_PATH
      ?? path.join(os.homedir(), 'litellm', 'claude-routes.json'),
    bgCeilingMs: Number(process.env.ZCODE_BG_CEILING_MS) || 30 * 60 * 1000,
    approvalTimeoutMs: Number(process.env.ZCODE_APPROVAL_TIMEOUT_MS) || 10 * 60 * 1000,
  };
}
