<script setup lang="ts">
/**
 * 主题选择器 —— 用户从这里挑页面风格。
 *
 * 关键点:缩略图不是「配色示意图」,而是同一段会话卡/消息气泡的**真实 DOM**,
 * 只把 CSS 变量换成该主题的值(局部 scope)。所见即所得,避免选完才发现不对。
 */
import { onMounted } from 'vue';
import { useRouter } from 'vue-router';

import { paletteList, setTheme, themeId } from '../theme/controller';
import type { ZPalette } from '../theme/palettes';

const router = useRouter();

/** 把某个调色板的 token 转成局部 CSS 变量,供缩略图作用域使用。 */
function scopeVars(p: ZPalette): Record<string, string> {
  return {
    '--z-bg': p.bg,
    '--z-surface': p.surface,
    '--z-surface-hi': p.surfaceHi,
    '--z-ink': p.ink,
    '--z-ink-soft': p.inkSoft,
    '--z-ink-faint': p.inkFaint,
    '--z-line': p.line,
    '--z-edge': p.edge,
    '--z-primary': p.primary,
    '--z-primary-deep': p.primaryDeep,
    '--z-aqua': p.aqua,
    '--z-lemon': p.lemon,
    '--z-rose': p.rose,
    '--z-grape': p.grape,
    '--z-on-ink': p.onInk,
    '--z-radius': `${p.radius}px`,
    '--z-border-w': `${p.borderWidth}px`,
    '--z-card-shadow': p.cardShadow,
    '--z-font-display': p.fontDisplay,
    '--z-font-body': p.fontBody,
    '--z-font-mono': p.fontMono,
  };
}

function choose(p: ZPalette) {
  setTheme(p.id);
}

function openPreview(p: ZPalette) {
  router.push({ name: 'preview', params: { id: p.id } });
}

onMounted(() => {
  // 选择页自身也用当前主题渲染,保证「页面本身」和「缩略图」在同一语境里
  setTheme(themeId.value);
});
</script>

<template>
  <div class="picker">
    <header class="picker__head">
      <div class="picker__mark">z</div>
      <div>
        <h1 class="picker__title">选一套皮肤</h1>
        <p class="picker__sub">
          zCode · 浏览器端 —— 与 Flutter app 一比一对比。点卡片即时切换,点「看完整页」进大图预览。
        </p>
      </div>
    </header>

    <div class="grid">
      <article
        v-for="p in paletteList"
        :key="p.id"
        class="card"
        :class="{ 'card--on': p.id === themeId }"
        :style="scopeVars(p)"
        @click="choose(p)"
      >
        <div class="card__stage" :style="{ background: p.bg, backgroundImage: p.atmosphere }">
          <!-- 会话卡:复刻 SessionsPage 的富卡片结构 -->
          <div class="mini">
            <div class="mini__card">
              <div class="mini__row">
                <span class="mini__title">重构 auth 中间件</span>
                <span class="mini__pill" style="color: var(--z-primary)">运行中</span>
              </div>
              <div class="mini__meta">zremote · claude-sonnet-4.5</div>
              <div class="mini__preview">看一下 server/src/http.ts 的鉴权钩子…</div>
            </div>

            <!-- 消息气泡:用户 + 助手 + 工具卡 -->
            <div class="mini__bubble-row">
              <div class="mini__user">把网关的 CORS 也一起改掉</div>
            </div>
            <div class="mini__bubble-row">
              <div class="mini__assistant">
                好,我先读一下现有实现。
                <code class="mini__code">app.get('/api/sessions')</code>
              </div>
            </div>
            <div class="mini__tool">
              <span class="mini__dot" />
              <span class="mini__toolname">Read</span>
              <span class="mini__toolarg">server/src/http.ts</span>
            </div>
          </div>
        </div>

        <div class="card__foot" :style="{ background: p.surface, borderColor: p.edge, color: p.ink }">
          <div class="card__names">
            <span class="card__label">{{ p.label }}</span>
            <span class="card__blurb" :style="{ color: p.inkSoft }">{{ p.blurb }}</span>
          </div>
          <div class="card__swatches">
            <i v-for="c in [p.primary, p.aqua, p.lemon, p.rose, p.grape]" :key="c" :style="{ background: c }" />
          </div>
          <button
            class="card__open"
            :style="{ borderColor: p.edge, color: p.inkSoft }"
            @click.stop="openPreview(p)"
          >
            看完整页 →
          </button>
        </div>

        <span v-if="p.id === themeId" class="card__badge" :style="{ background: p.primary, color: p.onInk }">
          当前
        </span>
      </article>
    </div>
  </div>
</template>

<style scoped>
.picker {
  max-width: 1180px;
  margin: 0 auto;
  padding: 40px 24px 72px;
}

.picker__head {
  display: flex;
  align-items: flex-start;
  gap: 16px;
  margin-bottom: 30px;
}

.picker__mark {
  width: 56px;
  height: 56px;
  flex: none;
  display: grid;
  place-items: center;
  border-radius: var(--z-radius);
  border: 1.6px solid var(--z-primary);
  background: color-mix(in srgb, var(--z-primary) 12%, transparent);
  box-shadow: var(--z-card-shadow);
  color: var(--z-primary);
  font-family: var(--z-font-mono);
  font-size: 28px;
  font-weight: 800;
}

.picker__title {
  font-size: 38px;
  letter-spacing: -1.2px;
}

.picker__sub {
  margin: 6px 0 0;
  max-width: 62ch;
  color: var(--z-ink-soft);
  font-size: 13px;
}

.grid {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
  gap: 22px;
}

.card {
  position: relative;
  overflow: hidden;
  border: var(--z-border-w) solid var(--z-edge);
  border-radius: var(--z-radius);
  background: var(--z-surface);
  box-shadow: var(--z-card-shadow);
  cursor: pointer;
  transition: transform 0.14s ease, box-shadow 0.14s ease;
}
.card:hover {
  transform: translate(-2px, -2px);
  box-shadow: 7px 7px 0 0 var(--z-ink);
}
.card--on {
  outline: 3px solid var(--z-primary);
  outline-offset: 2px;
}

.card__stage {
  height: 236px;
  padding: 14px;
  overflow: hidden;
}

.card__foot {
  display: flex;
  flex-direction: column;
  gap: 9px;
  padding: 13px 14px 14px;
  border-top: 1px solid;
}

.card__names {
  display: flex;
  flex-direction: column;
  gap: 2px;
}

.card__label {
  font-family: var(--z-font-display);
  font-size: 16px;
  font-weight: 800;
}

.card__blurb {
  font-size: 11.5px;
  line-height: 1.5;
}

.card__swatches {
  display: flex;
  gap: 5px;
}
.card__swatches i {
  width: 17px;
  height: 17px;
  border-radius: 4px;
  border: 1px solid rgba(0, 0, 0, 0.18);
}

.card__open {
  align-self: flex-start;
  padding: 5px 11px;
  border: 1px solid;
  border-radius: 99px;
  background: transparent;
  font-size: 11.5px;
  font-weight: 700;
  transition: color 0.14s ease, border-color 0.14s ease;
}
.card__open:hover {
  color: var(--z-primary);
  border-color: var(--z-primary);
}

.card__badge {
  position: absolute;
  top: 10px;
  right: 10px;
  padding: 3px 9px;
  border-radius: 99px;
  font-size: 10.5px;
  font-weight: 800;
}

/* ---------------------------------------------------- 缩略图内部:真实组件样式 */

.mini {
  display: flex;
  flex-direction: column;
  gap: 7px;
  font-family: var(--z-font-body);
}

.mini__card {
  padding: 9px 10px;
  border-radius: var(--z-radius);
  border: var(--z-border-w) solid var(--z-edge);
  background: var(--z-surface);
  box-shadow: var(--z-card-shadow);
}

.mini__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}

.mini__title {
  color: var(--z-ink);
  font-size: 13px;
  font-weight: 800;
}

.mini__pill {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  flex: none;
  padding: 2px 7px;
  border: 1.2px solid currentColor;
  border-radius: 99px;
  background: var(--z-surface);
  font-size: 10px;
  font-weight: 800;
}

.mini__meta {
  margin-top: 3px;
  color: var(--z-ink-faint);
  font-family: var(--z-font-mono);
  font-size: 10px;
}

.mini__preview {
  margin-top: 5px;
  color: var(--z-ink-soft);
  font-size: 11px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.mini__bubble-row {
  display: flex;
  justify-content: flex-end;
}

.mini__user {
  max-width: 84%;
  padding: 6px 10px;
  border-radius: var(--z-radius);
  border: var(--z-border-w) solid var(--z-edge);
  background: var(--z-primary);
  color: var(--z-on-ink);
  font-size: 11.5px;
  box-shadow: var(--z-card-shadow);
}

.mini__assistant {
  max-width: 88%;
  padding: 7px 10px;
  border-radius: var(--z-radius);
  border: var(--z-border-w) solid var(--z-edge);
  background: var(--z-surface);
  color: var(--z-ink);
  font-size: 11.5px;
  box-shadow: 0 2px 10px -6px rgba(0, 0, 0, 0.35);
}

.mini__code {
  display: inline-block;
  margin-top: 4px;
  padding: 1px 5px;
  border-radius: 4px;
  background: var(--z-surface-hi);
  border: 1px solid var(--z-line);
  color: var(--z-primary-deep);
  font-family: var(--z-font-mono);
  font-size: 10px;
}

.mini__tool {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 5px 9px;
  border-radius: calc(var(--z-radius) - 3px);
  border: 1px dashed var(--z-edge);
  background: var(--z-surface-hi);
  color: var(--z-ink-soft);
  font-size: 10.5px;
}

.mini__dot {
  width: 6px;
  height: 6px;
  flex: none;
  border-radius: 50%;
  background: var(--z-aqua);
}

.mini__toolname {
  color: var(--z-aqua);
  font-family: var(--z-font-mono);
  font-weight: 700;
}

.mini__toolarg {
  font-family: var(--z-font-mono);
  opacity: 0.75;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
</style>
