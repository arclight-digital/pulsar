# shellcheck shell=bash
# Part of pulsar (cli/pulsar reads it): pulsar theme and pulsar screen.

# ---------------------------------------------------------------------------
# pulsar theme -- the theme engine is its own program (python: colour maths in
# bash would be the whole file), so this verb is a doorway, not a second
# implementation. Arguments go through untouched, --json and --help included:
# they belong to the engine, not to this CLI's global flag parsing.
# ---------------------------------------------------------------------------
THEME_ENGINE=${PULSAR_THEME_ENGINE:-/usr/libexec/pulsar/pulsar-theme}

theme_usage() {
    cat <<'EOF'
usage: pulsar theme <command>

  list                      the themes, with swatches; * marks the current one
  set <theme>               recolor the desktop: accent, light/dark, GTK4 and
                            GTK3 apps, Ptyxis, btop, Text Editor, the top bar
                            and quick settings, the wallpaper, and coding
                            agents (Claude Code, Gemini CLI, opencode)
    --variant dark|light    pin one variant (default: follow Dark Style)
    --restart | --no-restart
                            open GTK apps keep the old colors until they
                            restart; by default you are asked, once per switch
  next | prev               cycle themes
  bg-next                   cycle the current theme's wallpapers
  current                   what is applied, and what it wrote
  revert [--to image]       back to stock GNOME, or with --to image to
                            the Pulsar image defaults
  audit [theme...]          WCAG contrast checks
  restart-apps [--yes]      list the open GTK apps still showing the
                            previous palette; --yes restarts them
  config [key [value]]      restart-prompt on|off
  import base16 <file|url>  add a base16/base24 scheme as your own theme

The Themes app does this too (Super+T, if the shortcut was free).
The image's themes are in /usr/share/pulsar/themes; yours in
~/.local/share/pulsar/themes.
EOF
}

cmd_theme() {
    case "${1:-}" in
        ""|-h|--help|help) theme_usage; return 0 ;;
    esac
    [ -x "$THEME_ENGINE" ] || die "theme engine not found at ${THEME_ENGINE}"
    exec "$THEME_ENGINE" "$@"
}

# pulsar screen text|qr -- the text or QR code in a part of the screen, onto
# the clipboard. GNOME's screenshot UI picks the area; see
# /usr/libexec/pulsar/pulsar-screen.
SCREEN_TOOL=${PULSAR_SCREEN_TOOL:-/usr/libexec/pulsar/pulsar-screen}

cmd_screen() {
    case "${1:-}" in
        text|qr) [ $# -eq 1 ] || die "usage: pulsar screen text | qr" ;;
        -h|--help|help|"")
            cat <<'EOF'
usage: pulsar screen text    pick an area of the screen; its text goes on
                             the clipboard (English). Super+Print does this,
                             if the shortcut was free
       pulsar screen qr      pick an area; the QR code's contents go on the
                             clipboard. A code that is one http(s) link gets
                             an Open link button
EOF
            return 0 ;;
        *) die "usage: pulsar screen text | qr" ;;
    esac
    [ -x "$SCREEN_TOOL" ] || die "not found: ${SCREEN_TOOL}"
    exec "$SCREEN_TOOL" "$1"
}
