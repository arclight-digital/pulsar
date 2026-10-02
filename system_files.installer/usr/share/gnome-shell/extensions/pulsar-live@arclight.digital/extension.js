// The live installer's session: start on the desktop, with the installer's
// window in front, not in the overview (where GNOME Shell starts a session
// that has no windows yet, and the installer then opened inside it).
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

export default class PulsarLive {
    enable() {
        if (Main.layoutManager._startingUp)
            Main.layoutManager.connectObject('startup-complete', () => Main.overview.hide(), this);
        else
            Main.overview.hide();
    }

    disable() {
        Main.layoutManager.disconnectObject(this);
    }
}
