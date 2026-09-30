// Loads $XDG_STATE_HOME/pulsar-theme/shell/gnome-shell-{dark,light}.css on top
// of the stock Shell theme -- the same St.Theme.load_stylesheet() call that
// gives every extension its stylesheet.css, so the API is stable; the
// SELECTORS in the generated file are not, and tests/theme-gate checks them
// against each GNOME release's stock stylesheet.
//
// It never replaces the Shell theme (what user-themes does, and why
// user-themes themes break every release). With no file, it does nothing.
//
// Two traps in St, both learned the hard way:
//  * load_stylesheet/unload_stylesheet make the St.Theme emit
//    custom-stylesheets-changed, which StThemeContext turns into a
//    SYNCHRONOUS 'changed'. A 'changed' handler that reloads unconditionally
//    recurses until the Shell dies. So the handler acts only when the theme
//    OBJECT changed, and _reload is guarded against re-entry.
//  * Dark Style and high contrast make the Shell build a new St.Theme, and
//    Main.loadTheme copies every custom stylesheet across -- ours included.
//    So unloading goes by directory on the CURRENT theme, not by the GFile
//    we happened to load, or carried-over copies pile up.
//
// A theme with one mode (Dracula is dark only, Alucard light only) has
// nothing for Dark Style to swap to, so the engine writes one-mode.json
// beside the sheets and the Quick Settings toggle goes insensitive while
// the desktop is in that mode. Settings and gsettings can still flip it;
// then the toggle comes back, so one click returns to the theme's mode.
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import St from 'gi://St';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import {Extension, InjectionManager} from 'resource:///org/gnome/shell/extensions/extension.js';

import {Glass} from './glass.js';

// beside the sheets: the one mode the applied theme has (engine's ONE_MODE)
const ONE_MODE = 'one-mode.json';

export default class PulsarThemeExtension extends Extension {
    enable() {
        this._dir = GLib.build_filenamev([GLib.get_user_state_dir(), 'pulsar-theme', 'shell']);
        GLib.mkdir_with_parents(this._dir, 0o755);
        this._reloading = false;
        this._theme = null;
        // Watch the directory: pulsar-theme replaces files with rename(2),
        // which a monitor on the old inode would miss.
        this._monitor = Gio.File.new_for_path(this._dir).monitor_directory(Gio.FileMonitorFlags.WATCH_MOVES, null);
        this._monitor.set_rate_limit(250);
        this._monitorId = this._monitor.connect('changed', (_m, file, other) => {
            const hit = f => f && f.get_basename().startsWith('gnome-shell');
            if (hit(file) || hit(other))
                this._reload();
            const lock = f => f && f.get_basename() === ONE_MODE;
            if (lock(file) || lock(other))
                this._readOneMode();
        });
        this._iface = new Gio.Settings({schema_id: 'org.gnome.desktop.interface'});
        this._schemeId = this._iface.connect('changed::color-scheme', () => {
            this._reload();
            this._syncDarkStyle();
            // GTK3 apps cannot follow the scheme themselves (no media
            // queries); the engine rewrites their half. Fire and forget.
            try {
                Gio.Subprocess.new(['/usr/libexec/pulsar/pulsar-theme', 'follow-scheme'],
                    Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
            } catch (e) {
                console.warn(`pulsar-theme: follow-scheme: ${e.message}`);
            }
        });
        // Workspace thumbnails draw windows only, over a flat colour; the
        // extension puts the current wallpaper behind them. Runtime-generated
        // (not in the theme's sheets) so it follows any wallpaper change,
        // the user's own included.
        this._thumbDir = GLib.build_filenamev([GLib.get_user_runtime_dir(), 'pulsar-theme']);
        GLib.mkdir_with_parents(this._thumbDir, 0o700);
        this._bg = new Gio.Settings({schema_id: 'org.gnome.desktop.background'});
        this._bgId = this._bg.connect('changed', (_s, key) => {
            if (key.startsWith('picture-'))
                this._reload();
        });
        this._themeCtx = St.ThemeContext.get_for_stage(global.stage);
        this._themeChangedId = this._themeCtx.connect('changed', () => {
            // Our own load/unload emits this too: only a NEW theme object
            // (a Shell theme swap) is a reason to reload.
            if (this._themeCtx.get_theme() !== this._theme)
                this._reload();
        });
        this._reload();
        this._toggle = null;
        this._readOneMode();
        // Glass and light (glass.js), switched by this extension's own
        // settings: the Extensions app's preferences and the theme picker.
        this._injections = new InjectionManager();
        this._glass = new Glass(this.getSettings(), this._injections);
    }

    disable() {
        if (this._toggleRetryId)
            GLib.source_remove(this._toggleRetryId);
        this._toggleRetryId = 0;
        this._oneMode = null;
        this._syncDarkStyle();      // gives the toggle back as it was
        this._injections?.clear();
        this._injections = null;
        this._glass?.destroy();
        this._glass = null;
        Glass.release();
        this._monitor?.disconnect(this._monitorId);
        this._monitor?.cancel();
        this._monitor = null;
        this._iface?.disconnect(this._schemeId);
        this._iface = null;
        this._bg?.disconnect(this._bgId);
        this._bg = null;
        this._themeCtx?.disconnect(this._themeChangedId);
        this._reloading = true;     // nothing from here on re-enters
        this._unload();
        this._themeCtx = null;
        this._theme = null;
    }

    _readOneMode() {
        this._oneMode = null;
        try {
            const [, bytes] = GLib.file_get_contents(GLib.build_filenamev([this._dir, ONE_MODE]));
            const m = JSON.parse(new TextDecoder().decode(bytes));
            if (m && (m.mode === 'dark' || m.mode === 'light'))
                this._oneMode = m;
        } catch (e) {}     // no file: the theme has both modes, or there is none
        this._syncDarkStyle();
    }

    // Quick Settings builds its toggles asynchronously at startup, so the
    // Dark Style one may not exist yet when the extension is first enabled.
    _findDarkStyle() {
        return Main.panel?.statusArea?.quickSettings?._darkMode?.quickSettingsItems?.[0] ?? null;
    }

    _syncDarkStyle() {
        const want = this._oneMode;
        let toggle = this._toggle;
        if (!toggle && want) {
            toggle = this._findDarkStyle();
            if (!toggle) {
                this._toggleRetryId ||= GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                    this._toggleRetryId = 0;
                    this._syncDarkStyle();
                    return GLib.SOURCE_REMOVE;
                });
                return;
            }
            this._toggle = toggle;
            this._stock = {subtitle: toggle.subtitle, reactive: toggle.reactive, canFocus: toggle.can_focus};
            toggle.connectObject('destroy', () => {
                this._toggle = null;
            }, this);
        }
        if (!toggle)
            return;
        if (!want) {
            toggle.disconnectObject(this);
            toggle.set({subtitle: this._stock.subtitle, reactive: this._stock.reactive,
                can_focus: this._stock.canFocus});
            this._toggle = null;
            return;
        }
        // Insensitive only while the desktop is in the theme's mode: after a
        // flip from Settings the toggle is the one-click way back.
        const dark = this._iface?.get_string('color-scheme') === 'prefer-dark';
        const inMode = (want.mode === 'dark') === dark;
        const name = String(want.name || 'This theme');
        toggle.set({
            subtitle: want.pinned ? `${name} is set to ${want.mode}` : `${name} is ${want.mode} only`,
            reactive: !inMode,
            can_focus: !inMode && this._stock.canFocus,
        });
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

    _thumbSheet() {
        const dark = this._iface.get_string('color-scheme') === 'prefer-dark';
        if (this._bg.get_string('picture-options') === 'none')
            return null;
        const uri = this._bg.get_string(dark ? 'picture-uri-dark' : 'picture-uri') ||
            this._bg.get_string('picture-uri');
        // a slideshow .xml is not an image St can draw
        if (!uri || !uri.startsWith('file://') || uri.endsWith('.xml') || /["\\]/.test(uri))
            return null;
        const css = '.workspace-thumbnails .workspace-thumbnail {\n' +
            `  background-image: url("${uri}");\n` +
            '  background-size: cover; }\n';
        const p = GLib.build_filenamev([this._thumbDir, 'thumbnails.css']);
        try {
            GLib.file_set_contents(p, css);
        } catch (e) {
            return null;
        }
        return p;
    }

    _unload() {
        const theme = this._themeCtx?.get_theme();
        if (!theme)
            return;
        // The list can hold null entries in GNOME 50 (seen in the theme gate),
        // so every element is checked before it is touched.
        for (const f of theme.get_custom_stylesheets()) {
            const path = f?.get_path?.();
            const dir = path ? GLib.path_get_dirname(path) : null;
            if (dir === this._dir || dir === this._thumbDir) {
                try {
                    theme.unload_stylesheet(f);
                } catch (e) {}
            }
        }
    }

    _reload() {
        if (this._reloading)
            return;
        this._reloading = true;
        try {
            this._unload();
            const path = this._path();
            // A fresh GFile each time: St.Theme caches parsed sheets per GFile.
            if (path) {
                this._themeCtx.get_theme().load_stylesheet(Gio.File.new_for_path(path));
                const thumbs = this._thumbSheet();
                if (thumbs)
                    this._themeCtx.get_theme().load_stylesheet(Gio.File.new_for_path(thumbs));
            }
        } catch (e) {
            console.warn(`pulsar-theme: ${e.message}`);
        } finally {
            this._theme = this._themeCtx?.get_theme() ?? null;
            this._reloading = false;
        }
    }
}
