// The extension's page in the Extensions app: its effects. The theme picker
// shows the same keys (EFFECTS in pulsar-settings).
import Adw from 'gi://Adw';
import Gio from 'gi://Gio';
import Gtk from 'gi://Gtk';
import {ExtensionPreferences} from 'resource:///org/gnome/Shell/Extensions/js/extensions/prefs.js';

// key, title, subtitle, the key it needs on
const EFFECTS = [
    ['glass', 'Glass', 'The top bar, the dash, menus, dialogs, notifications and on-screen displays blur what is behind them'],
    ['window-glass', 'Glass windows', 'GTK 4 app windows are 80% opaque over the same blur. GTK 3 apps and fullscreen windows stay solid, and so does the main area beside a sidebar, except Text Editor\'s document', 'glass'],
    ['lighting', 'Lighting', 'A menu\'s edge is lit from the button that opened it, and turns warmer when the battery is low'],
    ['power-on', 'Power-on', 'As a menu opens, its lit edge traces out from the button that opened it', 'lighting'],
    ['glow', 'Glow', 'Switches that are on, checked boxes, slider fills, progress bars and default buttons glow in the accent color'],
    ['focus-brackets', 'Focus brackets', 'While you use the keyboard, four corner brackets mark the focused button or menu item outside app windows'],
    ['glass-off-gaming', 'Disable glass when gaming', 'Glass and lighting turn off while GameMode runs a game (gg, ggm or gamemoderun)'],
    ['glass-off-power-saver', 'Disable glass in Power Saver', 'Glass and lighting turn off while the power mode is Power Saver'],
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
            description: 'Glass windows and Glow apply to apps opened after you change them. High contrast turns every ' +
                'effect off, except in app windows already open. The two Disable glass switches leave app ' +
                'windows\' glass on.',
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
