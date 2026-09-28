// The docs are the repo's own docs/*.md, read where they live. The site
// renders them; it never keeps a copy, so the docs and the repo cannot drift
// apart. A page's title is its first heading.
import { defineCollection } from 'astro:content';
import { glob } from 'astro/loaders';

const docs = defineCollection({
  loader: glob({ pattern: '*.md', base: '../docs', generateId: ({ entry }) => entry.replace(/\.md$/, '').toLowerCase() }),
});

export const collections = { docs };
