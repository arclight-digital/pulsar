// /og.jpg, the site-wide card: the home page's, drawn by the same renderer as
// every per-page card under /og/. It stays at this address because it has been
// shared and cached as the site's image, and because the structured data names
// it as Pulsar's image.
import { cardFor } from '../og/cards';
import { renderCard } from '../og/render';

export const prerender = true;

export const GET = async (): Promise<Response> => {
  const jpeg = await renderCard(cardFor('/'));
  return new Response(new Uint8Array(jpeg), { headers: { 'content-type': 'image/jpeg' } });
};
