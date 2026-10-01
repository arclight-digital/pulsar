#!/usr/bin/python3
"""HARNESS FIXTURE: a stand-in power-profiles-daemon on the gate's own
stand-in system bus (never the host's): org.freedesktop.UPower.PowerProfiles
with an ActiveProfile the scenario sets through Properties.Set, as
powerprofilesctl does, and a PropertiesChanged for each change."""
from gi.repository import Gio, GLib

NAME = "org.freedesktop.UPower.PowerProfiles"
PATH = "/org/freedesktop/UPower/PowerProfiles"
XML = f"""<node><interface name="{NAME}">
  <property name="ActiveProfile" type="s" access="readwrite"/>
</interface></node>"""
state = {"ActiveProfile": "balanced"}


def get(_conn, _sender, _path, _iface, prop):
    return GLib.Variant("s", state[prop])


def set_(conn, _sender, path, iface, prop, value):
    state[prop] = value.unpack()
    conn.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged",
                     GLib.Variant("(sa{sv}as)", (iface, {prop: value}, [])))
    return True


def acquired(conn, _name):
    conn.register_object(PATH, Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0], None, get, set_)


Gio.bus_own_name(Gio.BusType.SYSTEM, NAME, Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
