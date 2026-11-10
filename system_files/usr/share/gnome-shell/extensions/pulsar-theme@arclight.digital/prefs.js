// The extension's page in the Extensions app: its effects. The theme picker
// shows the same keys (EFFECTS in pulsar-settings).
import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

// key, title, subtitle, the key it needs on
const EFFECTS = [
    ['glass', 'Glass', 'Menus, the top bar, on-screen displays and notification banners are translucent over a blur of what is behind them'],
    ['window-glass', 'Glass windows', 'App windows are 80% opaque over the same blur; apps opened afterwards pick it up', 'glass'],
    ['lighting', 'Lighting', 'A menu\'s edge is lit from the button that opened it, and turns warmer when the battery is low'],
    ['power-on', 'Power-on', 'As a menu opens, its lit edge traces out from the button that opened it', 'lighting'],
    ['glow', 'Glow', 'Controls filled with the accent color, such as switches and sliders, glow in it; apps opened afterwards pick it up'],
    ['focus-brackets', 'Focus brackets', 'Four corner brackets mark the control the keyboard is on'],
    ['glass-off-gaming', 'Disable glass when gaming', 'Glass and lighting turn off while GameMode runs a game (gg, ggm or gamemoderun); app windows stay glass'],
    ['glass-off-power-saver', 'Disable glass in Power Saver', 'Glass and lighting turn off while the power mode is Power Saver; app windows stay glass'],
];

// Glass tint: clear to fully tinted, like the slider it is modeled on.
function tintRow(settings) {
    const row = new Adw.ActionRow({title: 'Glass tint'});
    const scale = new Gtk.Scale({
        adjustment: new Gtk.Adjustment({lower: 0, upper: 1, step_increment: 0.05, page_increment: 0.1}),
        draw_value: false, hexpand: true, width_request: 200, valign: Gtk.Align.CENTER,
    });
    scale.add_mark(0, Gtk.PositionType.BOTTOM, 'Clear');
    scale.add_mark(1, Gtk.PositionType.BOTTOM, 'Tinted');
    settings.bind('glass-tint', scale.adjustment, 'value', Gio.SettingsBindFlags.DEFAULT);
    settings.bind('glass', row, 'sensitive', Gio.SettingsBindFlags.GET);
    row.add_suffix(scale);
    return row;
}

export default class PulsarThemePrefs extends ExtensionPreferences {
    fillPreferencesWindow(window) {
        const settings = this.getSettings();
        const page = new Adw.PreferencesPage();
        const group = new Adw.PreferencesGroup({
            title: 'Effects',
            description: 'High contrast turns them all off, except in app windows already open.',
        });
        // every effect and the tint back to the defaults; live only while
        // something differs from them
        const keys = settings.settings_schema.list_keys();
        const reset = new Gtk.Button({
            label: 'Reset', tooltip_text: 'Put every effect and the tint back to the defaults',
            css_classes: ['flat'], valign: Gtk.Align.CENTER,
        });
        reset.connect('clicked', () => keys.forEach(k => settings.reset(k)));
        const changed = () => (reset.sensitive = keys.some(k => settings.get_user_value(k) !== null));
        settings.connect('changed', changed);
        changed();
        group.set_header_suffix(reset);
        for (const [key, title, subtitle, needs] of EFFECTS) {
            const row = new Adw.SwitchRow({title, subtitle});
            settings.bind(key, row, 'active', Gio.SettingsBindFlags.DEFAULT);
            if (needs)
                settings.bind(needs, row, 'sensitive', Gio.SettingsBindFlags.GET);
            group.add(row);
            if (key === 'glass')
                group.add(tintRow(settings));
        }
        page.add(group);
        window.add(page);
    }
}
