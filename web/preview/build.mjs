/**
 * 生成静态预览页 —— 一个主题一个 .html,直接双击用浏览器打开,无需服务器。
 *
 * 之所以用生成脚本而不是手写 5 份:五张页面结构完全相同,只有 token 不同。
 * 集中在一处维护,改结构不会漏掉某个主题。产物提交进仓库(用户要的是「本地静态页面」)。
 *
 *   node preview/build.mjs
 */
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));

/** 调色板:与 src/theme/palettes.ts 逐字一致。 */
const PALETTES = {
  citrus: {
    label: '柑橘晨光',
    blurb: '移植 app 现役主题:墨线粗框 + 纯墨硬阴影,状态色当贴纸用。',
    bg: '#FFF6E9', surface: '#FFFCF5', surfaceHi: '#FFF3DE',
    ink: '#241C15', inkSoft: '#5C5044', inkFaint: '#7A6853',
    line: '#E8DCC8', edge: '#241C15', primary: '#FF6B1A', primaryDeep: '#E05500',
    aqua: '#0FB5A3', lemon: '#FFC93C', rose: '#E5484D', grape: '#7C5CFF', onInk: '#FFF6E9',
    radius: 14, border: 1.6,
    atmos: 'radial-gradient(130% 90% at 0% -20%, rgba(255,107,26,.10), transparent 62%)',
    shadow: '4px 4px 0 0 var(--k-ink)',
    fontDisplay: "var(--sans)", fontBody: "var(--sans)", fontMono: "var(--mono)",
  },
  sticker: {
    label: '墨线贴纸',
    blurb: '柑橘加大号:更深的底 + 圆点纹理,2px 墨线 16 圆角,色块像贴纸。',
    bg: '#FFE9CC', surface: '#FFFCF5', surfaceHi: '#FFF3DE',
    ink: '#241C15', inkSoft: '#5C5044', inkFaint: '#7A6853',
    line: '#E8DCC8', edge: '#241C15', primary: '#FF6B1A', primaryDeep: '#E05500',
    aqua: '#0FB5A3', lemon: '#FFC93C', rose: '#E5484D', grape: '#7C5CFF', onInk: '#FFF6E9',
    radius: 16, border: 2,
    atmos: 'radial-gradient(#E8B98A 1.1px, transparent 1.1px)',
    atmosSize: '16px 16px',
    shadow: '5px 5px 0 0 var(--k-ink)',
    fontDisplay: "var(--sans)", fontBody: "var(--sans)", fontMono: "var(--mono)",
  },
  cream: {
    label: '原版奶油',
    blurb: '奶油底 + 焦糖橙,Framer 风的干净留白,柔和双层阴影、无框软卡。',
    bg: '#FAF6EF', surface: '#FFFFFF', surfaceHi: '#FFF8F0',
    ink: '#2B2118', inkSoft: '#8A8275', inkFaint: '#B9B1A4',
    line: '#EDE5D8', edge: '#E2D7C6', primary: '#E8590C', primaryDeep: '#C74405',
    aqua: '#4C8A7E', lemon: '#E9A13B', rose: '#D65745', grape: '#9B6FC9', onInk: '#FFFFFF',
    radius: 12, border: 1.3,
    atmos:
      'radial-gradient(120% 80% at 12% -10%, rgba(232,89,12,.07), transparent 60%),' +
      'radial-gradient(90% 60% at 100% 0%, rgba(233,161,59,.06), transparent 55%)',
    shadow: '0 14px 28px -18px rgba(232,89,12,.30), 0 4px 10px -6px rgba(232,89,12,.16)',
    fontDisplay: "'Fraunces','Songti SC',Georgia,serif",
    fontBody: "var(--sans)", fontMono: "var(--mono)",
  },
  phosphor: {
    label: '磷光终端',
    blurb: '深色磷绿 + 扫描线,把「遥控 CLI」这件事的语义直接翻成视觉。',
    bg: '#08110D', surface: '#0E1A14', surfaceHi: '#12241A',
    ink: '#D8FFE6', inkSoft: '#7FB894', inkFaint: '#4E7A60',
    line: '#1C3327', edge: '#3BE08A', primary: '#3BE08A', primaryDeep: '#22B26A',
    aqua: '#4FE3D0', lemon: '#F2D24B', rose: '#FF6B7A', grape: '#B58CFF', onInk: '#05100B',
    radius: 6, border: 1.2,
    atmos:
      'repeating-linear-gradient(0deg, rgba(59,224,138,.045) 0 1px, transparent 1px 3px),' +
      'radial-gradient(120% 70% at 50% -20%, rgba(59,224,138,.14), transparent 60%)',
    shadow: '0 0 0 1px rgba(59,224,138,.18), 0 10px 30px -18px rgba(59,224,138,.55)',
    fontDisplay: "var(--mono)", fontBody: "var(--mono)", fontMono: "var(--mono)",
  },
  editorial: {
    label: '编辑部',
    blurb: '杂志排印:高对比衬线 + 细金线 + 大留白,把 agent 的长回复当版面读。',
    bg: '#F7F4EE', surface: '#FFFDFA', surfaceHi: '#F1EBE0',
    ink: '#14110D', inkSoft: '#5A5245', inkFaint: '#8D8577',
    line: '#DFD7C8', edge: '#14110D', primary: '#9E2B25', primaryDeep: '#7A1F1A',
    aqua: '#2F6B63', lemon: '#B8860B', rose: '#9E2B25', grape: '#584B7A', onInk: '#FFFDFA',
    radius: 2, border: 1,
    atmos:
      'linear-gradient(180deg, rgba(20,17,13,.035), transparent 22%),' +
      'linear-gradient(90deg, transparent 49.9%, rgba(20,17,13,.03) 50%, transparent 50.1%)',
    shadow: '0 1px 0 0 var(--k-line), 0 18px 40px -32px rgba(20,17,13,.45)',
    fontDisplay: "'Fraunces','Songti SC',Georgia,serif",
    fontBody: "'Fraunces','Songti SC',Georgia,serif", fontMono: "'IBM Plex Mono',var(--mono)",
  },
};

/** 示例数据:只服务于「看风格」这一目的。 */
const SESSIONS = [
  { title: '重构 auth 中间件', status: 'running', label: '运行中', tone: 'primary', project: 'zremote', model: 'claude-sonnet-4.5', preview: '看一下 server/src/http.ts 的鉴权钩子,顺便把 CORS 收一下', time: '14:02' },
  { title: '排查图片上传内存暴涨', status: 'done', label: '空闲', tone: 'inkSoft', project: 'zremote', model: 'claude-opus-4.1', preview: '1280px 拍照原样解进 GPU 是缩略图的十几倍内存', time: '昨天' },
  { title: '用量统计图表对不上', status: 'waiting', label: '待确认', tone: 'lemon', project: 'billing', model: 'claude-haiku-4', preview: '需要你确认 7d 窗口是从本地零点算还是 UTC', time: '昨天' },
  { title: '给会话列表加批量删除', status: 'error', label: '异常', tone: 'rose', project: 'zremote', model: 'claude-sonnet-4.5', preview: 'batch-delete 接口 500:ids 为空数组时没短路', time: '9月11日' },
  { title: '写一份部署交接文档', status: 'queued', label: '排队中', tone: 'lemon', project: 'docs', model: 'claude-opus-4.1', preview: '把 5190/5191 双端口和令牌生成的步骤都写进去', time: '9月10日' },
];

// 会话卡 + 对话气泡 + 聊天页三屏并排,一屏看清主要界面
const ROW_HTML = SESSIONS.map((s) => `
        <article class="row">
          <div class="row__top">
            <span class="row__title">${s.title}</span>
            <span class="z-pill tone-${s.tone}"><i class="z-pulse"></i>${s.label}</span>
          </div>
          <div class="row__meta">
            <span class="row__proj">${s.project}</span>
            <span class="row__model z-mono">${s.model}</span>
            <span class="row__time">${s.time}</span>
          </div>
          <p class="row__preview">${s.preview}</p>
        </article>`).join('');

const CHAT_HTML = `
        <div class="msg msg--user"><div class="bub bub--user">把网关的 CORS 也一起改掉,顺手补个测试</div></div>
        <div class="msg"><div class="bub bub--asst">
          好,我先读一下现有实现,确认鉴权钩子和 CORS 的注册顺序。
          <pre class="code">app.addHook('onRequest', async (req, reply) => {
  reply.header('Access-Control-Allow-Origin', '*');
});</pre>
          <div class="think">思考中 · 3s<em>这里要注意 CORS 必须先于鉴权钩子注册,否则 OPTIONS 预检会被拦。</em></div>
          <div class="tool">
            <div class="tool__head"><i class="tool__dot"></i><b>Read</b><span>server/src/http.ts</span><span class="tool__ok">✓</span></div>
            <div class="tool__body">1  import Fastify from 'fastify';
2  import { registerHttpRoutes } from './http-routes.js';</div>
          </div>
        </div></div>
        <div class="msg"><div class="bub bub--perm">
          <div class="perm__head">⚠ 需要你确认</div>
          <div class="perm__tool z-mono">Bash · pnpm test</div>
          <div class="perm__acts"><span class="perm__allow">允许</span><span class="perm__deny">拒绝</span></div>
        </div></div>`;

const page = (t) => `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0" />
<title>zCode · ${t.label} · 整页预览</title>
<style>
  :root{
    --k-bg:${t.bg}; --k-surface:${t.surface}; --k-surface-hi:${t.surfaceHi};
    --k-ink:${t.ink}; --k-ink-soft:${t.inkSoft}; --k-ink-faint:${t.inkFaint};
    --k-line:${t.line}; --k-edge:${t.edge}; --k-primary:${t.primary};
    --k-primary-deep:${t.primaryDeep}; --k-aqua:${t.aqua}; --k-lemon:${t.lemon};
    --k-rose:${t.rose}; --k-grape:${t.grape}; --k-on-ink:${t.onInk};
    --k-radius:${t.radius}px; --k-border:${t.border}px;
    --k-shadow:${t.shadow};
    --k-f-display:${t.fontDisplay}; --k-f-body:${t.fontBody}; --k-f-mono:${t.fontMono};
    --sans:'Outfit','PingFang SC','Microsoft YaHei',system-ui,sans-serif;
    --mono:'JetBrains Mono',ui-monospace,Consolas,monospace;
  }
  *{box-sizing:border-box}
  body{
    margin:0;padding:30px 26px 80px;min-height:100vh;
    background-color:var(--k-bg);background-image:${t.atmos};
    ${t.atmosSize ? `background-size:${t.atmosSize};` : ''}
    color:var(--k-ink);font:14px/1.55 var(--k-f-body);
  }
  .top{max-width:1260px;margin:0 auto 26px;display:flex;align-items:center;gap:14px;flex-wrap:wrap}
  .back{padding:7px 13px;border:var(--k-border) solid var(--k-edge);border-radius:99px;
    background:var(--k-surface);color:var(--k-ink-soft);font:700 12px/1 var(--k-f-body);
    text-decoration:none}
  .back:hover{color:var(--k-primary);border-color:var(--k-primary)}
  .ttl{font:800 24px/1.2 var(--k-f-display)}
  .sub{color:var(--k-ink-soft);font-size:12.5px}
  .stage{max-width:1260px;margin:0 auto;display:grid;grid-template-columns:repeat(3,1fr);
    gap:22px;align-items:start}
  @media(max-width:1080px){.stage{grid-template-columns:1fr}}

  .phone{border:var(--k-border) solid var(--k-edge);border-radius:calc(var(--k-radius) + 14px);
    background:var(--k-surface);box-shadow:var(--k-shadow);padding:10px}
  .scr{height:664px;display:flex;flex-direction:column;overflow:hidden;border-radius:var(--k-radius);
    background-color:var(--k-bg);background-image:${t.atmos};
    ${t.atmosSize ? `background-size:${t.atmosSize};` : ''}}
  .bar{display:flex;align-items:center;justify-content:space-between;padding:13px 14px 7px}
  .bar b{font:900 21px/1 var(--k-f-display);letter-spacing:-.4px}
  .bar i{color:var(--k-ink-soft);font-style:normal;font-size:16px;letter-spacing:9px}
  .pad{padding:0 14px}
  .chips{display:flex;gap:7px;flex-wrap:wrap;padding:10px 14px 4px}
  .chip{padding:4px 10px;border:1.2px solid var(--k-edge);border-radius:99px;background:var(--k-surface);
    color:var(--k-ink-soft);font-size:11.5px;font-weight:700}
  .chip--on{background:var(--k-primary);border-color:var(--k-ink);color:var(--k-on-ink)}
  .list{flex:1;overflow-y:auto;display:flex;flex-direction:column;gap:9px;padding:10px 14px 14px}
  .nav{display:flex;border-top:1px solid var(--k-line);background:var(--k-surface)}
  .nav span{flex:1;padding:12px 0;text-align:center;color:var(--k-ink-faint);
    font-size:11.5px;font-weight:700}
  .nav .on{color:var(--k-primary)}

  .row{padding:11px 12px;background:var(--k-surface);border:var(--k-border) solid var(--k-edge);
    border-radius:var(--k-radius);box-shadow:var(--k-shadow)}
  .row__top{display:flex;align-items:center;justify-content:space-between;gap:8px}
  .row__title{font-size:14px;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .row__meta{display:flex;align-items:center;gap:6px;margin-top:5px;color:var(--k-ink-faint);font-size:10.5px}
  .row__proj{padding:1px 6px;border:1px solid var(--k-line);border-radius:5px;
    background:var(--k-surface-hi);color:var(--k-ink-soft);font-weight:700}
  .row__time{margin-left:auto}
  .row__preview{margin:7px 0 0;color:var(--k-ink-soft);font-size:11.5px;line-height:1.5;
    display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}

  .z-pill{display:inline-flex;align-items:center;gap:5px;flex:none;padding:3px 9px;border-radius:99px;
    border:1.2px solid currentColor;background:var(--k-surface);font-size:11.5px;font-weight:700;line-height:1}
  .z-pulse{width:7px;height:7px;border-radius:50%;background:currentColor;
    border:1px solid color-mix(in srgb,var(--k-ink) 45%,transparent)}
  .tone-primary{color:var(--k-primary)} .tone-inkSoft{color:var(--k-ink-soft)}
  .tone-lemon{color:var(--k-lemon)} .tone-rose{color:var(--k-rose)}
  .z-mono{font-family:var(--k-f-mono)}

  /* 对话页 */
  .chat{flex:1;overflow-y:auto;display:flex;flex-direction:column;gap:11px;padding:12px 14px}
  .msg{display:flex}
  .msg--user{justify-content:flex-end}
  .bub{max-width:88%;padding:9px 12px;border:var(--k-border) solid var(--k-edge);
    border-radius:var(--k-radius);font-size:12.5px;box-shadow:var(--k-shadow)}
  .bub--user{background:var(--k-primary);color:var(--k-on-ink)}
  .bub--asst{background:var(--k-surface);box-shadow:0 2px 12px -8px rgba(0,0,0,.4)}
  .code{margin:8px 0 0;padding:8px 10px;border-radius:calc(var(--k-radius) - 4px);
    background:var(--k-surface-hi);border:1px solid var(--k-line);color:var(--k-primary-deep);
    font:11px/1.6 var(--k-f-mono);overflow-x:auto}
  .think{margin-top:8px;padding:7px 9px;border-left:3px solid var(--k-grape);
    border-radius:4px;background:color-mix(in srgb,var(--k-grape) 9%,transparent);
    color:var(--k-ink-soft);font-size:11px}
  .think em{display:block;margin-top:3px;font-style:normal;color:var(--k-ink-faint)}
  .tool{margin-top:8px;border:1px solid var(--k-line);border-radius:calc(var(--k-radius) - 3px);
    overflow:hidden;background:var(--k-surface-hi)}
  .tool__head{display:flex;align-items:center;gap:7px;padding:6px 9px;font-size:11.5px;
    border-bottom:1px solid var(--k-line)}
  .tool__head b{color:var(--k-aqua);font-family:var(--k-f-mono)}
  .tool__head span{color:var(--k-ink-faint);font-family:var(--k-f-mono);font-size:10.5px;
    white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .tool__ok{margin-left:auto;color:var(--k-aqua)}
  .tool__dot{width:6px;height:6px;border-radius:50%;background:var(--k-aqua);flex:none}
  .tool__body{padding:7px 9px;font:10.5px/1.6 var(--k-f-mono);color:var(--k-ink-soft);
    white-space:pre;overflow-x:auto}
  .bub--perm{border-color:var(--k-lemon);background:color-mix(in srgb,var(--k-lemon) 12%,var(--k-surface))}
  .perm__head{font-weight:800;color:var(--k-lemon);font-size:12px}
  .perm__tool{margin-top:5px;font-size:11px;color:var(--k-ink-soft)}
  .perm__acts{display:flex;gap:8px;margin-top:9px}
  .perm__allow,.perm__deny{padding:4px 12px;border-radius:99px;font-size:11.5px;font-weight:800}
  .perm__allow{background:var(--k-primary);color:var(--k-on-ink);border:1.2px solid var(--k-ink)}
  .perm__deny{border:1.2px solid var(--k-edge);color:var(--k-ink-soft)}
  .composer{display:flex;gap:8px;align-items:center;padding:10px 14px;
    border-top:1px solid var(--k-line);background:var(--k-surface)}
  .composer .inp{flex:1;padding:9px 12px;border:var(--k-border) solid var(--k-edge);
    border-radius:99px;background:var(--k-bg);color:var(--k-ink-faint);font-size:12px}
  .composer .send{width:36px;height:36px;border-radius:50%;display:grid;place-items:center;
    background:var(--k-primary);color:var(--k-on-ink);border:1.2px solid var(--k-ink);font-size:15px}
</style>
</head>
<body>
  <div class="top">
    <a class="back" href="index.html">← 回到选择</a>
    <span class="ttl">${t.label}</span>
    <span class="sub">${t.blurb}</span>
  </div>

  <div class="stage">
    <!-- ① 会话列表 -->
    <div class="phone"><div class="scr">
      <div class="bar"><b>会话</b><i>⌕ ⋮</i></div>
      <div class="pad"><div class="z-input" style="padding:9px 12px;border:var(--k-border) solid var(--k-edge);border-radius:var(--k-radius);background:var(--k-surface);color:var(--k-ink-faint);font-size:12.5px">搜索会话标题 / 内容</div></div>
      <div class="chips">
        <span class="chip chip--on">全部</span><span class="chip">已置顶</span>
        <span class="chip">项目</span><span class="chip">已归档</span>
      </div>
      <div class="list">${ROW_HTML}</div>
      <div class="nav"><span class="on">会话</span><span>项目</span><span>我的</span></div>
    </div></div>

    <!-- ② 对话页 -->
    <div class="phone"><div class="scr">
      <div class="bar"><b>重构 auth 中间件</b><i>⋮</i></div>
      <div class="chat">${CHAT_HTML}</div>
      <div class="composer">
        <div class="inp">发消息…</div>
        <div class="send">↑</div>
      </div>
    </div></div>

    <!-- ③ 项目 / 用量 -->
    <div class="phone"><div class="scr">
      <div class="bar"><b>项目</b><i>⋮</i></div>
      <div class="list" style="padding-top:14px">
        <div class="row" style="display:flex;align-items:center;gap:10px">
          <span style="color:var(--k-primary)">▤</span>
          <span style="font-size:14.5px;font-weight:700">zremote</span>
          <span style="margin-left:auto;color:var(--k-ink-faint);font-size:12px">12 个会话</span>
        </div>
        <div class="row" style="display:flex;align-items:center;gap:10px">
          <span style="color:var(--k-primary)">▤</span>
          <span style="font-size:14.5px;font-weight:700">billing</span>
          <span style="margin-left:auto;color:var(--k-ink-faint);font-size:12px">4 个会话</span>
        </div>
        <div class="row" style="display:flex;align-items:center;gap:10px">
          <span style="color:var(--k-primary)">▤</span>
          <span style="font-size:14.5px;font-weight:700">docs</span>
          <span style="margin-left:auto;color:var(--k-ink-faint);font-size:12px">2 个会话</span>
        </div>
        <div style="margin-top:8px;padding:12px;border:var(--k-border) solid var(--k-edge);border-radius:var(--k-radius);background:var(--k-surface);box-shadow:var(--k-shadow)">
          <div style="font-size:13px;font-weight:800;margin-bottom:9px">近 7 天用量</div>
          <div style="display:flex;align-items:flex-end;gap:5px;height:76px">
            ${[38, 62, 44, 88, 71, 96, 55].map((h, i) => `<div style="flex:1;height:${h}%;border-radius:3px;background:${i === 5 ? 'var(--k-primary)' : 'var(--k-aqua)'};opacity:${i === 5 ? 1 : 0.55};border:1px solid var(--k-ink)"></div>`).join('')}
          </div>
          <div style="display:flex;gap:5px;margin-top:6px;color:var(--k-ink-faint);font-size:9.5px">
            <span style="flex:1;text-align:center">一</span><span style="flex:1;text-align:center">二</span>
            <span style="flex:1;text-align:center">三</span><span style="flex:1;text-align:center">四</span>
            <span style="flex:1;text-align:center">五</span><span style="flex:1;text-align:center">六</span>
            <span style="flex:1;text-align:center">日</span>
          </div>
        </div>
        <div style="display:flex;gap:8px;margin-top:2px">
          <div style="flex:1;padding:10px;border:var(--k-border) solid var(--k-edge);border-radius:var(--k-radius);background:var(--k-surface);box-shadow:var(--k-shadow)">
            <div style="color:var(--k-ink-faint);font-size:10.5px">总花费</div>
            <div style="font:800 19px/1.3 var(--k-f-mono)">$12.48</div>
          </div>
          <div style="flex:1;padding:10px;border:var(--k-border) solid var(--k-edge);border-radius:var(--k-radius);background:var(--k-surface);box-shadow:var(--k-shadow)">
            <div style="color:var(--k-ink-faint);font-size:10.5px">缓存命中</div>
            <div style="font:800 19px/1.3 var(--k-f-mono)">87%</div>
          </div>
        </div>
      </div>
      <div class="nav"><span>会话</span><span class="on">项目</span><span>我的</span></div>
    </div></div>
  </div>
</body>
</html>
`;

mkdirSync(here, { recursive: true });
for (const [id, t] of Object.entries(PALETTES)) {
  writeFileSync(join(here, `theme-${id}.html`), page(t), 'utf8');
  console.log('wrote', `preview/theme-${id}.html`, `(${t.label})`);
}
console.log('done:', Object.keys(PALETTES).length, 'files');
