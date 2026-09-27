#!/usr/bin/env node
// Walks the built site (dist/) and fails if any page breaks the search
// basics: exactly one <title> and one meta description, each inside its length
// bounds and unique across the site; one canonical, absolute, on the site's own
// origin (noindex pages may omit it); one h1 in the light DOM; every
// application/ld+json block valid JSON; no plain-http URLs; every internal link
// landing on a file the build wrote; every <img> with alt and dimensions;
// robots.txt naming the sitemap; the sitemap listing no noindex page.
//
// Run after a build: `npm run build && npm run seo`. It reads only dist/, so it
// checks what ships rather than what the source meant. Not wired into the
// deploy build; `npm run build:checked` is the gated form.
//
// Headings and images inside declarative shadow roots (<template
// shadowrootmode>) belong to ARC UI's components, not to the page's outline,
// so they are stripped before counting.
import { readFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIST = fileURLToPath(new URL('../dist/', import.meta.url));
const TITLE = [30, 65];
const DESC = [110, 165];

if (!existsSync(DIST)) {
  console.error('seo-check: no dist/ -- run the build first');
  process.exit(2);
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

/** Drop every <template shadowrootmode> subtree, nesting included. */
function lightDom(html) {
  let out = '';
  let depth = 0;
  const re = /<template\b[^>]*>|<\/template>/gi;
  let last = 0;
  let m;
  while ((m = re.exec(html))) {
    const open = m[0][1] !== '/';
    if (depth === 0) out += html.slice(last, m.index);
    if (open) {
      if (depth > 0 || /shadowrootmode/i.test(m[0])) depth++;
      else out += m[0];
    } else if (depth > 0) {
      depth--;
    } else {
      out += m[0];
    }
    last = re.lastIndex;
  }
  if (depth === 0) out += html.slice(last);
  return out;
}

const attr = (tag, name) => {
  const m = tag.match(new RegExp(`\\s${name}\\s*=\\s*("([^"]*)"|'([^']*)'|([^\\s>]+))`, 'i'));
  return m ? (m[2] ?? m[3] ?? m[4] ?? '') : null;
};
const decode = (s) =>
  s
    .replace(/&amp;/g, '&')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&nbsp;/g, ' ');

const files = walk(DIST);
const pages = files.filter((f) => f.endsWith('.html'));
const errors = [];
const warnings = [];
const rows = [];
const seenTitle = new Map();
const seenDesc = new Map();
const noindexPaths = new Set();
let origin = null;

const fail = (page, msg) => errors.push(`${page}: ${msg}`);
const warn = (page, msg) => warnings.push(`${page}: ${msg}`);

// What a root-relative href can land on, given format: 'file' and the Worker's
// auto-trailing-slash handling.
function resolves(path) {
  const clean = decodeURIComponent(path.split(/[?#]/)[0]);
  if (clean === '/' || clean === '') return existsSync(join(DIST, 'index.html'));
  const rel = clean.replace(/^\//, '').replace(/\/$/, '');
  return [rel, `${rel}.html`, join(rel, 'index.html')].some((c) => {
    const p = join(DIST, c);
    return existsSync(p) && statSync(p).isFile();
  });
}

for (const file of pages) {
  const page = '/' + relative(DIST, file).replace(/\\/g, '/');
  const html = readFileSync(file, 'utf8');
  const head = (html.match(/<head\b[^>]*>([\s\S]*?)<\/head>/i) || [])[1] ?? '';
  const body = lightDom(html);

  // <html lang>
  if (!/<html\b[^>]*\slang="[a-z]{2}/i.test(html)) fail(page, 'no <html lang>');

  const robots = [...head.matchAll(/<meta\b[^>]*name="robots"[^>]*>/gi)].map((m) => attr(m[0], 'content'));
  const noindex = robots.some((c) => /noindex/i.test(c ?? ''));

  // <title>: head only -- an inline SVG can carry its own
  const titles = [...head.matchAll(/<title\b[^>]*>([\s\S]*?)<\/title>/gi)].map((m) => decode(m[1].trim()));
  if (titles.length !== 1) fail(page, `${titles.length} <title> elements`);
  const title = titles[0] ?? '';
  if (!title) fail(page, 'empty <title>');
  else if (!noindex && (title.length < TITLE[0] || title.length > TITLE[1]))
    fail(page, `title is ${title.length} chars (want ${TITLE[0]}-${TITLE[1]}): ${title}`);

  const descs = [...head.matchAll(/<meta\b[^>]*name="description"[^>]*>/gi)].map((m) => decode(attr(m[0], 'content') ?? ''));
  if (descs.length !== 1) fail(page, `${descs.length} meta descriptions`);
  const desc = descs[0] ?? '';
  if (!desc) fail(page, 'empty meta description');
  else if (!noindex && (desc.length < DESC[0] || desc.length > DESC[1]))
    fail(page, `description is ${desc.length} chars (want ${DESC[0]}-${DESC[1]})`);

  if (!noindex) {
    if (seenTitle.has(title)) fail(page, `title duplicates ${seenTitle.get(title)}`);
    if (seenDesc.has(desc)) fail(page, `description duplicates ${seenDesc.get(desc)}`);
    seenTitle.set(title, page);
    seenDesc.set(desc, page);
  }

  const canon = [...head.matchAll(/<link\b[^>]*rel="canonical"[^>]*>/gi)].map((m) => attr(m[0], 'href'));
  if (canon.length > 1 || (!noindex && canon.length !== 1)) fail(page, `${canon.length} canonical links`);
  let canonPath = null;
  if (canon[0]) {
    try {
      const u = new URL(canon[0]);
      if (u.protocol !== 'https:') fail(page, `canonical is not https: ${canon[0]}`);
      origin ??= u.origin;
      if (u.origin !== origin) fail(page, `canonical origin ${u.origin} differs from ${origin}`);
      canonPath = u.pathname;
    } catch {
      fail(page, `canonical is not an absolute URL: ${canon[0]}`);
    }
  }
  if (noindex) noindexPaths.add(canonPath ?? page.replace(/\.html$/, '').replace(/\/index$/, '/'));

  const h1s = body.match(/<h1\b/gi) ?? [];
  if (h1s.length !== 1) fail(page, `${h1s.length} h1 elements in the light DOM`);

  // heading order: a warning, since a skipped level is untidy, not broken
  let prev = 0;
  for (const m of body.matchAll(/<h([1-6])\b/gi)) {
    const level = Number(m[1]);
    if (prev && level > prev + 1) {
      warn(page, `heading jumps h${prev} -> h${level}`);
      break;
    }
    prev = level;
  }

  const ld = [...html.matchAll(/<script\b[^>]*type="application\/ld\+json"[^>]*>([\s\S]*?)<\/script>/gi)];
  if (ld.length === 0) fail(page, 'no JSON-LD');
  for (const [, json] of ld) {
    try {
      const data = JSON.parse(json);
      const graph = data['@graph'] ?? [data];
      if (data['@context'] !== 'https://schema.org') fail(page, 'JSON-LD @context is not https://schema.org');
      const app = graph.find((n) => n['@type'] === 'SoftwareApplication');
      if (app) {
        for (const k of ['name', 'operatingSystem', 'applicationCategory', 'offers', 'softwareVersion', 'license', 'publisher'])
          if (app[k] == null || app[k] === '') fail(page, `SoftwareApplication has no ${k}`);
        if (app.offers && String(app.offers.price) !== '0') fail(page, 'SoftwareApplication offer is not free');
      }
      for (const n of graph)
        if (!n['@type']) fail(page, `JSON-LD node without @type: ${JSON.stringify(n).slice(0, 60)}`);
    } catch (e) {
      fail(page, `invalid JSON-LD: ${e.message}`);
    }
  }

  // mixed content: http:// in anything a browser fetches or follows
  for (const m of body.matchAll(/\s(?:src|href|srcset|content|poster|action)="(http:\/\/[^"]*)"/gi))
    fail(page, `plain-http URL: ${m[1]}`);

  // internal links
  for (const m of body.matchAll(/<(?:a|arc-button|arc-link|arc-nav-item|link)\b[^>]*\shref="(\/[^"/][^"]*|\/)"/gi)) {
    const href = m[1];
    if (!resolves(href)) fail(page, `broken internal link: ${href}`);
  }
  for (const m of body.matchAll(/<a\b[^>]*>([\s\S]*?)<\/a>/gi)) {
    const text = decode(m[1].replace(/<[^>]+>/g, '').trim()).toLowerCase();
    if (/^(here|click here|this|link|more|read more)$/.test(text)) warn(page, `vague link text "${text}"`);
  }

  for (const m of body.matchAll(/<img\b[^>]*>/gi)) {
    const tag = m[0];
    const src = attr(tag, 'src') ?? attr(tag, 'data-src') ?? '?';
    if (attr(tag, 'alt') === null) fail(page, `<img> without alt: ${src}`);
    if (attr(tag, 'width') === null || attr(tag, 'height') === null) warn(page, `<img> without width/height: ${src}`);
  }

  rows.push({ page, noindex, title, tl: title.length, dl: desc.length });
}

// robots.txt and the sitemap
const robotsTxt = existsSync(join(DIST, 'robots.txt')) ? readFileSync(join(DIST, 'robots.txt'), 'utf8') : '';
const sitemapLine = robotsTxt.match(/^Sitemap:\s*(\S+)/im);
if (!sitemapLine) fail('/robots.txt', 'no Sitemap line');
else {
  const u = new URL(sitemapLine[1]);
  if (origin && u.origin !== origin) fail('/robots.txt', `sitemap origin ${u.origin} differs from ${origin}`);
  if (!existsSync(join(DIST, u.pathname))) fail('/robots.txt', `sitemap ${u.pathname} was not built`);
}
const maps = files.filter((f) => /sitemap-\d+\.xml$/.test(f));
if (!maps.length) fail('/sitemap', 'no sitemap-N.xml');
for (const f of maps) {
  const xml = readFileSync(f, 'utf8');
  for (const [, loc] of xml.matchAll(/<loc>([^<]+)<\/loc>/g)) {
    const path = new URL(loc).pathname;
    if (noindexPaths.has(path)) fail('/sitemap', `lists noindex page ${path}`);
    if (origin && new URL(loc).origin !== origin) fail('/sitemap', `foreign origin ${loc}`);
    if (!resolves(path)) fail('/sitemap', `lists ${path}, which was not built`);
  }
}

console.log('page                 idx  title  desc  title');
for (const r of rows.sort((a, b) => a.page.localeCompare(b.page)))
  console.log(
    `${r.page.padEnd(20)} ${r.noindex ? 'no ' : 'yes'}  ${String(r.tl).padStart(5)}  ${String(r.dl).padStart(4)}  ${r.title}`,
  );
for (const w of warnings) console.log(`warn  ${w}`);
for (const e of errors) console.log(`FAIL  ${e}`);
console.log(`\n${pages.length} pages, ${errors.length} failures, ${warnings.length} warnings`);
process.exit(errors.length ? 1 : 0);
