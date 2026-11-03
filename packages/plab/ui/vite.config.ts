import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';

// Declared locally so the config type-checks without @types/node as a dependency.
declare const process: { env: Record<string, string | undefined> };

// In dev, /api (including the SSE stream) goes to a running `plab serve`: a local one, or
// galactica's through `ssh -L 8577:127.0.0.1:8577 galactica`.
export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  server: {
    proxy: { '/api': { target: process.env.PLAB_DEV_BACKEND ?? 'http://127.0.0.1:8577', changeOrigin: true } },
  },
  build: { outDir: 'dist', assetsDir: 'assets' },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
});
