"""The theme card, shared by the picker and the welcome app.

Each card wears its own theme: the wallpaper that theme ships, its palette as
dots over the picture, and a caption band painted in that theme's background
and text colours -- so the grid previews every theme at once rather than
showing sixteen copies of whichever one is applied.

    import pulsar_theme_cards as cards
    cards.install_css()
    card = cards.ThemeCard(pt, theme, current=True)

`pt` is the engine module (pulsar_theme_engine.load). Wallpapers are JPEG XL,
which GTK's own loaders cannot read: they go through gdk-pixbuf (glycin), at
card size, off the main thread, and fade in when ready.
"""
import threading

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # noqa: E402

THUMB_W = 640
DOTS = ("accent", "red", "orange", "yellow", "green", "cyan", "blue", "magenta")

CSS = """
flowboxchild.pt-child { padding: 0; border-radius: 18px; background: none; outline: none; }
flowboxchild.pt-child:selected { background: none; }
.pt-card { border-radius: 16px; box-shadow: 0 1px 2px rgba(0,0,0,.18), 0 6px 18px rgba(0,0,0,.14);
           transition: box-shadow 160ms ease-out; }
flowboxchild.pt-child:hover .pt-card { box-shadow: 0 0 0 2px alpha(currentColor, .25), 0 10px 26px rgba(0,0,0,.22); }
flowboxchild.pt-child:focus-visible .pt-card,
flowboxchild.pt-child:selected:focus-within .pt-card,
flowboxchild.pt-child:selected .pt-card { box-shadow: 0 0 0 3px var(--accent-bg-color), 0 10px 26px rgba(0,0,0,.22); }
.pt-wall { border-radius: 16px 16px 0 0; opacity: 0; transition: opacity 260ms ease-out; }
.pt-wall.loaded { opacity: 1; }
.pt-dots { margin: 10px; padding: 5px 7px; border-radius: 999px; background: rgba(0,0,0,.38); }
.pt-dot { min-width: 12px; min-height: 12px; border-radius: 999px; box-shadow: inset 0 0 0 1px rgba(255,255,255,.22); }
.pt-badge { margin: 10px; padding: 3px 10px; border-radius: 999px; font-weight: 700; font-size: 0.82em; }
.pt-band { border-radius: 0 0 16px 16px; padding: 12px 14px 13px; }
.pt-name { font-weight: 800; font-size: 1.08em; }
.pt-meta { font-size: 0.86em; }
.pt-chip { padding: 1px 8px; border-radius: 999px; font-size: 0.78em; font-weight: 700; }
.pt-busy { border-radius: 16px; background: rgba(0,0,0,.45); }
"""

_installed = False


def install_css():
    global _installed
    if _installed:
        return
    prov = Gtk.CssProvider()
    prov.load_from_string(CSS)
    Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                              Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    _installed = True


def mode_for(pt, th):
    """The variant to preview: what Dark Style says, if the theme has both."""
    if len(th.variants) > 1:
        m = pt.current_scheme()
        if m in th.variants:
            return m
    return th.prefer


def _hexa(c, a):
    return f"rgba({round(c.r * 255)}, {round(c.g * 255)}, {round(c.b * 255)}, {a})"


def _load_thumb(pic, path):
    try:
        pb = GdkPixbuf.Pixbuf.new_from_file_at_scale(path, THUMB_W, -1, True)
    except GLib.Error:
        return

    def done():
        pic.set_paintable(Gdk.Texture.new_for_pixbuf(pb))
        pic.add_css_class("loaded")
        return False
    GLib.idle_add(done)


class ThemeCard(Gtk.Box):
    def __init__(self, pt, th, current=False, width=300):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, css_classes=["pt-card", f"pt-{th.slug}"])
        self.theme = th
        mode = mode_for(pt, th)
        v = th.variants[mode]
        bg, fg, acc = v["background"], v["foreground"], v["accent"]
        acc_fg = v.p.get("accent_fg") or (bg if sum((acc.r, acc.g, acc.b)) > 1.5 else fg)
        # Per-card colours: a provider per card, scoped by its slug class.
        prov = Gtk.CssProvider()
        prov.load_from_string(f"""
.pt-{th.slug} {{ background-color: {bg.hex}; }}
.pt-{th.slug} .pt-art {{ background-image: radial-gradient(circle at 30% 70%, {_hexa(acc, .45)}, {bg.hex} 70%);
                         border-radius: 16px 16px 0 0; }}
.pt-{th.slug} .pt-band {{ background-color: {bg.hex}; }}
.pt-{th.slug} .pt-name {{ color: {fg.hex}; }}
.pt-{th.slug} .pt-meta {{ color: {_hexa(fg, .62)}; }}
.pt-{th.slug} .pt-chip {{ color: {fg.hex}; background-color: {_hexa(fg, .10)}; }}
.pt-{th.slug} .pt-badge {{ color: {acc_fg.hex}; background-color: {acc.hex}; }}
""")
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), prov,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)

        art = Gtk.Overlay(css_classes=["pt-art"])
        self.pic = Gtk.Picture(css_classes=["pt-wall"], content_fit=Gtk.ContentFit.COVER,
                               can_shrink=True)
        self.pic.set_size_request(width, round(width * 10 / 16))
        art.set_child(self.pic)
        walls = th.wallpapers.get(mode) or th.wallpapers.get("dark") or th.wallpapers.get("light") or []
        wp = walls[0] if walls else None
        if wp and wp.exists():
            threading.Thread(target=_load_thumb, args=(self.pic, str(wp)), daemon=True).start()

        dots = Gtk.Box(spacing=5, css_classes=["pt-dots"], halign=Gtk.Align.START, valign=Gtk.Align.END)
        for k in DOTS:
            c = v.p.get(k)
            if c is None:
                continue
            d = Gtk.DrawingArea(content_width=12, content_height=12, css_classes=["pt-dot"])
            d.set_draw_func(lambda _a, cr, w, h, c=c: (cr.arc(w / 2, h / 2, min(w, h) / 2, 0, 6.2832),
                                                        cr.set_source_rgb(c.r, c.g, c.b), cr.fill()))
            dots.append(d)
        art.add_overlay(dots)
        if current:
            art.add_overlay(Gtk.Label(label="Current", css_classes=["pt-badge"],
                                      halign=Gtk.Align.END, valign=Gtk.Align.START))
        self.busy = Gtk.Box(css_classes=["pt-busy"], visible=False,
                            halign=Gtk.Align.FILL, valign=Gtk.Align.FILL)
        sp = Gtk.Spinner(spinning=True, width_request=32, height_request=32, hexpand=True, vexpand=True,
                         halign=Gtk.Align.CENTER, valign=Gtk.Align.CENTER)
        self.busy.append(sp)
        art.add_overlay(self.busy)
        self.append(art)

        band = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4, css_classes=["pt-band"])
        top = Gtk.Box(spacing=8)
        top.append(Gtk.Label(label=th.name, xalign=0, hexpand=True, css_classes=["pt-name"],
                             ellipsize=3))
        for m in ("dark", "light"):
            if m in th.variants:
                top.append(Gtk.Label(label=m.capitalize(), css_classes=["pt-chip"]))
        band.append(top)
        band.append(Gtk.Label(label=th.author or "", xalign=0, css_classes=["pt-meta"], ellipsize=3))
        self.append(band)

    def set_busy(self, on):
        self.busy.set_visible(on)
