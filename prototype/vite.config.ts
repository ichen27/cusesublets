import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({root: new URL('.', import.meta.url).pathname, plugins:[react()], server:{host:'127.0.0.1',port:8931,strictPort:true},build:{outDir:'../prototype-dist',emptyOutDir:true}});
