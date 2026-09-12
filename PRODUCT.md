# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary: visitors evaluating the maintainer's work — the one-pager is a
showcase/portfolio piece for Pulsar and Arclight. Secondary: Fedora
Silverblue users who may fork the repo (with their own signing key) or, at
their own risk, run the published images or install from the weekly ISO.
Success is "this person ships polished work"; installs are welcome but
secondary.

## Product Purpose

Pulsar is a personal immutable Fedora Silverblue spin (bootc image) tuned
for gaming and development, built and signed entirely in CI and published to
ghcr.io with provenance attestations. The site's job is to present it well.

## Positioning

Lead claim (user-confirmed 2026-09-12): gamescale — games get the panel's
real resolution instead of a fractional-scaled one, and the desktop scale is
put back when the game exits, even when it does not exit cleanly. The site's
hero copy and its first section carry this claim.

Supporting claims, in order: the gaming + development stack (gamescope,
gamemode, mangohud, ntsync, scx_bpfland scheduling, distrobox, libvirt/KVM,
signed nvidia-open for Blackwell, greenboot auto-rollback); then the supply
chain — the machine that runs it never compiles anything; CI builds, signs,
and attests every image nightly, and the weekly ISO is built from the
published image and signed with the release key.

Honesty is part of the voice: it is one person's laptop OS, over-engineered
on purpose, MIT-licensed to fork.

## Operating Context

Site source lives in `site/` of the arclight-digital/pulsar monorepo, as an
Astro project. `site/stage-assets.mjs` (run by `npm run stage`, which `dev`
and `build` both depend on) copies the brand assets from `assets/` into
`site/public/assets`; the wallpaper shader is imported straight from
`assets/shaders/pulsar.frag` and compiled into the bundle. Built and deployed
by Cloudflare Workers git integration on push to main (root dir `site`, build
`npm run build`, output `dist`) to the assets-only `pulsar-site` Worker.
Local preview: `cd site && npm run dev`. The OS image build is a separate
workflow and must never be triggered by site edits.

The nightly on the build host commits `site/src/data/changelog.json` and
`site/src/data/manifest.json` (scripts/publish.sh); Astro renders the
changelog, the manifest card and the hero's build chip from them at build
time. Those two files are the only thing that hookup writes — never edit
them by hand, and never render them anywhere else. The changelog section
renders a derived digest of the diff (`site/src/data/digest.ts`, rules run
at build time, deterministic); `/changelog.json` still serves the raw diff
untouched. A build somebody started by hand defines nothing: only the
scheduled nightly publishes.

The hero chip is then checked live against the build host: `src/scripts/
beacon.ts` asks buildd's public API at beacon.arclight.digital what the
registry actually holds, so a nightly that ran without a site publish is
visible instead of invisible. CORS is locked to the site's origin, so the
fetch fails on a dev server by design and the chip keeps the build the page
was rendered from. Its failure mode is silence.

Weekly installer ISOs (one per variant, x86_64, 5–6 GB, the stock Silverblue
Anaconda installer landing directly in Pulsar) are built from the published
image and uploaded to an R2 bucket behind lighthouse.arclight.digital
(`/pulsar/iso/`). The `-latest` filenames are stable keys rewritten weekly;
dated originals stay untouched. Each ISO ships `.sha256`, `.sha256.sig` and
`.json` sidecars; the signature covers the checksum manifest, not the ISO.
The release key never leaves the signing host; its public half is published
beside the ISOs and committed as `keys/cosign.pub`.

## Capabilities and Constraints

- Astro, static output. Components are ARC UI (`@arclux/arc-ui`, Arclight's
  own Lit web-component library, v4.2.2 as of 2026-09-12), rendered to
  declarative shadow DOM at build time and hydrated on the client, the way
  arcui.dev itself does. This relaxes the earlier zero-client-framework rule
  (user decision, 2026-09-12): the Lit runtime ships. The page must still
  render complete without JavaScript; `site/src/scripts/` keeps the shader,
  the theme state, the spin easter egg, and the beacon fetch, which is the
  only thing that touches the network.
- Global CSS is the design system only (`src/styles/`: tokens, base, the
  terminal family, which crosses component boundaries). Everything else is a
  scoped `<style>` block in the component it belongs to.
- The hero background is `assets/shaders/pulsar.frag` (the actual OS
  wallpaper shader) in WebGL1; uniforms: u_resolution, u_time, u_theme
  (0 dark / 1 dawn), u_look (0 silk / 1 leak / 2 satin / 3 holo). The
  CI-rendered silk still is the CSS ground: the no-WebGL fallback and the
  first paint. Reduced motion renders a still frame.
- The share card (`og.jpg`) is an Astro endpoint rendered at build time with
  Satori from the same fonts and tokens as the page, over the silk still.
  Nothing about it is hand-maintained.
- Domain (confirmed 2026-09-12): the site lives at pulsar.arclight.digital,
  attached to the Worker in the Cloudflare dashboard; `astro.config.mjs`
  sets it as `site` for canonical, og:url and the sitemap. The GitHub Pages
  deployment is retired. URLs on the page stay relative anyway. The LLC site
  is arclight.build.
- URLs and registry names the page repeats are declared once in
  `site/src/data/site.ts` (repo, both image refs, beacon, ISO base and
  filenames, cosign public key).
- Target hardware (product truth, from the README): an Intel Core Ultra 9
  275HX (8 P-cores + 16 E-cores, no SMT), an RTX 5080 Max-Q (Blackwell
  GB203) beside the Arrow Lake iGPU, a 2560×1600 panel, 62 GB RAM. The
  nvidia variant assumes that GPU; the vanilla image assumes nothing. The
  gamescale section's resolution table is that panel's arithmetic.

## Brand Commitments

- Mark: `assets/brand/pulsar-mark.svg` (dark surfaces) and
  `pulsar-mark-color-dark.svg` (light surfaces — colored arc, dark cores);
  `pulsar-animated.svg` is the hero mark. All brand art is authored, in
  `assets/brand/`.
- Wordmark: PULSAR, Host Grotesk Bold, uppercase, 0.3em tracking.
- Tagline: "Your lighthouse in the sky." (the pulsar-as-cosmic-lighthouse
  metaphor, made personal; replaced "Lighthouses don't drift", which needed
  a decoder ring, which replaced "Fedora with a pulse", retired). Footer
  brandline: "AN IMMUTABLE FEDORA SPIN", with the by-Arclight badge from
  `@arclux/brand` (inlined by hand in `ByArclight.astro`; re-extract on
  version bumps) beside the colophon.
- Palette: ink #0B0E1A, deep #241F3D, cyan #3ECBFF, periwinkle #8FA8FF,
  violet #4B3FD4, star #E9EDF7. Fonts: Host Grotesk (UI and wordmark),
  JetBrains Mono (code), both OFL — license file must travel with any font
  redistribution. Nimbus Sans (documents) is not redistributed by this repo;
  it comes from urw-base35-nimbus-sans-fonts, installed by the Containerfile.
  Host Grotesk and JetBrains Mono are also bound to the generic `sans-serif`
  and `monospace` aliases in fontconfig, so apps that never read the GNOME
  settings still render in brand.
- Voice: dry, technical, confident; no marketing superlatives.

## Evidence on Hand

Everything real: public repo (github.com/arclight-digital/pulsar), green CI
with provenance attestations, signed images on ghcr, the nightly changelog
and manifest committed by the build host, the weekly signed ISOs on
lighthouse.arclight.digital, the live beacon, and the shader-rendered
wallpaper set. NO testimonials, user counts, or benchmarks exist — never
fabricate any.

## Product Principles

- The artifact is the pitch: show the real shader, real commands, real CI,
  the real build number — not stock art or invented claims.
- Honest scope: personal spin first, fork-me second, install-me third.
- The page and the OS share one source of truth (assets/, the committed
  manifest); nothing is hand-copied into the site, and the page cannot say
  something the registry does not.
- Site changes must stay free: never trigger the OS build pipeline.
