import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { resolve } from 'node:path';
export default defineConfig({
    plugins: [react()],
    base: '/admin-v2-assets/',
    build: {
        outDir: resolve(__dirname, '../foto_backend/admin_v2_dist'),
        emptyOutDir: true,
    },
    server: {
        port: 4174,
        proxy: {
            '/admin/api/v2': 'http://127.0.0.1:8000',
        },
    },
});
