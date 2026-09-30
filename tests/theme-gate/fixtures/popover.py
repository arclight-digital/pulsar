#!/usr/bin/python3
"""HARNESS FIXTURE: a libadwaita window whose menu button's popover opens on
request, so the glass scenario has a GTK popover without a pointer. The
request is the app's own `popup` action over D-Bus (`popdown` closes it):

  gdbus call --session --dest digital.arclight.GatePopover \
    --object-path /digital/arclight/GatePopover \
    --method org.gtk.Actions.Activate popup [] {}
"""
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, Gtk

APP_ID = "digital.arclight.GatePopover"


class PopoverApp(Adw.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID)
        for name, fn in (("popup", lambda: self.button.popup()), ("popdown", lambda: self.button.popdown())):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", lambda *_, fn=fn: fn())
            self.add_action(act)

    def do_activate(self):
        win = self.get_active_window()
        if not win:
            win = Adw.ApplicationWindow(application=self, title="Popover", default_width=700, default_height=500)
            tv = Adw.ToolbarView()
            head = Adw.HeaderBar()
            menu = Gio.Menu()
            for label in ("New Window", "Preferences", "Keyboard Shortcuts", "About"):
                menu.append(label, "app.none")
            self.button = Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu)
            head.pack_end(self.button)
            tv.add_top_bar(head)
            tv.set_content(Adw.StatusPage(title="Popover fixture"))
            win.set_content(tv)
        win.present()


if __name__ == "__main__":
    sys.exit(PopoverApp().run([sys.argv[0]]))
