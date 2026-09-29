#!/usr/bin/python3
"""Builds the classic themes' theme.toml files from their upstream palettes.

This is the hand-tuning, written down. Each theme starts from a published
base16/base24 scheme (tinted-theming/schemes, MIT, vendored in
assets/themes/imports/ so a rebuild never depends on the network) or from
the upstream project's own palette where no faithful base16 port exists,
then:

  1. slot fixes -- base16 slot meanings are convention, and ports break them
     (Tokyo Night's base08 "red" is a pale blue-white). Every fix is listed
     below with the upstream name of the colour it restores;
  2. the theme's own terminal mapping where upstream publishes one (Rose
     Pine's green is pine, by Rose Pine's own terminal ports);
  3. a contrast floor, applied mechanically and reported: every hue used as
     text (syntax, ANSI 1-6/9-14, btop) must clear 4.5:1 on the background,
     comments 3:1. The fit moves OKLab lightness only, so hue and chroma --
     the identity of the colour -- stay; it mostly bites pastel-on-paper
     light variants (Nord light's aurora, Rose Pine Dawn's gold);
  4. surfaces, accent and wallpaper renders, chosen per theme.

  scripts/build-themes.py            rewrite system_files/.../themes/<slug>/theme.toml
  scripts/build-themes.py --report   only print the contrast fixes

Run by hand when a palette changes, and the result committed: the build
never runs this, it ships the generated files. Pulsar and Pulsar Holo are not
in the table -- they are written by hand from DESIGN.md.
"""
import json
import pathlib
import sys



REPO = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))
import pulsar_theme_engine  # noqa: E402

pt = pulsar_theme_engine.load()
IMP = REPO / "assets" / "themes" / "imports"
OUT = REPO / "system_files" / "usr" / "share" / "pulsar" / "themes"

HUES = ["red", "orange", "yellow", "green", "cyan", "blue", "magenta"]
BRIGHT = ["bright_red", "bright_yellow", "bright_green", "bright_cyan", "bright_blue", "bright_magenta"]


def b16(name):
    y = pt.parse_flat_yaml((IMP / f"{name}.yaml").read_text())
    pal = y.get("palette") if isinstance(y.get("palette"), dict) else y
    return pt.base16_to_palette(pal), y


def V(src=None, pal=None, drop=(), **over):
    return dict(src=src, pal=pal or {}, drop=drop, over=over)


def R(variant, look, **kw):
    return dict(variant=variant, look=look, **kw)


# --------------------------------------------------------------------------
THEMES = [
    dict(slug="catppuccin", name="Catppuccin", author="Catppuccin (catppuccin.com), MIT",
         prefer="dark",
         dark=V("base24-catppuccin-mocha", accent="#cba6f7",
                background_deep="#11111b", background_sunken="#181825", window="#1e1e2e", view="#181825",
                headerbar="#181825", sidebar="#181825", card="#262637", popover="#313244"),
         light=V("base24-catppuccin-latte", drop=("background_deep", "background_sunken"), accent="#8839ef",
                 background_deep="#dce0e8", background_sunken="#e6e9ef", window="#eff1f5", view="#f7f8fa",
                 headerbar="#e6e9ef", sidebar="#e6e9ef", card="#f7f8fa", popover="#ffffff"),
         renders=[
             # pastel foil is the Catppuccin mood: mauve | pink | sapphire | teal
             R("dark", "holo", c1="magenta", c4="bright_magenta", c2="bright_blue", c3="cyan",
               gain=1.25, stars=0.8, desat=0.0),
             R("light", "holo", c1="magenta", c4="bright_magenta", c2="blue", c3="cyan", wash=0.42, gain=0.9,
               dawn_bottom="#eff1f5", dawn_top="#dce0e8"),
             R("dark", "silk", c1="magenta", c2="blue", c3="bright_magenta", seed=[2.4, -1.1], stars=0.6, desat=0.0, gain=1.35),
             R("light", "silk", c1="magenta", c2="blue", c3="bright_magenta", seed=[2.4, -1.1], wash=0.3, stars=0.4),
         ]),

    dict(slug="gruvbox", name="Gruvbox", author="Pavel Pertsev (morhetz), MIT", prefer="dark",
         # bright set as the main hues (what gruvbox.vim uses on dark);
         # blue #83a598 reads teal but IS gruvbox's blue -- kept on purpose
         dark=V("base24-gruvbox-dark", red="#fb4934", green="#b8bb26", yellow="#fabd2f", blue="#83a598",
                magenta="#d3869b", cyan="#8ec07c", orange="#fe8019", accent="#fe8019",
                bright_red="#fb4934", bright_green="#b8bb26", bright_yellow="#fabd2f", bright_blue="#83a598",
                bright_magenta="#d3869b", bright_cyan="#8ec07c",
                background_deep="#1d2021", background_sunken="#1d2021", window="#282828", view="#1d2021",
                headerbar="#32302f", sidebar="#282828", card="#32302f", popover="#3c3836"),
         # faded set on paper, as gruvbox.vim does on light
         light=V("base24-gruvbox-light", drop=("background_deep", "background_sunken"),
                 red="#9d0006", green="#79740e", yellow="#b57614", blue="#076678", magenta="#8f3f71",
                 cyan="#427b58", orange="#af3a03", accent="#af3a03",
                 bright_red="#cc241d", bright_green="#98971a", bright_yellow="#d79921", bright_blue="#458588",
                 bright_magenta="#b16286", bright_cyan="#689d6a",
                 background_deep="#ebdbb2", background_sunken="#f2e5bc", window="#fbf1c7", view="#f9f5d7",
                 headerbar="#f2e5bc", sidebar="#f2e5bc", card="#f9f5d7", popover="#f9f5d7"),
         renders=[
             # warm cloth: an ember bloom low on the left, no stars (gruvbox is
             # earth, not sky)
             R("dark", "satin", c1="red", c2="orange", c3="yellow", bloom=[-0.35, -0.18], stars=0, desat=0.1),
             R("light", "satin", c1="orange", c2="yellow", c3="yellow", bloom=[-0.35, -0.18], wash=0.35,
               dawn_bottom="#fbf1c7", dawn_top="#ebdbb2"),
             R("dark", "leak", c1="red", c2="orange", c3="yellow", beam=-0.22, stars=0, desat=0.2),
             R("light", "leak", c1="red", c2="orange", c3="#fabd2f", beam=-0.22, wash=0.45,
               dawn_bottom="#fbf1c7", dawn_top="#ebdbb2"),
         ]),

    dict(slug="tokyo-night", name="Tokyo Night", author="enkia (Tokyo Night), MIT", prefer="dark",
         # the base16 port's hue slots are shuffled; these are upstream's Night
         dark=V("base16-tokyo-night-dark", foreground="#c0caf5", foreground_dim="#a9b1d6", muted="#565f89",
                red="#f7768e", orange="#ff9e64", yellow="#e0af68", green="#9ece6a", cyan="#7dcfff",
                blue="#7aa2f7", magenta="#bb9af7", accent="#7aa2f7",
                background_deep="#16161e", background_sunken="#16161e", window="#1a1b26", view="#16161e",
                headerbar="#1f2335", sidebar="#16161e", card="#1f2335", popover="#24283b"),
         # and upstream's Day, which has no faithful base16 port at all
         light=V(pal=dict(background="#e1e2e7", foreground="#3760bf", foreground_dim="#6172b0", muted="#848cb5",
                          selection="#b7c1e3", red="#f52a65", orange="#b15c00", yellow="#8c6c3e", green="#587539",
                          cyan="#007197", blue="#2e7de9", magenta="#9854f1", brown="#8c6c3e"),
                 accent="#2e7de9", background_deep="#d0d5e3", background_sunken="#d8dbe5", window="#e1e2e7",
                 view="#e9e9ed", headerbar="#d8dbe5", sidebar="#d8dbe5", card="#e9e9ed", popover="#f0f0f3",
                 background_raised="#d8dbe5"),
         renders=[
             # neon through rain: leak beams in magenta / blue / cyan
             R("dark", "leak", c1="magenta", c2="blue", c3="cyan", beam=-0.42, stars=0.35),
             R("light", "leak", c1="magenta", c2="blue", c3="cyan", beam=-0.42, wash=0.45,
               dawn_bottom="#e1e2e7", dawn_top="#d0d5e3"),
             R("dark", "silk", c1="magenta", c2="blue", c3="cyan", seed=[4.0, 2.0], stars=0.5, desat=0.0, gain=1.4),
             R("light", "silk", c1="magenta", c2="blue", c3="cyan", seed=[4.0, 2.0], wash=0.35, stars=0.3),
         ]),

    dict(slug="nord", name="Nord", author="Arctic Ice Studio, MIT", prefer="dark",
         dark=V("base16-nord", accent="#88c0d0", muted="#616e88",
                background_deep="#242933", background_sunken="#272c36", window="#2e3440", view="#292e39",
                headerbar="#3b4252", sidebar="#2e3440", card="#3b4252", popover="#3b4252"),
         # Nord ships no light theme; this is Nord's own Snow Storm + Aurora
         # used light, via the community nord-light port, contrast-fitted
         light=V("base16-nord-light", accent="#5e81ac", muted="#7b88a1", selection="#d8dee9",
                 background="#eceff4", background_raised="#e5e9f0",
                 background_deep="#d8dee9", background_sunken="#e5e9f0", window="#eceff4", view="#f4f6f9",
                 headerbar="#e5e9f0", sidebar="#e5e9f0", card="#f4f6f9", popover="#f7f9fb"),
         renders=[
             # aurora: frost blue -> frost cyan -> aurora green, under stars
             R("dark", "silk", c1="#5e81ac", c2="cyan", c3="green", seed=[-2.5, 1.4], dir=[-1.0, -0.25],
               fold=1.9, stars=1.0, down=0.10, desat=0.0, gain=1.5),
             R("light", "silk", c1="#5e81ac", c2="#88c0d0", c3="#a3be8c", seed=[-2.5, 1.4], dir=[-1.0, -0.25],
               fold=1.9, wash=0.0, gain=1.7, stars=0.25, dawn_bottom="#eceff4", dawn_top="#d8dee9"),
             R("dark", "satin", c1="#5e81ac", c2="blue", c3="cyan", bloom=[-0.30, -0.22], stars=0, desat=0.0),
             R("light", "satin", c1="#5e81ac", c2="#81a1c1", c3="#88c0d0", bloom=[-0.30, -0.22], wash=0.15,
               dawn_bottom="#eceff4", dawn_top="#d8dee9"),
         ]),

    dict(slug="rose-pine", name="Rosé Pine", author="Rosé Pine (rosepinetheme.com), MIT", prefer="dark",
         # Rose Pine's own terminal mapping: green = pine, blue = foam,
         # magenta = iris, cyan = rose (the base16 port put gold in magenta)
         dark=V("base16-rose-pine", red="#eb6f92", yellow="#f6c177", green="#31748f", blue="#9ccfd8",
                magenta="#c4a7e7", cyan="#ebbcba", orange="#ebbcba", accent="#c4a7e7", muted="#6e6a86",
                foreground_dim="#908caa", selection="#403d52",
                background_deep="#12101a", background_sunken="#16141f", window="#191724", view="#16141f",
                headerbar="#1f1d2e", sidebar="#1f1d2e", card="#1f1d2e", popover="#26233a"),
         light=V("base16-rose-pine-dawn", red="#b4637a", yellow="#ea9d34", green="#286983", blue="#56949f",
                 magenta="#907aa9", cyan="#d7827e", orange="#d7827e", accent="#907aa9", muted="#9893a5",
                 foreground_dim="#797593", selection="#dfdad9",
                 background_deep="#f2e9e1", background_sunken="#f4ede8", window="#faf4ed", view="#fffaf3",
                 headerbar="#f2e9e1", sidebar="#f4ede8", card="#fffaf3", popover="#fffaf3"),
         renders=[
             R("dark", "silk", c1="magenta", c2="red", c3="yellow", seed=[1.7, -3.0], dir=[-0.5, -0.9],
               stars=0.3, desat=0.0, gain=1.6),
             R("light", "silk", c1="#907aa9", c2="#d7827e", c3="#ea9d34", seed=[1.7, -3.0], dir=[-0.5, -0.9],
               wash=0.35, stars=0.2, dawn_bottom="#faf4ed", dawn_top="#f2e9e1"),
             R("dark", "leak", c1="magenta", c2="#eb6f92", c3="yellow", beam=-0.30, stars=0.2),
             R("light", "leak", c1="#907aa9", c2="#b4637a", c3="#ea9d34", beam=-0.30, wash=0.45,
               dawn_bottom="#faf4ed", dawn_top="#f2e9e1"),
         ]),

    dict(slug="everforest", name="Everforest", author="sainnhe, MIT", prefer="dark",
         dark=V("base16-everforest", accent="#a7c080", brown="#9da9a0",
                background_deep="#232a2e", background_sunken="#272e33", window="#2d353b", view="#272e33",
                headerbar="#343f44", sidebar="#2d353b", card="#343f44", popover="#3d484d"),
         light=V("base16-everforest-light-medium", accent="#8da101", brown="#829181",
                 background_deep="#efebd4", background_sunken="#f4f0d9", window="#fdf6e3", view="#fffbef",
                 headerbar="#f4f0d9", sidebar="#f4f0d9", card="#fffbef", popover="#fffbef"),
         renders=[
             # mist over a forest floor: light rising from the bottom, no stars
             R("dark", "silk", c1="cyan", c2="green", c3="green~yellow@0.4", seed=[6.0, 1.0], dir=[0.1, -1.0], fold=2.0,
               stars=0, desat=0.0, gain=1.8, down=0.08),
             R("light", "silk", c1="#35a77c", c2="#8da101", c3="#dfa000", seed=[6.0, 1.0], dir=[0.1, -1.0], fold=2.0,
               wash=0.2, gain=1.3, stars=0, dawn_bottom="#fdf6e3", dawn_top="#efebd4"),
             R("dark", "satin", c1="green", c2="cyan", c3="green", bloom=[-0.25, -0.30], stars=0, desat=0.05),
             R("light", "satin", c1="#8da101", c2="#35a77c", c3="#8da101", bloom=[-0.25, -0.30], wash=0.3,
               dawn_bottom="#fdf6e3", dawn_top="#efebd4"),
         ]),

    dict(slug="kanagawa", name="Kanagawa", author="rebelot (kanagawa.nvim), MIT", prefer="dark",
         # Wave from the base16 port with upstream's brighter wave hues for text
         dark=V("base16-kanagawa", red="#e46876", yellow="#e6c384", green="#98bb6c", cyan="#7aa89f",
                blue="#7e9cd8", magenta="#957fb8", orange="#ffa066", accent="#7e9cd8", foreground_bright="#dcd7ba",
                background_deep="#16161d", background_sunken="#181820", window="#1f1f28", view="#1a1a22",
                headerbar="#2a2a37", sidebar="#1f1f28", card="#2a2a37", popover="#363646"),
         # Lotus: upstream's light palette, no base16 port exists
         light=V(pal=dict(background="#f2ecbc", foreground="#545464", foreground_dim="#43436c", muted="#8a8980",
                          selection="#c9cbd1", red="#c84053", orange="#cc6d00", yellow="#77713f", green="#6f894e",
                          cyan="#597b75", blue="#4d699b", magenta="#624c83", brown="#836f4a"),
                 accent="#4d699b", background_deep="#e4d794", background_sunken="#e7dba0", window="#f2ecbc",
                 view="#f7f3d6", headerbar="#e7dba0", sidebar="#e5ddb0", card="#f7f3d6", popover="#f7f3d6",
                 background_raised="#e5ddb0"),
         renders=[
             # the wave: big slow folds in wave blue and violet, a carp-gold crest
             R("dark", "silk", c1="magenta", c2="blue", c3="yellow", seed=[9.0, -4.0], fold=1.7, dir=[-0.9, -0.4],
               stars=0.25, desat=0.0, gain=2.4),
             R("light", "silk", c1="#624c83", c2="#4d699b", c3="#cc6d00", seed=[9.0, -4.0], fold=1.7,
               dir=[-0.9, -0.4], wash=0.15, gain=1.5, stars=0.15, dawn_bottom="#f2ecbc", dawn_top="#e4d794"),
             R("dark", "leak", c1="red", c2="orange", c3="yellow", beam=-0.28, stars=0.2),
             R("light", "leak", c1="#c84053", c2="#cc6d00", c3="#e6c384", beam=-0.28, wash=0.35,
               dawn_bottom="#f2ecbc", dawn_top="#e4d794"),
         ]),

    dict(slug="solarized", name="Solarized", author="Ethan Schoonover, MIT", prefer="dark",
         dark=V("base16-solarized-dark", accent="#268bd2", foreground="#93a1a1", muted="#657b83",
                selection="#073642",
                background_deep="#00212b", background_sunken="#002530", window="#002b36", view="#00252f",
                headerbar="#073642", sidebar="#002b36", card="#073642", popover="#073642"),
         light=V("base16-solarized-light", accent="#268bd2", foreground="#586e75", muted="#93a1a1",
                 selection="#eee8d5",
                 background_deep="#eee8d5", background_sunken="#f5efdc", window="#fdf6e3", view="#fffbef",
                 headerbar="#eee8d5", sidebar="#f5efdc", card="#fffbef", popover="#fffbef"),
         renders=[
             R("dark", "satin", c1="blue", c2="cyan", c3="cyan", bloom=[-0.10, -0.25], stars=0, desat=0.0),
             R("light", "satin", c1="blue", c2="cyan", c3="cyan", bloom=[-0.10, -0.25], wash=0.3,
               dawn_bottom="#fdf6e3", dawn_top="#eee8d5"),
             R("dark", "leak", c1="magenta", c2="blue", c3="cyan", beam=-0.35, stars=0.3),
             R("light", "leak", c1="magenta", c2="blue", c3="cyan", beam=-0.35, wash=0.55,
               dawn_bottom="#fdf6e3", dawn_top="#eee8d5"),
         ]),

    # Two CRT terminals, dark only by nature. A literally monochrome palette
    # would make red errors and green success the same colour, so every ANSI
    # slot keeps its meaning and is only PULLED toward the phosphor: the
    # warm hues stay recognisably warm, desaturated toward the tint. The
    # contrast fit below then holds all of them to the usual floors.
    dict(slug="phosphor", name="Phosphor", author="Pulsar; after P1 green-phosphor terminals", prefer="dark",
         shell_glow=True,
         dark=V(pal=dict(background="#050a06", foreground="#5dff8a", foreground_dim="#3fc46a", muted="#2f7a45",
                         selection="#0f3a1c", accent="#33ff66",
                         red="#e38a6d", orange="#e0b55c", yellow="#c8ff5c", green="#33ff66", cyan="#66ffd0",
                         blue="#57c8e0", magenta="#cf94b8", brown="#a8a060",
                         bright_red="#f0a080", bright_yellow="#dcff85", bright_green="#8affaa",
                         bright_cyan="#99ffe0", bright_blue="#85dcee", bright_magenta="#e0b0cc"),
                background_deep="#020503", background_sunken="#030704", window="#07100a", view="#040a06",
                headerbar="#0b1a10", sidebar="#07100a", card="#0b1a10", popover="#0f2416",
                background_raised="#0b1a10"),
         renders=[
             # plasma in a phosphor tube: the strongest treatment of any theme
             R("dark", "silk", c1="#06351a", c2="#1f9e48", c3="bright_green", seed=[7.3, -1.9], fold=2.0,
               dir=[-0.9, -0.5], stars=0.0, desat=0.15, gain=0.95, glow=1.15, signal=1.4, down=0.04),
             R("dark", "leak", c1="#0f5a2a", c2="green", c3="yellow", beam=-0.25, stars=0.0, desat=0.0,
               glow=1.15, signal=1.4, seed=[2.2, 5.4], web=0.8),
         ]),

    dict(slug="amber", name="Amber", author="Pulsar; after P3 amber-phosphor terminals", prefer="dark",
         shell_glow=True,
         dark=V(pal=dict(background="#0a0703", foreground="#ffb000", foreground_dim="#c98a14", muted="#8a6420",
                         selection="#3a2608", accent="#ffb000",
                         red="#ff6a3d", orange="#ff8c1a", yellow="#ffd24a", green="#b8c94a", cyan="#a8d4b0",
                         blue="#a3b8cc", magenta="#e38aa0", brown="#b08040",
                         bright_red="#ff8f66", bright_yellow="#ffe07a", bright_green="#d0de70",
                         bright_cyan="#c4e6cc", bright_blue="#c0d0e0", bright_magenta="#f0aabc"),
                background_deep="#050301", background_sunken="#070502", window="#0e0a04", view="#080602",
                headerbar="#1a1207", sidebar="#0e0a04", card="#1a1207", popover="#241a0a",
                background_raised="#1a1207"),
         renders=[
             R("dark", "leak", c1="#7a3a00", c2="orange", c3="#ffc84a", beam=-0.20, stars=0.0, desat=0.0,
               glow=1.15, signal=1.4, seed=[-4.1, 3.3], web=0.8),
             R("dark", "silk", c1="#6a3000", c2="orange", c3="yellow", seed=[-6.2, 2.7], fold=1.9,
               dir=[-0.7, -0.8], stars=0.0, desat=0.0, gain=1.6, glow=1.15, signal=1.4, down=0.06),
         ]),

    dict(slug="alucard", name="Alucard", author="Dracula Theme (draculatheme.com), MIT", prefer="light",
         # Dracula's light theme, from the Dracula spec (draculatheme.com/spec):
         # light only, its own theme, and it sets Light Style when chosen.
         # No base16 port, so by hand; the contrast fit below does the rest.
         light=V(pal=dict(background="#fffbeb", foreground="#1f1f1f", muted="#6c664b", selection="#cfcfde",
                          red="#cb3a2a", orange="#a34d14", yellow="#846e15", green="#14710a", cyan="#036a96",
                          blue="#644ac9", magenta="#a3144d", brown="#6c664b", foreground_dim="#4f4b38"),
                 accent="#644ac9", background_deep="#ece7d5", background_sunken="#f4efdd", window="#fffbeb",
                 view="#fffdf5", headerbar="#f4efdd", sidebar="#f4efdd", card="#fffdf5", popover="#ffffff",
                 background_raised="#f4efdd"),
         renders=[
             R("light", "leak", c1="#644ac9", c2="#a3144d", c3="#036a96", beam=-0.40, wash=0.4,
               dawn_bottom="#fffbeb", dawn_top="#ece7d5"),
             R("light", "silk", c1="#644ac9", c2="#a3144d", c3="#036a96", seed=[1.1, -2.6], fold=1.8,
               dir=[-1.0, -0.1], wash=0.3, gain=1.4, stars=0.2, dawn_bottom="#fffbeb", dawn_top="#ece7d5"),
         ]),

    dict(slug="dracula", name="Dracula", author="Dracula Theme (draculatheme.com), MIT", prefer="dark",
         # Dracula's own ANSI: blue slot is purple, magenta is pink. Dark only,
         # as upstream ships it; its light counterpart is Alucard (the entry above), a
         # separate theme on purpose -- choosing one is choosing its mood,
         # not a variant that flips with Dark Style.
         dark=V("base24-dracula", accent="#bd93f9",
                background_deep="#191a21", background_sunken="#1e1f29", window="#282a36", view="#21222c",
                headerbar="#21222c", sidebar="#21222c", card="#343746", popover="#343746"),
         renders=[
             R("dark", "leak", c1="blue", c2="magenta", c3="cyan", beam=-0.40, stars=0.5, desat=0.0),
             R("dark", "silk", c1="blue", c2="magenta", c3="cyan", seed=[1.1, -2.6], fold=1.8, dir=[-1.0, -0.1], stars=0.7, desat=0.0, gain=2.3),
         ]),

    dict(slug="flexoki", name="Flexoki", author="Steph Ango (stephango.com/flexoki), MIT", prefer="dark",
         dark=V("base16-flexoki-dark", accent="#4385be", muted="#878580",
                background_deep="#0b0a0a", background_sunken="#100f0f", window="#100f0f", view="#0b0a0a",
                headerbar="#1c1b1a", sidebar="#1c1b1a", card="#1c1b1a", popover="#282726"),
         light=V("base16-flexoki-light", accent="#205ea6", muted="#6f6e69",
                 background_deep="#e6e4d9", background_sunken="#f2f0e5", window="#fffcf0", view="#fffcf0",
                 headerbar="#f2f0e5", sidebar="#f2f0e5", card="#ffffff", popover="#ffffff"),
         renders=[
             # ink on paper: cloth weave, blue/cyan ink with an orange fleck
             R("dark", "satin", c1="blue", c2="cyan", c3="cyan", bloom=[-0.30, -0.20], stars=0, desat=0.0),
             R("light", "satin", c1="blue", c2="cyan", c3="cyan", bloom=[-0.30, -0.20], wash=0.35,
               dawn_bottom="#fffcf0", dawn_top="#e6e4d9"),
             R("dark", "silk", c1="magenta", c2="orange", c3="yellow", seed=[-5.0, 3.0], stars=0, desat=0.05, gain=1.3),
             R("light", "silk", c1="magenta", c2="orange", c3="yellow", seed=[-5.0, 3.0], wash=0.25, gain=1.2, stars=0),
         ]),

    dict(slug="ayu", name="Ayu", author="Ike Ku (ayu-theme), MIT", prefer="dark",
         dark=V("base16-ayu-dark", accent="#e6b450", muted="#5c6773",
                background_deep="#07090d", background_sunken="#0b0e14", window="#0b0e14", view="#0d1017",
                headerbar="#131721", sidebar="#0d1017", card="#131721", popover="#1a1f29"),
         light=V("base16-ayu-light", accent="#fa8d3e", muted="#8a9199",
                 background_deep="#e7eaed", background_sunken="#f0f2f4", window="#f8f9fa", view="#fcfcfc",
                 headerbar="#edeff1", sidebar="#f0f2f4", card="#fcfcfc", popover="#ffffff"),
         renders=[
             # a low sun: warm beams from the left over near-black
             R("dark", "leak", c1="red", c2="orange", c3="yellow", beam=-0.18, stars=0.3),
             R("light", "leak", c1="#f07171", c2="#fa8d3e", c3="#ffb454", beam=-0.18, wash=0.3,
               dawn_bottom="#f8f9fa", dawn_top="#e7eaed"),
             R("dark", "silk", c1="red", c2="orange", c3="yellow", seed=[3.3, 5.1], stars=0.3, desat=0.0, gain=1.3),
             R("light", "silk", c1="#f07171", c2="#fa8d3e", c3="#ffb454", seed=[3.3, 5.1], wash=0.2, stars=0.2),
         ]),
]

FLOORS = {"hue": 4.55, "bright": 3.05, "muted": 3.05, "foreground_dim": 4.55}


def build_variant(spec, mode):
    pal = {}
    src = None
    if spec["src"]:
        pal, src = b16(spec["src"])
    for k in spec["drop"]:
        pal.pop(k, None)
    pal.update(spec["pal"])
    pal.update(spec["over"])
    # resolve derived values once so the fit sees what the engine will see
    v = pt.Variant(mode, pal)
    bg = v["background"]
    fixes = []
    # write every key out: the file is the complete, reviewable palette
    out = {k: v[k].hex for k in pt.PALETTE_KEYS + pt.SURFACE_KEYS}
    for k in HUES + ["brown"]:
        c = v[k]
        n = pt.fit_contrast(c, bg, FLOORS["hue"])
        if n.hex != c.hex:
            fixes.append(f"{k} {c.hex}->{n.hex} ({c.contrast(bg):.1f}->{n.contrast(bg):.1f})")
        out[k] = n.hex
    for k in BRIGHT:
        c = pt.Color.parse(out[k])
        n = pt.fit_contrast(c, bg, FLOORS["bright"])
        if n.hex != c.hex:
            fixes.append(f"{k} {c.hex}->{n.hex}")
        out[k] = n.hex
    for k in ("muted", "foreground_dim"):
        c = v[k]
        n = pt.fit_contrast(c, bg, FLOORS[k])
        if n.hex != c.hex:
            fixes.append(f"{k} {c.hex}->{n.hex} ({c.contrast(bg):.1f}->{n.contrast(bg):.1f})")
        out[k] = n.hex
    # UI floors: re-resolve with the fitted palette, then fix surfaces
    C = pt.Color.parse
    def fg_min():
        return min(C(out["foreground"]).contrast(C(out[k])) for k in
                   ("window", "view", "card", "popover", "background_deep", "headerbar"))
    if fg_min() < 4.55:
        worst = min(("window", "view", "card", "popover", "background_deep", "headerbar"),
                    key=lambda k: C(out["foreground"]).contrast(C(out[k])))
        n = pt.fit_contrast(C(out["foreground"]), C(out[worst]), 4.6)
        fixes.append(f"foreground {out['foreground']}->{n.hex} (vs {worst})"); out["foreground"] = n.hex
    sel = C(out["selection"])
    if C(out["foreground"]).contrast(sel) < 4.55:
        for i in range(1, 21):
            cand = sel.mix(C(out["background"]), i / 20)
            if C(out["foreground"]).contrast(cand) >= 4.6:
                break
        fixes.append(f"selection {out['selection']}->{cand.hex}"); out["selection"] = cand.hex
    acc = C(out["accent"])
    for surf in ("popover", "window"):
        n = pt.fit_contrast(acc, C(out[surf]), 3.05)
        if n.hex != acc.hex:
            fixes.append(f"accent {acc.hex}->{n.hex} (UI 3:1 vs {surf})"); acc = n
    out["accent"] = acc.hex
    return out, (src or {}), fixes


def toml_value(v):
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, list):
        return "[" + ", ".join(toml_value(x) for x in v) + "]"
    return repr(v)


def main():
    report_only = "--report" in sys.argv
    for t in THEMES:
        lines = [f"# GENERATED by scripts/build-themes.py -- edit the table there, not this file.",
                 f'name = "{t["name"]}"', f'author = "{t["author"]}"', f'prefer = "{t["prefer"]}"']
        srcs = []
        for mode in ("dark", "light"):
            if mode not in t:
                continue
            out, src, fixes = build_variant(t[mode], mode)
            srcs.append(f'{mode}: {t[mode]["src"] or "upstream palette, by hand"}')
            print(f"{t['slug']:12} {mode:5} contrast fixes: {'; '.join(fixes) or 'none'}")
            lines.append("")
            lines.append(f"[{mode}]")
            for k in pt.PALETTE_KEYS + pt.SURFACE_KEYS:
                if k in out:
                    lines.append(f'{k} = "{out[k]}"')
        lines.insert(3, f'source = "{"; ".join(srcs)}"')
        if t.get("shell_glow"):
            # the Shell's text glows like the phosphor while Lighting is on
            lines.insert(5, "shell_glow = true")
        lines.append("")
        lines.append("[wallpaper]")
        for mode in ("dark", "light"):
            # .jxl: rendered as PNG on the builder, converted in the Containerfile
            files = [f"backgrounds/{r['look']}-{mode}.jxl" for r in t["renders"] if r["variant"] == mode]
            if files:
                lines.append(f"{mode} = {toml_value(files)}")
        for r in t["renders"]:
            lines.append("")
            lines.append("[[wallpaper.render]]")
            for k, v in r.items():
                lines.append(f"{k} = {toml_value(v)}")
        if not report_only:
            d = OUT / t["slug"]
            d.mkdir(parents=True, exist_ok=True)
            (d / "theme.toml").write_text("\n".join(lines) + "\n")
            pt.Theme(d / "theme.toml")


if __name__ == "__main__":
    main()
