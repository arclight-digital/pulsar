#!/usr/bin/python3
"""HARNESS FIXTURE: a stand-in game. A plain GTK4 window titled GateGame,
with no application id (so it gets no window glass of its own, as a game
would not), redrawing its whole surface every frame.

  game.py fullscreen MONITOR    fullscreen on that monitor (GDK's index)
  game.py borderless W H        undecorated, W x H; the scenario places it

It starts the way a GTK app does, through Gtk.Application (with no id, so
the window still carries none), not by building a Gtk.Window off a bare
GLib main loop. On GNOME 51 / GTK 4.24, in the glass scenario's session
(two monitors, fractional scale), that bare start got
"g_object_ref: assertion 'G_IS_OBJECT (object)' failed" on the first two
widgets and the window never reached the Shell, so every game check failed
on "game() is undefined". Anything that brought up GtkSettings before the
first widget cured it (bisected in the gate: touching the display or its
monitors did not), and Gtk.Application's startup does that as a matter of
course. GNOME 50 / GTK 4.22 never minded either way.
"""
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, Gtk


def activate(app):
    win = Gtk.Window(application=app, title="GateGame")
    area = Gtk.DrawingArea(hexpand=True, vexpand=True)
    frame = [0]

    def draw(_area, cr, _w, _h):
        frame[0] += 1
        cr.set_source_rgb((frame[0] % 60) / 60, 0.3, 0.5)
        cr.paint()

    area.set_draw_func(draw)
    area.add_tick_callback(lambda a, _clock: (a.queue_draw(), True)[1])
    win.set_child(area)
    if sys.argv[1] == "fullscreen":
        win.fullscreen_on_monitor(Gdk.Display.get_default().get_monitors().get_item(int(sys.argv[2])))
    else:
        win.set_decorated(False)
        win.set_default_size(int(sys.argv[2]), int(sys.argv[3]))
    win.present()


# no application id: no D-Bus name, no uniqueness, and no app id on the
# window; the app quits when its window closes, as the loop used to
app = Gtk.Application(application_id=None, flags=Gio.ApplicationFlags.NON_UNIQUE)
app.connect("activate", activate)
sys.exit(app.run([sys.argv[0]]))
