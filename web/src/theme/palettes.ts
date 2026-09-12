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
  primaryDeep: string; // 深主色(浅底上可读)
  aqua: string; // 青(工具/信息/完成)
  lemon: string; // 黄(等待/警示)
  rose: string; // 红(错误)
  grape: string; // 紫(思考)
  onInk: string; // 主色/墨色填充上的文字

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
}

/** 原版:明快奶油 Framer 风 —— 奶油底 + 焦糖橙主色 + 暖棕文字,干净无辉光。 */
export const kZCream: ZPalette = {
  id: 'cream',
  label: '原版奶油',
  blurb: '奶油底 + 焦糖橙,Framer 风的干净留白,柔和双层阴影。',
  bg: '#FAF6EF',
  surface: '#FFFFFF',
  surfaceHi: '#FFF8F0',
  ink: '#2B2118',
  inkSoft: '#8A8275',
  inkFaint: '#B9B1A4',
  line: '#EDE5D8',
  edge: '#E2D7C6',
  primary: '#E8590C',
  primaryDeep: '#C74405',
  aqua: '#4C8A7E',
  lemon: '#E9A13B',
  rose: '#D65745',
  grape: '#9B6FC9',
  onInk: '#FFFFFF',
  radius: 12,
  neoShadow: false,
  borderWidth: 1.3,
  cardBorderWidth: 0,
  bgDot: null,
  bgDotStep: 16,
  fontDisplay: "'Fraunces', 'Songti SC', Georgia, serif",
  fontBody: "'Outfit', 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif",
  fontMono: "'JetBrains Mono', ui-monospace, 'Cascadia Code', Consolas, monospace",
  atmosphere:
    'radial-gradient(120% 80% at 12% -10%, rgba(232,89,12,0.07), transparent 60%),' +
    'radial-gradient(90% 60% at 100% 0%, rgba(233,161,59,0.06), transparent 55%)',
  cardShadow: '0 14px 28px -18px rgba(232,89,12,0.30), 0 4px 10px -6px rgba(232,89,12,0.16)',
};

/** 柑橘晨光 Citrus Morning —— 奶油底 + 蜜橘主色 + 墨线硬阴影 neo-brutalist。 */
export const kZCitrus: ZPalette = {
  id: 'citrus',
  label: '柑橘晨光',
  blurb: '移植 app 现役主题:墨线粗框 + 纯墨硬阴影,状态色当贴纸用。',
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
};

/** 墨线贴纸 Sticker —— 柑橘系的「加大号」:底色更深 + 圆点纹理,墨线 2px、圆角 16。 */
export const kZSticker: ZPalette = {
  id: 'sticker',
  label: '墨线贴纸',
  blurb: '柑橘加大号:更深的底 + 圆点纹理,2px 墨线 16 圆角,色块像贴纸。',
  bg: '#FFE9CC',
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
  radius: 16,
  neoShadow: true,
  borderWidth: 2.0,
  cardBorderWidth: 2.0,
  bgDot: '#E8B98A',
  bgDotStep: 16,
  fontDisplay: "'Outfit', 'PingFang SC', system-ui, sans-serif",
  fontBody: "'Outfit', 'PingFang SC', 'Microsoft YaHei', system-ui, sans-serif",
  fontMono: "'JetBrains Mono', ui-monospace, Consolas, monospace",
  atmosphere:
    'radial-gradient(#E8B98A 1.1px, transparent 1.1px)',
  cardShadow: '5px 5px 0 0 var(--z-ink)',
};

/* ------------------------------------------------------------------ 新增风格 */

/**
 * 终端磷光 Terminal Phosphor —— 反相深色:把「遥控 CLI」这件事的语义直接
 * 翻成视觉,磷绿 + 扫描线,讨好长时间盯屏的开发者。与 app 的三套浅色形成对照。
 */
export const kZPhosphor: ZPalette = {
  id: 'phosphor',
  label: '磷光终端',
  blurb: '深色磷绿 + 扫描线,把「遥控 CLI」的语义直接做成界面。',
  bg: '#08110D',
  surface: '#0E1A14',
  surfaceHi: '#12241A',
  ink: '#D8FFE6',
  inkSoft: '#7FB894',
  inkFaint: '#4E7A60',
  line: '#1C3327',
  edge: '#3BE08A',
  primary: '#3BE08A',
  primaryDeep: '#22B26A',
  aqua: '#4FE3D0',
  lemon: '#F2D24B',
  rose: '#FF6B7A',
  grape: '#B58CFF',
  onInk: '#05100B',
  radius: 6,
  neoShadow: false,
  borderWidth: 1.2,
  cardBorderWidth: 1.2,
  bgDot: null,
  bgDotStep: 16,
  fontDisplay: "'JetBrains Mono', ui-monospace, Consolas, monospace",
  fontBody: "'JetBrains Mono', ui-monospace, Consolas, monospace",
  fontMono: "'JetBrains Mono', ui-monospace, Consolas, monospace",
  atmosphere:
    'repeating-linear-gradient(0deg, rgba(59,224,138,0.045) 0 1px, transparent 1px 3px),' +
    'radial-gradient(120% 70% at 50% -20%, rgba(59,224,138,0.14), transparent 60%)',
  cardShadow: '0 0 0 1px rgba(59,224,138,0.18), 0 10px 30px -18px rgba(59,224,138,0.55)',
};

/**
 * 编辑部 Editorial —— 杂志排印风:高对比衬线 + 细金线 + 大留白,
 * 把会话列表当版面做,适合长文阅读(agent 的回复本身就是长文)。
 */
export const kZEditorial: ZPalette = {
  id: 'editorial',
  label: '编辑部',
  blurb: '杂志排印:高对比衬线 + 细金线 + 大留白,把长回复当版面读。',
  bg: '#F7F4EE',
  surface: '#FFFDFA',
  surfaceHi: '#F1EBE0',
  ink: '#14110D',
  inkSoft: '#5A5245',
  inkFaint: '#8D8577',
  line: '#DFD7C8',
  edge: '#14110D',
  primary: '#9E2B25',
  primaryDeep: '#7A1F1A',
  aqua: '#2F6B63',
  lemon: '#B8860B',
  rose: '#9E2B25',
  grape: '#584B7A',
  onInk: '#FFFDFA',
  radius: 2,
  neoShadow: false,
  borderWidth: 1,
  cardBorderWidth: 1,
  bgDot: null,
  bgDotStep: 16,
  fontDisplay: "'Fraunces', 'Songti SC', Georgia, serif",
  fontBody: "'Fraunces', 'Songti SC', Georgia, serif",
  fontMono: "'IBM Plex Mono', ui-monospace, Consolas, monospace",
  atmosphere:
    'linear-gradient(180deg, rgba(20,17,13,0.035), transparent 22%),' +
    'linear-gradient(90deg, transparent 49.9%, rgba(20,17,13,0.03) 50%, transparent 50.1%)',
  cardShadow: '0 1px 0 0 var(--z-line), 0 18px 40px -32px rgba(20,17,13,0.45)',
};

/** 全部可选主题(顺序即选择器里的展示顺序)。 */
export const PALETTES: ZPalette[] = [
  kZCitrus,
  kZSticker,
  kZCream,
  kZPhosphor,
  kZEditorial,
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
    'shadow-dx': p.neoShadow ? '4px' : '0px',
    'shadow-dy': p.neoShadow ? '4px' : '0px',
  };
  for (const [k, v] of Object.entries(map)) root.style.setProperty(`--z-${k}`, v);
  root.dataset.ztheme = p.id;
  // bgDot 为空时不设变量,CSS 侧以 --z-bg-dot 未定义判定「无纹理」
  if (p.bgDot) root.style.setProperty('--z-bg-dot', p.bgDot);
  else root.style.removeProperty('--z-bg-dot');
  root.style.colorScheme = p.id === 'phosphor' ? 'dark' : 'light';
}
