// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import arcDsd from './integrations/arc-dsd.mjs';
import { SITE } from './src/data/site.ts';
import changelog from './src/data/changelog.json' with { type: 'json' };

// The one date the build knows for certain: when last night's diff was
// written. The home page and the changelog both render it, so their lastmod is
// that stamp; the other pages change only when the repo does, and a guessed
// date is worse than none, so they carry no lastmod at all.
const NIGHTLY = changelog.generated ? new Date(changelog.generated).toISOString() : undefined;

// Static output. The deploy target is an assets-only Cloudflare Worker (see
// wrangler.jsonc) serving ./dist from the edge -- there is no server, so there
// is no adapter. `site` is what canonical, og:url, robots.txt and the sitemap
// are built from; crawlers resolve nothing relative, so it has to be the real
// origin. It is spelled once, in src/data/site.ts.
//
// The components are ARC UI web components (@arclux/arc-ui). They are
// pre-rendered into declarative shadow DOM by the arc-dsd integration after the
// build, so the HTML that ships is complete and styled before Lit loads.
export default defineConfig({
  // Off, on purpose. Astro's compressor deletes the whitespace at a source
  // line break whenever it sits next to a tag or a {…} expression, and this
  // site's prose wraps constantly -- so "usual job.<link>", "as one
  // change.<code>" and "Digital LLC.<span>Support…" each shipped glued
  // together, one at a time, as they were found. Fixing instances by hand
  // was whack-a-mole; keeping the whitespace costs a few KB of HTML.
  compressHTML: false,
  site: SITE,
  output: 'static',
  // Slash-less URLs, everywhere they appear: the nav, the canonical tags, the
  // sitemap, and what the CDN serves. `format: 'file'` writes install.html
  // rather than install/index.html, and the Worker's auto-trailing-slash
  // then serves /install and redirects /install/ to it -- instead of the
  // reverse, which had every canonical pointing at a redirect.
  trailingSlash: 'never',
  integrations: [
    arcDsd(),
    sitemap({
      // /preview/* are the hero options, rendered for choosing between and
      // marked noindex; they are not pages anyone should land on. Neither is
      // the 404 page.
      filter: (page) => {
        const path = new URL(page).pathname;
        return !path.startsWith('/preview/') && path !== '/404';
      },
      // the home page and the changelog change every night; the rest when
      // the repo does
      serialize: (item) => {
        const path = new URL(item.url).pathname;
        const nightly = path === '/' || path === '/changelog';
        item.changefreq = nightly ? 'daily' : 'weekly';
        if (nightly && NIGHTLY) item.lastmod = NIGHTLY;
        item.priority = path === '/' ? 1 : path === '/install' ? 0.9 : 0.7;
        return item;
      },
    }),
  ],
  build: {
    format: 'file',
    // One site that is mostly CSS. Inlining the small sheets would scatter the
    // brand tokens across <style> tags and lose the cache on every deploy.
    inlineStylesheets: 'never',
  },
  vite: {
    build: {
      rollupOptions: {
        output: {
          // Lit's hydration support has to evaluate before any component class
          // is defined, or Lit renders over the server's markup instead of
          // adopting it. Importing it first is not enough: the module is small,
          // Rollup inlines it into the entry chunk, and the components' own
          // cross-chunk imports hoist above that inlined code. As a chunk of
          // its own it becomes a cross-chunk import too, and those keep their
          // source order. (Copied from arcui.dev's config, which found this the
          // hard way.)
          manualChunks(id) {
            if (id.includes('ssr-client') || id.endsWith('arc-ui/src/hydrate.js')) {
              return 'arc-hydrate';
            }
          },
        },
      },
    },
    ssr: {
      // ESM-only; bundle it into the build pipeline rather than externalising.
      // `lit` stays external on purpose -- a second copy in the server chunk
      // means a second custom-element registry.
      noExternal: ['@arclux/arc-ui'],
    },
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
