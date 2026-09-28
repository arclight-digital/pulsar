// The extension's page in the Extensions app: its effects. The theme picker
// shows the same keys (EFFECTS in pulsar-theme-picker).
import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

// key, title, subtitle, the key it needs on
const EFFECTS = [
    ['glass', 'Glass', 'Menus, the top bar, OSDs and banners are translucent over a blur of what is behind them'],
    ['window-glass', 'Glass windows', 'App windows are a little translucent too; apps opened afterwards pick it up', 'glass'],
    ['lighting', 'Lighting', 'Menus catch light from the button that opened them; the edge warms when the battery is low'],
    ['power-on', 'Power-on', 'The edge traces out from the light as a menu opens', 'lighting'],
    ['focus-brackets', 'Focus brackets', 'Corner brackets lock onto the control the keyboard is on'],
];

// Glass tint: clear to fully tinted, like the slider it is modeled on.
function tintRow(settings) {
    const row = new Adw.ActionRow({title: 'Glass tint', subtitle: 'From clear to fully tinted'});
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
            description: 'High contrast turns them all off.',
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
