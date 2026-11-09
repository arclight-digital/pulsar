// Runs the Shell extension's own modules under node, for tests of their
// logic: every `gi://` and `resource://` import becomes a fake the test
// sets up (globalThis.__gi, __mod), and nothing else in the module changes.
// The fakes model only what a test asserts on: actors keep their children,
// handlers and style classes; anything not modelled is a `fake()`, which
// takes any call, property or `new` and does nothing.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

// Anything at all: every property is another fake (made once and kept),
// every call and `new` returns a fresh one, and it iterates as empty.
// `props` are real values in its place.
export function fake(name = 'fake', props = {}) {
    const store = Object.assign(Object.create(null), props);
    const target = function () {};
    return new Proxy(target, {
        get(t, k) {
            if (k in store)
                return store[k];
            if (k === Symbol.iterator)
                return function* () {};
            if (k === Symbol.toPrimitive)
                return hint => (hint === 'number' ? NaN : `[${name}]`);
            if (typeof k === 'symbol' || k === 'then')
                return undefined;
            if (k === 'prototype')
                return t.prototype;
            return (store[k] = fake(`${name}.${k}`));
        },
        set(_t, k, v) {
            store[k] = v;
            return true;
        },
        has(_t, k) {
            return k in store;
        },
        apply() {
            return fake(`${name}()`);
        },
        construct() {
            return fake(`new ${name}`);
        },
    });
}

// The Shell's connectObject()/disconnectObject() (misc/signalTracker.js)
// and plain connect()/disconnect(), with the handlers countable.
export class Signals {
    constructor() {
        this._handlers = [];
        this._nextId = 1;
    }

    connect(signal, fn) {
        const id = this._nextId++;
        this._handlers.push({id, signal, fn, owner: null});
        return id;
    }

    disconnect(id) {
        this._handlers = this._handlers.filter(h => h.id !== id);
    }

    connectObject(...args) {
        const owner = args.pop();
        for (let i = 0; i + 1 < args.length; i += 2) {
            // (a GObject.ConnectFlags after a handler is skipped)
            if (typeof args[i] !== 'string') {
                i--;
                continue;
            }
            this.connect(args[i], args[i + 1]);
            this._handlers[this._handlers.length - 1].owner = owner;
        }
    }

    disconnectObject(owner) {
        this._handlers = this._handlers.filter(h => h.owner !== owner);
    }

    emit(signal, ...args) {
        for (const h of [...this._handlers]) {
            if (h.signal === signal)
                h.fn(this, ...args);
        }
    }

    handlers(signal) {
        return this._handlers.filter(h => h.signal === signal).length;
    }
}

// What a theme node answers when nothing is styled
export const plainNode = fake('ThemeNode', {
    lookup_color: () => [false, null],
    get_background_color: () => ({red: 0, green: 0, blue: 0, alpha: 0}),
    get_foreground_color: () => ({red: 255, green: 255, blue: 255, alpha: 255}),
    get_border_radius: () => 0,
});

// Clutter.Actor / St.Widget
export class FakeActor extends Signals {
    constructor(params = {}) {
        super();
        this._children = [];
        this._parent = null;
        this._classes = new Set();
        this._effects = new Map();
        this.opacity = 255;
        this.visible = true;
        this.x = this.y = this.width = this.height = 0;
        this.destroyed = false;
        const {style_class: cls, effect, layout_manager: _lm, ...rest} = params;
        Object.assign(this, rest);
        for (const c of (cls ?? '').split(/\s+/).filter(Boolean))
            this._classes.add(c);
        if (effect)
            this.add_effect_with_name(effect.name ?? 'effect', effect);
    }

    get_parent() {
        return this._parent;
    }

    get_children() {
        return [...this._children];
    }

    get_first_child() {
        return this._children[0] ?? null;
    }

    [Symbol.iterator]() {
        return this.get_children()[Symbol.iterator]();
    }

    _insert(child, index) {
        child._parent?.remove_child(child);
        this._children.splice(index, 0, child);
        child._parent = this;
        this.emit('child-added', child);
    }

    add_child(child) {
        this._insert(child, this._children.length);
    }

    insert_child_at_index(child, index) {
        this._insert(child, Math.max(0, Math.min(index, this._children.length)));
    }

    insert_child_above(child, sibling) {
        this._insert(child, sibling ? this._children.indexOf(sibling) + 1 : this._children.length);
    }

    insert_child_below(child, sibling) {
        this._insert(child, sibling ? this._children.indexOf(sibling) : 0);
    }

    remove_child(child) {
        this._children = this._children.filter(c => c !== child);
        child._parent = null;
    }

    destroy() {
        if (this.destroyed)
            return;
        this.destroyed = true;
        this.emit('destroy');
        for (const c of [...this._children])
            c.destroy();
        this._parent?.remove_child(this);
        this._handlers = [];
    }

    set_position(x, y) {
        [this.x, this.y] = [x, y];
    }

    set_size(w, h) {
        [this.width, this.height] = [w, h];
    }

    get_size() {
        return [this.width, this.height];
    }

    add_style_class_name(c) {
        this._classes.add(c);
    }

    remove_style_class_name(c) {
        this._classes.delete(c);
    }

    has_style_class_name(c) {
        return this._classes.has(c);
    }

    add_effect_with_name(name, effect) {
        this._effects.set(name, effect);
    }

    get_effect(name) {
        return this._effects.get(name) ?? null;
    }

    get_theme_node() {
        return plainNode;
    }

    bind_property() {
        return {unbind() {}};
    }

    queue_redraw() {}

    queue_relayout() {}
}

// Clutter.Effect and the shader effects
export class FakeEffect extends Signals {
    constructor() {
        super();
        this.enabled = true;
    }

    queue_repaint() {}

    get_actor() {
        return this._actor ?? null;
    }

    vfunc_set_actor(actor) {
        this._actor = actor;
    }
}

// GLib's timeouts and idles, run only when the test says (run())
export function fakeLoop() {
    const sources = new Map();
    let next = 1;
    const add = fn => {
        const id = next++;
        sources.set(id, fn);
        return id;
    };
    return {
        sources,
        timeout_add: (_prio, _ms, fn) => add(fn),
        timeout_add_seconds: (_prio, _s, fn) => add(fn),
        idle_add: (_prio, fn) => add(fn),
        source_remove: id => {
            if (!sources.delete(id))
                throw new Error(`source_remove(${id}): no such source`);
            return true;
        },
        run() {
            for (const [id, fn] of [...sources]) {
                sources.delete(id);
                fn();
            }
        },
    };
}

const registry = Object.create(null);
// The fake for an import, by the module's name: `gi://Clutter` is
// __gi.Clutter; a `resource://` or relative import is __mod('main') for
// main.js, __mod('glass') for ./glass.js. Unset, it is a fake().
export function provide(name, value) {
    registry[name] = value;
}
globalThis.__mod = name => (registry[name] ??= fake(name));
globalThis.__gi = new Proxy({}, {
    get: (_t, k) => globalThis.__mod(k),
});

// The basics every module of the extension touches at load
provide('GObject', fake('GObject', {
    registerClass: (a, b) => (typeof a === 'function' ? a : b),
}));
provide('Clutter', fake('Clutter', {Effect: FakeEffect, ShaderEffect: FakeEffect, Actor: FakeActor}));
provide('St', fake('St', {Widget: FakeActor, Bin: FakeActor, BoxLayout: FakeActor, DrawingArea: FakeActor}));
provide('Shell', fake('Shell', {GLSLEffect: FakeEffect, BlurEffect: FakeEffect}));

// Imports the module at `file` with its imports faked, and with `names`
// (top-level functions or constants it does not export) exported too, and
// __peek(name), which reads any of its top-level bindings as they are now.
export async function load(file, names = []) {
    let src = fs.readFileSync(file, 'utf8');
    const key = spec => path.basename(spec).replace(/\.js$/, '');
    src = src
        .replace(/^import (\w+) from 'gi:\/\/(\w+)[^']*';$/gm,
            (_m, local, mod) => `const ${local} = globalThis.__gi.${mod};`)
        .replace(/^import \* as (\w+) from '([^']+)';$/gm,
            (_m, local, spec) => `const ${local} = globalThis.__mod(${JSON.stringify(key(spec))});`)
        .replace(/^import \{([^}]*)\} from '([^']+)';$/gm,
            (_m, locals, spec) => `const {${locals}} = globalThis.__mod(${JSON.stringify(key(spec))});`);
    const left = src.match(/^import .*$/m);
    if (left)
        throw new Error(`shell-js: an import it cannot fake: ${left[0]}`);
    const exported = new Set([...src.matchAll(/^export (?:default )?(?:class|function|const|let) (\w+)/gm)].map(m => m[1]));
    const extra = names.filter(n => !exported.has(n));
    src += `\nexport const __peek = name => eval(name);\n`;
    if (extra.length)
        src += `export {${extra.join(', ')}};\n`;
    const dir = fs.mkdtempSync(path.join(process.env.BATS_TEST_TMPDIR ?? os.tmpdir(), 'shell-js-'));
    const out = path.join(dir, `${key(file)}.mjs`);
    fs.writeFileSync(out, src);
    return import(pathToFileURL(out).href);
}
