#!/usr/bin/python3
"""HARNESS FIXTURE: a minimal libadwaita app that behaves like a GNOME editor
on quit -- app.quit with unsaved text raises "Save changes?" and does NOT
exit. `--dirty` starts it with unsaved text (no keyboard needed)."""
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gio, Gtk

APP_ID = "digital.arclight.GateNotes"


class Notes(Adw.Application):
    def __init__(self, dirty):
        super().__init__(application_id=APP_ID)
        self.dirty = dirty
        quit = Gio.SimpleAction.new("quit", None)
        quit.connect("activate", self.on_quit)
        self.add_action(quit)

    def do_activate(self):
        win = self.get_active_window()
        if not win:
            win = Adw.ApplicationWindow(application=self, title="Notes", default_width=900, default_height=600)
            tv = Adw.ToolbarView()
            tv.add_top_bar(Adw.HeaderBar())
            self.buf = Gtk.TextBuffer()
            self.buf.set_text("Draft: the theme switch must never eat this paragraph.\n" if self.dirty else "")
            self.buf.set_modified(self.dirty)
            tv.set_content(Gtk.TextView(buffer=self.buf, top_margin=18, left_margin=18))
            win.set_content(tv)
        win.present()

    def on_quit(self, *_):
        if not self.buf.get_modified():
            self.quit()
            return
        d = Adw.AlertDialog(heading="Save Changes?", body="Open documents contain unsaved changes.")
        d.add_response("cancel", "Cancel")
        d.add_response("discard", "Discard")
        d.add_response("save", "Save")
        d.set_response_appearance("discard", Adw.ResponseAppearance.DESTRUCTIVE)
        d.set_response_appearance("save", Adw.ResponseAppearance.SUGGESTED)
        d.present(self.get_active_window())


if __name__ == "__main__":
    sys.exit(Notes("--dirty" in sys.argv).run([sys.argv[0]]))
