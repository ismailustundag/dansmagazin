import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { resolve } from 'node:path'

const projectDir = fileURLToPath(new URL('.', import.meta.url))

export default defineConfig(({ command }) => ({
  plugins: [react()],
  base: command === 'serve' ? '/' : '/admin-v2-assets/',
  build: {
    outDir: resolve(projectDir, '../foto_backend/admin_v2_dist'),
    emptyOutDir: true,
  },
  server: {
    port: 4174,
    proxy: {
      '/admin/api/v2': 'http://127.0.0.1:8000',
    },
  },
  test: {
    exclude: ['e2e/**', 'node_modules/**'],
  },
}))
