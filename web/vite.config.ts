import { fileURLToPath, URL } from 'node:url';
import { defineConfig } from 'vite';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
  plugins: [vue()],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },
  server: {
    port: 5273,
    // 开发时把 /api 与 /ws 代理到本机 zcode-server,规避浏览器跨域与混合内容限制。
    // 生产部署时可改为同源反向代理,或直接填服务器绝对地址(CORS 已开 *)。
    proxy: {
      '/api': { target: 'http://127.0.0.1:5190', changeOrigin: true },
      '/ws': { target: 'ws://127.0.0.1:5190', ws: true },
    },
  },
});
