/**
 * Astro integration around `@arclux/arc-ui/ssr`, copied from arcui.dev's own
 * docs site (arc-ui/docs/integrations/arc-dsd.mjs) -- it imports only package
 * specifiers, so it runs unchanged from node_modules.
 *
 * It is an `astro:build:done` pass: every built HTML file that contains an
 * `<arc-` tag is handed to `renderDeclarativeShadowDOM`, which pre-renders each
 * component into declarative shadow DOM and lifts the shared component
 * stylesheets into /_arc/<hash>.css. The page therefore arrives styled and
 * complete before any JavaScript runs; Lit then adopts that markup rather than
 * rendering over it, provided hydration support is in its own chunk -- see
 * `manualChunks` in astro.config.mjs and the client import order in
 * src/layouts/Base.astro.
 *
 * The dev server never runs this hook, so `npm run dev` renders client-side and
 * flashes unstyled elements. That is a dev-only artefact; `npm run build` is
 * what ships.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderDeclarativeShadowDOM } from '@arclux/arc-ui/ssr';
/**
 * Registers Phosphor in the *build* process, which is a separate program from
 * the browser bundle — `[slug].astro` registering it client-side does nothing
 * here. Since 4.7 core selects no library, and without this every `<arc-icon
 * name="…">` across 19,539 pre-rendered shadow roots resolves to null and paints
 * its empty-slot fallback into the HTML. Not a broken page — the client produces
 * the same tree, so hydration is clean — but a page whose icons only appear
 * after JavaScript, which is the thing pre-rendering exists to avoid.
 */
import '@arclux/arc-ui-icons/phosphor';

/** Where the shared stylesheets are written, relative to the site root. */
const SHEET_DIR = '_arc';

/**
 * `ARC_DSD=0 pnpm build` skips the pass; `ARC_DSD_LIFT=0` keeps the shadow
 * stylesheets inline. Both exist for measuring against. The dev server never
 * runs it — this is an `astro:build:done` hook — so dev renders client-side.
 */
export default function arcDsd({
  enabled = process.env.ARC_DSD !== '0',
  lift = process.env.ARC_DSD_LIFT !== '0',
} = {}) {
  return {
    name: 'arc-dsd',
    hooks: {
      'astro:build:done': async ({ dir, logger }) => {
        if (!enabled) return logger.info('skipped (disabled)');

        const distDir = fileURLToPath(dir);
        const stylesheets = new Map();
        const failures = [];
        let rendered = 0;
        let roots = 0;
        let deferred = 0;
        let before = 0;
        let after = 0;

        for (const file of htmlFiles(distDir)) {
          const source = fs.readFileSync(file, 'utf-8');
          if (!source.includes('<arc-')) continue;

          let result;
          try {
            result = await renderDeclarativeShadowDOM(source, {
              lift,
              stylesheetPath: `/${SHEET_DIR}`,
              stylesheets,
            });
          } catch (error) {
            failures.push({ file: path.relative(distDir, file), error });
            continue;
          }

          roots += result.roots;
          deferred += result.deferred;
          before += source.length;
          after += result.html.length;
          rendered++;
          fs.writeFileSync(file, result.html);
        }

        const sheetDir = path.join(distDir, SHEET_DIR);
        fs.mkdirSync(sheetDir, { recursive: true });
        let sheetBytes = 0;
        for (const [css, name] of stylesheets) {
          fs.writeFileSync(path.join(sheetDir, name), css);
          sheetBytes += css.length;
        }

        const kb = (n) => `${(n / 1024).toFixed(0)}K`;
        logger.info(
          `${rendered} pages, ${roots} shadow roots; ${deferred} closed overlays deferred`
        );
        logger.info(
          `html ${kb(before)} -> ${kb(after)}; ` +
          `${stylesheets.size} shared stylesheets, ${kb(sheetBytes)} total`
        );

        if (failures.length > 0) {
          for (const { file, error } of failures) {
            logger.error(`${file}: ${error?.message ?? error}`);
          }
          throw new Error(
            `arc-dsd: ${failures.length} page(s) failed to server-render. ` +
            'A component that throws here would have shipped as an empty tag.'
          );
        }
      },
    },
  };
}

function htmlFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...htmlFiles(full));
    else if (entry.name.endsWith('.html')) out.push(full);
  }
  return out;
}
