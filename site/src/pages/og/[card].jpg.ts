// One share card per page, at /og/<slug>.jpg, rendered at build time from
// src/og/cards.ts. See src/og/render.ts for how, and why nothing is committed.
import type { GetStaticPaths } from 'astro';
import { CARDS, type Card } from '../../og/cards';
import { renderCard } from '../../og/render';

export const prerender = true;

export const getStaticPaths = (() =>
  CARDS.map((card) => ({ params: { card: card.slug }, props: { card } }))) satisfies GetStaticPaths;

export const GET = async ({ props }: { props: { card: Card } }): Promise<Response> => {
  const jpeg = await renderCard(props.card);
  return new Response(new Uint8Array(jpeg), { headers: { 'content-type': 'image/jpeg' } });
};
