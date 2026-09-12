---
version: 1
slug: "site-src-pages-index-astro"
primary_target: "site/src/pages/index.astro"
related_targets: ["site/src/pages/install.astro","site/src/pages/gamescale.astro","site/src/pages/provenance.astro","site/src/pages/changelog.astro","site/src/pages/cli.astro"]
---

# Surface: / (home) — Persuade

Scope: the Pulsar home page, redesigned on ARC UI v4.2.2 web components (SSR'd declarative shadow DOM + Lit hydration). Part of a six-route site: / · /install · /gamescale · /provenance · /changelog · /cli. The five inner routes are Read surfaces that inherit this one's world and chrome.

Audience and job: a visitor evaluating the maintainer's work decides in one viewport that this is real, alive, and inspectable; a Silverblue user finds the install command or the ISO without scrolling past the proof.

Action: the primary action is `bootc switch` (copy), secondary the weekly ISO; both live on /install and are surfaced from the hero as one command row plus a link.

Proof/content: all real. The nightly's changelog.json and manifest.json (committed by the build host), the beacon's live registry check, the shader, the attestation verify command, the ISO sidecars and cosign key. No testimonials, counts, or benchmarks exist; none are shown.

Constraints: Pulsar palette through ARC's two-color contract (accent-primary cyan #3ECBFF, accent-secondary periwinkle #8FA8FF on dark; violet #4B3FD4 on light), Host Grotesk and JetBrains Mono in the font roles, the wallpaper shader owns the hero background, dark is the default. ARC's own rules bind: no colored left borders for state, tokens not literals, glow over outline, motion motivated. Everything renders without JS; the beacon is the only network call. Never touch site/src/data/*.json.

Chosen direction (surface seed a91dc502, candidate 4 of 7, user-approved 2026-09-12): DIFF FIRST. The hero's content is tonight's real diff: the lead transition, the arithmetic sentence, the from→to digest pair, the build chip live-checked by the beacon. The page then answers, in order: why that diff can be trusted (pipeline rail + attest command), what it runs (gamescale as first chapter, then the stack against the manifest readout), how to get it (install row, ISO row), and closes on the full changelog ledger.

Memorable moment: the shader field behind a live package diff; a first-time visitor sees the OS change before they read what it is.

Unresolved: whether the deck's four wallpaper looks stay as hero controls on inner routes (decided: home only). No image comps were generated (no image tool this session); the build is inspected by screenshot instead.

## Finish (2026-09-12)

Finish review disposition: **ship**. Material findings (hero opener stack,
code-block titles escaping their frames, gamescale page repeating its
sentence) resolved; cosmetic items left open: nav pills and the secondary
button are outline-first where ARC prefers glow; the ledger chevron icon was
unverified in the reviewer's captures. No comps were generated (no image tool
this session); the build was inspected by screenshot in two rounds.

## Revision (2026-09-12, later)

The user saw the diff-first hero and rejected it ("why is gamescale central" —
the lead package happened to be gamescope). The hero is the identity hero
again: 180px animated mark with the flywheel easter egg, PULSAR wordmark with
ARC's bloom twin, tagline, one sentence, build chip, the two install commands.
The diff is the first chapter under the hero, not the hero. Also: tighter
chapter rhythm, ARC's line-gradient rule under every h2, glow hairlines between
chapters, arc-badge tags in the ledger, an arc-cta-banner close on the home
page, page-header borders on inner routes.
