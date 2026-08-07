// @ts-check
import { defineConfig } from 'astro/config';

// Static output. The deploy target is an assets-only Cloudflare Worker (see
// wrangler.jsonc) serving ./dist from the edge -- there is no server, so there
// is no adapter. `site` is what canonical, og:url and the sitemap are built
// from; crawlers resolve nothing relative, so it has to be the real origin.
export default defineConfig({
  site: 'https://pulsar.arclight.digital',
  output: 'static',
  build: {
    // One page that is mostly CSS. Inlining the small sheets would scatter the
    // brand tokens across <style> tags and lose the cache on every deploy.
    inlineStylesheets: 'never',
  },
  vite: {
    server: {
      fs: {
        // src/scripts/sky.ts imports ../../../assets/shaders/pulsar.frag with
        // ?raw -- the actual OS wallpaper shader, compiled into the bundle
        // rather than copied. The dev server refuses reads above the project
        // root unless the repo is allowed explicitly; the build does not care.
        allow: ['..'],
      },
    },
  },
});
