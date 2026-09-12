/**
 * 主题控制器 —— 对应 app/lib/theme.dart 的 ZThemeController。
 *
 * Dart 版用 ValueNotifier + SharedPreferences;Web 侧用 Vue 的 ref + localStorage。
 * 对外只暴露:当前 palette(响应式)、setTheme、以及 5 个调色板供选择器渲染缩略图。
 */
import { computed, ref, type ComputedRef } from 'vue';

import { applyPalette, DEFAULT_THEME_ID, paletteOf, PALETTES, type ZPalette } from './palettes';

const STORAGE_KEY = 'zcode.theme';

/** 当前主题 id(响应式)。切换时整树通过 CSS 变量自动跟随。 */
const currentId = ref<string>(DEFAULT_THEME_ID);

/** 存档损坏 / 未知名回退默认主题,与 Dart 版 `?? ZTheme.cream` 同语义。 */
function initialId(): string {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved && PALETTES.some((p) => p.id === saved)) return saved;
  } catch {
    /* 隐私模式等场景 localStorage 不可用,静默回退 */
  }
  return DEFAULT_THEME_ID;
}

/** 当前调色板对象(响应式只读)。 */
export const palette: ComputedRef<ZPalette> = computed(() => paletteOf(currentId.value));

export const paletteList: ZPalette[] = PALETTES;

/** 启动时读回持久化主题。main.ts 里在挂载前调用一次。 */
export function initTheme(): void {
  currentId.value = initialId();
  applyPalette(palette.value);
}

/** 切换主题:写 CSS 变量 + 持久化 + 通知 Vue。 */
export function setTheme(id: string): void {
  currentId.value = id;
  applyPalette(palette.value);
  try {
    localStorage.setItem(STORAGE_KEY, id);
  } catch {
    /* 存不下不影响本次会话生效 */
  }
}

/** 只读出口,给需要判断当前主题的组件用。 */
export const themeId = computed(() => currentId.value);

/**
 * 状态色语义:running=橘 / done=青 / error=玫红 / queued=柠黄 / thinking=葡萄紫。
 * 对应 theme.dart 的 StatusChip 映射表,保证 Web 侧与 app 逐字一致。
 */
export function statusMeta(phase: string): { cssVar: string; label: string } {
  const p = (phase || '').toLowerCase();
  switch (p) {
    case 'running':
    case 'working':
    case 'processing':
      return { cssVar: '--z-primary', label: '运行中' };
    case 'prewarming':
      return { cssVar: '--z-lemon', label: '预热中' };
    case 'queued':
      return { cssVar: '--z-lemon', label: '排队中' };
    case 'waitinginput':
      return { cssVar: '--z-grape', label: '等待输入' };
    case 'waiting':
    case 'permission':
      return { cssVar: '--z-lemon', label: '待确认' };
    case 'reconnecting':
      return { cssVar: '--z-rose', label: '断线' };
    case 'error':
    case 'failed':
      return { cssVar: '--z-rose', label: '异常' };
    case 'done':
    case 'idle':
    case '':
      return { cssVar: '--z-ink-soft', label: '空闲' };
    default:
      return { cssVar: '--z-aqua', label: phase };
  }
}
