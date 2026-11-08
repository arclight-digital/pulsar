#!/usr/bin/python3
"""HARNESS FIXTURE: a libadwaita window over a busy page, with a dialog
inside it (an in-window sheet, which only GTK's own backdrop-filter can
blur) and, with --float, an alert of its own (a dialog with no parent: a
window, so the Shell's glass is behind it). The sheets scenario shoots it.

  sheets.py [--float]
"""
import sys
import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gtk

APP_ID = "digital.arclight.GateSheets"
# a page busy enough that the sheet's glass has something to show: bright
# and dark blocks, colors, and text
BLOCKS = ["#f5f5f5", "#1e1e1e", "#e01b24", "#2ec27e", "#3584e4", "#f6d32d", "#9141ac", "#ff7800"]


class SheetsApp(Adw.Application):
    def __init__(self, floating):
        super().__init__(application_id=APP_ID)
        self.floating = floating

    def do_activate(self):
        win = Adw.ApplicationWindow(application=self, title="Sheets", default_width=900, default_height=640)
        tv = Adw.ToolbarView()
        tv.add_top_bar(Adw.HeaderBar())
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12, margin_top=18, margin_bottom=18,
                      margin_start=18, margin_end=18)
        grid = Gtk.Grid(column_spacing=8, row_spacing=8, column_homogeneous=True)
        css = Gtk.CssProvider()
        css.load_from_string("".join(f".blk{i} {{ background: {c}; min-height: 150px; }}" for i, c in enumerate(BLOCKS)))
        Gtk.StyleContext.add_provider_for_display(win.get_display(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        for i in range(len(BLOCKS)):
            b = Gtk.Box()
            b.add_css_class(f"blk{i}")
            grid.attach(b, i % 4, i // 4, 1, 1)
        lst = Gtk.ListBox(selection_mode=Gtk.SelectionMode.NONE)
        lst.add_css_class("boxed-list")
        for t in ("Wi-Fi", "Bluetooth", "Displays", "Sound", "Power"):
            lst.append(Adw.ActionRow(title=t, subtitle="The quick brown fox jumps over the lazy dog"))
        box.append(lst)
        box.append(grid)
        view = Gtk.TextView(editable=False, vexpand=True)
        view.get_buffer().set_text(("A view: the content pane of an editor or a list. " * 4 + "\n") * 14)
        box.append(view)
        tv.set_content(box)
        win.set_content(tv)
        win.present()
        sheet = Adw.Dialog(title="Preferences", content_width=420, content_height=360)
        st = Adw.ToolbarView()
        st.add_top_bar(Adw.HeaderBar())
        page = Adw.PreferencesPage()
        grp = Adw.PreferencesGroup(title="Appearance")
        for t in ("Dark Style", "Glass", "Lighting"):
            grp.add(Adw.SwitchRow(title=t, active=True))
        page.add(grp)
        st.set_content(page)
        sheet.set_child(st)
        sheet.present(win)
        if self.floating:
            alert = Adw.AlertDialog(heading="Discard changes?", body="A dialog with no parent window floats on its own.")
            alert.add_response("cancel", "Cancel")
            alert.add_response("discard", "Discard")
            alert.set_response_appearance("discard", Adw.ResponseAppearance.DESTRUCTIVE)
            alert.present(None)


if __name__ == "__main__":
    sys.exit(SheetsApp("--float" in sys.argv).run([sys.argv[0]]))
