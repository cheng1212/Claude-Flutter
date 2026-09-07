// 项目文件夹管理:默认总目录(~/zcode-projects)下的子文件夹 = 项目。
// 手机端新建会话/移动会话时从这里选择,也可新建;名字做白名单清洗防路径穿越。
import { beforeEach, describe, expect, it } from 'vitest';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

let root = '';

beforeEach(() => {
  root = fs.mkdtempSync(path.join(os.tmpdir(), 'zcode-projects-'));
});

describe('项目文件夹', () => {
  it('createProject:清洗名字并建目录;非法名拒绝', async () => {
    const { createProject } = await import('../src/projects.js');
    expect(createProject(root, ' 商城后端 ').name).toBe('商城后端');
    expect(fs.existsSync(path.join(root, '商城后端'))).toBe(true);
    expect(createProject(root, 'a/../b').ok).toBe(false);
    expect(createProject(root, '').ok).toBe(false);
    expect(createProject(root, 'con').ok).toBe(false); // Windows 保留名
    expect(fs.readdirSync(root).sort()).toEqual(['商城后端']);
  });

  it('listProjects:只列子目录,按名字排序', async () => {
    const { listProjects, createProject } = await import('../src/projects.js');
    createProject(root, 'b-项目');
    createProject(root, 'a-项目');
    fs.writeFileSync(path.join(root, 'loose-file.txt'), 'x');
    const rows = listProjects(root);
    expect(rows.map((r) => r.name)).toEqual(['a-项目', 'b-项目']);
    expect(listProjects(path.join(root, '不存在'))).toEqual([]);
  });
});
