#!/usr/bin/python3
# GTK's own parser on a gtk.css (tests/theme.bats): its parse errors, and
# whether the backdrop-filter glass survived, beside whether this GTK (4.22
# and later) has backdrop-filter at all.
import sys

import gi
gi.require_version("Gtk", "4.0")
from gi.repository import Gtk

p = Gtk.CssProvider()
errs = []
p.connect("parsing-error", lambda _p, _s, e: errs.append(e.message))
p.load_from_path(sys.argv[1])
print("errors:", errs)
print("gated:", "backdrop-filter" in p.to_string(), (Gtk.get_major_version(), Gtk.get_minor_version()) >= (4, 22))
