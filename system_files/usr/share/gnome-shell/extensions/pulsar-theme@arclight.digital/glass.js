// Glass and light for the Shell's surfaces: menus, the top bar, the OSDs
// (volume, brightness), notification banners, and GTK windows.
//
// GNOME owns the structure (layout, radii, type, timing); this adds only
// material and light, each a switch in the extension's settings:
//
//  * Glass: a surface's own background turns translucent (the theme's sheet
//    does that under .pulsar-glass) over a live blur of whatever is really
//    beneath it -- windows, video, the overview -- with a soft drop shadow.
//  * Glass windows: GTK apps' chrome (the engine makes libadwaita's window
//    ground, header bars and sidebars a little translucent in gtk.css) sits
//    over the same live blur, drawn inside each window actor so it moves,
//    minimizes and appears in the overview with the window. Content stays
//    solid.
//  * Lighting: one source per surface -- the button that opened a menu, the
//    screen edge an OSD or banner comes from. A cheap shader draws the rim
//    facing it, a little spill, a Fresnel glint inside the edge, faint
//    scatter and grain, and the date menu's divider. The rim warms while the
//    battery is low and goes the theme's red for a critical banner or a
//    battery about to run out.
//  * Power-on: when a surface appears its rim traces out from the source.
//  * Focus brackets: four corner brackets around the control the keyboard
//    is on, beside the stock focus ring (never instead of it).
//
// The blur (LiveBlur) is real, cheap and redone every frame: it keeps a
// half-size copy of the pixels already drawn beneath the surface, patched
// wherever a frame redraws, runs it down a Kawase pyramid and back, and
// draws the result up through a mask that rounds its corners and drops its
// shadow at full resolution.
// Shell.BlurEffect's background mode does the copy-and-blur too, but it
// cannot round its corners, which is why this builds the same paint nodes
// itself. Where it is on screen comes from the framebuffer's own matrices
// at paint time, so a window's glass is right in the overview's scaled
// previews too.
//
// Menus paint through an offscreen buffer (BoxPointer sets
// offscreen_redirect ALWAYS), where a copy of "what is beneath" would read
// an empty texture. A menu's glass therefore lives BESIDE it: two mirrors in
// its host's parent, one under it (the blur) and one over it (the light),
// that copy its geometry, fade and slide. The dash paints offscreen too
// (it fades as one while a window is dragged), and is dressed the same way.
//
// Never while the screen is locked, and never in high contrast.
import Clutter from 'gi://Clutter';
import Cogl from 'gi://Cogl';
import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';
import Graphene from 'gi://Graphene';
import Meta from 'gi://Meta';
import Mtk from 'gi://Mtk';
import Shell from 'gi://Shell';
import St from 'gi://St';

import * as AltTab from 'resource:///org/gnome/shell/ui/altTab.js';
import * as AppDisplay from 'resource:///org/gnome/shell/ui/appDisplay.js';
import * as CloseDialog from 'resource:///org/gnome/shell/ui/closeDialog.js';
import * as Background from 'resource:///org/gnome/shell/ui/background.js';
import * as Dash from 'resource:///org/gnome/shell/ui/dash.js';
import * as IBusCandidatePopup from 'resource:///org/gnome/shell/ui/ibusCandidatePopup.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as MessageList from 'resource:///org/gnome/shell/ui/messageList.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as Slider from 'resource:///org/gnome/shell/ui/slider.js';
import * as SwitcherPopup from 'resource:///org/gnome/shell/ui/switcherPopup.js';
import * as WorkspaceSwitcherPopup from 'resource:///org/gnome/shell/ui/workspaceSwitcherPopup.js';

// The blur: a dual-filter (Kawase) pyramid, the kind KWin blurs with.
// What is beneath is halved, then halved BLUR_LEVELS more times (one more
// on a 2x screen, so it is as wide in logical pixels), each step spreading
// its taps BLUR_OFFSET texels apart, and brought back up the same steps. A
// deep pyramid is both wide and smooth: a Gaussian as wide at one size
// needs taps so far apart that its kernel shows as ghosted copies. Then
// saturation to keep the color of what is behind, and contrast under 1 so
// a bright line of text behind cannot streak through.
const BLUR_LEVELS = 3;
const BLUR_OFFSET = 3;
// how finely a partial redraw is probed, in logical pixels
const TILE = 32;
const SATURATE = 1.5;
const CONTRAST = 0.8;
const BRIGHTNESS = 1.06;
// The blurred copy reaches this far past a surface on every side, so the
// blur has real pixels to draw on at the edge, and the shadow has room.
const BLUR_PAD = 64;
// How far past its own edge a surface's blur reads what is beside it, in
// logical pixels: about the blur's width, so a bright neighbor glows in at
// the edge the way it does through frosted glass, instead of the edge
// pixels repeating outward. Within both pads (BLUR_PAD, WINDOW_PAD).
const EDGE_SAMPLE = 24;
// The shadow floating glass (menus, Quick Settings, OSDs, banners, dialogs,
// the dash) casts: soft and ambient, from no direction -- 2px down, fading
// over 22px, in the theme's own deep ground (deepShadow()), at alpha
// [light theme, dark theme]. With the darkened band just inside the edge
// ([light, dark], drawn by the light) it lifts the glass off what is behind
// it. Drawn by the blur's mask, not CSS, because a box-shadow would be
// clipped by the BoxPointer's offscreen buffer; BLUR_PAD leaves it room.
const SHADOW = {y: 2, blur: 22, alpha: [0.14, 0.38]};
const EDGE_DARK = [0.14, 0.32];
// The theme's deep ground (background_deep), read off the top bar's glass
// tint, which the sheet makes rgba(background_deep, glass alpha); the last
// answer stands while the bar is transparent (the overview). A light
// theme's deep ground is pale: its hue is taken down to a dark ink. A dark
// one's keeps its hue, a little stronger, at most as light as it is.
let lastDeep = null;
function deepShadow(lt) {
    try {
        const bg = Main.panel.get_theme_node().get_background_color();
        if (bg.alpha > 0)
            lastDeep = [bg.red / 255, bg.green / 255, bg.blue / 255];
    } catch {}
    const c = lastDeep ?? [0, 0, 0];
    const l = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
    const [target, chroma] = lt ? [0.1, 3] : [Math.min(l, 0.06), 2];
    return c.map(v => Math.min(Math.max(target + (v - l) * chroma, 0), 1));
}
// The top bar's: short and close, a ledge rather than a float.
const PANEL_SHADOW = {pad: 16};
// the overview's own show/hide time (ui/overview.js ANIMATION_TIME)
const PANEL_FADE_MS = 250;
// How far the light may spill past the edge.
const LIGHT_PAD = 48;
// How close the light may come to the glass. A menu opened at the pointer
// (the desktop's, a window's) has its source on its own corner, inside the
// spill's reach: the spill lit the square behind the rounded corner, cut
// off where the source passes from one side of each point to the other.
// A panel button sits about 25px off its menu, and lights it cleanly.
const LIGHT_MIN_DISTANCE = 24;
const GRAIN = 0.008;
const GAIN = 1.3;
const POWER_ON_MS = 300;
// The lens: [rim band px, bend px, red/blue dispersion, sharpness at the rim].
// Menus, OSDs and banners are thick glass; windows are a thin pane, bent a
// little and never sharp (no copy kept for them).
const SURFACE_LENS = [28, 14, 0.12, 0.63];
// Menus, OSDs, banners and the dash are liquid glass: blurred less than a
// window, under a lighter tint (the sheet's surface_alpha), so what is
// behind them keeps its shapes, soft, and bends at the rim. Three levels
// with close taps, not two with wide ones: the same width (within 3% at 1x,
// 1.33x and 2x), but two levels 3.5 apart blurred a bright point into a
// diamond (the up-pass's eight taps, spread far: 145% uneven around the
// blur at 1.33x, 3.5% now), and big bright text behind showed it.
const SURFACE_LEVELS = 3;
const SURFACE_OFFSET = 1.6;
const WINDOW_LENS = [10, 4, 0, 0];
// What is beneath, lifted so its color reads through a light tint and text
// on the glass stays readable: darker behind a dark surface, lighter behind
// a light one (saturate, contrast, brightness).
// A clearer surface needs less of its contrast taken: text behind it now
// shows as shapes, and 0.75 flattened them to a wash.
const SURFACE_GRADE = {dark: [1.6, 0.85, 0.85], light: [1.45, 0.85, 1.1]};
// Windows match the panels 1:1 (Nick, 2026-10-02): the same grade, and the
// same blur below. They keep only their own thin lens (WINDOW_LENS): the
// panels' thick refracting rim would bend the window's own edge.
const WINDOW_GRADE = SURFACE_GRADE;
// libadwaita's window shape, measured on GNOME 50: the frame rect, its 1px
// border included, with 16px corners (15 inside the border). The mask
// follows it exactly and fades across the border; over the last few pixels
// the vibrancy fades out too (WINDOW_GRADE_EDGE), so the window's own
// antialiased edge shows what is beneath as it is, not a lifted halo.
const WINDOW_RADIUS = 16;
const WINDOW_PAD = 48;
const WINDOW_GRADE_EDGE = 4;
// A window's grade (WINDOW_GRADE) follows the scheme the theme is in, as
// the menus' does. A fixed [1.9, 0.9, 1.35] made what is beneath a window loud,
// bright blobs beside a menu. The scheme is read off the top bar's glass,
// which the same sheet colors for the same mode the GTK theme is in -- a
// single-mode theme included, where Dark Style says nothing about it. The
// bar goes transparent in the overview and on the lock screen; then it says
// nothing either, and the last answer stands.
let lastWindowGrade = WINDOW_GRADE.dark;
function windowGrade() {
    try {
        const bg = Main.panel.get_theme_node().get_background_color();
        if (bg.alpha > 0)
            lastWindowGrade = luminance(bg) > 0.5 ? WINDOW_GRADE.light : WINDOW_GRADE.dark;
    } catch {}
    return lastWindowGrade;
}
const ENGINE = '/usr/libexec/pulsar/pulsar-theme';

const MASK_DECL = `
uniform sampler2D tex;
uniform vec2 size;
uniform vec4 rect;
uniform float radius;
uniform vec3 grade;
uniform vec4 shadow;
uniform vec2 shadowGeom;
uniform float gradeEdge;
uniform float opacity;
uniform float soft;
uniform vec2 uvScale;
uniform sampler2D sharp;
uniform vec2 sharpScale;
uniform vec4 lens;
uniform float edgeDark;
uniform vec4 tint;
uniform sampler2D cut;
uniform vec4 cutRect;
float sd(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
vec3 unpremul(vec4 c) { return c.a > 0.0 ? c.rgb / c.a : vec3(0.0); }
`;
const MASK_CODE = `
vec2 uv = cogl_tex_coord_in[0].xy / uvScale;
vec2 f = uv * size;
vec2 ctr = rect.xy + rect.zw * 0.5;
vec2 b = rect.zw * 0.5;
float d = sd(f - ctr, b, radius);
/* The lens (lens: band width px, bend px, dispersion, clarity). Inside a
   band along the rim, sample from further in along the surface's normal,
   bending harder toward the edge, so what is behind magnifies and curves
   like a thick lens; there the frosted copy gives way to the sharp one,
   red and blue bent a little apart. Only the band pays for it. */
vec3 raw;
float t = lens.x > 0.0 ? clamp(1.0 + d / lens.x, 0.0, 1.0) : 0.0;
if (t > 0.0) {
  vec2 p = f - ctr;
  vec2 n = normalize(vec2(sd(p + vec2(0.5, 0.0), b, radius) - sd(p - vec2(0.5, 0.0), b, radius),
                          sd(p + vec2(0.0, 0.5), b, radius) - sd(p - vec2(0.0, 0.5), b, radius)) + 1e-5);
  float bend = t * t * t * lens.y;
  vec2 off = -n * bend / size;
  raw = unpremul(texture2D(tex, clamp(uv + off, 0.0, 1.0) * uvScale));
  if (lens.w > 0.0) {
    vec3 e;
    e.r = unpremul(texture2D(sharp, clamp(uv + off * (1.0 + lens.z), 0.0, 1.0) * sharpScale)).r;
    e.g = unpremul(texture2D(sharp, clamp(uv + off, 0.0, 1.0) * sharpScale)).g;
    e.b = unpremul(texture2D(sharp, clamp(uv + off * (1.0 - lens.z), 0.0, 1.0) * sharpScale)).b;
    raw = mix(raw, e, t * t * lens.w);
  }
} else {
  raw = unpremul(texture2D(tex, uv * uvScale));
}
float l = dot(raw, vec3(0.2126, 0.7152, 0.0722));
vec3 rgb = mix(vec3(l), raw, grade.x);
rgb = (rgb - 0.5) * grade.y + 0.5;
rgb = clamp(rgb * grade.z, 0.0, 1.0);
/* the darkened edge: a thin band just inside the rim, under the surface's
   own border -- the separation iOS 27 gives its glass instead of a shadow */
if (edgeDark > 0.0 && d < 0.0) rgb *= 1.0 - edgeDark * exp(d / 2.2);
/* where the surface's own antialiased edge lets this through, show plain
   blur, not the graded one: a lifted edge reads as a halo */
if (gradeEdge > 0.0) rgb = mix(raw, rgb, 1.0 - smoothstep(-gradeEdge, -1.0, d));
/* out to the surface's edge, fading across its 1px border: stop short and
   what is beneath shows unblurred through the tint as a second ring. A
   surface with no border on whole pixels (the top bar) gets a hard edge:
   its fade would show as a lighter frame. */
float a = soft > 0.0 ? 1.0 - smoothstep(-soft, 0.0, d) : step(d, 0.0);
/* a popup's own shape (cutRect: where its buffer lies, from here): only
   where it draws its body -- the rounded box and the arrow -- not the soft
   shadow and hairline border around them, whose alpha stays near 0.25. A
   glass popover's body is 0.47 at the clearest tint, so it is all in. */
if (cutRect.z > 0.0) {
  vec2 cu = (f + cutRect.xy) / cutRect.zw;
  vec2 in2 = step(vec2(0.0), cu) * step(cu, vec2(1.0));
  a *= in2.x * in2.y * smoothstep(0.3, 0.42, texture2D(cut, clamp(cu, 0.0, 1.0)).a);
}
/* the shadow: the same shape, dropped and softened, showing only outside it */
float ds = sd(f - (rect.xy + rect.zw * 0.5) - vec2(0.0, shadowGeom.x), rect.zw * 0.5, radius);
float s = shadow.a * (1.0 - smoothstep(-shadowGeom.y * 0.3, shadowGeom.y, ds)) * smoothstep(-0.5, 0.5, d);
/* the surface's own tint, painted here inside the rounded mask rather than
   by St, whose translucent rounded fills are pieced from separate corners */
rgb = mix(rgb, tint.rgb, tint.a);
/* a triangular dither of about half an 8-bit step, so the smooth dark
   gradients of a blur do not band on the screen */
vec2 q = gl_FragCoord.xy;
float n1 = fract(sin(dot(q, vec2(12.9898, 78.233))) * 43758.5453);
float n2 = fract(sin(dot(q + 17.31, vec2(39.3468, 11.135))) * 24634.6345);
rgb += (n1 + n2 - 1.0) / 255.0;
/* shadow is straight color and alpha, and s carries its alpha already:
   premultiplied once, here */
cogl_color_out = vec4(rgb * a + shadow.rgb * s, a + s) * opacity;
`;

// Nothing below makes a boxed value (a matrix, a rect, a point) while it
// paints. Each is a small JS object holding a native copy the collector does
// not count, so it never hurries for them: made every frame, they piled up
// for as long as the Shell was busy, hundreds of MB under a steady redraw.

// Each stage view's place on the stage and scale, by the framebuffer it
// paints into. A paint context does not say which view it paints (not to
// JS), and the stage does not list them; each is noted as it starts a frame.
// Views are remade when monitors change, and the notes with them.
const Views = {
    _map: new Map(),
    gen: 0,
    watch() {
        // not ??=: unwatch() leaves 0, which ??= would keep, and every lock
        // disables and re-enables the extension -- the first unlock would
        // leave no view known for the rest of the session
        if (this._id)
            return;
        this._id = global.stage.connect('before-paint', (_stage, view) => {
            const fb = view.get_framebuffer();
            if (!this._map.has(fb)) {
                const l = view.layout;
                this._map.set(fb, {x: l.x, y: l.y, w: l.width, h: l.height, scale: view.get_scale()});
            }
        });
    },
    get(fb) {
        return this._map.get(fb);
    },
    clear() {
        this._map.clear();
        this.gen++;
    },
    unwatch() {
        if (this._id)
            global.stage.disconnect(this._id);
        this._id = 0;
        this._map.clear();
    },
};

// Over a game the blurs hold still (see Glass._watchCover): each draws
// the blur it has, and nothing beneath is copied or blurred again, so a game
// redrawing every frame beneath costs one textured rectangle a frame, not a
// capture and a pyramid. One that moves, or has nothing kept yet (a menu
// first opened over the game), blurs once at its new place and holds that.
// Held on the stage views of the monitors a window covers (`monitors`,
// stage rects), or everywhere (`all`). `gen`
// counts the changes: each one, every kept copy is taken whole again.
const Hold = {
    all: false,
    monitors: [],
    gen: 0,
    set(all, monitors) {
        const same = all === this.all && monitors.length === this.monitors.length &&
            monitors.every((m, i) => m === this.monitors[i]);
        if (same)
            return false;
        this.all = all;
        this.monitors = monitors;
        this.gen++;
        return true;
    },
    // a deviceRect() painted on a view
    on(r) {
        return this.all || this.monitors.some(m =>
            r.vx0 >= m.x && r.vx0 < m.x + m.width && r.vy0 >= m.y && r.vy0 < m.y + m.height);
    },
};

// Where the rect (x, y, w, h), in the painted actor's coordinates, lands in
// the framebuffer being painted, in device pixels (top-left origin), written
// into `out`. Painting onto a view, from the actor's place on the stage (plain
// numbers); anywhere else (an offscreen, a screenshot's), through the
// framebuffer's matrices, the rare case that may allocate. A clone's paint
// (a window's preview in the overview) goes through the matrices even on a
// view: the actor's place on the stage is where the WINDOW is, and the
// preview is somewhere else, scaled, by the clone's transform alone.
function deviceRect(fb, actor, x, y, w, h, out, clone = false) {
    const v = Views.get(fb);
    if (v && clone) {
        if (!matrixRect(fb, x, y, w, h, out))
            return false;
        out.scale = v.scale;
        out.sx0 = out.x / v.scale + v.x;
        out.sy0 = out.y / v.scale + v.y;
        out.sx1 = (out.x + out.w) / v.scale + v.x;
        out.sy1 = (out.y + out.h) / v.scale + v.y;
        out.vx0 = v.x;
        out.vy0 = v.y;
        out.vx1 = v.x + v.w;
        out.vy1 = v.y + v.h;
        return true;
    }
    if (v) {
        const [tx, ty] = actor.get_transformed_position();
        const [tw, th] = actor.get_transformed_size();
        const sx = tw / actor.width, sy = th / actor.height;
        const x0 = (tx + x * sx - v.x) * v.scale, y0 = (ty + y * sy - v.y) * v.scale;
        const x1 = x0 + w * sx * v.scale, y1 = y0 + h * sy * v.scale;
        out.x = Math.floor(x0);
        out.y = Math.floor(y0);
        out.w = Math.ceil(x1) - out.x;
        out.h = Math.ceil(y1) - out.y;
        // the on-stage rect, for _covered
        out.sx0 = tx + x * sx;
        out.sy0 = ty + y * sy;
        out.sx1 = out.sx0 + w * sx;
        out.sy1 = out.sy0 + h * sy;
        out.scale = v.scale;
        // this view's own part of the stage: the redraw clip is per view, so
        // nothing past its edge (another monitor) can ever count as redrawn
        out.vx0 = v.x;
        out.vy0 = v.y;
        out.vx1 = v.x + v.w;
        out.vy1 = v.y + v.h;
        return true;
    }
    out.sx0 = NaN;
    out.scale = 1;
    return matrixRect(fb, x, y, w, h, out);
}

function matrixRect(fb, x, y, w, h, out) {
    // row vectors: v' = v * (modelview * projection), z = 0, w = 1
    const m = fb.get_modelview_matrix().multiply(fb.get_projection_matrix()).to_float();
    const vp = fb.get_viewport4fv();
    let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
    for (let i = 0; i < 4; i++) {
        const px = i & 1 ? x + w : x, py = i & 2 ? y + h : y;
        const cx = px * m[0] + py * m[4] + m[12];
        const cy = px * m[1] + py * m[5] + m[13];
        const cw = px * m[3] + py * m[7] + m[15];
        if (Math.abs(cw) < 1e-6)
            return false;
        const sx = vp[0] + (cx / cw + 1) * vp[2] / 2;
        const sy = vp[1] + (1 - cy / cw) * vp[3] / 2;
        x0 = Math.min(x0, sx);
        y0 = Math.min(y0, sy);
        x1 = Math.max(x1, sx);
        y1 = Math.max(y1, sy);
    }
    out.x = Math.floor(x0);
    out.y = Math.floor(y0);
    out.w = Math.ceil(x1) - out.x;
    out.h = Math.ceil(y1) - out.y;
    return true;
}

// Clutter flags only a clone's source as in a clone paint, not the source's
// children, and window glass is a child of the window actor.
function inClonePaint(actor) {
    for (let a = actor; a; a = a.get_parent()) {
        if (a.is_in_clone_paint())
            return true;
    }
    return false;
}

function box(x1, y1, x2, y2) {
    return new Clutter.ActorBox({x1, y1, x2, y2});
}

// Scratch textures for one blur at a time, shared by every glass surface
// (a paint's nodes are drawn before the next actor paints). Allocated with
// headroom and reused, so the paint path allocates no GPU memory: creating
// textures per paint -- what a ClutterBlurNode does -- grew the Shell by
// gigabytes a minute, and its collections were the freezes.
const Scratch = {
    _t: {},
    get(key, w, h) {
        const t = this._t[key];
        if (t && t.W >= w && t.H >= h)
            return t;
        const W = Math.ceil(Math.max(w, t?.W ?? 0) / 64) * 64;
        const H = Math.ceil(Math.max(h, t?.H ?? 0) / 64) * 64;
        // the full-size copy of the framebuffer stays 8-bit (see makeTarget)
        this._t[key] = makeTarget(W, H, key !== 'full');
        return this._t[key];
    },
    clear() {
        this._t = {};
    },
};

// Every stage after the copy keeps 16-bit float color: 8 bits, rounded at
// each of the chain's passes, band into visible steps in a dark theme's
// narrow range. (The copy itself stays 8-bit: GL will not blit between an
// 8-bit framebuffer and a float one, and it has no more to keep.) Falls back
// to 8-bit where the driver has no half floats.
let floatTargets = true;
function makeTarget(W, H, precise = true) {
    const ctx = global.stage.context.get_backend().get_cogl_context();
    if (precise && floatTargets) {
        try {
            const tex = Cogl.Texture2D.new_with_format(ctx, W, H, Cogl.PixelFormat.RGBA_FP_16161616_PRE);
            const fb = Cogl.Offscreen.new_with_texture(tex);
            fb.allocate();
            fb.orthographic(0, 0, W, H, -1, 1);
            return {W, H, tex, fb};
        } catch (e) {
            floatTargets = false;
            console.warn(`pulsar-theme: glass: no half-float targets, using 8-bit (${e.message})`);
        }
    }
    const tex = Cogl.Texture2D.new_with_size(ctx, W, H);
    const fb = Cogl.Offscreen.new_with_texture(tex);
    fb.allocate();
    fb.orthographic(0, 0, W, H, -1, 1);
    return {W, H, tex, fb};
}

// The dual-filter (Kawase) pyramid. Down: five taps, the centre and four
// diagonals, each step half the size of the last. Up: eight taps weighted
// as a tent. Every tap is clamped to `box`, the part of the source in use
// (and, for the first step, the part of it that was on screen: off-screen
// padding repeats the screen's edge instead of reading black).
const DOWN_DECL = `
uniform sampler2D tex;
uniform vec2 halfPixel;
uniform vec4 box;
vec4 tap(vec2 uv) { return texture2D(tex, clamp(uv, box.xy, box.zw)); }
`;
const DOWN_CODE = `
vec2 uv = cogl_tex_coord_in[0].xy;
vec2 h = halfPixel;
vec4 c = tap(uv) * 4.0;
c += tap(uv - h);
c += tap(uv + h);
c += tap(uv + vec2(h.x, -h.y));
c += tap(uv - vec2(h.x, -h.y));
cogl_color_out = c / 8.0;
`;
const UP_DECL = `
uniform sampler2D tex;
uniform vec2 halfPixel;
uniform vec4 box;
vec4 tap(vec2 uv) { return texture2D(tex, clamp(uv, box.xy, box.zw)); }
`;
const UP_CODE = `
vec2 uv = cogl_tex_coord_in[0].xy;
vec2 h = halfPixel;
vec4 c = tap(uv + vec2(-h.x * 2.0, 0.0));
c += tap(uv + vec2(-h.x, h.y)) * 2.0;
c += tap(uv + vec2(0.0, h.y * 2.0));
c += tap(uv + vec2(h.x, h.y)) * 2.0;
c += tap(uv + vec2(h.x * 2.0, 0.0));
c += tap(uv + vec2(h.x, -h.y)) * 2.0;
c += tap(uv + vec2(0.0, -h.y * 2.0));
c += tap(uv + vec2(-h.x, -h.y)) * 2.0;
cogl_color_out = c / 12.0;
`;

// One snippet per shader, shared by every pipeline that runs it. Cogl's
// program cache tells snippets apart by pointer, not by source: a snippet
// made per surface is a new GLSL program compiled and linked for every menu,
// window and popover the first time it paints.
const SNIPPETS = new Map();
function snippet(decl, code) {
    let s = SNIPPETS.get(code);
    if (!s) {
        s = Cogl.Snippet.new(Cogl.SnippetHook.FRAGMENT, decl, null);
        s.set_replace(code);
        SNIPPETS.set(code, s);
    }
    return s;
}

function pipeline(decl, code) {
    const ctx = global.stage.context.get_backend().get_cogl_context();
    const p = Cogl.Pipeline.new(ctx);
    p.set_layer_filters(0, Cogl.PipelineFilter.LINEAR, Cogl.PipelineFilter.LINEAR);
    p.set_layer_wrap_mode(0, Cogl.PipelineWrapMode.CLAMP_TO_EDGE);
    if (code)
        p.add_snippet(snippet(decl, code));
    return p;
}

// Draw `pipe` (reading its layer 0) into `target` over (x0, y0)-(x1, y1),
// now. Direct Cogl draws, not paint nodes: nodes made per paint are freed
// only when the JS collector runs, in big stalling batches. Flushed at once:
// the scratch textures are shared by every glass surface, and a draw left
// queued in one target's journal would read a scratch texture only after
// the next surface had drawn its own pixels into it -- someone else's blur,
// or an empty one, a dark rectangle for a frame.
function pass(target, pipe, x0, y0, x1, y1, u0, v0, u1, v1) {
    target.fb.draw_textured_rectangle(pipe, x0, y0, x1, y1, u0, v0, u1, v1);
    target.fb.flush();
}

// The size of each step of the pyramid, from the half-size copy down.
function levels(hw, hh, n, out) {
    out.length = n + 1;
    let w = hw, h = hh;
    for (let i = 0; i <= n; i++) {
        out[i] = [w, h];
        w = Math.max(1, Math.ceil(w / 2));
        h = Math.max(1, Math.ceil(h / 2));
    }
    return out;
}

// How the redraw clip overlaps the stage rect (x0, y0)-(x1, y1), grown by
// one logical pixel on every side (within the stage). The clip is in logical
// pixels, rounded outward from the device pixels actually repainted, so at a
// fractional scale its edge can claim a device pixel that still holds the
// last frame -- the glass's own window, the bar over it. Blurring that
// pixel feeds the glass its own image back, and it flickers. A region the
// clip holds with a pixel to spare was repainted to its last device pixel.
function probe(clip, q, x0, y0, x1, y1, r) {
    q.x = Math.max(r.vx0, x0 - 1);
    q.y = Math.max(r.vy0, y0 - 1);
    q.width = Math.min(r.vx1, x1 + 1) - q.x;
    q.height = Math.min(r.vy1, y1 + 1) - q.y;
    return clip.contains_rectangle(q);
}

// The live blur: under the actor's own paint, a blurred copy of what is
// already drawn beneath it, cut to a rounded shape, graded, and shadowed.
// `pad` lets it draw past the actor's edges (the shadow of a surface it is
// on directly); the shape is given in the actor's coordinates.
//
// Every paint blurs afresh, so the glass follows what moves beneath it
// frame for frame. What it blurs is a kept half-size copy of what is
// beneath: a redraw of all of the glass replaces the whole copy, and a
// partial one (a cursor, a caret, a window dragged across part of it)
// patches in only the redrawn part. Outside a redraw the framebuffer holds
// the last frame whole, the glass's own window and everything over it
// included; blurring those pixels drew dark squares. Inside it, at this
// point in the paint, only what is beneath has been drawn.
const LiveBlur = GObject.registerClass(
class PulsarLiveBlur extends Clutter.Effect {
    constructor(params = {}) {
        super();
        this._pad = params.pad ?? 0;
        this._down = pipeline(DOWN_DECL, DOWN_CODE);
        this._up = pipeline(UP_DECL, UP_CODE);
        this._downLoc = {};
        this._upLoc = {};
        for (const u of ['tex', 'halfPixel', 'box']) {
            this._downLoc[u] = this._down.get_uniform_location(u);
            this._upLoc[u] = this._up.get_uniform_location(u);
        }
        this._down.set_uniform_1i(this._downLoc.tex, 0);
        this._up.set_uniform_1i(this._upLoc.tex, 0);
        this._mask = pipeline(MASK_DECL, MASK_CODE);
        this._loc = {};
        for (const u of ['tex', 'size', 'rect', 'radius', 'grade', 'shadow', 'shadowGeom', 'gradeEdge', 'opacity', 'soft',
            'uvScale', 'sharp', 'sharpScale', 'lens', 'edgeDark', 'tint', 'cut', 'cutRect'])
            this._loc[u] = this._mask.get_uniform_location(u);
        this._mask.set_uniform_1i(this._loc.tex, 0);
        this._mask.set_uniform_1i(this._loc.sharp, 1);
        this._mask.set_uniform_1i(this._loc.cut, 2);
        for (const l of [1, 2]) {
            this._mask.set_layer_filters(l, Cogl.PipelineFilter.LINEAR, Cogl.PipelineFilter.LINEAR);
            this._mask.set_layer_wrap_mode(l, Cogl.PipelineWrapMode.CLAMP_TO_EDGE);
        }
        // setCut(): a popup's buffer, whose alpha is the shape
        this._cut = null;
        this._f('cutRect', 0, 0, 0, 0);
        // [band px, bend px, dispersion, clarity]; the sharp rim reads the
        // unblurred half-size copy
        this._lens = params.lens ?? [0, 0, 0, 0];
        // how many times it is halved past the first: how wide the blur is
        this._depth = params.levels ?? BLUR_LEVELS;
        // and how far apart each step's taps are
        this._offset = params.offset ?? BLUR_OFFSET;
        this._f('lens', ...this._lens);
        this.setEdgeDark(0);
        this.setTint(0, 0, 0, 0);
        this._shape = null;
        // per stage view (by framebuffer): the kept copy and its blur
        this._states = new Map();
        this._last = null;          // the one a clone paint shows
        this._levels = [];
        this._v2 = [0, 0];
        this._v4 = [0, 0, 0, 0];
        this.setGrade(SATURATE, CONTRAST, BRIGHTNESS);
        this.setShadowGeom(SHADOW.y, SHADOW.blur);
        this.setShadow(0, 0, 0, 0);
        this.setGradeEdge(0);
        this.setSoft(1);
    }

    // the width of the antialiased edge; 0 for a hard, pixel-aligned one
    setSoft(px) {
        this._f('soft', px);
    }

    _f(name, ...v) {
        this._mask.set_uniform_float(this._loc[name], v.length, 1, v);
    }

    // straight (not premultiplied) color and alpha; none until set
    setShadow(r, g, b, a) {
        this._f('shadow', r, g, b, a);
        this.queue_repaint();
    }

    setShadowGeom(y, blur) {
        this._f('shadowGeom', y, blur);
    }

    setGrade(saturate, contrast, brightness) {
        this._f('grade', saturate, contrast, brightness);
        this.queue_repaint();
    }

    setGradeEdge(px) {
        this._f('gradeEdge', px);
    }

    setEdgeDark(v) {
        this._f('edgeDark', v);
    }

    // straight (not premultiplied) color and alpha, painted over the blur
    setTint(r, g, b, a) {
        this._f('tint', r, g, b, a);
        this.queue_repaint();
    }

    // Hold the blur it has instead of copying what is beneath. Let go, the
    // next paint copies all of it again: what is beneath may have changed
    // anywhere while it was held.
    setFrozen(v) {
        if (this._frozen === v)
            return;
        this._frozen = v;
        if (!v) {
            for (const s of this._states.values())
                s.key[0] = NaN;
        }
        this.queue_repaint();
    }

    // the rounded shape, in the actor's coordinates
    setShape(rect, radius) {
        // the same shape again (a relayout that moved nothing): no repaint
        const s = this._shape;
        if (s && radius === this._shapeRadius && rect.every((v, i) => v === s[i]))
            return;
        this._shapeRadius = radius;
        this._shape = rect;
        this._f('radius', radius);
        this.queue_repaint();
    }

    // Cut to what another actor's buffer draws: `get()` gives [texture, x,
    // y, width, height], where the buffer lies in this actor's coordinates,
    // or null for nothing drawn yet (then no blur at all).
    setCut(get) {
        this._cut = get;
        this.queue_repaint();
    }

    // the big preview's kept blur: the larger of the two
    _bigPreview() {
        const ps = this._previews;
        if (!ps)
            return null;
        return (ps[1].key[2] || 0) > (ps[0].key[2] || 0) ? ps[1] : ps[0];
    }

    vfunc_modify_paint_volume(volume) {
        // The actors this draws on are empty: their volume is their own
        // box, at their origin. Set outright, from one kept point.
        const actor = this.get_actor();
        if (this._pad && actor) {
            this._origin ??= new Graphene.Point3D({x: -this._pad, y: -this._pad, z: 0});
            volume.set_origin(this._origin);
            volume.set_width(actor.width + 2 * this._pad);
            volume.set_height(actor.height + 2 * this._pad);
        }
        return true;
    }

    vfunc_paint_node(root, paintContext, _flags) {
        const actor = this.get_actor();
        try {
            this._paint(root, paintContext, actor);
        } catch (e) {
            if (!this._warned)
                console.warn(`pulsar-theme: glass: ${e.message}`);
            this._warned = true;
        }
        // Nothing else: the actors this draws under are empty (a mirror's
        // backdrop, the bar's, a window's), and a node for their own paint,
        // made every paint, is one more thing for the collector.
    }

    // Whether this redraw covers all of the glass on the stage. (Its padding
    // can run off screen, where no redraw reaches: only the on-stage part
    // counts.)
    _covered(clip, r, loose = false) {
        // not painting onto a view: nothing to go on but a whole redraw
        if (!clip || Number.isNaN(r.sx0))
            return true;
        const x0 = Math.max(r.vx0, Math.floor(r.sx0)), y0 = Math.max(r.vy0, Math.floor(r.sy0));
        const x1 = Math.min(r.vx1, Math.ceil(r.sx1)), y1 = Math.min(r.vy1, Math.ceil(r.sy1));
        if (x1 <= x0 || y1 <= y0)
            return true;
        const q = this._clipRect ??= new Mtk.Rectangle();
        if (loose) {
            q.x = x0;
            q.y = y0;
            q.width = x1 - x0;
            q.height = y1 - y0;
            return clip.contains_rectangle(q) === Mtk.RegionOverlap.IN;
        }
        return probe(clip, q, x0, y0, x1, y1, r) === Mtk.RegionOverlap.IN;
    }

    // Moved, and this redraw shows only part of what is beneath at the new
    // place: redraw all of it on the very next frame.
    _redrawSoon() {
        if (this._redrawPending)
            return;
        this._redrawPending = GLib.idle_add(GLib.PRIORITY_HIGH, () => {
            this._redrawPending = 0;
            this.get_actor()?.queue_redraw();
            return GLib.SOURCE_REMOVE;
        });
    }

    vfunc_set_actor(actor) {
        if (!actor && this._redrawPending) {
            GLib.source_remove(this._redrawPending);
            this._redrawPending = 0;
        }
        if (!actor) {
            this._states.clear();
            this._last = null;
            this._previews = null;
        }
        super.vfunc_set_actor(actor);
    }

    _paint(root, paintContext, actor) {
        const aw = actor.width, ah = actor.height;
        const p = this._pad;
        const x0 = -p, y0 = -p, w = aw + 2 * p, h = ah + 2 * p;
        if (!this._shape || aw < 1 || ah < 1)
            return;
        const fb = paintContext.get_framebuffer();
        // A clone's paint (a window's preview in the overview) blurs what
        // is beneath the preview, all the way through the overview's zoom,
        // kept apart from the real blur. The blur the window's last real
        // paint kept was of what lay beneath it then: at login that paint
        // can come before the wallpaper does, and the preview sat unfrosted
        // until the overview closed. A paint anywhere but a stage view (a
        // screenshot, a screencast) shows what the screen does: a window
        // screenshot paints the window alone, with nothing beneath it to
        // blur.
        const clone = inClonePaint(actor);
        if (!Views.get(fb) && (clone || this._last?.result)) {
            const s = clone && this._bigPreview()?.result ? this._bigPreview() : this._last;
            if (s?.result)
                this._draw(fb, actor, x0, y0, w, h, s);
            return;
        }
        // Held (setFrozen): the blur it has, and nothing copied.
        if (this._frozen) {
            const s = this._states.get(fb) ?? this._last;
            if (s?.result)
                this._draw(fb, actor, x0, y0, w, h, s);
            return;
        }
        const r = this._rect ??= {x: 0, y: 0, w: 0, h: 0, sx0: 0, sy0: 0, sx1: 0, sy1: 0, scale: 1};
        if (!deviceRect(fb, actor, x0, y0, w, h, r, clone) ||
            r.w < 2 || r.h < 2 || r.w > 16384 || r.h > 16384)
            return;

        // A stage view keeps its copy from frame to frame. Anything else (a
        // screenshot's offscreen, a screencast's) is drawn whole, once, into
        // scratch, and keeps nothing.
        let s;
        const onView = !Number.isNaN(r.sx0);
        if (clone) {
            if (!onView)
                return;
            // The big preview and the workspace thumbnail each keep their
            // own copy: blurring both into one, each would find it moved and
            // blur it whole every frame. Each takes the one already its size,
            // else the one the other did not paint with last. (Telling them
            // apart by size against the big one's last size, a window shrunk
            // to under half had its preview taken for the thumbnail, and it
            // showed the big window's old blur squeezed into it, for good.)
            const ps = this._previews ??= [0, 1].map(() =>
                ({copy: null, result: null, key: [NaN, NaN, NaN, NaN], hw: 0, hh: 0, used: 0}));
            s = ps.find(q => q.key[2] === r.w && q.key[3] === r.h) ??
                (ps[0].used <= ps[1].used ? ps[0] : ps[1]);
            s.used = this._previewTick = (this._previewTick ?? 0) + 1;
        } else if (onView) {
            if (this._gen !== Views.gen) {
                this._states.clear();
                this._gen = Views.gen;
            }
            s = this._states.get(fb);
            if (!s) {
                s = {copy: null, result: null, key: [NaN, NaN, NaN, NaN], hw: 0, hh: 0};
                this._states.set(fb, s);
            }
        } else {
            s = this._transient ??= {copy: null, result: null, key: [NaN, NaN, NaN, NaN], hw: 0, hh: 0};
            s.key[0] = NaN;
        }
        const hw = Math.ceil(r.w / 2), hh = Math.ceil(r.h / 2);
        const k = s.key;
        // Whenever what is held (Hold) changes, the copy is taken whole
        // again, once: while held, what is beneath may have changed anywhere.
        if (onView && !clone && s.holdGen !== Hold.gen) {
            s.holdGen = Hold.gen;
            k[0] = NaN;
        }
        const moved = k[0] !== r.x || k[1] !== r.y || k[2] !== r.w || k[3] !== r.h;
        // Held on this view, in place, with a blur kept: that blur as it is.
        if (onView && !clone && !moved && s.copy && s.result && Hold.on(r)) {
            this._draw(fb, actor, x0, y0, w, h, s);
            return;
        }
        const clip = paintContext.get_redraw_clip();
        const covered = this._covered(clip, r);

        // Moving, the strict test would almost never pass (the redraw is the
        // window's own old and new place, no pixel to spare): there a stale
        // device pixel can only be at the padding's outer edge, far from the
        // glass, and gone the moment it stops.
        if (moved || !s.copy) {
            if (!covered && !this._covered(clip, r, true)) {
                // nothing whole to copy from yet: last frame's blur for this
                // one frame (gone for a frame, the glass would blink)
                if (s.result)
                    this._draw(fb, actor, x0, y0, w, h, s);
                this._redrawSoon();
                return;
            }
            if (onView) {
                // made to fit, and made again when it no longer fits: too
                // small, or four times the size it needs (a maximized window
                // restored kept a whole screen's worth). Only here, where
                // all of it is copied and blurred again anyway.
                const tw = Math.ceil(hw / 32) * 32 + 32, th = Math.ceil(hh / 32) * 32 + 32;
                const fits = t => t && t.W >= hw && t.H >= hh && t.W * t.H <= 4 * tw * th;
                if (!fits(s.copy))
                    s.copy = makeTarget(tw, th, false);
                if (!fits(s.result))
                    s.result = makeTarget(tw, th);
            } else {
                s.copy = Scratch.get('tcopy', hw, hh);
                s.result = Scratch.get('tresult', hw, hh);
            }
            if (!this._capture(fb, r, s, null))
                return;
            k[0] = r.x;
            k[1] = r.y;
            k[2] = r.w;
            k[3] = r.h;
        } else {
            this._patched = 0;
            if (!this._capture(fb, r, s, covered ? null : clip))
                return;
            // nothing beneath it redrawn (only the glass's own window): the
            // blur it has is still right
            if (!covered && !this._patched) {
                this._draw(fb, actor, x0, y0, w, h, s);
                return;
            }
        }
        s.hw = hw;
        s.hh = hh;
        // What the blur may read, in the copy's half-size texels: the
        // surface's own shape and EDGE_SAMPLE beyond it, on screen, so what
        // is beside the surface bleeds in at its edge as through frosted
        // glass. (Clamped to the shape alone, the edge pixels repeated
        // outward and the edge looked unstable as anything beside it moved.)
        const sp = this._shape, fw = fb.get_width(), fh = fb.get_height();
        const kx = r.w / w / 2, ky = r.h / h / 2;
        const m = EDGE_SAMPLE;
        const bx = s.box ??= [0, 0, 0, 0];
        bx[0] = Math.max((sp[0] - m - x0) * kx, (Math.max(r.x, 0) - r.x) / 2, 0);
        bx[1] = Math.max((sp[1] - m - y0) * ky, (Math.max(r.y, 0) - r.y) / 2, 0);
        bx[2] = Math.min((sp[0] + sp[2] + m - x0) * kx, (Math.min(r.x + r.w, fw) - r.x) / 2, r.w / 2);
        bx[3] = Math.min((sp[1] + sp[3] + m - y0) * ky, (Math.min(r.y + r.h, fh) - r.y) / 2, r.h / 2);
        this._blur(s, r.scale);
        // what is beneath the preview may change anywhere before the next
        // overview: its next paint copies all of it again
        if (onView && !clone) {
            this._last = s;
            for (const q of this._previews ?? [])
                q.key[0] = NaN;
        }
        this._draw(fb, actor, x0, y0, w, h, s);
    }

    // Copy what is beneath into the kept half-size copy: all of it, or
    // (given the redraw's clip) only the parts this redraw repainted,
    // trimmed inward to whole half-size texels so no stale pixel mixes in.
    _capture(fb, r, s, clip) {
        const fw = fb.get_width(), fh = fb.get_height();
        // on screen, in the rect's own device pixels
        const ox0 = Math.max(r.x, 0) - r.x, oy0 = Math.max(r.y, 0) - r.y;
        const ox1 = Math.min(r.x + r.w, fw) - r.x, oy1 = Math.min(r.y + r.h, fh) - r.y;
        if (ox1 <= ox0 || oy1 <= oy0)
            return false;
        const full = Scratch.get('full', r.w, r.h);
        if (!clip)
            return this._patch(fb, r, s, full, ox0, oy0, ox1, oy1, true);
        // Which parts were redrawn: the clip's own rectangles cannot be read
        // from JS (MtkRegion hands them back as bare structs, and GJS
        // crashes the Shell on those), so it is probed in tiles, and each
        // row's run of wholly redrawn tiles, merged down while the rows
        // below repeat it, is one patch.
        const v = Views.get(fb);
        const q = this._tile ??= new Mtk.Rectangle();
        const x0 = Math.max(r.vx0, Math.floor(r.sx0)), y0 = Math.max(r.vy0, Math.floor(r.sy0));
        const x1 = Math.min(r.vx1, Math.ceil(r.sx1)), y1 = Math.min(r.vy1, Math.ceil(r.sy1));
        const open = this._runs ??= [];
        open.length = 0;
        const flush = (run) => {
            const ax0 = Math.max(ox0, Math.ceil((run[0] - v.x) * v.scale) - r.x);
            const ay0 = Math.max(oy0, Math.ceil((run[2] - v.y) * v.scale) - r.y);
            const ax1 = Math.min(ox1, Math.floor((run[1] - v.x) * v.scale) - r.x);
            const ay1 = Math.min(oy1, Math.floor((run[3] - v.y) * v.scale) - r.y);
            if (ax1 > ax0 && ay1 > ay0)
                this._patch(fb, r, s, full, ax0, ay0, ax1, ay1, false);
        };
        for (let ty = y0; ty < y1; ty += TILE) {
            const ty1 = Math.min(ty + TILE, y1);
            // a row wholly in or wholly out is one probe, not one per tile
            const row = probe(clip, q, x0, ty, x1, ty1, r);
            let start = -1;
            // one step past the end, which closes the last run
            for (let tx = x0; tx < x1 + TILE; tx += TILE) {
                let inside = row === Mtk.RegionOverlap.IN && tx < x1;
                if (row === Mtk.RegionOverlap.PART && tx < x1) {
                    inside = probe(clip, q, tx, ty, Math.min(tx + TILE, x1), ty1, r) === Mtk.RegionOverlap.IN;
                }
                if (inside && start < 0) {
                    start = tx;
                } else if (!inside && start >= 0) {
                    const ex = Math.min(tx, x1);
                    // the same run as the row above: grow it down
                    const same = open.find(o => o[0] === start && o[1] === ex && o[3] === ty);
                    if (same) {
                        same[3] = ty1;
                        same[4] = 1;
                    } else {
                        open.push([start, ex, ty, ty1, 1]);
                    }
                    start = -1;
                }
            }
            // runs this row did not continue are done
            for (let i = open.length - 1; i >= 0; i--) {
                if (open[i][4]) {
                    open[i][4] = 0;
                    continue;
                }
                flush(open[i]);
                open.splice(i, 1);
            }
        }
        open.forEach(flush);
        open.length = 0;
        return true;
    }

    // One region, in the rect's device pixels: blit it, then halve it into
    // the copy. A whole capture spreads the on-screen part's edge over any
    // off-screen padding; a patch reads only its own pixels.
    _patch(fb, r, s, full, ax0, ay0, ax1, ay1, whole) {
        let hx0, hy0, hx1, hy1;
        if (whole) {
            [hx0, hy0, hx1, hy1] = [0, 0, Math.ceil(r.w / 2), Math.ceil(r.h / 2)];
        } else {
            [hx0, hy0] = [Math.ceil(ax0 / 2), Math.ceil(ay0 / 2)];
            [hx1, hy1] = [Math.floor(ax1 / 2), Math.floor(ay1 / 2)];
            if (hx1 <= hx0 || hy1 <= hy0)
                return true;
            [ax0, ay0, ax1, ay1] = [hx0 * 2, hy0 * 2, hx1 * 2, hy1 * 2];
        }
        if (!fb.blit(full.fb, r.x + ax0, r.y + ay0, ax0, ay0, ax1 - ax0, ay1 - ay0))
            return false;
        this._patched++;
        const D = this._down, W = full.W, H = full.H;
        D.set_layer_texture(0, full.tex);
        this._v2[0] = this._v2[1] = 0;
        D.set_uniform_float(this._downLoc.halfPixel, 2, 1, this._v2);
        const b = this._v4;
        b[0] = (ax0 + 0.5) / W;
        b[1] = (ay0 + 0.5) / H;
        b[2] = (ax1 - 0.5) / W;
        b[3] = (ay1 - 0.5) / H;
        D.set_uniform_float(this._downLoc.box, 4, 1, b);
        pass(s.copy, D, hx0, hy0, hx1, hy1, 2 * hx0 / W, 2 * hy0 / H, 2 * hx1 / W, 2 * hy1 / H);
        return true;
    }

    // The copy down the pyramid and back up into the kept result.
    // As wide in logical pixels at every scale as at 1.0, where it was
    // tuned. Each extra level doubles the width in device pixels, and whole
    // levels alone missed the fractional scales: 1.25 got none and was 20%
    // narrower, 1.5 got one and was a third wider. The taps' spread makes
    // up the rest: scale / 2^extra, exactly 1 at 1.0 and 2.0.
    _blur(s, scale) {
        const extra = Math.max(0, Math.round(Math.log2(scale)));
        const n = this._depth + extra;
        const offset = this._offset * scale / 2 ** extra;
        const L = levels(s.hw, s.hh, n, this._levels);
        const D = this._down, U = this._up;
        const b = this._v4, hp = this._v2;
        let src = s.copy;
        for (let i = 1; i <= n; i++) {
            const dst = Scratch.get(`d${i}`, L[i][0], L[i][1]);
            const [sw, sh] = L[i - 1];
            D.set_layer_texture(0, src.tex);
            hp[0] = 0.5 * offset / src.W;
            hp[1] = 0.5 * offset / src.H;
            D.set_uniform_float(this._downLoc.halfPixel, 2, 1, hp);
            if (i === 1 && s.box[2] - s.box[0] >= 1 && s.box[3] - s.box[1] >= 1) {
                b[0] = (s.box[0] + 0.5) / src.W;
                b[1] = (s.box[1] + 0.5) / src.H;
                b[2] = (s.box[2] - 0.5) / src.W;
                b[3] = (s.box[3] - 0.5) / src.H;
            } else {
                b[0] = 0.5 / src.W;
                b[1] = 0.5 / src.H;
                b[2] = (sw - 0.5) / src.W;
                b[3] = (sh - 0.5) / src.H;
            }
            D.set_uniform_float(this._downLoc.box, 4, 1, b);
            pass(dst, D, 0, 0, L[i][0], L[i][1], 0, 0, sw / src.W, sh / src.H);
            src = dst;
        }
        for (let i = n - 1; i >= 0; i--) {
            const dst = i === 0 ? s.result : Scratch.get(`u${i}`, L[i][0], L[i][1]);
            const [sw, sh] = L[i + 1];
            U.set_layer_texture(0, src.tex);
            hp[0] = 0.5 * offset / src.W;
            hp[1] = 0.5 * offset / src.H;
            U.set_uniform_float(this._upLoc.halfPixel, 2, 1, hp);
            b[0] = 0.5 / src.W;
            b[1] = 0.5 / src.H;
            b[2] = (sw - 0.5) / src.W;
            b[3] = (sh - 0.5) / src.H;
            U.set_uniform_float(this._upLoc.box, 4, 1, b);
            pass(dst, U, 0, 0, L[i][0], L[i][1], 0, 0, sw / src.W, sh / src.H);
            src = dst;
        }
    }

    // The kept blur, drawn back up through the mask.
    _draw(fb, actor, x0, y0, w, h, s) {
        // a first capture that failed leaves no size: uv / 0 is NaN glass
        if (!s.result || !s.hw || !s.hh)
            return;
        const out = s.result;
        const rw = s.hw, rh = s.hh;
        const sh = this._shape;
        const opacity = actor.get_paint_opacity();
        const cut = this._cut?.();
        if (this._cut && !cut)
            return;
        this._mask.set_layer_texture(0, out.tex);
        // a layer must hold a texture; with no cut it reads none of it
        this._mask.set_layer_texture(2, cut?.[0] ?? out.tex);
        if (cut)
            this._f('cutRect', cut[1] + x0, cut[2] + y0, cut[3], cut[4]);
        this._f('uvScale', rw / out.W, rh / out.H);
        // a layer must hold a texture; with no lens it reads none of it
        const sharp = this._lens[3] > 0 && s.copy ? s.copy : out;
        this._mask.set_layer_texture(1, sharp.tex);
        this._f('sharpScale', rw / sharp.W, rh / sharp.H);
        this._f('size', w, h);
        this._f('rect', sh[0] - x0, sh[1] - y0, sh[2], sh[3]);
        this._f('opacity', opacity / 255);
        fb.draw_textured_rectangle(this._mask, x0, y0, x0 + w, y0 + h, 0, 0, rw / out.W, rh / out.H);
    }
});

// The light, ported from the mockup's WebGL prototype (glass-light.js):
// everything in logical pixels, the surface given as a rect inside this
// actor. On a dark theme it adds light (premultiplied, alpha 0); on a light
// one, where adding light would only wash to white, it lays color over.
const LIGHT_DECL = `
uniform vec2 size;
uniform vec4 rect;
uniform float radius;
uniform vec2 light;
uniform float line;
uniform vec3 acc;
uniform vec3 neu;
uniform float gain;
uniform float grain;
uniform float lt;
uniform float divx;
uniform float scale;
uniform float trace;
uniform float alarm;
uniform float opacity;
uniform float darkEdge;
float sd(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
float hash(vec2 p) {
  vec3 p3 = fract(vec3(p.xyx) * 0.1031);
  p3 += dot(p3, p3.yzx + 33.33);
  return fract((p3.x + p3.y) * p3.z);
}
`;
const LIGHT_CODE = `
vec2 f = cogl_tex_coord_in[0].xy * size;
vec2 b = rect.zw * 0.5;
vec2 ctr = rect.xy + b;
vec2 p = f - ctr;
float d = sd(p, b, radius);
vec2 n = normalize(vec2(sd(p + vec2(0.5, 0.0), b, radius) - sd(p - vec2(0.5, 0.0), b, radius),
                        sd(p + vec2(0.0, 0.5), b, radius) - sd(p - vec2(0.0, 0.5), b, radius)) + 1e-5);
/* top-full, bottom-full: a line along that edge, each point lit from the
   nearest point of it rather than from one spot */
vec2 src = line > 0.5 ? vec2(clamp(f.x, rect.x + radius, rect.x + rect.z - radius), light.y) : light;
vec2 tl = src - f;
float dist = length(tl);
vec2 L = tl / max(dist, 1e-3);
float face = max(dot(n, L), 0.0);
float att = 1.0 / (1.0 + pow(dist / 280.0, 2.0));
/* power-on: the rim is drawn out from the point nearest the source, both
   ways round, with a bright head; everything else fades up behind it */
float th = acos(clamp(dot(normalize(p + 1e-4), normalize(light - ctr + 1e-4)), -1.0, 1.0)) / 3.14159;
float tt = trace * 1.15;
float on = 1.0 - smoothstep(tt - 0.07, tt, th);
float head = trace < 1.0 ? exp(-abs(th - tt + 0.035) / 0.025) * (1.0 - trace) : 0.0;
/* the rim: a thin core and its bloom, facing the source. The core is a
   gaussian about a pixel wide, centred on the surface's own 1px border
   (d = -0.5): a sharper one steps along curves, and one off the border
   reads as a second line beside it */
float db = d + 0.5;
float core = exp(-(db * db) / 0.72);
float bloom = exp(-abs(db) / 4.0);
float I = (core * 0.9 + bloom * 0.22) * pow(face, 1.5) * att * gain * on;
I += (core * 0.9 + bloom * 0.2) * head * gain * 0.6;
/* the warning edge: a quiet glow all the way round, in the warning's own
   color, so it reads on any surface wherever its light comes from */
I += (core * 0.22 + bloom * 0.09) * alarm * trace;
/* Fresnel: the glass's own thickness, strongest on top */
float fr = d < 0.0 ? exp(d / 1.3) * (0.04 + 0.07 * max(-n.y, 0.0)) * on : 0.0;
/* the divider, lit by the same source */
float dv = 0.0;
if (divx > 0.0) {
  float x = abs(f.x - (rect.x + divx));
  float y0 = rect.y + 14.0;
  float y1 = rect.y + rect.w - 14.0;
  float inY = smoothstep(y0, y0 + 40.0, f.y) * (1.0 - smoothstep(y1 - 40.0, y1, f.y));
  dv = exp(-x / 0.55) * inY * (0.08 + 0.5 / (1.0 + pow(dist / 320.0, 2.0))) * gain * trace;
}
/* scatter inside the glass, and the grain that also keeps the blur from
   banding */
float sc = 0.0;
float g = 0.0;
if (d < 0.0) {
  /* the rounded box's exact normal jumps at the edges of each corner's
     square, which the scatter (16px deep) drew as a square in the corners
     facing the light; a superellipse's normal turns smoothly everywhere */
  vec2 e = p / b;
  vec2 ns = normalize(sign(e) * pow(abs(e), vec2(7.0)) / b + 1e-6);
  float faceS = max(dot(ns, L), 0.0);
  sc = (exp(-dist / 230.0) * 0.09 + exp(d / 16.0) * faceS * att * 0.05) * gain * 0.5 * trace;
  g = (hash(floor(f * scale)) - 0.5) * grain;
}
/* the darkened edge (iOS 27): a thin band just inside the border, drawn
   over the surface's tint -- in the backdrop the tint would hide it. Its
   alpha darkens what is below while the light above still adds. */
float dk = d < -1.0 ? darkEdge * exp((d + 1.0) / 2.2) : 0.0;
if (lt < 0.5) {
  vec3 hot = mix(acc, vec3(1.0), smoothstep(0.5, 1.1, I) * 0.55);
  vec3 c = hot * I + vec3(fr) + neu * dv * 0.7 + acc * sc + vec3(max(g, 0.0));
  cogl_color_out = vec4(c, dk) * opacity;
} else {
  float al = clamp(I * 0.9 + dv * 0.6 + sc * 0.8, 0.0, 1.0);
  cogl_color_out = vec4(acc * al, max(al, dk)) * opacity;
}
`;

const LIGHT_UNIFORMS = ['size', 'rect', 'radius', 'light', 'line', 'acc', 'neu', 'gain', 'grain', 'lt', 'divx',
    'scale', 'trace', 'alarm', 'opacity', 'darkEdge'];

// Draws the light straight onto the stage as one rectangle at the actor's
// exact coordinates -- no offscreen: an offscreen effect's texture is
// rounded and padded to whole device pixels, which put the rim up to two
// pixels off the surface's border, a second ring outside it.
const LightEffect = GObject.registerClass({
    Properties: {
        // eased from 0 to 1 when the surface appears (power-on)
        'trace': GObject.ParamSpec.float('trace', null, null, GObject.ParamFlags.READWRITE, 0, 1, 1),
    },
}, class PulsarGlassLight extends Clutter.Effect {
    constructor() {
        super();
        const ctx = global.stage.context.get_backend().get_cogl_context();
        this._pipeline = Cogl.Pipeline.new(ctx);
        // a layer, so the rectangle carries texture coordinates for the shader
        this._pipeline.set_layer_texture(0, Cogl.Texture2D.new_with_size(ctx, 1, 1));
        this._pipeline.add_snippet(snippet(LIGHT_DECL, LIGHT_CODE));
        this._loc = {};
        for (const u of LIGHT_UNIFORMS)
            this._loc[u] = this._pipeline.get_uniform_location(u);
        this.set('gain', GAIN);
        this.set('grain', GRAIN);
        this.set('alarm', 0);
        this.set('darkEdge', 0);
        this._trace = 1;
        this.set('trace', 1);
        this._scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        this._u('scale', this._scale);
    }

    get trace() {
        return this._trace ?? 1;
    }

    set trace(v) {
        if (this._trace === v)
            return;
        this._trace = v;
        if (this._loc)
            this._u('trace', v);
        this.queue_repaint();
        this.notify('trace');
    }

    // what the surface sets (its geometry, its colors), counted so its
    // layout knows when the light is already as it would set it
    set(name, ...v) {
        this._u(name, ...v);
        this._ugen = (this._ugen ?? 0) + 1;
    }

    // what the light keeps up itself, as it animates and paints
    _u(name, ...v) {
        this._pipeline.set_uniform_float(this._loc[name], v.length, 1, v);
    }

    // Drawn directly, under the actor's own paint (see pass()).
    vfunc_paint_node(root, paintContext, _flags) {
        const actor = this.get_actor();
        const w = actor.width, h = actor.height;
        if (w >= 1 && h >= 1) {
            const opacity = actor.get_paint_opacity();
            if (opacity !== this._opacity) {
                this._opacity = opacity;
                this._u('opacity', opacity / 255);
            }
            // The grain is one cell per device pixel: the scale of the view
            // this paints (1.25 draws 1.25 device pixels to a logical one,
            // where St's own scale says 1). Painted anywhere else (a
            // screenshot), the last view's.
            const view = Views.get(paintContext.get_framebuffer());
            if (view && view.scale !== this._scale) {
                this._scale = view.scale;
                this._u('scale', view.scale);
            }
            paintContext.get_framebuffer().draw_textured_rectangle(this._pipeline, 0, 0, w, h, 0, 0, 1, 1);
        }
        // the light's actor is empty: no node for its own paint
    }
});

// An St/Cogl color as [r, g, b] in 0..1.
function rgb(c) {
    return c ? [c.red / 255, c.green / 255, c.blue / 255] : [0.24, 0.8, 1.0];
}

// The shaders' sd(): signed distance from (px, py) to the rounded rect.
function roundedDistance(px, py, [x, y, w, h], r) {
    const qx = Math.abs(px - (x + w / 2)) - w / 2 + r;
    const qy = Math.abs(py - (y + h / 2)) - h / 2 + r;
    return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}

// The light, held back to LIGHT_MIN_DISTANCE from the glass along the line
// from its middle.
function holdBack([lx, ly], rect, r) {
    const cx = rect[0] + rect[2] / 2, cy = rect[1] + rect[3] / 2;
    let [dx, dy] = [lx - cx, ly - cy];
    const len = Math.hypot(dx, dy);
    [dx, dy] = len > 1e-3 ? [dx / len, dy / len] : [0, -1];
    for (let i = 0; i < 8; i++) {
        const d = roundedDistance(lx, ly, rect, r);
        if (d >= LIGHT_MIN_DISTANCE - 0.5)
            break;
        lx += dx * (LIGHT_MIN_DISTANCE - d);
        ly += dy * (LIGHT_MIN_DISTANCE - d);
    }
    return [lx, ly];
}

// The light comes from one of eight places, whatever opened the surface:
// the left end, the middle or the right end of its top edge or of its
// bottom edge, or the whole of either edge at once. A source picks the edge
// (whether it is above or below the surface's middle) and the third it is
// over: a menu under a button on the left of the bar is lit top left, the
// date menu top center, Quick Settings top right, the OSDs and the
// screenshot panel bottom center. With no source the whole top edge is lit
// (the switchers, the dialogs, and banners, which come down from the top
// of the screen); opts.full 'bottom' lights the whole bottom edge (the
// dash, a shelf on the bottom of the screen). Returns the spot, in the
// light actor's coordinates (the surface is [LIGHT_PAD, LIGHT_PAD, w, h]),
// and whether it is a line along that edge.
function lightSpot(src, w, h, r, full) {
    const [x0, y0] = [LIGHT_PAD, LIGHT_PAD];
    const top = y0 - LIGHT_MIN_DISTANCE, bottom = y0 + h + LIGHT_MIN_DISTANCE;
    if (full === 'bottom')
        return [[x0 + w / 2, bottom], true];
    if (!src)
        return [[x0 + w / 2, top], true];
    const f = (src[0] - x0) / w;
    const x = f < 1 / 3 ? x0 + r : f > 2 / 3 ? x0 + w - r : x0 + w / 2;
    return [[x, src[1] > y0 + h / 2 ? bottom : top], false];
}

function luminance(c) {
    return (0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue) / 255;
}

// A notification group in the date menu stacks its cards while collapsed:
// all of each one behind the newest, 10px lower and 6px narrower a side,
// painted underneath. The stock cards are opaque, so only a sliver of each
// shows. On glass they are a faint lift, and every card behind read through
// the one over it, text and all -- and so did the group's header (its name
// and the collapse button), under them all as the group opens and closes.
// Each card in a group, and its header, is therefore drawn offscreen and
// cut wherever the cards over it lie -- the same rounded shape,
// antialiased against their edge -- while anything covers it at all:
// collapsed, and opening or closing. Otherwise, and with glass off, it
// paints as it would have.
const STACK_CUT = 'pulsar-stack-cut';
// the cards over one that are cut out of it: the newest, and the nearest
const STACK_SLOTS = 8;
const STACK_DECL = `
uniform sampler2D tex;
uniform vec4 map;
uniform float px;
uniform vec4 rects[${STACK_SLOTS}];
uniform float radii[${STACK_SLOTS}];
float sd(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}
`;
const STACK_CODE = `
vec2 uv = cogl_tex_coord_in[0].xy;
vec2 p = map.xy + uv * map.zw;
float cover = 0.0;
for (int i = 0; i < ${STACK_SLOTS}; i++) {
  vec2 b = (rects[i].zw - rects[i].xy) * 0.5;
  cover = max(cover, clamp(0.5 - sd(p - rects[i].xy - b, b, radii[i]) * px, 0.0, 1.0));
}
cogl_color_out = texture2D(tex, uv) * cogl_color_in * (1.0 - cover);
`;

const StackCut = GObject.registerClass(
class PulsarStackCut extends Shell.GLSLEffect {
    constructor() {
        super();
        this._loc = {};
        for (const u of ['map', 'px', 'rects', 'radii'])
            this._loc[u] = this.get_uniform_location(u);
        this._rects = new Array(4 * STACK_SLOTS).fill(0);
        this._radii = new Array(STACK_SLOTS).fill(0);
        this._card = [0, 0, 0, 0];
        this._other = [0, 0, 0, 0];
    }

    // once per class: each instance copies it
    vfunc_build_pipeline() {
        this.add_glsl_snippet(Cogl.SnippetHook.FRAGMENT, STACK_DECL, STACK_CODE, true);
    }

    // Drawn afresh every paint: a texture kept from a frame it was cut
    // would come back stale on a later one it was not.
    vfunc_paint(node, paintContext, flags) {
        super.vfunc_paint(node, paintContext, flags | Clutter.EffectPaintFlags.ACTOR_DIRTY);
    }

    // offscreen only while a card lies over this one
    vfunc_pre_paint(node, paintContext) {
        return this._lay() > 0 && super.vfunc_pre_paint(node, paintContext);
    }

    vfunc_paint_target(node, paintContext) {
        const card = this.actor;
        const s = card.get_resource_scale();
        const tex = this.get_texture();
        const [ox, oy] = offscreenOrigin(card, tex, s);
        this.set_uniform_float(this._loc.map, 4, [ox, oy, tex.get_width() / s, tex.get_height() / s]);
        this.set_uniform_float(this._loc.px, 1, [s]);
        this.set_uniform_float(this._loc.rects, 4, this._rects);
        this.set_uniform_float(this._loc.radii, 1, this._radii);
        super.vfunc_paint_target(node, paintContext);
    }

    // The cards over this one, in its own units, into the uniforms; how
    // many of them touch it.
    _lay() {
        const card = this.actor;
        // a message in its bin, or the header on its own
        let bin = card?.get_parent(), group = bin?.get_parent();
        if (bin instanceof MessageList.NotificationMessageGroup)
            [bin, group] = [card, bin];
        if (!(group instanceof MessageList.NotificationMessageGroup) ||
            !Main.layoutManager.uiGroup.has_style_class_name('pulsar-glass'))
            return 0;
        // the group paints its children last to first: the first is on top
        const kids = group.get_children();
        const over = kids.slice(0, kids.indexOf(bin))
            .filter(c => c.visible && c.child instanceof MessageList.Message);
        if (over.length > STACK_SLOTS)
            over.splice(1, over.length - STACK_SLOTS);
        const [cx, cy, csx, csy] = inGroup(card, this._card);
        // (coming in from nothing: nothing to cut yet)
        if (csx < 0.01 || csy < 0.01)
            return 0;
        const w = card.width, h = card.height;
        let n = 0;
        for (let i = 0; i < STACK_SLOTS; i++) {
            const r = this._rects;
            if (i >= over.length) {
                r[4 * i] = r[4 * i + 1] = r[4 * i + 2] = r[4 * i + 3] = -1e4;
                this._radii[i] = 0;
                continue;
            }
            // what it paints: inside its border (stock's is transparent, so
            // the 1px ring past its edge shows what is beneath)
            const other = over[i].child;
            const node = other.get_theme_node();
            const bl = node.get_border_width(St.Side.LEFT), bt = node.get_border_width(St.Side.TOP);
            const br = node.get_border_width(St.Side.RIGHT), bb = node.get_border_width(St.Side.BOTTOM);
            const [ax, ay, asx, asy] = inGroup(other, this._other);
            const x1 = (ax + bl * asx - cx) / csx, y1 = (ay + bt * asy - cy) / csy;
            const x2 = (ax + (other.width - br) * asx - cx) / csx, y2 = (ay + (other.height - bb) * asy - cy) / csy;
            [r[4 * i], r[4 * i + 1], r[4 * i + 2], r[4 * i + 3]] = [x1, y1, x2, y2];
            const radius = Math.max(node.get_border_radius(St.Corner.BOTTOMLEFT) - Math.max(bl, bb), 0) * asx / csx;
            this._radii[i] = Math.min(radius, (x2 - x1) / 2, (y2 - y1) / 2);
            if (x1 < w && x2 > 0 && y1 < h && y2 > 0)
                n++;
        }
        return n;
    }
});

// A message's corner in its group and its scale there: its bin eases it
// in and out about the bin's middle (ScaleLayout). The header is the
// group's own child. Plain numbers, no boxed values (see the note above),
// into `out`.
function inGroup(message, out) {
    const bin = message.get_parent();
    if (bin instanceof MessageList.NotificationMessageGroup) {
        [out[0], out[1], out[2], out[3]] = [message.x + message.translation_x, message.y + message.translation_y, 1, 1];
        return out;
    }
    const sx = bin.scale_x, sy = bin.scale_y;
    out[0] = bin.x + bin.translation_x + bin.width * (1 - sx) / 2 + message.x * sx;
    out[1] = bin.y + bin.translation_y + bin.height * (1 - sy) / 2 + message.y * sy;
    out[2] = sx;
    out[3] = sy;
    return out;
}

// Where an offscreen effect's texture starts in its actor, in the actor's
// units. Clutter (clutter-offscreen-effect.c, pre_paint) takes the paint
// volume, rounds it out (_clutter_actor_box_enlarge_for_effects: the width
// to whole units plus 3, the far edge up past 0.75) and keeps the near
// corner. A card's paint volume is its allocation, which a texture of the
// size that gives confirms without asking for the volume, a boxed value.
function offscreenOrigin(actor, tex, scale) {
    const edge = (a1, a2) => Math.ceil(a2 + 0.75) - Math.trunc(a2 - a1 + 0.5) - 3;
    const w = actor.width, h = actor.height;
    if (tex.get_width() === Math.ceil((Math.trunc(w + 0.5) + 3) * scale) &&
        tex.get_height() === Math.ceil((Math.trunc(h + 0.5) + 3) * scale))
        return [edge(0, w), edge(0, h)];
    const pv = actor.get_paint_volume();
    if (!pv)
        return [edge(0, w), edge(0, h)];
    const o = pv.get_origin();
    return [edge(o.x, o.x + pv.get_width()), edge(o.y, o.y + pv.get_height())];
}

// Every message in a notification group, and its header, carries a
// StackCut (idle until a card lies over it).
function cutStack(group) {
    for (const a of stacked(group)) {
        if (!a.get_effect(STACK_CUT))
            a.add_effect_with_name(STACK_CUT, new StackCut());
    }
}

function uncutStacks() {
    for (const g of messageGroups()) {
        for (const a of stacked(g))
            a.remove_effect_by_name(STACK_CUT);
    }
}

function stacked(group) {
    return [...group._notificationToMessage?.values() ?? [], group._headerBox].filter(a => a);
}

function messageGroups() {
    const view = Main.panel.statusArea.dateMenu?._messageList?._messageView;
    return (view?.messages ?? []).filter(m => m instanceof MessageList.NotificationMessageGroup);
}

// A kept origin, for the transforms a layout reads (see the note on boxed
// values above): never written to.
const ZERO = new Graphene.Point3D();

function laterAdd(fn) {
    return global.compositor.get_laters().add(Meta.LaterType.BEFORE_REDRAW, () => {
        fn();
        return GLib.SOURCE_REMOVE;
    });
}

function laterRemove(id) {
    if (id)
        global.compositor.get_laters().remove(id);
}

// An actor in the host's parent that copies the host's fade, slide and
// scale, so what it holds moves as one with the surface. Its position and
// size are copied before each redraw (Surface), not with a BindConstraint:
// Quick Settings' parent lays its children out before the BoxPointer has
// moved, so a constraint on the one under it reads last frame's position.
const Mirror = GObject.registerClass(
class PulsarGlassMirror extends St.Widget {
    constructor(host) {
        super({reactive: false});
        this._bindings = ['opacity', 'scale-x', 'scale-y', 'translation-x', 'translation-y', 'pivot-point', 'visible']
            .map(p => host.bind_property(p, this, p, GObject.BindingFlags.SYNC_CREATE));
    }

    unbind() {
        this._bindings.forEach(b => b.unbind());
        this._bindings = [];
    }
});

// One lit glass surface beside an offscreen-painted host: the live blur in
// a mirror under the host, the light in one over it. `host` is the actor
// that moves and fades (a menu's BoxPointer, an OSD window, the banner
// bin); opts.box() is the styled surface inside it, opts.source() the
// light's stage position, opts.divider() the date menu's column,
// opts.tone() 'warn' / 'alert' / null, opts.follow() the actor whose
// fade and scale the glass copies when that isn't the host (a dialog that
// animates its box, not its layout), opts.frame() a still ancestor to
// measure from when one between it and the host animates, opts.still a
// surface that shows without the power-on trace (a tooltip, shown on every
// hover).
class Surface {
    constructor(owner, host, opts) {
        this._owner = owner;
        this._host = host;
        this._opts = opts;
        const parent = host.get_parent();

        const follow = opts.follow?.() ?? host;
        this._under = new Mirror(follow);
        this._under.connect('destroy', () => (this._under = null));
        this._backdrop = new St.Widget({width: 1, height: 1});
        this._blur = new LiveBlur({lens: SURFACE_LENS, levels: SURFACE_LEVELS, offset: SURFACE_OFFSET});
        this._backdrop.add_effect_with_name('pulsar-blur', this._blur);
        this._under.add_child(this._backdrop);
        parent.insert_child_below(this._under, host);

        this._over = new Mirror(follow);
        this._over.connect('destroy', () => (this._over = null));
        this._lightActor = new St.Widget({width: 1, height: 1});
        this._light = new LightEffect();
        this._lightActor.add_effect_with_name('pulsar-light', this._light);
        this._over.add_child(this._lightActor);
        parent.insert_child_above(this._over, host);

        this._wasVisible = false;
        host.connectObject(
            'notify::allocation', () => this._queue(),
            'notify::x', () => this._queue(),
            'notify::y', () => this._queue(),
            'notify::visible', () => this._shown(),
            'notify::mapped', () => this._queue(),
            'destroy', () => owner.forget(this),
            this);
        // a surface keyed by something other than its host (Alt+Tab's
        // thumbnails) goes with that, not with the host that outlives it
        if (opts.key && opts.key !== host)
            opts.key.connectObject('destroy', () => owner.forget(this), this);
        this._rebox();
        this.sync();
        this._shown();
    }

    get host() {
        return this._host;
    }

    get key() {
        return this._opts.key ?? this._host;
    }

    // The styled surface can change under the same host (a new banner).
    _rebox() {
        const b = this._opts.box();
        if (b === this._box)
            return;
        this._box?.disconnectObject(this);
        this._box = b;
        b?.connectObject(
            'notify::allocation', () => this._queue(),
            // a size about to change (Quick Settings growing round an open
            // submenu): laid out in the same frame, not the one after
            'queue-relayout', () => this._queue(),
            'style-changed', () => this.sync(),
            'destroy', () => {
                this._box = null;
                this.sync();
            },
            this);
    }

    // A new banner in the same bin: restyle and power on again.
    renew() {
        this._rebox();
        this.sync();
        this._powerOn();
    }

    _shown() {
        const v = this._host.visible;
        if (v && !this._wasVisible)
            this._powerOn();
        // shown again: wait for where it lands before laying out
        if (!v)
            this._placed = false;
        this._wasVisible = v;
        this._queue();
    }

    _powerOn() {
        this._lightActor.remove_transition('@effects.pulsar-light.trace');
        if (!this._owner.powerOn || this._opts.still || !this._host.visible) {
            this._light.trace = 1;
            return;
        }
        this._light.trace = 0;
        this._lightActor.ease_property('@effects.pulsar-light.trace', 1, {
            duration: POWER_ON_MS,
            mode: Clutter.AnimationMode.EASE_OUT_CUBIC,
        });
    }

    // Copy the geometry once the frame's layout has settled, then place
    // what the mirrors hold.
    _queue() {
        if (!this._later)
            this._later = laterAdd(() => {
                this._later = 0;
                this._layout();
            });
    }

    // Whether each layer is wanted right now (settings, lock, overview),
    // and the colors, off the surface's own style.
    sync() {
        if (!this._under || !this._over)
            return;
        const b = this._box;
        this._backdrop.visible = this._owner.glass && !!b;
        this._lightActor.visible = this._owner.lighting && !!b;
        if (b) {
            const node = b.get_theme_node();
            const [hasTint, tint] = node.lookup_color('-pulsar-glass-tint', false);
            const bg = hasTint ? tint : node.get_background_color();
            // A light surface wants the light laid over, not added.
            this._lt = bg.alpha > 0 && luminance(bg) > 0.5 ? 1 : 0;
            this._blur.setTint(...(hasTint ? [...rgb(tint), tint.alpha / 255] : [0, 0, 0, 0]));
            const tone = this._opts.tone?.() ?? null;
            const pick = name => {
                const [ok, c] = node.lookup_color(name, true);
                return ok ? c : null;
            };
            const accent = (tone === 'alert' && pick('-pulsar-light-alert')) ||
                (tone === 'warn' && pick('-pulsar-light-warn')) ||
                pick('-pulsar-light') || node.get_foreground_color();
            this._light.set('acc', ...rgb(accent));
            this._light.set('alarm', tone ? 1 : 0);
            this._light.set('neu', ...rgb(tone ? accent : pick('-pulsar-light-neutral') ?? accent));
            this._light.set('lt', this._lt);
            // a soft ambient shadow in the theme's deep ground, and the
            // darkened edge inside the rim, drawn over the tint by the light
            const i = this._lt ? 0 : 1;
            this._blur.setShadow(...deepShadow(this._lt), SHADOW.alpha[i]);
            this._blur.setEdgeDark(0);
            this._light.set('darkEdge', EDGE_DARK[i]);
            this._blur.setGrade(...(this._lt ? SURFACE_GRADE.light : SURFACE_GRADE.dark));
            this._radius = node.get_border_radius(St.Corner.TOPLEFT);
        }
        this._queue();
    }

    // Keep the mirrors on either side of the host. A host can restack itself:
    // Shell 50's OsdWindow.show() raises the OSD to the top of uiGroup every
    // time it appears, which left the blur and the light far below it, and
    // the OSD (its own background cleared for glass) drew as bare text.
    _restack() {
        const parent = this._host.get_parent();
        if (!parent)
            return;
        if (this._under.get_parent() === parent && this._under.get_next_sibling() !== this._host)
            parent.set_child_below_sibling(this._under, this._host);
        if (this._over.get_parent() === parent && this._over.get_previous_sibling() !== this._host)
            parent.set_child_above_sibling(this._over, this._host);
    }

    _layout() {
        const b = this._box;
        // unparented (on its way out): nowhere to place the mirrors
        const parent = this._host.get_parent();
        if (!this._under || !this._over || !b || !this._host.visible || !parent)
            return;
        // Still waiting on a relayout: try again next frame. It may land on
        // the same box as before, and then no notify::allocation comes.
        // Given up after 30, the count starts over, or a surface that first
        // tried while hidden (the dash, before the overview has been shown)
        // would never try again.
        // A surface already up and placed that is only changing size (Quick
        // Settings growing and shrinking round an open submenu) does not
        // wait: it needs a relayout on every frame of that, and waiting for
        // one left the glass at its old size until the animation had ended.
        // This runs before the frame's layout, where a box's width and
        // height are already the size this frame gives it.
        const resizing = this._placed && this._host.visible && b.is_mapped();
        const o = b.apply_relative_transform_to_point(this._host, ZERO);
        const hb = this._host.get_allocation_box();
        // Either way, only on numbers it can use: a banner's box reads NaN
        // against its bin for a moment as it comes and goes, and an actor
        // placed at NaN is never drawn (and Clutter complains).
        const finite = [o.x, o.y, b.width, b.height, hb.x1, hb.y1, hb.get_width(), hb.get_height()]
            .every(Number.isFinite);
        if (!finite || (!resizing && (!b.has_allocation() || !this._host.has_allocation()))) {
            if ((this._retries = (this._retries ?? 0) + 1) <= 30)
                this._queue();
            else
                this._retries = 0;
            return;
        }
        this._retries = 0;
        this._placed = true;
        this._restack();
        const [w, h] = [b.width, b.height];
        // A pill's CSS radius (Shell 50's OSD: 999px) is far past half its
        // height, and the masks' rounded-rect distance then covers nothing:
        // blur and light both vanished. Clamp it as CSS itself does.
        const r = Math.min(this._radius ?? 0, w / 2, h / 2);
        // the host's own allocation (hb, above): its x/y can read 0 while a
        // layout that centers it (the banner bin's) is still settling
        const [hx, hy, pw, ph] = [hb.x1, hb.y1, hb.get_width(), hb.get_height()];
        for (const m of [this._under, this._over]) {
            m.set_position(hx, hy);
            m.set_size(pw, ph);
        }
        // Where the host sits once it has settled. opts.frame() is a still
        // ancestor above one that animates in (an app folder zooms out of
        // its icon on its child's scale and translation): the stage
        // transform would place the source by wherever the zoom had got to.
        const frame = this._opts.frame?.();
        let origin;
        if (frame) {
            const [fx, fy] = frame.get_transformed_position();
            origin = {x: fx + hx, y: fy + hy};
            for (let a = parent; a && a !== frame; a = a.get_parent()) {
                const ab = a.get_allocation_box();
                origin.x += ab.x1;
                origin.y += ab.y1;
            }
        } else {
            const pt = this._hostPoint ??= new Graphene.Point3D();
            pt.x = hx;
            pt.y = hy;
            origin = parent.apply_relative_transform_to_point(null, pt);
        }

        // under: the live blur, reaching past the surface for its shadow
        this._backdrop.set_position(o.x - BLUR_PAD, o.y - BLUR_PAD);
        this._backdrop.set_size(w + 2 * BLUR_PAD, h + 2 * BLUR_PAD);
        this._blur.setShape([BLUR_PAD, BLUR_PAD, w, h], r);

        // over: the light
        const [lw, lh] = [w + 2 * LIGHT_PAD, h + 2 * LIGHT_PAD];
        this._lightActor.set_position(o.x - LIGHT_PAD, o.y - LIGHT_PAD);
        this._lightActor.set_size(lw, lh);
        const lx0 = origin.x + o.x - LIGHT_PAD, ly0 = origin.y + o.y - LIGHT_PAD;
        const src = this._opts.source(origin.x + o.x, origin.y + o.y, w, h);
        const [spot, line] = lightSpot(src && [src[0] - lx0, src[1] - ly0], w, h, r,
            this._opts.full);
        const light = line ? spot : holdBack(spot, [LIGHT_PAD, LIGHT_PAD, w, h], r);
        const column = this._opts.divider?.();
        // stock draws no line there, only a gap (the column's margin); light its middle
        const divx = column
            ? column.apply_relative_transform_to_point(b, ZERO).x -
              column.get_theme_node().get_margin(St.Side.LEFT) / 2
            : 0;
        // Relaid out with nothing moved (a relayout anywhere inside the
        // surface lands here: the date menu's clock, a label), the light
        // stays as it is, unless sync() has set it since.
        const L = this._light;
        const key = [lw, lh, w, h, r, light[0], light[1], line ? 1 : 0, divx];
        if (L._ugen === this._lightGen && this._lightKey?.every((v, i) => v === key[i]))
            return;
        this._lightKey = key;
        L.set('size', lw, lh);
        L.set('rect', LIGHT_PAD, LIGHT_PAD, w, h);
        L.set('radius', r);
        L.set('light', ...light);
        L.set('line', line ? 1 : 0);
        L.set('divx', divx);
        L.queue_repaint();
        this._lightGen = L._ugen;
    }

    destroy() {
        laterRemove(this._later);
        this._later = 0;
        this._box?.disconnectObject(this);
        this._host.disconnectObject(this);
        if (this._opts.key && this._opts.key !== this._host)
            this._opts.key.disconnectObject(this);
        // At Shell exit the host's parent may have destroyed them already.
        for (const m of [this._under, this._over]) {
            m?.unbind();
            m?.destroy();
        }
    }
}

// The top bar's lower edge: one device pixel of light with a soft glow to
// either side, brightest a little left of center and fading along the bar.
// Drawn over BROW_ROWS device rows centered on the bar's last one. Unlit
// (the Light switch off), only that one row, as a faint plain hairline.
const BROW_ROWS = 5;
const BROW_DECL = `
uniform vec2 size;
uniform vec3 acc;
uniform vec3 fg;
uniform float lt;
uniform float lit;
uniform float opacity;
`;
const BROW_CODE = `
vec2 f = cogl_tex_coord_in[0].xy * size;
float dy = f.y - size.y * 0.5;
float core = exp(-(dy * dy) / 0.3);
float halo = exp(-abs(dy) / 1.1);
float xn = f.x / size.x;
float tx = (xn - 0.42) / 0.38;
float hot = 0.4 + 0.6 * exp(-tx * tx);
float I = (core * 0.34 + halo * 0.1) * hot;
if (lit < 0.5) {
  float a = step(abs(dy), 0.5) * 0.1;
  cogl_color_out = vec4(fg * a, a) * opacity;
} else if (lt < 0.5) {
  vec3 c = mix(acc, vec3(1.0), core * 0.15);
  cogl_color_out = vec4(c * I, I * 0.35) * opacity;
} else {
  float a = I * 0.6;
  cogl_color_out = vec4(acc * a, a) * opacity;
}
`;

const BrowEffect = GObject.registerClass(
class PulsarGlassBrow extends Clutter.Effect {
    constructor() {
        super();
        const ctx = global.stage.context.get_backend().get_cogl_context();
        this._pipeline = Cogl.Pipeline.new(ctx);
        this._pipeline.set_layer_texture(0, Cogl.Texture2D.new_with_size(ctx, 1, 1));
        this._pipeline.add_snippet(snippet(BROW_DECL, BROW_CODE));
        this._loc = {};
        for (const u of ['size', 'acc', 'fg', 'lt', 'lit', 'opacity'])
            this._loc[u] = this._pipeline.get_uniform_location(u);
        this.set('lit', 1);
        this.set('opacity', 1);
    }

    set(name, ...v) {
        this._pipeline.set_uniform_float(this._loc[name], v.length, 1, v);
    }

    vfunc_paint_node(_root, paintContext, _flags) {
        const actor = this.get_actor();
        const w = actor.width, h = actor.height;
        if (w >= 1 && h >= 1)
            paintContext.get_framebuffer().draw_textured_rectangle(this._pipeline, 0, 0, w, h, 0, 0, 1, 1);
    }
});

// The top bar: a translucent bar over a live blur of what is beneath it.
// Its shadow is a separate soft gradient in the window group, just above
// the wallpaper and below every window, so it falls on the desktop only.
class PanelGlass {
    constructor() {
        const panelBox = Main.layoutManager.panelBox;
        this._actor = new St.Widget({reactive: false});
        this._actor.add_constraint(new Clutter.BindConstraint({source: panelBox, coordinate: Clutter.BindCoordinate.ALL}));
        this._blur = new LiveBlur();
        this._blur.setSoft(0);
        this._actor.add_effect_with_name('pulsar-blur', this._blur);
        Main.layoutManager.uiGroup.insert_child_below(this._actor, panelBox);

        this._shadow = new St.Widget({style_class: 'pulsar-panel-shadow', reactive: false});
        for (const coordinate of [Clutter.BindCoordinate.X, Clutter.BindCoordinate.WIDTH])
            this._shadow.add_constraint(new Clutter.BindConstraint({source: panelBox, coordinate}));
        // Inside the background group, which the compositor keeps under every
        // window (a child of the window group itself gets re-stacked with the
        // windows, and can land above one), on top of the wallpaper -- and
        // back on top whenever a new wallpaper actor is added.
        this._bg = Main.layoutManager._backgroundGroup;
        this._bg.add_child(this._shadow);
        this._bg.connectObject('child-added', (_g, child) => {
            if (child !== this._shadow)
                this._bg.set_child_above_sibling(this._shadow, null);
        }, this);
        // the ledge: a lit hairline, one device pixel at any scale
        this._line = new St.Widget({style_class: 'pulsar-panel-hairline', reactive: false});
        this._brow = new BrowEffect();
        this._line.add_effect(this._brow);
        this._line.connectObject('style-changed', () => this._colors(), this);
        Main.layoutManager.uiGroup.insert_child_above(this._line, panelBox);
        panelBox.connectObject('notify::allocation', () => this._shape(), this);
        Main.layoutManager.connectObject('monitors-changed', () => this._shape(), this);
        this._shape();
    }

    _shape() {
        const panelBox = Main.layoutManager.panelBox;
        const [w, h] = panelBox.get_size();
        const index = Main.layoutManager.primaryIndex;
        const scale = global.display.get_monitor_scale(index) || 1;
        const half = Math.floor(BROW_ROWS / 2);
        this._line.set_position(panelBox.x, panelBox.y + h - (half + 1) / scale);
        this._line.set_size(w, BROW_ROWS / scale);
        this._brow.set('size', w * scale, BROW_ROWS);
        // past the screen's edges on three sides: only the bottom is an edge
        this._blur.setShape([-4, -4, w + 8, h + 4], 0);
        this._shadow.set_position(panelBox.x, panelBox.y + h);
        this._shadow.set_height(PANEL_SHADOW.pad);
    }

    _colors() {
        const node = this._line.get_theme_node();
        const [ok, acc] = node.lookup_color('-pulsar-light', true);
        const fg = node.get_foreground_color();
        this._brow.set('acc', ...rgb(ok ? acc : fg));
        this._brow.set('fg', ...rgb(fg));
        // dark text: a light theme, where the light is laid over, not added
        this._brow.set('lt', luminance(fg) < 0.5 ? 1 : 0);
        this._line.queue_redraw();
    }

    set lit(v) {
        this._brow.set('lit', v ? 1 : 0);
        this._line.queue_redraw();
    }

    // The blur is held on the desktop's last frame while the overview is up.
    // The overview swaps what is beneath the bar in one frame each way (the
    // wallpaper for its own flat ground as it opens, and back once it has
    // gone), and a live blur fading across those swaps showed each as a
    // flicker at the ends of the fade.
    set frozen(v) {
        this._blur.setFrozen(v);
    }

    // Faded, not switched, as the overview comes and goes: the bar's glass
    // leaves as Activities opens and is back as it closes, over the
    // overview's own 250 ms, on the curve St fades the bar's tint with (its
    // CSS transition). On a faster curve the blur came back ahead of the
    // tint that darkens it, and the bar swelled bright before settling.
    // ease() is instant with animations off.
    set visible(v) {
        for (const a of [this._actor, this._shadow, this._line]) {
            a.remove_transition('opacity');
            if (v) {
                if (!a.visible) {
                    a.opacity = 0;
                    a.show();
                }
                a.ease({opacity: 255, duration: PANEL_FADE_MS, mode: Clutter.AnimationMode.EASE_IN_OUT_QUAD});
            } else if (a.visible) {
                a.ease({
                    opacity: 0,
                    duration: PANEL_FADE_MS,
                    mode: Clutter.AnimationMode.EASE_IN_OUT_QUAD,
                    onStopped: finished => finished && a.hide(),
                });
            }
        }
    }

    destroy() {
        Main.layoutManager.panelBox.disconnectObject(this);
        Main.layoutManager.disconnectObject(this);
        this._bg.disconnectObject(this);
        this._actor.destroy();
        this._shadow.destroy();
        this._line.disconnectObject(this);
        this._line.destroy();
    }
}

// The overview's ground: the wallpaper, blurred, under a tint of the theme's
// deep ground (.pulsar-overview-ground), in place of its flat color, so
// what floats in the overview (the dash, the search entry and its results,
// the thumbnails) has something to be glass over. The same blurred
// wallpaper the lock screen shows, a Shell.BlurEffect on a wallpaper actor
// per monitor, which blurs once and keeps the result until the wallpaper
// changes. It is the overview group's bottom child: the workspace opens
// full screen over it and uncovers it as it shrinks, so it never pops in.
const GROUND_BLUR = 60;

class OverviewGround {
    constructor() {
        this._actor = new St.Widget({reactive: false});
        Main.layoutManager.overviewGroup.insert_child_at_index(this._actor, 0);
        this._bgManagers = [];
        Main.layoutManager.connectObject('monitors-changed', () => this._build(), this);
        St.ThemeContext.get_for_stage(global.stage).connectObject(
            'notify::scale-factor', () => this._radius(), this);
        this._build();
    }

    _build() {
        this._bgManagers.forEach(m => m.destroy());
        this._bgManagers = [];
        this._actor.destroy_all_children();
        Main.layoutManager.monitors.forEach((m, monitorIndex) => {
            const geometry = {x: m.x, y: m.y, width: m.width, height: m.height};
            const wall = new St.Widget({...geometry, effect: new Shell.BlurEffect({name: 'blur'})});
            this._bgManagers.push(new Background.BackgroundManager({
                container: wall, monitorIndex, controlPosition: false,
            }));
            this._actor.add_child(wall);
            this._actor.add_child(new St.Widget({...geometry, style_class: 'pulsar-overview-ground'}));
        });
        this._radius();
    }

    _radius() {
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        for (const c of this._actor)
            c.get_effect('blur')?.set({brightness: 1, radius: GROUND_BLUR * scale});
    }

    destroy() {
        Main.layoutManager.disconnectObject(this);
        St.ThemeContext.get_for_stage(global.stage).disconnectObject(this);
        this._bgManagers.forEach(m => m.destroy());
        this._bgManagers = [];
        this._actor.destroy();
    }
}

// Mutter skips painting whatever is beneath a surface's opaque region, but
// only under a surface at full opacity. Glass beneath or inside such a
// window then blurs that window's own last frame back in around its edges.
// So these surfaces sit at 254 of 255: everything beneath is painted, and
// one step of opacity cannot be seen. Returns the surfaces it changed;
// `visit` sees every actor it looks inside.
function uncull(actor, skip = null, into = new Set(), visit = null) {
    visit?.(actor);
    for (const c of actor.get_children()) {
        if (c === skip)
            continue;
        // a subsurface is a child of its parent's surface actor
        if (c.opacity === 255 && GObject.type_name_from_instance(c).includes('SurfaceActor')) {
            c.opacity = 254;
            into.add(c);
        }
        uncull(c, skip, into, visit);
    }
    return into;
}

function recull(surfaces) {
    for (const c of surfaces ?? []) {
        if (c.opacity === 254)
            c.opacity = 255;
    }
}

// uncull() kept up as a window's surfaces come and go. A window says
// 'damaged' on every commit (every frame of an app animating), and the tree
// is walked again only after something was added somewhere in it.
class Uncull {
    constructor(root, skip = null) {
        this._root = root;
        this._skip = skip;
        this.surfaces = new Set();
        this._watched = new Set();
        this._dirty = true;
    }

    update() {
        if (!this._dirty)
            return;
        this._dirty = false;
        uncull(this._root, this._skip, this.surfaces, a => this._watch(a));
    }

    _watch(actor) {
        if (this._watched.has(actor))
            return;
        this._watched.add(actor);
        actor.connectObject(
            'child-added', () => (this._dirty = true),
            'destroy', () => this._watched.delete(actor),
            this);
    }

    // back to full opacity; the next update() walks again
    recull() {
        recull(this.surfaces);
        this.surfaces.clear();
        this._dirty = true;
    }

    destroy() {
        for (const a of this._watched)
            a.disconnectObject(this);
        this._watched.clear();
    }
}

// Popovers, menus and tooltips: GTK's are windows of their own, opaque, and
// they open over glass windows.
const POPUP_TYPES = [Meta.WindowType.DROPDOWN_MENU, Meta.WindowType.POPUP_MENU, Meta.WindowType.COMBO,
    Meta.WindowType.TOOLTIP, Meta.WindowType.MENU];

// Windows that opened while window glass was on (see Glass._glassy). Kept
// at module level: every lock disables the extension and makes a new Glass,
// and the set must outlive that, or a lock would strip their blur.
const GLASSY = new WeakSet();

const GLASS_TYPES = [Meta.WindowType.NORMAL, Meta.WindowType.DIALOG, Meta.WindowType.MODAL_DIALOG, Meta.WindowType.UTILITY];

// Whether each process, by pid, has GTK 4 loaded (null: its maps could not
// be read), read once per process: see WindowGlass.wanted(). An entry goes
// with the process's last window (Glass._watchGeometry), since its pid may
// be the next process's.
const GTK4 = new Map();

// The live blur inside one window actor, under its surfaces, cut to the
// window's frame and corners. Only GTK apps get one: they are the ones the
// engine's gtk.css makes translucent (anything else paints opaque over it,
// and would only cost the blur).
//
// A popup (a popover, a menu, a tooltip) over a glass window gets one too.
// Most are opaque and hide it, but an app may make its own translucent --
// Ptyxis draws its popovers at the terminal's opacity or 0.85, whichever is
// more, above anything gtk.css can say -- and with nothing beneath them
// blurred, the terminal's text read through them sharp. A popup's frame
// rect holds its arrow as well as its body (GTK trims only the shadow), so
// its blur is cut to what the popup's own buffer draws, not to a shape.
class WindowGlass {
    constructor(owner, actor, popup = false) {
        this._owner = owner;
        this._actor = actor;
        this._win = actor.meta_window;
        this._popup = popup;
        this._backdrop = new St.Widget({reactive: false, width: 1, height: 1});
        this._blur = new LiveBlur({lens: popup ? [0, 0, 0, 0] : WINDOW_LENS,
            levels: SURFACE_LEVELS, offset: SURFACE_OFFSET});
        // vibrancy: what is beneath lifted, so its color reads through the
        // window's tint instead of muddying it
        this._blur.setGrade(...windowGrade());
        this._blur.setGradeEdge(popup ? 0 : WINDOW_GRADE_EDGE);
        if (popup) {
            this._blur.setCut(() => {
                // one plane: an RGBA buffer, which a GTK popup always is
                const mt = actor.get_texture?.()?.get_texture?.();
                const tex = mt?.is_simple() ? mt.get_plane(0) : null;
                const b = this._backdrop;
                if (!tex || !b)
                    return null;
                const buffer = this._win.get_buffer_rect();
                // from the backdrop to the buffer, which starts at the actor's origin
                return [tex, b.x, b.y, buffer.width, buffer.height];
            });
        }
        // a new sheet (a theme, a Dark Style flip) may be the other scheme
        Main.panel.connectObject('style-changed', () => this._blur.setGrade(...windowGrade()), this);
        this._backdrop.add_effect_with_name('pulsar-blur', this._blur);
        actor.insert_child_at_index(this._backdrop, 0);
        this._backdrop.connect('destroy', () => (this._backdrop = null));
        this._cull = new Uncull(actor, this._backdrop);
        this._win.connectObject(
            'size-changed', () => this._layout(),
            'notify::fullscreen', () => this._layout(),
            'notify::maximized-horizontally', () => this._layout(),
            'notify::maximized-vertically', () => this._layout(),
            this);
        actor.connectObject(
            'destroy', () => owner.forgetWindow(actor),
            // a new or replaced surface (a subsurface, a new buffer role)
            'damaged', () => this._uncull(),
            this);
        this._layout();
        this._uncull();
    }

    // GTK tells the compositor which parts of a window are opaque (cards,
    // boxed lists): see uncull().
    _uncull() {
        if (!this._off)
            this._cull.update();
    }

    // No glass while this window is fullscreen, covers its whole monitor as
    // a borderless game does (direct scanout wants it opaque and nothing in
    // its actor but its surfaces), or sits beneath a window that covers it
    // (unseen, it was blurred afresh on every frame the game drew).
    // `covered` comes from Glass._cover().
    get _off() {
        return this._win.is_fullscreen() || !!this._covered;
    }

    cover(covered) {
        if (covered === !!this._covered)
            return;
        this._covered = covered;
        this._layout();
    }

    // back to full opacity: fullscreen (a game keeps direct scanout, which
    // a translucent surface would lose) or the glass going away
    _recull() {
        this._cull.recull();
    }

    // gtk.css is GTK 4's, so a window gets glass if its process has GTK 4
    // loaded: an app's own windows, a libadwaita dialog floating with no
    // parent, and the helpers that are no GtkApplication and carry no
    // application id at all (the portal's file chooser and "Open With",
    // the VPN password prompt). A GTK 3 app is opaque, and gets none.
    // A process whose maps cannot be read is judged the old way: a window
    // with an application id is a GTK app's, and so is any window of the
    // same process. `gtkPids` gives the processes with such a window, made
    // once for a whole pass over the windows, not once per window.
    static wanted(actor, gtkPids = WindowGlass.gtkPids) {
        const w = actor?.meta_window;
        if (!w || !GLASS_TYPES.includes(w.get_window_type()))
            return false;
        const pid = w.get_pid();
        const gtk4 = WindowGlass.gtk4(pid);
        if (gtk4 !== null)
            return gtk4;
        if (w.get_gtk_application_id?.())
            return true;
        return pid > 0 && gtkPids().has(pid);
    }

    // Read once per process: a GTK 4 app loads GTK before it opens a window.
    // A Flatpak app's pid is the host's, and its maps name the runtime's
    // copy of the library, which matches all the same.
    static gtk4(pid) {
        if (!(pid > 0))
            return null;
        if (!GTK4.has(pid)) {
            let found = null;
            try {
                const [, maps] = GLib.file_get_contents(`/proc/${pid}/maps`);
                found = new TextDecoder().decode(maps).includes('/libgtk-4.so');
            } catch {}
            GTK4.set(pid, found);
        }
        return GTK4.get(pid);
    }

    static gtkPids() {
        const pids = new Set();
        for (const a of global.get_window_actors()) {
            if (a.meta_window?.get_gtk_application_id?.())
                pids.add(a.meta_window.get_pid());
        }
        return pids;
    }

    _layout() {
        if (!this._backdrop)
            return;
        const w = this._win;
        if (this._off) {
            this._backdrop.hide();
            this._recull();
            return;
        }
        this._uncull();
        const frame = w.get_frame_rect();
        const buffer = w.get_buffer_rect();
        const maximized = w.is_maximized?.() ?? (w.maximized_horizontally && w.maximized_vertically);
        // tiled and maximized windows are square
        const square = maximized || w.maximized_vertically || w.maximized_horizontally;
        const p = WINDOW_PAD;
        this._backdrop.set_position(frame.x - buffer.x - p, frame.y - buffer.y - p);
        this._backdrop.set_size(frame.width + 2 * p, frame.height + 2 * p);
        this._blur.setShape([p, p, frame.width, frame.height], square || this._popup ? 0 : WINDOW_RADIUS);
        this._backdrop.show();
    }

    destroy() {
        this._win.disconnectObject(this);
        this._actor.disconnectObject(this);
        Main.panel.disconnectObject(this);
        this._recull();
        this._cull.destroy();
        this._backdrop?.destroy();
        this._backdrop = null;
    }
}

// Four corner brackets that lock onto the control the keyboard is on and
// glide between controls. Only while the keyboard is the last input device:
// the Shell moves key focus for the mouse too (a hovered menu item takes it,
// a menu opened by a click gives it to its first item), and brackets on a
// control nobody tabbed to read as random marks. The backend says which
// device was used last whatever holds a grab (an open menu does, and the
// stage never sees its key presses). The stock focus ring stays.
class FocusBrackets {
    constructor(owner) {
        this._owner = owner;
        this._target = null;
        this._area = new St.DrawingArea({style_class: 'pulsar-focus-brackets', reactive: false, visible: false});
        this._area.connect('repaint', a => this._draw(a));
        this._area.connect('destroy', () => (this._area = null));
        Main.layoutManager.uiGroup.add_child(this._area);
        global.stage.connectObject('notify::key-focus', () => this._queue(), this);
        this._keyboard = false;
        global.backend.connectObject('last-device-changed', (_b, device) => {
            const keyboard = device?.get_device_type() === Clutter.InputDeviceType.KEYBOARD_DEVICE;
            if (keyboard === this._keyboard)
                return;
            this._keyboard = keyboard;
            this._queue();
        }, this);
    }

    _queue() {
        if (!this._later)
            this._later = laterAdd(() => {
                this._later = 0;
                this._update();
            });
    }

    _wanted(f) {
        return this._owner.brackets && this._keyboard &&
            f instanceof St.Widget && f.get_stage() && f.get_paint_opacity() > 0 && !(f instanceof St.Entry) && f.mapped && f.can_focus &&
            f.has_style_pseudo_class('focus') &&
            (f instanceof St.Button || f.has_style_class_name('popup-menu-item')) &&
            Main.layoutManager.uiGroup.contains(f);
    }

    _update() {
        if (!this._area)
            return;
        const f = global.stage.key_focus;
        if (f !== this._target) {
            this._target?.disconnectObject(this);
            this._target = null;
        }
        if (!this._wanted(f)) {
            this._hide();
            return;
        }
        if (!this._target) {
            this._target = f;
            f.connectObject(
                'notify::allocation', () => this._queue(),
                'notify::mapped', () => this._queue(),
                'destroy', () => {
                    this._target = null;
                    this._queue();
                },
                this);
        }
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const pad = 4 * scale;
        const [x, y] = f.get_transformed_position();
        const [w, h] = f.get_transformed_size();
        const rect = {x: x - pad, y: y - pad, width: w + 2 * pad, height: h + 2 * pad};
        const key = JSON.stringify(rect);
        if (this._area.visible && key === this._rectKey && f === this._shown)
            return;
        this._rectKey = key;
        this._shown = f;
        const ui = Main.layoutManager.uiGroup;
        ui.set_child_above_sibling(this._area, null);
        if (!this._area.visible) {
            this._area.remove_all_transitions();
            this._area.set(rect);
            this._area.opacity = 0;
            this._area.show();
            this._area.ease({opacity: 255, duration: 120, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
        } else {
            this._area.ease({...rect, duration: 140, mode: Clutter.AnimationMode.EASE_OUT_QUAD});
        }
        // A menu slides and scales in as it opens: settle on where it lands.
        // And while shown, keep checking: a closing menu, a dialog going away
        // or the session ending does not always move key focus, and the
        // brackets must never outlive what they mark.
        if (!this._watch)
            this._watch = GLib.timeout_add(GLib.PRIORITY_DEFAULT_IDLE, 250, () => {
                if (!this._area?.visible) {
                    this._watch = 0;
                    return GLib.SOURCE_REMOVE;
                }
                this._update();
                return GLib.SOURCE_CONTINUE;
            });
    }

    _hide() {
        if (!this._area?.visible)
            return;
        this._area.remove_all_transitions();
        this._area.ease({
            opacity: 0, duration: 100, mode: Clutter.AnimationMode.EASE_OUT_QUAD,
            onComplete: () => this._area.hide(),
        });
    }

    _draw(area) {
        const cr = area.get_context();
        const [w, h] = area.get_surface_size();
        const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
        const c = area.get_theme_node().get_foreground_color();
        const lw = 2 * scale;
        const arm = Math.max(4 * scale, Math.min(12 * scale, w / 3, h / 3));
        const i = lw / 2;
        cr.setSourceRGBA(c.red / 255, c.green / 255, c.blue / 255, 0.95);
        cr.setLineWidth(lw);
        for (const [x, y, dx, dy] of [[i, i, 1, 1], [w - i, i, -1, 1], [i, h - i, 1, -1], [w - i, h - i, -1, -1]]) {
            cr.moveTo(x, y + dy * arm);
            cr.lineTo(x, y);
            cr.lineTo(x + dx * arm, y);
        }
        cr.stroke();
        cr.$dispose();
    }

    destroy() {
        laterRemove(this._later);
        if (this._watch)
            GLib.source_remove(this._watch);
        global.stage.disconnectObject(this);
        global.backend.disconnectObject(this);
        this._target?.disconnectObject(this);
        this._area?.destroy();
    }
}

// The glow under a slider's fill, in the -pulsar-glow color the theme sets
// only under .pulsar-glow: no rule, no glow, so the switch and the lock
// screen need nothing here. Cairo has no blur; stacked rounded bars, each a
// little larger and fainter, make the falloff, and they stop short of the
// slider's own surface (the handle makes it taller than the bar), so the
// glow fades out rather than being cut off at its edge.
// The reach follows the bar's thickness by the engine's rule (glow_for() in
// pulsar-theme: 0.5 + 0.2 x thickness, 2.5 to 11 logical px -- a 4px bar
// gets 2.5), never more than 90% of the room around the bar; the strength
// is the engine's too, in the color it sets.
const GLOW_STEPS = 8;
const GLOW_LAYER = 0.22;    // of the glow color's alpha, per layer
const glowReach = t => Math.min(Math.max(0.5 + 0.2 * t, 2.5), 11);
function fillGlow(bar) {
    if (!(bar._value > 0) || !(bar._maxValue > 0))
        return;
    const [ok, color] = bar.get_theme_node().lookup_color('-pulsar-glow', false);
    if (!ok || color.alpha === 0)
        return;
    const [width, height] = bar.get_surface_size();
    const bh = bar._barLevelHeight;
    const r0 = Math.min(width, bh) / 2;
    const rtl = bar.get_text_direction() === Clutter.TextDirection.RTL;
    const progress = Math.min(bar._value, bar._maxValue) / bar._maxValue;
    const end = r0 + (width - 2 * r0) * progress;
    const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
    const reach = Math.min(Math.max(0, (height - bh) / 2) * 0.9, glowReach(bh / scale) * scale);
    const cr = bar.get_context();
    cr.setSourceRGBA(color.red / 255, color.green / 255, color.blue / 255,
        color.alpha / 255 * GLOW_LAYER);
    for (let i = 1; i <= GLOW_STEPS; i++) {
        const g = reach * i / GLOW_STEPS;
        const r = r0 + g;
        // a rounded bar from the fill's start to just past its end (never
        // shorter than its own two caps)
        let x0 = 0, x1 = Math.max(end + g, 2 * r);
        if (rtl)
            [x0, x1] = [width - x1, width];
        cr.newSubPath();
        cr.arc(x1 - r, height / 2, r, -Math.PI / 2, Math.PI / 2);
        cr.arc(x0 + r, height / 2, r, Math.PI / 2, 3 * Math.PI / 2);
        cr.closePath();
        cr.fill();
    }
    cr.$dispose();
}

export class Glass {
    constructor(settings, injections) {
        this._settings = settings;
        Views.watch();
        this._surfaces = new Map();     // host (or opts.key) -> Surface
        this._panel = null;
        this._brackets = null;
        this._windows = new Map();      // window actor -> WindowGlass
        // Windows that opened while window glass was on. GTK reads its
        // stylesheet at launch, so they stay translucent for life: switched
        // off, they keep their blur until they close (without it they would
        // be see-through), and only windows opened after follow the switch.
        this._glassy = GLASSY;
        this._battery = null;           // 'warn' / 'alert' / null, from UPower
        this._a11y = new Gio.Settings({schema_id: 'org.gnome.desktop.a11y.interface'});
        const self = this;
        // Every popup menu with a BoxPointer, whoever made it: the panel's,
        // extensions', app and desktop context menus.
        injections.overrideMethod(PopupMenu.PopupMenu.prototype, 'open',
            open => function (...args) {
                open.call(this, ...args);
                // never throw into the Shell's own menu code
                try {
                    self._trackMenu(this);
                } catch (e) {
                    console.warn(`pulsar-theme: glass: menu: ${e.message}`);
                }
            });
        // A slider's fill is drawn with cairo in its repaint, which CSS cannot
        // reach: the glow goes under it here, before the bar and the handle.
        // On Slider, not BarLevel: a vfunc override rehooks the class's own
        // vtable slot, and Slider has one of its own (its super call reaches
        // BarLevel's JS method directly, never an override there).
        injections.overrideMethod(Slider.Slider.prototype, 'vfunc_repaint',
            repaint => function (...args) {
                try {
                    fillGlow(this);
                } catch (e) {
                    console.warn(`pulsar-theme: glow: ${e.message}`);
                }
                repaint.call(this, ...args);
            });
        // Notification banners: a new banner in the same bin.
        injections.overrideMethod(MessageTray.MessageTray.prototype, '_showNotification',
            show => function (...args) {
                show.call(this, ...args);
                try {
                    self._trackBanner();
                } catch (e) {
                    console.warn(`pulsar-theme: glass: banner: ${e.message}`);
                }
            });
        // The switchers (Alt+Tab and its kin, and the workspace one), the
        // Shell's own dialogs and app folders, each as it is shown.
        const after = (proto, name, track) => injections.overrideMethod(proto, name,
            orig => function (...args) {
                const ret = orig.call(this, ...args);
                try {
                    track.call(self, this);
                } catch (e) {
                    console.warn(`pulsar-theme: glass: ${name}: ${e.message}`);
                }
                return ret;
            });
        after(SwitcherPopup.SwitcherPopup.prototype, 'show', this._trackSwitcher);
        // Alt+Tab on an app with several windows opens a second list, the
        // windows' thumbnails, made new each time and long after show().
        // The sheet clears every .switcher-list, so without its own glass it
        // was a bare row of previews.
        after(AltTab.AppSwitcherPopup.prototype, '_createThumbnails', this._trackThumbnails);
        after(WorkspaceSwitcherPopup.WorkspaceSwitcherPopup.prototype, 'display', this._trackWorkspaces);
        after(ModalDialog.ModalDialog.prototype, 'open', this._trackDialog);
        // "Not responding" is a Dialog of its own over the window, not a
        // ModalDialog, but it carries .modal-dialog, which the sheet clears.
        // (_initDialog, not vfunc_show: GJS reads a vfunc when the class is
        // registered, so replacing one on the prototype is never called.)
        after(CloseDialog.CloseDialog.prototype, '_initDialog', this._trackCloseDialog);
        after(AppDisplay.AppFolderDialog.prototype, 'popup', this._trackFolder);
        after(IBusCandidatePopup.CandidatePopup.prototype, 'open', this._trackCandidates);
        // A notification group's stacked cards, each cut where the cards
        // over it lie (StackCut): every one as it is added, and those already
        // in the date menu.
        after(MessageList.NotificationMessageGroup.prototype, '_addNotification', cutStack);
        messageGroups().forEach(cutStack);
        after(Dash.DashItemContainer.prototype, 'showLabel', this._trackDashLabel);
        // The overview's controls lay out only the children they know; the
        // dash's mirrors (_trackDash) stand where they were put.
        const controls = Main.overview.dash?.get_parent()?.layout_manager;
        if (controls)
            injections.overrideMethod(Object.getPrototypeOf(controls), 'vfunc_allocate',
                allocate => function (container, box) {
                    allocate.call(this, container, box);
                    for (const c of container.get_children()) {
                        if (c instanceof Mirror)
                            c.allocate_preferred_size(c.fixed_x, c.fixed_y);
                    }
                });
        settings.connectObject(
            // not for the tint: nothing _sync sets reads it (the Shell's half
            // comes back in the re-rendered sheet), and a slider drag sends
            // a change per step
            'changed', (_s, key) => key !== 'glass-tint' && this._sync(),
            // the other half of Glass windows is the engine's gtk.css
            'changed::window-glass', () => this._engine('window-glass'),
            'changed::glass', () => this._engine('window-glass'),
            // and so is Glow's: the Shell's half is the class _sync sets
            'changed::glow', () => this._engine('window-glass'),
            // the tint is the theme sheet's; the engine re-renders it
            'changed::glass-tint', () => this._tintSoon(),
            this);
        // A theme set while this was off wrote opaque windows (and the
        // switch turned back on changes no setting): put them right.
        this._engine('window-glass', '--if-stale');
        global.display.connectObject('window-created', (_d, win) => {
            // the actor exists once the window is shown
            laterAdd(() => {
                if (this._destroyed)
                    return;
                this._trackWindow(win.get_compositor_private());
                this._trackPopup(win);
            });
        }, this);
        this._a11y.connectObject('changed::high-contrast', () => {
            this._sync();
            this._engine('window-glass');
        }, this);
        Main.sessionMode.connectObject('updated', () => this._sync(), this);
        // 'hiding', not only 'hidden': the top bar's glass fades back in as
        // the overview closes, not after it has gone
        Main.overview.connectObject(
            'showing', () => {
                this._leavingOverview = false;
                this._sync();
            },
            'hiding', () => {
                this._leavingOverview = true;
                this._sync();
            },
            'hidden', () => {
                this._leavingOverview = false;
                this._sync();
            },
            this);
        Main.layoutManager.panelBox.connectObject('notify::visible', () => this._sync(), this);
        // the surfaces' shadow is the top bar's deep ground (deepShadow)
        Main.panel.connectObject('style-changed', () => {
            for (const s of this._surfaces.values())
                s.sync();
        }, this);
        Main.layoutManager.connectObject('monitors-changed', () => {
            Views.clear();
            laterAdd(() => this._destroyed || this._trackOsds());
            this._coverSoon();
        }, this);
        this._watchBattery();
        this._watchCover();
        this._watchSuspend();
        this._sync();
    }

    // ---- a window covering its monitor ----
    //
    // Fullscreen, or borderless and exactly the monitor's size, as many
    // games run (one sized to the work area is maximized by Mutter, and left
    // alone). Window glass beneath it goes (unseen, it was blurred afresh on
    // every frame the game drew), its own goes if it is a GTK window (direct
    // scanout wants it opaque, with nothing in its actor but its surfaces),
    // and every blur on that monitor -- the bar's, Quick Settings', an
    // OSD's -- is held (Hold). All of it comes back on its own the frame the
    // window goes: a held blur copies all of what is beneath again on its
    // next paint. The overview holds nothing: its window previews carry
    // their glass.
    _watchCover() {
        this._covered = new Map();      // monitor index -> covering window's stack index
        this._games = new Set();        // windows whose geometry is watched
        const cover = () => this._coverSoon();
        global.display.connectObject(
            'restacked', cover,
            'in-fullscreen-changed', cover,
            'window-created', (_d, win) => {
                this._watchGeometry(win);
                cover();
            },
            this);
        global.workspace_manager.connectObject('active-workspace-changed', cover, this);
        global.get_window_actors().forEach(a => this._watchGeometry(a.meta_window));
        this._cover();
    }

    // ---- glass off while gaming, or in Power Saver ----
    //
    // Read off D-Bus, never through a setting (a dconf write at game launch
    // is what deadlocked the Shell once), and never written back: the
    // switches stay as the user left them, and so does the power profile.
    // GameMode (gamemoded, which Steam and `gamemoderun` start games under)
    // counts its clients; the power profile comes from power-profiles-daemon
    // or tuned-ppd under either of their names. Either one gone (quit,
    // crashed, never there) counts as no game and no Power Saver.
    _watchSuspend() {
        this._gaming = false;
        this._powerSaver = false;
        this._proxy(Gio.BusType.SESSION, 'com.feralinteractive.GameMode', '/com/feralinteractive/GameMode',
            p => (this._gamemode = p), () => {
                const p = this._gamemode;
                this._suspend('_gaming', !!p.g_name_owner &&
                    (p.get_cached_property('ClientCount')?.unpack() ?? 0) > 0);
            });
        const profile = (name, path) => this._proxy(Gio.BusType.SYSTEM, name, path,
            p => (this._profiles = [...this._profiles ?? [], p]), () => {
                const on = this._profiles.find(p => p.g_name_owner);
                this._suspend('_powerSaver', on?.get_cached_property('ActiveProfile')?.unpack() === 'power-saver');
            });
        profile('org.freedesktop.UPower.PowerProfiles', '/org/freedesktop/UPower/PowerProfiles');
        profile('net.hadess.PowerProfiles', '/net/hadess/PowerProfiles');
    }

    // A proxy for `name` (also its interface) at `path`, kept by `keep`,
    // `read` whenever its owner or properties change. Never starts the
    // service.
    _proxy(bus, name, path, keep, read) {
        Gio.DBusProxy.new_for_bus(bus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null, name, path, name, null,
            (_o, res) => {
                let p;
                try {
                    p = Gio.DBusProxy.new_for_bus_finish(res);
                } catch {
                    return;
                }
                if (this._destroyed)
                    return;
                keep(p);
                p.connectObject(
                    'g-properties-changed', read,
                    'notify::g-name-owner', read,
                    this);
                read();
            });
    }

    _suspend(key, v) {
        if (this[key] === v)
            return;
        this[key] = v;
        this._sync();
    }

    _watchGeometry(win) {
        if (!win || this._games.has(win))
            return;
        this._games.add(win);
        const cover = () => this._coverSoon();
        // An application id (or a class) set after the window was shown
        // came too late for the one look window-created takes.
        const track = () => {
            this._trackWindow(win.get_compositor_private());
            this._trackPopup(win);
        };
        win.connectObject(
            'position-changed', cover,
            'size-changed', cover,
            'notify::fullscreen', cover,
            'notify::minimized', cover,
            'notify::gtk-application-id', track,
            'notify::wm-class', track,
            'unmanaged', () => {
                win.disconnectObject(this);
                this._games.delete(win);
                // the process's last window: its pid is free for another
                const pid = win.get_pid();
                if (!global.display.list_all_windows().some(o => o !== win && o.get_pid() === pid))
                    GTK4.delete(pid);
                cover();
            },
            this);
    }

    _coverSoon() {
        if (!this._coverLater)
            this._coverLater = laterAdd(() => {
                this._coverLater = 0;
                if (!this._destroyed)
                    this._cover();
            });
    }

    // Which monitors a window covers, topmost first; then every glass's
    // part in it.
    _cover() {
        const covered = this._covered;
        if (!covered)
            return;
        covered.clear();
        // Not in the overview: the previews there are clones of the windows,
        // glass and all, and the dash's blur moves with them.
        const overview = Main.overview.visible && !this._leavingOverview;
        const monitors = Main.layoutManager.monitors;
        const actors = global.get_window_actors();
        const self = new Set();         // windows that cover their monitor themselves
        for (let i = overview ? -1 : actors.length - 1; i >= 0; i--) {
            const a = actors[i], w = a.meta_window;
            if (!w || !a.visible || w.minimized ||
                [Meta.WindowType.DESKTOP, Meta.WindowType.DOCK].includes(w.get_window_type()))
                continue;
            const m = w.get_monitor();
            const mon = monitors[m];
            if (!mon || covered.has(m))
                continue;
            const f = w.get_frame_rect();
            const is = r => r && f.x === r.x && f.y === r.y && f.width === r.width && f.height === r.height;
            // a maximized window fills a monitor without a top bar too, and
            // keeps its glass
            const free = !w.is_maximized?.() && !w.maximized_horizontally && !w.maximized_vertically;
            if (w.is_fullscreen() || (free && is(mon))) {
                self.add(a);
                covered.set(m, i);
            }
        }
        // a full redraw takes every held copy whole again (Hold.gen)
        // suspended (a game, Power Saver), what glass is left -- GTK
        // windows' -- holds still everywhere
        if (Hold.set(!!this._suspended && !overview, [...covered.keys()].map(m => monitors[m])))
            global.stage.queue_redraw();
        const index = new Map(actors.map((a, i) => [a, i]));
        for (const [a, wg] of this._windows) {
            const top = covered.get(a.meta_window.get_monitor());
            wg.cover(self.has(a) || (top !== undefined && (index.get(a) ?? Infinity) < top));
        }
    }

    get _allowed() {
        return this._session && !this._a11y.get_boolean('high-contrast');
    }

    // The user's own session, not locked: high contrast aside, which takes
    // glass away but not from windows that opened translucent (_sync).
    get _session() {
        return !Main.sessionMode.isLocked && !Main.sessionMode.isGreeter &&
            Main.sessionMode.currentMode === 'user';
    }

    // Glass and light off for now, as if switched off, without touching the
    // switches: while a game runs (GameMode has a client) or the power
    // profile is Power Saver, each if its own switch says so. GTK windows
    // keep theirs (see _watchSuspend).
    get _suspended() {
        return (this._gaming && this._settings.get_boolean('glass-off-gaming')) ||
            (this._powerSaver && this._settings.get_boolean('glass-off-power-saver'));
    }

    get glass() {
        return this._allowed && !this._suspended && this._settings.get_boolean('glass');
    }

    get lighting() {
        return this._allowed && !this._suspended && this._settings.get_boolean('lighting');
    }

    get glowing() {
        return this._allowed && this._settings.get_boolean('glow');
    }

    get powerOn() {
        return this.lighting && this._settings.get_boolean('power-on');
    }

    // Not suspended with the rest: a GTK window's translucency is in the
    // gtk.css it opened with, and without its blur it would be see-through.
    get windows() {
        return this._allowed && this._settings.get_boolean('glass') && this._settings.get_boolean('window-glass');
    }

    get brackets() {
        return this._allowed && this._settings.get_boolean('focus-brackets');
    }

    // Surfaces are made lazily, the first time each is shown with an effect on.
    _add(host, opts) {
        const key = opts.key ?? host;
        if (!host || this._surfaces.has(key) || !(this.glass || this.lighting) || !host.get_parent())
            return null;
        const s = new Surface(this, host, opts);
        this._surfaces.set(key, s);
        return s;
    }

    _trackMenu(menu) {
        const bp = menu?._boxPointer;
        if (!bp || !menu.box || this._surfaces.has(bp))
            return;
        this._add(bp, {
            box: () => menu.box,
            // the middle of the widget that opened it
            source: () => {
                const src = menu.sourceActor;
                if (!src?.has_allocation())
                    return null;
                const [sx, sy] = src.get_transformed_position();
                const [sw, sh] = src.get_transformed_size();
                return [sx + sw / 2, sy + sh / 2];
            },
            // the date menu's divider is its calendar column's leading edge
            divider: () => menu === Main.panel.statusArea.dateMenu?.menu
                ? menu.box.find_child_by_name?.('calendarArea')?.get_children()
                    .find(c => c.has_style_class_name?.('datemenu-calendar-column')) ?? null
                : null,
            tone: () => this._battery,
        });
    }

    // The OSDs, one per monitor, lit from the bottom edge they sit on.
    _trackOsds() {
        for (const osd of Main.osdWindowManager?._osdWindows ?? []) {
            if (!osd?._hbox)
                continue;
            this._add(osd, {
                box: () => osd._hbox,
                source: (x, y, w) => {
                    const m = Main.layoutManager.monitors[osd._monitorIndex] ?? Main.layoutManager.primaryMonitor;
                    return [x + w / 2, m.y + m.height];
                },
                tone: () => this._battery,
            });
        }
    }

    // Alt+Tab and its kin: the popup covers the screen and fades as one;
    // the list is the surface. Opened from the keyboard, so lit from above.
    _trackSwitcher(popup) {
        const list = popup._switcherList;
        if (list)
            this._add(popup, {box: () => list, source: () => null, tone: () => this._battery});
    }

    // The thumbnails list under Alt+Tab's apps. Its glass stands beside the
    // popup, as the apps' list's does: inside it, the popup's allocate
    // (which places only the lists it knows) would never place the mirrors.
    // Keyed by the list, which comes and goes while the popup stays, and
    // following it, since it fades in and out on its own.
    _trackThumbnails(popup) {
        const list = popup._thumbnails;
        if (list)
            this._add(popup, {key: list, box: () => list, follow: () => list, source: () => null, tone: () => this._battery});
    }

    // The input method's candidates: a BoxPointer of its own, not a menu's,
    // so the menu hook never sees it. Lit from the text it follows.
    _trackCandidates(popup) {
        const box = popup.bin?.get_child();
        if (!box)
            return;
        this._add(popup, {
            box: () => box,
            source: () => {
                const c = popup._dummyCursor;
                if (!c?.has_allocation())
                    return null;
                const [cx, cy] = c.get_transformed_position();
                const [cw, ch] = c.get_transformed_size();
                return [cx + cw / 2, cy + ch / 2];
            },
            tone: () => this._battery,
        });
    }

    // One pill per monitor, in a popup the window manager keeps and reuses.
    _trackWorkspaces(popup) {
        for (const m of popup.get_children()) {
            if (m._list)
                this._add(m, {box: () => m._list, source: () => null, tone: () => this._battery});
        }
    }

    // A Shell dialog (power off, a password, Run): its box paints offscreen
    // (Dialog sets offscreen_redirect ALWAYS), so the glass goes beside the
    // layout that holds it, above the dialog's lightbox.
    _trackDialog(dialog) {
        const layout = dialog.dialogLayout;
        if (layout?._dialog)
            this._add(layout, {box: () => layout._dialog, source: () => null, tone: () => this._battery});
    }

    // The "not responding" dialog: a layout the size of the window, inside
    // the window actor. It scales and fades its box, not the layout, so the
    // glass copies the box (centered in the layout, so the pivots agree).
    _trackCloseDialog(close) {
        this._trackCloseLayout(close._dialog);
    }

    _trackCloseLayout(layout) {
        const box = layout?._dialog;
        if (box)
            this._add(layout, {box: () => box, follow: () => box, source: () => null, tone: () => this._battery});
    }

    // An app folder, lit from the folder it opened from. The dialog is an
    // St.Bin, which lays out only its one child, and it paints its own
    // shade beneath that child: the glass has to go between the two. So
    // the child is wrapped once in a box that holds it and the mirrors,
    // and the wrapper, now the dialog's child, is what zooms and fades.
    _trackFolder(dialog) {
        let wrap = this._folders?.get(dialog);
        if (!wrap) {
            const inner = dialog.child;
            if (!inner || !dialog._viewBox)
                return;
            wrap = new St.Widget({layout_manager: new Clutter.BinLayout(), x_expand: true, y_expand: true});
            dialog.set_child(null);
            wrap.add_child(inner);
            dialog.set_child(wrap);
            (this._folders ??= new Map()).set(dialog, wrap);
            dialog.connectObject('destroy', () => this._folders?.delete(dialog), this);
        }
        const inner = wrap.get_first_child();
        this._add(inner, {
            box: () => dialog._viewBox,
            frame: () => dialog,
            source: () => {
                const src = dialog._source;
                if (!src?.has_allocation())
                    return null;
                const [sx, sy] = src.get_transformed_position();
                const [sw, sh] = src.get_transformed_size();
                return [sx + sw / 2, sy + sh / 2];
            },
            tone: () => this._battery,
        });
    }

    _unwrapFolders() {
        for (const [dialog, wrap] of this._folders ?? []) {
            dialog.disconnectObject(this);
            const inner = wrap.get_first_child();
            if (inner) {
                wrap.remove_child(inner);
                dialog.set_child(inner);
            }
            wrap.destroy();
        }
        this._folders = null;
    }

    // The screenshot UI's panel, lit from the bottom edge it sits on. The
    // panel fades itself (and paints offscreen while it does), so the glass
    // goes beside it -- beside the panel, not its monitor box: the round
    // close button overlaps the panel's corner in the same box, and the
    // light has to go under it.
    _trackScreenshot() {
        const panel = Main.screenshotUI?._panel;
        if (!panel)
            return;
        this._add(panel, {
            box: () => panel,
            source: (x, y, w) => {
                const m = Main.layoutManager.primaryMonitor;
                return [x + w / 2, m ? m.y + m.height : y];
            },
            tone: () => this._battery,
        });
    }

    // The dash, lit along the whole bottom edge it sits on. Its host is the
    // overview's controls, whose layout places only the children it knows:
    // the mirrors beside the dash are placed after it, where they stand.
    _trackDash() {
        const dash = Main.overview.dash;
        const controls = dash?.get_parent();
        if (!dash?._background || !controls)
            return;
        this._add(dash, {
            box: () => dash._background,
            full: 'bottom',
            source: (x, y, w) => {
                const m = Main.layoutManager.primaryMonitor;
                return [x + w / 2, m ? m.y + m.height : y];
            },
            tone: () => this._battery,
        });
    }

    // The overview's search entry, in the controls beside the dash, and like
    // the dash placed after their layout. Lit top center (Nick, 2026-10-02:
    // not along its whole top edge), from a point just above its middle.
    _trackSearch() {
        const entry = Main.overview.searchEntry;
        const bin = entry?.get_parent();
        if (!bin?.get_parent())
            return;
        this._add(bin, {
            box: () => entry,
            source: () => {
                if (!entry.has_allocation())
                    return null;
                const [ex, ey] = entry.get_transformed_position();
                const [ew] = entry.get_transformed_size();
                return [ex + ew / 2, ey - 1];
            },
            tone: () => this._battery,
        });
    }

    // A dash icon's name, over the icon: lit from below, like the dash. A
    // tooltip comes and goes with every hover, so no power-on trace.
    _trackDashLabel(item) {
        const label = item?.label;
        if (!label || this._surfaces.has(label))
            return;
        this._add(label, {
            box: () => label,
            source: () => {
                if (!item.has_allocation())
                    return null;
                const [sx, sy] = item.get_transformed_position();
                const [sw, sh] = item.get_transformed_size();
                return [sx + sw / 2, sy + sh / 2];
            },
            tone: () => this._battery,
            still: true,
        });
    }

    // The banner bin, lit from the top edge banners come down from; a
    // critical banner's rim is the theme's red.
    _trackBanner() {
        const tray = Main.messageTray;
        const bin = tray?._bannerBin;
        if (!bin)
            return;
        const s = this._surfaces.get(bin) ?? this._add(bin, {
            box: () => bin.get_first_child(),
            source: () => null,
            tone: () => tray._notification?.urgency === MessageTray.Urgency.CRITICAL ? 'alert' : this._battery,
        });
        s?.renew();
    }

    // UPower's display device: WarningLevel 3 is low, 4 and up critical.
    _watchBattery() {
        Gio.DBusProxy.new_for_bus(Gio.BusType.SYSTEM, Gio.DBusProxyFlags.NONE, null,
            'org.freedesktop.UPower', '/org/freedesktop/UPower/devices/DisplayDevice',
            'org.freedesktop.UPower.Device', null, (_o, res) => {
                try {
                    this._upower = Gio.DBusProxy.new_for_bus_finish(res);
                } catch (e) {
                    return;     // no UPower: no warning edge
                }
                if (this._destroyed)
                    return;
                this._upower.connectObject('g-properties-changed', () => this._readBattery(), this);
                this._readBattery();
            });
    }

    _readBattery() {
        const level = this._upower?.get_cached_property('WarningLevel')?.unpack() ?? 0;
        const tone = level >= 4 ? 'alert' : level === 3 ? 'warn' : null;
        if (tone !== this._battery) {
            this._battery = tone;
            this._sync();
        }
    }

    // The extension turned off by the user (not the lock screen, which
    // disables extensions every time): take the translucency back too.
    static release() {
        if (Main.sessionMode.currentMode === 'user' && !Main.sessionMode.isLocked)
            Glass.prototype._engine('window-glass');
    }

    // a slider sends many changes: re-render once it rests
    _tintSoon() {
        if (this._tintId)
            GLib.source_remove(this._tintId);
        this._tintId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 300, () => {
            this._tintId = 0;
            this._engine('window-glass');
            return GLib.SOURCE_REMOVE;
        });
    }

    _engine(cmd, ...args) {
        try {
            Gio.Subprocess.new([ENGINE, cmd, ...args], Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE);
        } catch (e) {
            console.warn(`pulsar-theme: ${cmd}: ${e.message}`);
        }
    }

    // A popover over a glass window, uncull()ed for as long as it is open.
    _trackPopup(win) {
        const actor = win.get_compositor_private();
        // (asked again when its id or class changes: once is enough)
        if (!actor || !POPUP_TYPES.includes(win.get_window_type()) || !this._windows.size ||
            this._windows.has(actor) || this._popups?.has(actor))
            return;
        // over a glass window (or a popup of one): glass of its own
        const parent = win.get_transient_for()?.get_compositor_private();
        if (parent && this._windows.has(parent) && !this._windows.has(actor)) {
            this._windows.set(actor, new WindowGlass(this, actor, true));
            // as glassy as the window it opened from: with Glass windows
            // off, _sync keeps only glassy windows' glass, and stripped it
            // from an open popover of a glassy window
            if (this._glassy.has(parent))
                this._glassy.add(actor);
            return;
        }
        const cull = new Uncull(actor);
        cull.update();
        this._popups ??= new Map();
        this._popups.set(actor, cull);
        actor.connectObject(
            'damaged', () => cull.update(),
            'destroy', () => {
                cull.destroy();
                this._popups?.delete(actor);
            },
            this);
    }

    // `glassy`: one that opened translucent, kept whatever the switch says
    _trackWindow(actor, glassy = false, gtkPids = undefined) {
        if (!(this.windows || (glassy && this._session)) || !actor || this._windows.has(actor) ||
            !WindowGlass.wanted(actor, gtkPids))
            return;
        this._windows.set(actor, new WindowGlass(this, actor));
        if (this.windows)
            this._glassy.add(actor);
        this._coverSoon();
    }

    forgetWindow(actor) {
        this._windows.get(actor)?.destroy();
        this._windows.delete(actor);
    }

    forget(surface) {
        surface.destroy();
        this._surfaces.delete(surface.key);
    }

    _sync() {
        const ui = Main.layoutManager.uiGroup;
        const glass = this.glass, lit = this.lighting;
        // The theme's sheet keys the translucent material and the emitter
        // glow off these two classes.
        (glass ? ui.add_style_class_name : ui.remove_style_class_name).call(ui, 'pulsar-glass');
        (lit ? ui.add_style_class_name : ui.remove_style_class_name).call(ui, 'pulsar-lit');
        (this.glowing ? ui.add_style_class_name : ui.remove_style_class_name).call(ui, 'pulsar-glow');
        if (glass && !this._panel)
            this._panel = new PanelGlass();
        else if (!glass && this._panel) {
            this._panel.destroy();
            this._panel = null;
        }
        if (glass && !this._ground)
            this._ground = new OverviewGround();
        else if (!glass && this._ground) {
            this._ground.destroy();
            this._ground = null;
        }
        if (this._panel) {
            // 'showing' comes after the overview has taken the screen but
            // before it paints, so this holds the desktop's last frame
            this._panel.frozen = Main.overview.visible;
            this._panel.visible = Main.layoutManager.panelBox.visible &&
                (!Main.overview.visible || this._leavingOverview);
            this._panel.lit = this.lighting;
        }
        if (this.brackets && !this._brackets)
            this._brackets = new FocusBrackets(this);
        else if (!this.brackets && this._brackets) {
            this._brackets.destroy();
            this._brackets = null;
        }
        if (glass || lit) {
            this._trackOsds();
            this._trackScreenshot();
            this._trackDash();
            this._trackSearch();
            // A banner already up: at unlock the tray shows what queued
            // during the lock in the same sessionMode update that turns this
            // extension back on, before the _showNotification hook exists,
            // and .pulsar-glass would leave it with no background at all.
            if (Main.messageTray?._banner)
                this._trackBanner();
            // Dialogs already open, which no hook saw open: one left open
            // across a lock (polkit's hides while locked and shows again at
            // unlock) comes back to a new Glass, and the sheet has cleared
            // its .modal-dialog; so does glass switched on under one.
            for (const d of Main.layoutManager.modalDialogGroup.get_children()) {
                if (d instanceof ModalDialog.ModalDialog &&
                    (d.state === ModalDialog.State.OPENED || d.state === ModalDialog.State.OPENING))
                    this._trackDialog(d);
            }
            // and "not responding", inside its window's actor
            for (const a of global.get_window_actors()) {
                for (const c of a.get_children()) {
                    if (c._dialog?.has_style_class_name?.('close-dialog'))
                        this._trackCloseLayout(c);
                }
            }
        }
        // the GTK apps' processes, found once for all the windows, if asked
        let pids = null;
        const gtkPids = () => (pids ??= WindowGlass.gtkPids());
        if (this.windows)
            global.get_window_actors().forEach(a => this._trackWindow(a, false, gtkPids));
        else if (!this._session)
            [...this._windows.keys()].forEach(a => this.forgetWindow(a));
        else
            // switched off, or high contrast on: the translucent ones keep
            // their blur (back after a lock too), since GTK never reads
            // gtk.css again; the rest go
            global.get_window_actors().forEach(a => this._glassy.has(a)
                ? this._trackWindow(a, true, gtkPids) : this.forgetWindow(a));

        for (const s of this._surfaces.values())
            s.sync();
        // the overview coming or going, a new bar
        this._cover();
    }

    destroy() {
        this._destroyed = true;
        laterRemove(this._coverLater);
        for (const p of [this._gamemode, ...this._profiles ?? []])
            p?.disconnectObject(this);
        global.workspace_manager.disconnectObject(this);
        for (const w of this._games ?? [])
            w.disconnectObject(this);
        this._games = null;
        this._covered = null;
        Hold.set(false, []);
        Views.unwatch();
        if (this._tintId)
            GLib.source_remove(this._tintId);
        this._settings.disconnectObject(this);
        this._a11y.disconnectObject(this);
        this._upower?.disconnectObject(this);
        Main.sessionMode.disconnectObject(this);
        Main.overview.disconnectObject(this);
        Main.layoutManager.panelBox.disconnectObject(this);
        Main.layoutManager.disconnectObject(this);
        Main.panel.disconnectObject(this);
        for (const s of [...this._surfaces.values()])
            this.forget(s);
        this._unwrapFolders();
        uncutStacks();
        this._panel?.destroy();
        this._panel = null;
        this._ground?.destroy();
        this._ground = null;
        this._brackets?.destroy();
        this._brackets = null;
        global.display.disconnectObject(this);
        for (const a of [...this._windows.keys()])
            this.forgetWindow(a);
        // nothing sees windows close while this is off (a lock): their
        // pids may be other processes' by the next Glass
        GTK4.clear();
        for (const [a, cull] of this._popups ?? []) {
            a.disconnectObject(this);
            cull.recull();
            cull.destroy();
        }
        this._popups = null;
        Scratch.clear();
        const ui = Main.layoutManager.uiGroup;
        ui.remove_style_class_name('pulsar-glass');
        ui.remove_style_class_name('pulsar-lit');
        ui.remove_style_class_name('pulsar-glow');
    }
}
