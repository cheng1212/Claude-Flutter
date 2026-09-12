<script setup lang="ts">
/**
 * 单主题整页预览 —— 把「会话列表」这一屏用指定主题完整渲染一遍。
 *
 * 数据是写死的样例(此处不连服务器):这一步的目的是**选风格**,
 * 不是验功能。选完再把这套 token 铺到真实页面上。
 */
import { computed, onMounted } from 'vue';
import { useRoute, useRouter } from 'vue-router';

import { paletteOf, type ZPalette } from '../theme/palettes';
import { setTheme } from '../theme/controller';

const route = useRoute();
const router = useRouter();

const p = computed<ZPalette>(() => paletteOf(String(route.params.id ?? '')));

/** 预览页要把该主题真正应用到整站,才能看出氛围差异。 */
onMounted(() => setTheme(p.value.id));

const sessions = [
  { title: '重构 auth 中间件', status: 'running', label: '运行中', project: 'zremote', model: 'claude-sonnet-4.5', preview: '看一下 server/src/http.ts 的鉴权钩子,顺便把 CORS 收一下', time: '14:02' },
  { title: '排查图片上传内存暴涨', status: 'done', label: '空闲', project: 'zremote', model: 'claude-opus-4.1', preview: '1280px 拍照原样解进 GPU 是缩略图的十几倍内存', time: '昨天' },
  { title: '用量统计图表对不上', status: 'waiting', label: '待确认', project: 'billing', model: 'claude-haiku-4', preview: '需要你确认一下 7d 窗口是从本地零点算还是 UTC', time: '昨天' },
  { title: '给会话列表加批量删除', status: 'error', label: '异常', project: 'zremote', model: 'claude-sonnet-4.5', preview: 'batch-delete 接口返回 500:ids 为空数组时没短路', time: '9月11日' },
  { title: '写一份部署交接文档', status: 'queued', label: '排队中', project: 'docs', model: 'claude-opus-4.1', preview: '把 5190/5191 双端口和令牌生成的步骤都写进去', time: '9月10日' },
];

const projects = [
  { name: 'zremote', count: 12 },
  { name: 'billing', count: 4 },
  { name: 'docs', count: 2 },
];
</script>

<template>
  <div class="prev">
    <div class="prev__bar">
      <button class="z-btn z-btn-ghost" @click="router.push({ name: 'theme' })">← 回到选择</button>
      <span class="prev__name">{{ p.label }}</span>
      <span class="prev__blurb">{{ p.blurb }}</span>
    </div>

    <!-- 手机框:让 1:1 对比 app 这件事有参照 */
    <div class="phone">
      <div class="phone__screen">
        <!-- AppBar -->
        <div class="bar">
          <div class="bar__title">会话</div>
          <div class="bar__actions">
            <span class="bar__ico">⌕</span>
            <span class="bar__ico">⋮</span>
          </div>
        </div>

        <!-- 搜索 -->
        <div class="search">
          <input class="z-input" placeholder="搜索会话标题 / 内容" readonly />
        </div>

        <!-- 筛选 chips -->
        <div class="chips">
          <span class="chip chip--on">全部</span>
          <span class="chip">已置顶</span>
          <span class="chip">项目</span>
          <span class="chip">已归档</span>
        </div>

        <!-- 会话卡 -->
        <div class="list">
          <article v-for="s in sessions" :key="s.title" class="row z-card">
            <div class="row__top">
              <span class="row__title">{{ s.title }}</span>
              <span
                class="z-pill"
                :style="{
                  color: `var(--z-${
                    s.status === 'running' ? 'primary'
                    : s.status === 'done' ? 'ink-soft'
                    : s.status === 'waiting' ? 'lemon'
                    : s.status === 'error' ? 'rose' : 'lemon'
                  })`,
                }"
              >
                <i class="z-pulse" />
                {{ s.label }}
              </span>
            </div>
            <div class="row__meta">
              <span class="row__proj">{{ s.project }}</span>
              <span class="row__sep">·</span>
              <span class="row__model z-mono">{{ s.model }}</span>
              <span class="row__time">{{ s.time }}</span>
            </div>
            <p class="row__preview">{{ s.preview }}</p>
          </article>
        </div>

        <!-- 底部导航 -->
        <nav class="nav">
          <span class="nav__item nav__item--on">会话</span>
          <span class="nav__item">项目</span>
          <span class="nav__item">我的</span>
        </nav>
      </div>
    </div>

    <!-- 右侧:项目 tab 的形态 -->
    <div class="side">
      <h2 class="side__h">项目</h2>
      <div class="side__list">
        <div v-for="pr in projects" :key="pr.name" class="z-card side__item">
          <span class="side__folder">▤</span>
          <span class="side__pname">{{ pr.name }}</span>
          <span class="side__count">{{ pr.count }} 个会话</span>
        </div>
      </div>

      <h2 class="side__h">色板</h2>
      <div class="swatches">
        <div v-for="c in [
          ['主色', p.primary], ['青', p.aqua], ['柠黄', p.lemon],
          ['玫红', p.rose], ['葡萄', p.grape], ['墨', p.ink],
        ]" :key="c[0]" class="sw">
          <i :style="{ background: c[1] }" />
          <span class="sw__name">{{ c[0] }}</span>
          <span class="sw__hex z-mono">{{ c[1] }}</span>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.prev {
  display: grid;
  grid-template-columns: 1fr 392px 320px;
  align-items: start;
  gap: 28px;
  max-width: 1240px;
  margin: 0 auto;
  padding: 28px 24px 80px;
}

.prev__bar {
  grid-column: 1 / -1;
  display: flex;
  align-items: center;
  gap: 14px;
}

.prev__name {
  font-family: var(--z-font-display);
  font-size: 22px;
  font-weight: 800;
}

.prev__blurb {
  color: var(--z-ink-soft);
  font-size: 12.5px;
}

/* 手机框 */
.phone {
  grid-column: 1 / 2;
  justify-self: center;
  padding: 10px;
  border: var(--z-border-w) solid var(--z-edge);
  border-radius: calc(var(--z-radius) + 14px);
  background: var(--z-surface);
  box-shadow: var(--z-card-shadow);
}

.phone__screen {
  width: 360px;
  height: 720px;
  display: flex;
  flex-direction: column;
  overflow: hidden;
  border-radius: var(--z-radius);
  background: var(--z-bg);
  background-image: var(--z-atmosphere, none);
}

.bar {
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 14px 14px 8px;
}
.bar__title {
  font-family: var(--z-font-display);
  font-size: 21px;
  font-weight: 900;
  letter-spacing: -0.4px;
}
.bar__actions {
  display: flex;
  gap: 12px;
  color: var(--z-ink-soft);
  font-size: 17px;
}

.search {
  padding: 0 14px;
}

.chips {
  display: flex;
  gap: 7px;
  padding: 10px 14px 4px;
  flex-wrap: wrap;
}
.chip {
  padding: 4px 10px;
  border: 1.2px solid var(--z-edge);
  border-radius: 99px;
  background: var(--z-surface);
  color: var(--z-ink-soft);
  font-size: 11.5px;
  font-weight: 700;
}
.chip--on {
  background: var(--z-primary);
  border-color: var(--z-ink);
  color: var(--z-on-ink);
}

.list {
  flex: 1;
  overflow-y: auto;
  display: flex;
  flex-direction: column;
  gap: 9px;
  padding: 10px 14px 14px;
}

.row {
  padding: 11px 12px;
}
.row__top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.row__title {
  font-size: 14px;
  font-weight: 800;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.row__meta {
  display: flex;
  align-items: center;
  gap: 6px;
  margin-top: 5px;
  color: var(--z-ink-faint);
  font-size: 10.5px;
}
.row__proj {
  padding: 1px 6px;
  border: 1px solid var(--z-line);
  border-radius: 5px;
  background: var(--z-surface-hi);
  color: var(--z-ink-soft);
  font-weight: 700;
}
.row__time {
  margin-left: auto;
}
.row__preview {
  margin: 7px 0 0;
  color: var(--z-ink-soft);
  font-size: 11.5px;
  line-height: 1.5;
  display: -webkit-box;
  -webkit-line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}

.nav {
  display: flex;
  border-top: 1px solid var(--z-line);
  background: var(--z-surface);
}
.nav__item {
  flex: 1;
  padding: 12px 0;
  text-align: center;
  color: var(--z-ink-faint);
  font-size: 11.5px;
  font-weight: 700;
}
.nav__item--on {
  color: var(--z-primary);
}

/* 右侧 */
.side {
  grid-column: 3 / 4;
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.side__h {
  margin-top: 8px;
  font-size: 15px;
  letter-spacing: 0.2px;
}
.side__list {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.side__item {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 11px 12px;
}
.side__folder {
  color: var(--z-primary);
}
.side__pname {
  font-size: 13.5px;
  font-weight: 700;
}
.side__count {
  margin-left: auto;
  color: var(--z-ink-faint);
  font-size: 11px;
}

.swatches {
  display: flex;
  flex-direction: column;
  gap: 6px;
}
.sw {
  display: flex;
  align-items: center;
  gap: 9px;
  font-size: 11.5px;
}
.sw i {
  width: 20px;
  height: 20px;
  border-radius: 5px;
  border: 1px solid rgba(0, 0, 0, 0.2);
}
.sw__name {
  flex: none;
  width: 42px;
  font-weight: 700;
}
.sw__hex {
  color: var(--z-ink-faint);
  font-size: 10.5px;
}

@media (max-width: 1120px) {
  .prev {
    grid-template-columns: 1fr;
    justify-items: center;
  }
  .side {
    grid-column: 1 / -1;
    width: 100%;
    max-width: 420px;
  }
}
</style>
