// Loads $XDG_STATE_HOME/pulsar-theme/shell/gnome-shell-{dark,light}.css on top
// of the stock Shell theme -- the same St.Theme.load_stylesheet() call that
// gives every extension its stylesheet.css, so the API is stable; the
// SELECTORS in the generated file are not, and harness/gate.sh checks them
// against each GNOME release's stock stylesheet.
//
// It never replaces the Shell theme (what user-themes does, and why
// user-themes themes break every release). With no file, it does nothing.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

export default class PulsarThemeExtension extends Extension {
    enable() {
        this._dir = GLib.build_filenamev([GLib.get_user_state_dir(), 'pulsar-theme', 'shell']);
        GLib.mkdir_with_parents(this._dir, 0o755);
        // Watch the directory: pulsar-theme replaces files with rename(2),
        // which a monitor on the old inode would miss.
        this._monitor = Gio.File.new_for_path(this._dir).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._monitor.set_rate_limit(250);
        this._monitorId = this._monitor.connect('changed', (_m, file, other) => {
            const hit = f => f && f.get_basename().startsWith('gnome-shell');
            if (hit(file) || hit(other))
                this._reload();
        });
        this._iface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._schemeId = this._iface.connect('changed::color-scheme', () => this._reload());
        this._themeCtx = St.ThemeContext.get_for_stage(global.stage);
        this._themeChangedId = this._themeCtx.connect('changed', () => {
            if (this._loaded && this._loaded.theme !== this._themeCtx.get_theme())
                this._reload();
        });
        this._reload();
    }

    disable() {
        this._monitor?.disconnect(this._monitorId);
        this._monitor?.cancel();
        this._monitor = null;
        this._iface?.disconnect(this._schemeId);
        this._iface = null;
        this._themeCtx?.disconnect(this._themeChangedId);
        this._themeCtx = null;
        this._unload();
    }

    _path() {
        const dark = this._iface.get_string('color-scheme') === 'prefer-dark';
        for (const name of [dark ? 'gnome-shell-dark.css' : 'gnome-shell-light.css', 'gnome-shell.css']) {
            const p = GLib.build_filenamev([this._dir, name]);
            if (GLib.file_test(p, GLib.FileTest.EXISTS))
                return p;
        }
        return null;
    }

    _unload() {
        if (this._loaded) {
            try {
                this._loaded.theme.unload_stylesheet(this._loaded.file);
            } catch (e) {}
        }
        this._loaded = null;
    }

    _reload() {
        this._unload();
        const path = this._path();
        if (!path)
            return;
        // A fresh GFile each time: St.Theme caches parsed sheets per GFile.
        const file = Gio.File.new_for_path(path);
        const theme = this._themeCtx.get_theme();
        try {
            theme.load_stylesheet(file);
            this._loaded = {theme, file};
        } catch (e) {
            console.warn(`pulsar-theme: ${e.message}`);
        }
    }
}
