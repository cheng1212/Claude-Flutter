import { createApp } from 'vue';
import { createPinia } from 'pinia';
import { createRouter, createWebHashHistory } from 'vue-router';

import App from './App.vue';
import { initTheme } from './theme/controller';
import './styles/base.css';

const router = createRouter({
  history: createWebHashHistory(),
  routes: [
    { path: '/', redirect: '/theme' },
    { path: '/theme', name: 'theme', component: () => import('./views/ThemePicker.vue') },
    { path: '/preview/:id', name: 'preview', component: () => import('./views/StylePreview.vue') },
  ],
});

// 挂载前先把主题变量注入 :root,避免首帧用兜底色闪一下
initTheme();

createApp(App).use(createPinia()).use(router).mount('#app');
