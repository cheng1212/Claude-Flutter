// 项目文件夹:默认总目录(~/zcode-projects)下的子文件夹 = 项目。
// 手机端新建会话/移动会话从这里选择,也可现场新建;名字白名单清洗防路径穿越。
import fs from 'node:fs';
import path from 'node:path';

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
