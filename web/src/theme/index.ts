/**
 * 主题控制器(React 版) —— 对应 app/lib/theme.dart 的 ZThemeController。
 *
 * Dart 版用 ValueNotifier + SharedPreferences;这里用模块级状态 +
 * useSyncExternalStore,数据(PALETTES/applyPalette)全部来自 palettes.ts。
 */
import { useSyncExternalStore } from 'react';
import { applyPalette, DEFAULT_THEME_ID, paletteOf, PALETTES, type ZPalette } from './palettes';

const STORAGE_KEY = 'zcode.theme';

function initialId(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved && PALETTES.some((p) => p.id === saved)) return saved;
  } catch {
    /* 隐私模式等场景 localStorage 不可用,静默回退默认 */
  }
  // 用户没手动选过:跟随系统,深色偏好给磷光终端(唯一的深色主题)
  try {
    if (typeof matchMedia !== 'undefined' && matchMedia('(prefers-color-scheme: dark)').matches) return 'phosphor';
  } catch {
    /* matchMedia 不可用时回退默认 */
  }
  return DEFAULT_THEME_ID;
}

let currentId = initialId();
const subs = new Set<() => void>();

function snapshot(): ZPalette {
  return paletteOf(currentId);
}

/** 启动时把持久化主题写进 :root CSS 变量;main.tsx 在挂载前调用一次。 */
export function initTheme(): void {
  applyPalette(snapshot());
}

/** 切换主题:写 CSS 变量 + 持久化 + 通知订阅组件。 */
export function setTheme(id: string): void {
  if (!PALETTES.some((p) => p.id === id)) return;
  currentId = id;
  try {
    localStorage.setItem(STORAGE_KEY, id);
  } catch {
    /* 写不进就只切不存 */
  }
  applyPalette(paletteOf(id));
  subs.forEach((cb) => cb());
}

/** React 侧读当前调色板(切换时触发重渲染)。 */
export function useTheme(): ZPalette {
  return useSyncExternalStore(
    (cb) => {
      subs.add(cb);
      return () => subs.delete(cb);
    },
    snapshot,
  );
}

export { PALETTES };
