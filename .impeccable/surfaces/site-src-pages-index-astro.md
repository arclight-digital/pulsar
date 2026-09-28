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

## Redesign (2026-09-27): the simple hero and the story order

User brief, pinned: a 100vh hero with the Pulsar logo, one line, and ONE
button, "Get started", anchored to #install; nothing may move when ARC UI
hydrates (measured before: mobile CLS 0.22 from the hero's two code blocks
collapsing on hydration). Sections, in order: a short plain intro; install
(the signed ISO first-class for fresh installs, `bootc switch` for existing
atomic Fedora users); It can't rot; agentic (with the safety stack and its
honest limit); themes; games led by gamescale; changelog; provenance. A /docs
section like ARC UI's. Copy: earnest, short, human-centric (replaces "dry,
technical"); never name or allude to other distros. Built code-led: no image
generation this session.

## Direction contract

THESIS: A calm front door. The hero is the brand and one action, nothing
else; the page then reads like a person explaining their computer to a
friend, in the order a visitor's questions arrive: what is it, how do I get
it, will it break, what does it do for me.
OWN-WORLD: the established world unchanged: ink ground, the live wallpaper
shader, Host Grotesk with JetBrains Mono for anything a machine wrote, ARC UI
components under the two-color contract, hairline-ruled lists, glow over
outline, terminals pinned dark.
STORY: the visitor learns it is a desktop that looks after itself, installs it
from the ISO (or switches), trusts it because it can roll itself back, and
wants it for the agent, the themes and the games; the ledger and the paper
trail close as proof.
FIRST VIEWPORT: the shader fills 100svh; centered, the animated mark at hero
scale over the PULSAR wordmark, the line "Stylish, atomic, agentic." beneath,
one primary arc-button "Get started" under it; the look picker quiet at the
bottom edge; the top bar transparent above. No build chip, no commands.
FORM: user-pinned structure (precise brief; no concept roll run, per
new-work 3 for a precisely specified surface). Seed: none.
FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
