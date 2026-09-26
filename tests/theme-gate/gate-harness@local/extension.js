// GATE ONLY -- never shipped. Turns on unsafe mode inside the throwaway
// headless Shell so org.gnome.Shell.Eval and Screenshot answer the scenario.
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
export default class Harness extends Extension {
    enable() { global.context.unsafe_mode = true; }
    disable() {}
}
