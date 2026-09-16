/**
 * 设计 token —— 从 app/lib/theme.dart 一比一移植。
 *
 * 原文件里 ZPalette 是一组 const 调色板、ZT 是委托门面;这里保持同样分层:
 *   PALETTES(数据) → applyPalette() 写进 :root 的 CSS 变量 → CSS 通过 var(--z-*) 读。
 * 这样「换主题 = 换一个调色板」的架构在 Web 侧同样成立,组件里不出现散落的色值。
 */

/** 全部设计 token 的形状(与 Dart 版 ZPalette 字段一一对应)。 */
export interface ZPalette {
  /** 主题标识,同时作为 <html data-ztheme> 的值 */
  id: string;
  /** 中文名,选择器里展示 */
  label: string;
  /** 一句话描述设计方向 */
  blurb: string;

  bg: string; // 页面底
  surface: string; // 卡片
  surfaceHi: string; // 高亮面板
  ink: string; // 主文字
  inkSoft: string; // 次级文字
  inkFaint: string; // 暗文字
  line: string; // 发丝线
  edge: string; // 默认描边
  primary: string; // 主色
  primaryDeep: string; // 深主色(浅底上可读);暗色主题里是"亮主色"(暗底上可读)
  aqua: string; // 青(工具/信息/完成)
  lemon: string; // 黄(等待/警示)
  rose: string; // 红(错误)
  grape: string; // 紫(思考)
  onInk: string; // 主色/墨色填充上的文字
  /** 是否深色主题:驱动 color-scheme 与系统偏好回退 */
  isDark: boolean;

  radius: number; // 全局圆角
  /** true = 墨线硬阴影(blur 0, neo-brutalist);false = 柔影 */
  neoShadow: boolean;
  borderWidth: number; // 默认描边宽度
  cardBorderWidth: number; // 列表卡描边
  bgDot: string | null; // 页面底圆点纹理色;null = 纯平底色
  bgDotStep: number; // 圆点纹理网格步长(逻辑像素)

  /** --- 以下为 Web 侧补充的排版/氛围字段(原 Dart 版由 TextStyle 硬编码) --- */
  /** 显示字体栈(标题/大字号) */
  fontDisplay: string;
  /** 正文字体栈 */
  fontBody: string;
  /** 等宽字体栈 */
  fontMono: string;
  /** 底纹氛围:CSS background-image 片段,与 bg 叠加 */
  atmosphere: string;
  /** 卡片阴影(随 neoShadow 决定是硬影还是柔影) */
  cardShadow: string;
  /** 三档浮起阴影 + 警示阴影:组件一律用 token,不写死偏移色块(深色主题下实色偏移块极丑) */
  shadowSm: string;
  shadowMd: string;
  shadowLg: string;
  shadowWarn: string;
}

/** 亮色:柑橘晨光 Citrus Morning —— 奶油底 + 蜜橘主色 + 墨线硬阴影 neo-brutalist。 */
export const kZCitrus: ZPalette = {
  id: 'citrus',
  label: '柑橘晨光',
  blurb: '墨线粗框 + 纯墨硬阴影,状态色当贴纸用。',
  bg: '#FFF6E9',
  surface: '#FFFCF5',
  surfaceHi: '#FFF3DE',
  ink: '#241C15',
  inkSoft: '#5C5044',
  inkFaint: '#7A6853',
  line: '#E8DCC8',
  edge: '#241C15',
  primary: '#FF6B1A',
  primaryDeep: '#E05500',
  aqua: '#0FB5A3',
  lemon: '#FFC93C',
  rose: '#E5484D',
  grape: '#7C5CFF',
  onInk: '#FFF6E9',
  isDark: false,
  radius: 14,
  neoShadow: true,
  borderWidth: 1.6,
  cardBorderWidth: 1.6,
  bgDot: null,
  bgDotStep: 16,
  fontDisplay: "'Outfit', 'PingFang SC', system-ui, sans-serif",
  fontBody: "'Outfit', 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif",
  fontMono: "'JetBrains Mono', ui-monospace, Consolas, monospace",
  atmosphere: 'radial-gradient(130% 90% at 0% -20%, rgba(255,107,26,0.10), transparent 62%)',
  cardShadow: '4px 4px 0 0 var(--z-ink)',
  shadowSm: '3px 3px 0 0 var(--z-ink)',
  shadowMd: '5px 5px 0 0 var(--z-ink)',
  shadowLg: '8px 8px 0 0 var(--z-ink)',
  shadowWarn: '5px 5px 0 0 var(--z-lemon)',
};

/**
 * 暗色:经典暗色 Graphite —— 业界通行的中性暗色方案(shadcn/ui 默认暗色、GitHub Dark、
 * VS Code Dark+ 的共识):纯中性灰阶、近黑不纯黑的底、一级更亮的卡片、1px 细边、
 * 近白文字、灰色次级文字,点缀品牌橘。不带任何色相偏色。
 */
export const kZGraphite: ZPalette = {
  id: 'graphite',
  label: '经典暗色',
  blurb: '中性灰阶 + 品牌橘,shadcn/GitHub 式的普通暗色。',
  bg: '#09090b',
  surface: '#18181b',
  surfaceHi: '#27272a',
  ink: '#fafafa',
  inkSoft: '#a1a1aa',
  inkFaint: '#71717a',
  line: '#27272a',
  edge: '#3f3f46',
  primary: '#FF6B1A',
  primaryDeep: '#FF8A3D',
  aqua: '#2dd4bf',
  lemon: '#fbbf24',
  rose: '#f87171',
  grape: '#a78bfa',
  onInk: '#fafafa',
  isDark: true,
  radius: 10,
  neoShadow: false,
  borderWidth: 1,
  cardBorderWidth: 1,
  bgDot: null,
  bgDotStep: 16,
  fontDisplay: "'Outfit', 'PingFang SC', system-ui, sans-serif",
  fontBody: "'Outfit', 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif",
  fontMono: "'JetBrains Mono', ui-monospace, Consolas, monospace",
  atmosphere: 'radial-gradient(120% 60% at 50% -10%, rgba(255,255,255,0.045), transparent 60%)',
  cardShadow: '0 1px 2px rgba(0,0,0,0.5), 0 8px 24px -12px rgba(0,0,0,0.5)',
  shadowSm: '0 1px 2px rgba(0,0,0,0.4), 0 2px 8px -4px rgba(0,0,0,0.45)',
  shadowMd: '0 2px 6px -2px rgba(0,0,0,0.45), 0 10px 24px -12px rgba(0,0,0,0.55)',
  shadowLg: '0 4px 12px -4px rgba(0,0,0,0.5), 0 20px 44px -16px rgba(0,0,0,0.6)',
  shadowWarn: '0 0 0 1px rgba(251,191,36,0.4), 0 8px 24px -10px rgba(251,191,36,0.25)',
};

/** 全部可选主题(亮/暗各一;顺序即初始回退优先级)。 */
export const PALETTES: ZPalette[] = [
  kZCitrus,
  kZGraphite,
];

export const DEFAULT_THEME_ID = 'citrus';

export function paletteOf(id: string): ZPalette {
  return PALETTES.find((p) => p.id === id) ?? kZCitrus;
}

/**
 * 把调色板写进 :root 的 CSS 变量 —— 对应 Dart 版 `ZT._palette = paletteOf(t)`。
 * 所有组件只读 `var(--z-*)`,因此换主题不需要重建任何组件。
 */
export function applyPalette(p: ZPalette): void {
  const root = document.documentElement;
  const map: Record<string, string> = {
    bg: p.bg,
    surface: p.surface,
    'surface-hi': p.surfaceHi,
    ink: p.ink,
    'ink-soft': p.inkSoft,
    'ink-faint': p.inkFaint,
    line: p.line,
    edge: p.edge,
    primary: p.primary,
    'primary-deep': p.primaryDeep,
    aqua: p.aqua,
    lemon: p.lemon,
    rose: p.rose,
    grape: p.grape,
    'on-ink': p.onInk,
    radius: `${p.radius}px`,
    'border-w': `${p.borderWidth}px`,
    'card-border-w': `${p.cardBorderWidth}px`,
    'bg-dot-step': `${p.bgDotStep}px`,
    'font-display': p.fontDisplay,
    'font-body': p.fontBody,
    'font-mono': p.fontMono,
    atmosphere: p.atmosphere,
    'card-shadow': p.cardShadow,
    'shadow-sm': p.shadowSm,
    'shadow-md': p.shadowMd,
    'shadow-lg': p.shadowLg,
    'shadow-warn': p.shadowWarn,
  };
  for (const [k, v] of Object.entries(map)) root.style.setProperty(`--z-${k}`, v);
  root.dataset.ztheme = p.id;
  // bgDot 为空时不设变量,CSS 侧以 --z-bg-dot 未定义判定「无纹理」
  if (p.bgDot) root.style.setProperty('--z-bg-dot', p.bgDot);
  else root.style.removeProperty('--z-bg-dot');
  root.style.colorScheme = p.isDark ? 'dark' : 'light';
  // 移动端浏览器地址栏/状态栏跟随主题底色
  const themeColor = document.querySelector('meta[name="theme-color"]');
  if (themeColor) themeColor.setAttribute('content', p.bg);
}
