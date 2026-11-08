#!/usr/bin/python3
"""HARNESS FIXTURE: a stand-in GDM on the gate's own stand-in system bus
(never the host's), answering only its Manager's Version. The Shell builds
its lock screen only where GDM answers that (LoginManager.canLock(), with
/run/systemd/seats present: run.sh mounts one for the lockscreen
scenario); nothing else of GDM's is there, so unlocking is the scenario's
own call, never a password."""
from gi.repository import Gio, GLib

NAME = "org.gnome.DisplayManager"
PATH = "/org/gnome/DisplayManager/Manager"
XML = f"""<node><interface name="{NAME}.Manager">
  <property name="Version" type="s" access="read"/>
</interface></node>"""


def get(_conn, _sender, _path, _iface, _prop):
    return GLib.Variant("s", "51.0")


def acquired(conn, _name):
    conn.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], None, get, None)


Gio.bus_own_name(Gio.BusType.SYSTEM, NAME, Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
