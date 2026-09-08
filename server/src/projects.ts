// 项目文件夹:默认总目录(~/zcode-projects)下的子文件夹 = 项目。
// 手机端新建会话/移动会话从这里选择,也可现场新建;名字白名单清洗防路径穿越。
import fs from 'node:fs';
import path from 'node:path';
import type { Db } from './db.js';

// Windows 保留设备名:做目录名会在资源管理器/部分程序里出鬼
const WINDOWS_RESERVED = new Set([
  'con', 'prn', 'aux', 'nul',
  ...Array.from({ length: 9 }, (_, i) => `com${i + 1}`),
  ...Array.from({ length: 9 }, (_, i) => `lpt${i + 1}`),
]);

/** 项目名清洗:空/超长/含路径非法字符(含 .. 穿越)/Windows 保留名 → null。 */
export function sanitizeProjectName(raw: string): string | null {
  const name = String(raw ?? '').trim();
  if (!name || name.length > 64) return null;
  if (/[\\/:*?"<>|]/.test(name) || name.includes('..')) return null;
  if (WINDOWS_RESERVED.has(name.toLowerCase())) return null;
  return name;
}

/** 总目录下的项目列表(只列子目录,按名字排序);目录不存在 → 空。 */
export function listProjects(root: string): { name: string }[] {
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return [];
  }
  return entries
    .filter((e) => e.isDirectory())
    .map((e) => ({ name: e.name }))
    .sort((a, b) => a.name.localeCompare(b.name));
}

/** 新建项目文件夹;名字非法/建目录失败 → ok:false。已存在视为成功(幂等)。 */
export function createProject(root: string, rawName: string): { ok: boolean; name: string } {
  const name = sanitizeProjectName(rawName);
  if (!name) return { ok: false, name: String(rawName ?? '') };
  try {
    fs.mkdirSync(path.join(root, name), { recursive: true });
  } catch {
    return { ok: false, name };
  }
  return { ok: true, name };
}

/** 重命名项目文件夹;原名不存在/新名已存在/名字非法 → ok:false+error。同名幂等成功。 */
export function renameProject(root: string, rawOld: string, rawNew: string): { ok: boolean; name: string; error?: string } {
  const oldName = sanitizeProjectName(rawOld);
  const name = sanitizeProjectName(rawNew);
  if (!oldName || !name) return { ok: false, name: String(rawNew ?? ''), error: '项目名非法' };
  if (oldName === name) return { ok: true, name };
  const from = path.join(root, oldName);
  const to = path.join(root, name);
  try {
    if (!fs.existsSync(from)) return { ok: false, name, error: '项目不存在' };
    if (fs.existsSync(to)) return { ok: false, name, error: '新项目名已存在' };
    fs.renameSync(from, to);
  } catch {
    return { ok: false, name, error: '重命名失败(文件夹可能被占用)' };
  }
  return { ok: true, name };
}

/** 删除项目文件夹(递归,含其中文件);目录不存在视为成功(幂等)。 */
export function deleteProjectDir(root: string, rawName: string): { ok: boolean; error?: string } {
  const name = sanitizeProjectName(rawName);
  if (!name) return { ok: false, error: '项目名非法' };
  try {
    fs.rmSync(path.join(root, name), { recursive: true, force: true });
  } catch {
    return { ok: false, error: '删除失败(文件夹可能被占用)' };
  }
  return { ok: true };
}

/** 项目下(cwd 恰为该项目目录)的会话 id;子目录/无关同名项目不算。 */
export function projectSessionIds(db: Db, root: string, rawName: string): string[] {
  const name = sanitizeProjectName(rawName);
  if (!name) return [];
  const cwd = path.normalize(path.join(root, name));
  const rows = db.prepare('SELECT id, cwd FROM sessions').all() as { id: string; cwd: string | null }[];
  return rows.filter((r) => r.cwd != null && path.normalize(r.cwd) === cwd).map((r) => r.id);
}

/** 项目重命名后,把 cwd 恰为旧项目目录的会话迁到新目录;返回迁移数。 */
export function renameProjectSessions(db: Db, root: string, rawOld: string, rawNew: string): number {
  const oldName = sanitizeProjectName(rawOld);
  const newName = sanitizeProjectName(rawNew);
  if (!oldName || !newName) return 0;
  const from = path.normalize(path.join(root, oldName));
  const to = path.join(root, newName);
  const rows = db.prepare('SELECT id, cwd FROM sessions').all() as { id: string; cwd: string | null }[];
  let moved = 0;
  for (const r of rows) {
    if (r.cwd != null && path.normalize(r.cwd) === from) {
      db.prepare('UPDATE sessions SET cwd=? WHERE id=?').run(to, r.id);
      moved++;
    }
  }
  return moved;
}
