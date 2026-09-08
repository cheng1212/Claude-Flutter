import { mkdtempSync, mkdirSync, existsSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { describe, expect, it, afterEach } from 'vitest';
import { createProject, renameProject, deleteProjectDir, projectSessionIds, renameProjectSessions } from '../src/projects.js';
import { openDb, createSession, listSessions } from '../src/db.js';

describe('projects · 重命名/删除', () => {
  let root = '';
  afterEach(() => { if (root) rmSync(root, { recursive: true, force: true }); });

  it('renameProject 改名成功:旧目录消失,内容原样在新目录', () => {
    root = mkdtempSync(path.join(tmpdir(), 'zcode-projects-'));
    createProject(root, 'a');
    writeFileSync(path.join(root, 'a', 'f.txt'), 'x');
    const r = renameProject(root, 'a', 'b');
    expect(r.ok).toBe(true);
    expect(r.name).toBe('b');
    expect(existsSync(path.join(root, 'b', 'f.txt'))).toBe(true);
    expect(existsSync(path.join(root, 'a'))).toBe(false);
  });

  it('改名守门:同名幂等 / 新名已存在 / 原名不存在 / 非法名 全部拒绝', () => {
    root = mkdtempSync(path.join(tmpdir(), 'zcode-projects-'));
    createProject(root, 'a');
    createProject(root, 'b');
    expect(renameProject(root, 'a', 'a').ok).toBe(true);
    expect(renameProject(root, 'a', 'b').ok).toBe(false);
    expect(renameProject(root, 'nope', 'c').ok).toBe(false);
    expect(renameProject(root, 'a', '../evil').ok).toBe(false);
    expect(renameProject(root, 'a', 'a/b').ok).toBe(false);
  });

  it('deleteProjectDir 递归删除;不存在的项目幂等成功', () => {
    root = mkdtempSync(path.join(tmpdir(), 'zcode-projects-'));
    createProject(root, 'a');
    mkdirSync(path.join(root, 'a', 'sub'), { recursive: true });
    writeFileSync(path.join(root, 'a', 'sub', 'f.txt'), 'x');
    expect(deleteProjectDir(root, 'a').ok).toBe(true);
    expect(existsSync(path.join(root, 'a'))).toBe(false);
    expect(deleteProjectDir(root, 'ghost').ok).toBe(true);
  });

  it('projectSessionIds 只认 cwd 恰为项目目录的会话,子目录/无关会话不算', () => {
    root = mkdtempSync(path.join(tmpdir(), 'zcode-projects-'));
    createProject(root, 'a');
    const db = openDb(':memory:');
    createSession(db, { title: 'in', cwd: path.join(root, 'a') });
    createSession(db, { title: 'sub', cwd: path.join(root, 'a', 'sub') });
    createSession(db, { title: 'other', cwd: path.join(root, 'zzz') });
    const ids = projectSessionIds(db, root, 'a');
    expect(ids.length).toBe(1);
    expect(listSessions(db).find((s) => s.title === 'in')?.id).toBe(ids[0]);
  });

  it('renameProjectSessions 只迁移 cwd 恰为旧项目目录的会话,项目字段随 cwd 自动变', () => {
    root = mkdtempSync(path.join(tmpdir(), 'zcode-projects-'));
    createProject(root, 'a');
    const db = openDb(':memory:');
    createSession(db, { title: 'in', cwd: path.join(root, 'a') });
    createSession(db, { title: 'sub', cwd: path.join(root, 'a', 'sub') });
    expect(renameProjectSessions(db, root, 'a', 'b')).toBe(1);
    const rows = listSessions(db);
    expect(rows.find((s) => s.title === 'in')?.cwd).toBe(path.join(root, 'b'));
    expect(rows.find((s) => s.title === 'sub')?.cwd).toBe(path.join(root, 'a', 'sub'));
    expect(rows.find((s) => s.title === 'in')?.project).toBe('b');
  });
});
