import { defineConfig } from 'vite';
import preact from '@preact/preset-vite';

export default defineConfig({
  base: './',
  plugins: [preact()],
  build: {
    outDir: '../ui',
    emptyOutDir: true,
    target: 'es2022',
    sourcemap: false,
  },
});
