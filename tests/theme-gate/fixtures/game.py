#!/usr/bin/python3
"""HARNESS FIXTURE: a stand-in game. A plain GTK4 window titled GateGame,
with no application id (so it gets no window glass of its own, as a game
would not), redrawing its whole surface every frame.

  game.py fullscreen MONITOR    fullscreen on that monitor (GDK's index)
  game.py borderless W H        undecorated, W x H; the scenario places it
"""
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, GLib, Gtk

loop = GLib.MainLoop()
win = Gtk.Window(title="GateGame")
area = Gtk.DrawingArea(hexpand=True, vexpand=True)
frame = [0]


def draw(_area, cr, _w, _h):
    frame[0] += 1
    cr.set_source_rgb((frame[0] % 60) / 60, 0.3, 0.5)
    cr.paint()


area.set_draw_func(draw)
area.add_tick_callback(lambda a, _clock: (a.queue_draw(), True)[1])
win.set_child(area)
win.connect("close-request", lambda *_: (loop.quit(), False)[1])
if sys.argv[1] == "fullscreen":
    win.fullscreen_on_monitor(Gdk.Display.get_default().get_monitors().get_item(int(sys.argv[2])))
else:
    win.set_decorated(False)
    win.set_default_size(int(sys.argv[2]), int(sys.argv[3]))
win.present()
loop.run()
