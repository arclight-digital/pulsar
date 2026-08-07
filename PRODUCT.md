# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary: visitors evaluating the maintainer's work — the one-pager is a
showcase/portfolio piece for Pulsar and Arclight. Secondary: Fedora
Silverblue users who may fork the repo (with their own signing key) or, at
their own risk, run the published images. Success is "this person ships
polished work"; installs are welcome but secondary.

## Product Purpose

Pulsar is a personal immutable Fedora Silverblue spin (bootc image) tuned
for gaming and development, built and signed entirely on GitHub CI and
published to ghcr.io with provenance attestations. The site's job is to
present it well.

## Positioning

Lead claim (user-confirmed): a gaming + development Fedora spin — scx_bpfland
scheduling, gamescope/gamemode/mangohud, distrobox, libvirt/KVM, signed
nvidia-open for Blackwell. Supporting claim: the supply chain — the machine
that runs it never compiles anything; CI builds, signs, and attests every
image nightly. Honesty is part of the voice: it is one person's laptop OS,
over-engineered on purpose, MIT-licensed to fork.

## Operating Context

Site source lives in `site/` of the arclight-digital/pulsar monorepo, as an
Astro project. `site/stage-assets.mjs` (run by `npm run stage`, which `dev`
and `build` both depend on) copies the brand assets from `assets/` into
`site/public/assets`; the wallpaper shader is imported straight from
`assets/shaders/pulsar.frag` and compiled into the bundle. Built and deployed
by Cloudflare Workers git integration on push to main (root dir `site`, build
`npm run build`, output `dist`, deploy `npx wrangler deploy`) to the
pulsar-site Worker. Local preview: `cd site && npm run dev`. The OS image
build is a separate workflow and must never be triggered by site edits.

The nightly on the build host commits `site/src/data/changelog.json` and
`site/src/data/manifest.json` (scripts/publish.sh); Astro renders the
changelog list, the manifest card and the hero's build chip from them at
build time. Those two files are the only thing that hookup writes — never
edit them by hand, and never render them anywhere else.

## Capabilities and Constraints

- Astro, static output, zero client framework. The only JavaScript shipped is
  `site/src/scripts/` — theme, tabs, copy buttons, shader — bundled by Astro.
- Global CSS is the design system only (`src/styles/`: tokens, base, the
  terminal family, which crosses component boundaries). Everything else is a
  scoped `<style>` block in the component it belongs to.
- The hero background is `assets/shaders/pulsar.frag` (the actual OS
  wallpaper shader) in WebGL1; uniforms: u_resolution, u_time, u_theme
  (0 dark / 1 dawn), u_look (0 silk / 1 leak / 2 satin / 3 holo). CSS
  ground is the no-WebGL fallback; reduced motion renders a still frame.
- Domain: LLC site is arclight.build; this page will PROBABLY live at
  pulsar.arclight.digital (not final — keep URLs relative and the footer
  ARCLIGHT.BUILD as a text label until confirmed).
- Currently deployed to arclight-digital.github.io/pulsar (subpath — another
  reason relative URLs are mandatory).

## Brand Commitments

- Mark: `assets/brand/pulsar-mark.svg` (dark surfaces) and
  `pulsar-mark-color-dark.svg` (light surfaces — colored arc, dark cores).
  All brand art is authored, in `assets/brand/`.
- Wordmark: PULSAR, Host Grotesk Bold, uppercase, 0.3em tracking.
- Tagline: "Your lighthouse in the sky." (the pulsar-as-cosmic-lighthouse
  metaphor, made personal; replaced "Lighthouses don't drift", which needed
  a decoder ring, which replaced "Fedora with a pulse", retired). Footer
  line: "AN IMMUTABLE FEDORA SPIN · ARCLIGHT.BUILD".
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
with provenance attestations, signed images on ghcr, the shader-rendered
wallpaper set. NO testimonials, user counts, or benchmarks exist — never
fabricate any.

## Product Principles

- The artifact is the pitch: show the real shader, real commands, real CI —
  not stock art or invented claims.
- Honest scope: personal spin first, fork-me second, install-me third.
- The page and the OS share one source of truth (assets/); nothing is
  hand-copied into the site.
- Site changes must stay free: never trigger the OS build pipeline.
