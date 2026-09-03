import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

// raw spawn 不跟 .cmd wrapper:把 "claude" 解析成真 exe(Windows)。
export function resolveClaudeExecutable(configured?: string): string {
  const value = (configured ?? process.env.CLAUDE_CLI_PATH ?? 'claude').trim().replace(/^["']|["']$/g, '');
  if (process.platform !== 'win32') return value;
  if (/\.(exe|cjs|js|mjs)$/i.test(value) && (value.includes('/') || value.includes('\\'))) return value;
  try {
    const out = execFileSync('where.exe', [value], {
      encoding: 'utf8', windowsHide: true, stdio: ['ignore', 'pipe', 'ignore'],
    });
    const candidates = out.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
    const exe = candidates.find((c) => c.toLowerCase().endsWith('.exe'));
    if (exe) return exe;
    // npm wrapper(.cmd):读内容找 claude.exe 真身
    for (const candidate of candidates) {
      try {
        const content = fs.readFileSync(candidate, 'utf8');
        const match = [...content.matchAll(/["']([^"'\r\n]*claude\.exe)["']/gi)][0];
        if (match) {
          const target = match[1].replace(/^(%~dp0|%dp0%|\$basedir)[\\/]/i, '');
          const resolved = path.isAbsolute(target) ? target : path.resolve(path.dirname(candidate), target);
          if (fs.existsSync(resolved)) return resolved;
        }
      } catch {
        // 不是 wrapper,跳过
      }
    }
  } catch {
    // where 失败,交由 SDK 报错
  }
  return value;
}
