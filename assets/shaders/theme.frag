// theme.frag -- Pulsar's wallpaper shader (assets/shaders/pulsar.frag),
// generalised so any theme palette can drive it.
//
// What changed from pulsar.frag, and why:
//  * every brand constant is a uniform, fed from the theme's palette by
//    wallpapers/render.py, so a wallpaper is always in its theme's colours;
//  * colour ramps interpolate in OKLab instead of sRGB. The brand ramp
//    (violet -> peri -> cyan) is analogous, so sRGB mixing never showed a
//    problem; theme ramps are not (gruvbox orange -> red, rose-pine iris ->
//    rose), and sRGB midpoints between distant hues are exactly the muddy
//    greys the review asked us to kill;
//  * composition knobs (field seed, fold scale, light direction, bloom
//    position, beam angle, star density) are uniforms, so two themes on the
//    same look do not share a layout;
//  * the dawn (light) cut takes its ground and its lights from the theme's
//    LIGHT palette, with a per-theme wash, instead of fixed pastels.
// The looks themselves -- nebula / leak / satin / holo -- are Pulsar's, math
//
// The looks live in looks/, one file each, appended after this file in the
// order looks/looks.json gives (the renderers and the site's sky.ts assemble
// it the same way). This file is the contract -- the uniforms and helpers --
// and the dispatch in main(). Nebula, Leak and Holo keep a theme half and a
// brand half in their files (BRAND is defined only by pulsar.frag).
// untouched; that is what keeps a Catppuccin desktop recognisably Pulsar.
uniform vec2  u_resolution;
uniform float u_time;
uniform float u_theme;   // 0 = night, 1 = dawn
uniform float u_look;    // 0 nebula 1 leak 2 satin 3 holo 4 relief 5 tide 6 orbit 7 beacon

uniform vec3  u_ga, u_gb;         // night ground: far (upper right), near (light side)
uniform vec3  u_da, u_db;         // dawn ground: bottom, top
uniform vec3  u_c1, u_c2, u_c3;   // lights: deep, mid, highlight
uniform vec3  u_c4;               // holo's contrast column (rose, in the brand)
uniform vec3  u_star;
uniform float u_desat;            // pull toward luminance (brand: 0.18)
uniform float u_gain;             // light intensity (1 = brand)
uniform float u_stars;            // star amount (0 = none, 1 = brand)
uniform float u_down;             // downlight amount (brand: 0.17)
uniform float u_wash;             // dawn: how far lights go toward white
uniform float u_fold;             // nebula field scale (brand: 2.2)
uniform vec2  u_seed;             // nebula field offset: moves every fold
uniform vec2  u_dir;              // direction the light mass flows FROM (brand: lower-left)
uniform vec2  u_bloom;            // satin bloom centre
uniform float u_beam;             // leak beam angle (brand: -0.35)
uniform float u_quiet;            // how hard the top-right (quick settings) corner is calmed
uniform float u_glow;             // luminescence: emissive cores, filaments, halos (0 = the plain look)
uniform float u_signal;           // signal treatment: lit lattice, edge aberration (0 = none)
uniform float u_grain;            // grain multiplier (it is also the 8-bit dither: never 0)
uniform float u_web;              // filament + lattice density/brightness (nebula 1; leak/holo 0.55, satin 0.45)
uniform float u_live;             // 1 on the site's live hero: the newer looks move (0 = the still)

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
// Grain and dither only: a sine-free hash (Dave Hoskins' hash12). The sine
// hash above leaves faint diagonal line structure at screen-space inputs,
// and sliding its input every frame made those lines march across the sky
// as moving bands, on every look. Stars and threads keep the sine hash so
// the art itself does not move.
float hashS(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return s;
}
float starLayer(vec2 uv, float scale, float density, float size, float tw) {
    vec2 g = uv * scale;
    vec2 id = floor(g);
    // most cells hold no star (density is a few percent): leave before any
    // of the star's own math, which is most of this layer's cost
    if (hash(id) < 1.0 - density) return 0.0;
    vec2 pos = vec2(hash(id + vec2(3.1, 1.7)), hash(id + vec2(7.7, 9.2)));
    // Drawn in screen pixels, not cell units: a star is a point of light
    // whatever the resolution. In cell units the fine layer fell below a
    // pixel (flickering single pixels) and the coarse one grew into a soft
    // 3-pixel smudge.
    float ppc = u_resolution.y / scale;                           // pixels per cell
    vec2 v = (fract(g) - pos) * ppc;                              // offset in pixels
    float b = hash(id + vec2(5.5, 2.2));                          // brightness
    // size keeps its old meaning (bigger size = smaller star), now as a
    // core radius in pixels, never under half a pixel so it stays resolved
    float r = clamp(ppc / sqrt(2.0 * size) * 0.55, 0.45, 1.1) * (0.8 + 0.4 * b);
    float dp2 = dot(v, v);
    // Each cell draws only its own star, so anything reaching past the
    // cell's edge is cut off square there. The glow's reach is capped to the
    // cell, and the glow and the cross both fade out before the edge.
    vec2 fc = fract(g);
    float edge = min(min(fc.x, 1.0 - fc.x), min(fc.y, 1.0 - fc.y)) * ppc;  // px to the nearest edge
    float gr = min(r * 3.5, ppc * 0.12);
    float star = 1.3 * exp(-dp2 / (r * r))
               + 0.32 * exp(-sqrt(dp2) / gr) * smoothstep(0.0, gr * 3.0, edge);
    // the brightest few get a thin four-point diffraction cross
    float L = r * (7.0 + 9.0 * b);
    float cross = exp(-abs(v.x) / L * 2.5) * exp(-v.y * v.y / (r * r * 0.3))
                + exp(-abs(v.y) / L * 2.5) * exp(-v.x * v.x / (r * r * 0.3));
    star += cross * 0.55 * smoothstep(0.86, 1.0, b) * smoothstep(0.0, L, edge);
    // twinkle, live only (stills pass 0): slow, each star on its own phase
    float twk = 1.0 - tw * 0.35 * (0.5 + 0.5 * sin(u_time * (0.8 + b * 1.6) + hash(id + 1.3) * 6.2831));
    return star * (0.4 + 0.6 * b) * twk;
}

// ---- OKLab mixing -------------------------------------------------------
vec3 toLin(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 toSrgb(vec3 c) { c = max(c, 0.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
// exp(-x^2) without pow(): GLSL leaves pow() undefined for a negative base,
// and some mobile GPUs return NaN there, which blacked out the whole frame
float gauss(float x) { return exp(-x * x); }
vec3 toLab(vec3 c) {
    c = toLin(c);
    vec3 lms = vec3(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b,
                    0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b,
                    0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b);
    lms = pow(max(lms, 0.0), vec3(1.0 / 3.0));
    return vec3(0.2104542553 * lms.x + 0.7936177850 * lms.y - 0.0040720468 * lms.z,
                1.9779984951 * lms.x - 2.4285922050 * lms.y + 0.4505937099 * lms.z,
                0.0259040371 * lms.x + 0.7827717662 * lms.y - 0.8086757660 * lms.z);
}
vec3 fromLab(vec3 L) {
    vec3 lms = vec3(L.x + 0.3963377774 * L.y + 0.2158037573 * L.z,
                    L.x - 0.1055613458 * L.y - 0.0638541728 * L.z,
                    L.x - 0.0894841775 * L.y - 1.2914855480 * L.z);
    lms = lms * lms * lms;
    return toSrgb(vec3( 4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                       -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                       -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z));
}
vec3 mixo(vec3 a, vec3 b, float t) { return fromLab(mix(toLab(a), toLab(b), clamp(t, 0.0, 1.0))); }
vec3 grey(vec3 c, float amt) { vec3 l = toLab(c); return fromLab(vec3(l.x, l.yz * (1.0 - amt))); }

// thin line with a gaussian profile; d is a distance in field units
float line(float d, float w) { return exp(-(d * d) / (w * w)); }

// Circuit lattice: a grid whose cells each carry at most one trace segment
// (horizontal, vertical or none) and, rarely, a node. Traces are only ever
// LIT by the glow around them, so the structure is felt, not drawn.
float lattice(vec2 uv, float scale) {
    vec2 g = uv * scale;
    vec2 id = floor(g), f = fract(g);
    float h = hash(id + 17.0);
    float w = 0.045;
    float lh = 1.0 - smoothstep(w * 0.5, w, abs(f.y - 0.5));
    float lv = 1.0 - smoothstep(w * 0.5, w, abs(f.x - 0.5));
    float seg = h < 0.30 ? lh : (h < 0.52 ? lv : 0.0);
    float node = step(0.94, hash(id + 3.1)) * (1.0 - smoothstep(0.07, 0.11, length(f - 0.5)));
    return max(seg * (0.55 + 0.45 * hash(id + 9.7)), node);
}

// Soft-knee highlight rolloff: identity below the knee, so the dark grounds
// keep their exact values, and an exponential shoulder above it, so hot
// cores bloom toward white instead of clipping flat.
vec3 knee(vec3 x) {
    const float k = 0.62;
    vec3 over = max(x - k, 0.0);
    return min(x, vec3(k)) + (1.0 - k) * (1.0 - exp(-over / (1.0 - k)));
}

// ---- per-pixel state the looks read and write ----------------------------
// Set by main() before any look runs; the looks' own functions (looks/*.glsl)
// read them, and the luminescence pass accumulates into emit/dawnFx/dawnInk.
vec2 uv;
float r, theme, starsNight, starsDawn;
bool wantDawn;          // light shows (theme > 0): the light cut is drawn at all
vec3 dawnBase, l1, l2, l3, l4;
float inten, carry, g2, fil, halo, tr, dawnInk;
vec3 emit, soft, dawnFx;

// the looks, defined in looks/*.glsl
vec3 nebulaNight();
vec3 nebulaDawn();
void nebulaGlow(float wNebula);
vec3 nebulaPearl(vec3 dawn, float amount);
vec3 leakNight();
vec3 leakDawn();
void leakGlow(float wLeak);
vec3 holoNight();
vec3 holoDawn();
void holoGlow(float wHolo);
vec3 freshLook(float look, out vec3 dawnN, out vec3 emitN);
vec3 freshNight(vec3 lightc);
vec3 freshGlow(vec3 night, vec3 emitN, float calm);
void quietCorner(inout vec3 night, inout vec3 dawn);

void main() {
    uv = (gl_FragCoord.xy - 0.5 * u_resolution) / u_resolution.y;
    r = length(uv);
    theme = clamp(u_theme, 0.0, 1.0);

    // two fields at fixed places, faded between by theme (see pulsar.frag)
    // and each look its own sky: the field shifts with the look, so swapping
    // looks swaps the stars too (Nebula, look 0, keeps its field exactly).
    // Only Nebula, Leak and Holo read these (the looks since place their own),
    // and dawn's field only when light shows: all uniform branches.
    float lookN = floor(clamp(u_look, 0.0, 7.0) + 0.5);
    vec2 skySeed = vec2(lookN * 37.1, lookN * 11.9);
    vec2 seedD = uv + u_seed + skySeed, seedL = uv + vec2(31.7, 17.3) + u_seed + skySeed;
    float lookAll = clamp(u_look, 0.0, 7.0);
    bool firstLooks = lookAll < 3.5 && abs(lookAll - 2.0) > 0.5;
    // mix(a, b, 0) is a exactly, so dark needs only the dark field; light
    // keeps the full mix, whose result is not bit-exactly b
    starsNight = 0.0; starsDawn = 0.0;
    if (firstLooks) {
        if (theme < 0.5) {
            starsNight = starLayer(seedD, 110.0, 0.030, 600.0, 0.0) + starLayer(seedD, 28.0, 0.050, 260.0, 0.0);
            if (theme > 0.0)
                starsDawn = starLayer(seedD,  60.0, 0.018, 380.0, 0.0) + starLayer(seedD, 18.0, 0.040, 180.0, 0.0);
        } else {
            starsNight = mix(starLayer(seedD, 110.0, 0.030, 600.0, 0.0) + starLayer(seedD, 28.0, 0.050, 260.0, 0.0),
                             starLayer(seedL, 110.0, 0.030, 600.0, 0.0) + starLayer(seedL, 28.0, 0.050, 260.0, 0.0), step(0.5, theme));
            starsDawn  = mix(starLayer(seedD,  60.0, 0.018, 380.0, 0.0) + starLayer(seedD, 18.0, 0.040, 180.0, 0.0),
                             starLayer(seedL,  60.0, 0.018, 380.0, 0.0) + starLayer(seedL, 18.0, 0.040, 180.0, 0.0), step(0.5, theme));
        }
    }

    // ---- dawn ground and lights ----
    dawnBase = mix(u_da, u_db, smoothstep(-0.5, 0.5, uv.y));
    // the washed lights only Nebula, Leak and Holo's light cuts use
    wantDawn = theme > 0.0;
    if (firstLooks && wantDawn) {
        l1 = mixo(u_c1, vec3(1.0), u_wash); l2 = mixo(u_c2, vec3(1.0), u_wash);
        l3 = mixo(u_c3, vec3(1.0), u_wash * 0.9); l4 = mixo(u_c4, vec3(1.0), u_wash);
    }

    vec3 night, dawn = vec3(0.0);
    // Nebula, Leak and Holo keep their original data flow below, mix chain
    // included, so their pixels are exactly what they were. Satin and the
    // looks since draw in the fresh path.
    if (firstLooks) {
        // only the showing look is drawn (uniform branches); a skipped one
        // entered the chain below at weight zero, and mix(x, y, 0) is x
        float look = clamp(u_look, 0.0, 3.0);
        float wNebula = 1.0 - clamp(look, 0.0, 1.0);
        float wLeak = clamp(look, 0.0, 1.0) - clamp(look - 1.0, 0.0, 1.0);
        float wHolo = clamp(look - 2.0, 0.0, 1.0);
        night = vec3(0.0);
        if (wNebula > 0.0) night = nebulaNight();
        vec3 leak = vec3(0.0);
        if (wLeak > 0.0) leak = leakNight();
        // Satin's slot in the chain stays, as zero: it keeps the chain's
        // arithmetic what it was when Satin sat here
        vec3 satinSlot = vec3(0.0);
        vec3 holo = vec3(0.0);
        if (wHolo > 0.0) holo = holoNight();
        night = mix(night, leak,  clamp(look, 0.0, 1.0));
        night = mix(night, satinSlot, clamp(look - 1.0, 0.0, 1.0));
        night = mix(night, holo,  clamp(look - 2.0, 0.0, 1.0));

        // dawn only when light shows (or mid-fade): dark is mix(night, dawn, 0)
        if (wantDawn) {
            dawn = vec3(0.0);
            if (wNebula > 0.0) dawn = nebulaDawn();
            vec3 dawnL = vec3(0.0);
            if (wLeak > 0.0) dawnL = leakDawn();
            vec3 dawnS = vec3(0.0);
            vec3 dawnH = vec3(0.0);
            if (wHolo > 0.0) dawnH = holoDawn();
            dawn = mix(dawn, dawnL, clamp(look, 0.0, 1.0));
            dawn = mix(dawn, dawnS, clamp(look - 1.0, 0.0, 1.0));
            dawn = mix(dawn, dawnH, clamp(look - 2.0, 0.0, 1.0));
        }

        // ---- each look's own luminescence (both variants) ------------------
        // One signature effect per look (see each look's Glow), all quiet
        // enough to be noticed on a second look rather than the first: soft
        // peaks, wide falloffs, more of the calm ground showing. Nothing
        // outshines the look's own emissive core, and no effect runs brighter
        // than the theme's highlight colour. u_web scales them all (the
        // phosphor themes ask for more); u_signal the hacker-ish parts.
        inten = clamp(dot(night - mix(u_ga, u_gb, 0.5), vec3(0.3333)) * 2.6, 0.0, 1.0);
        carry = 0.05 + 0.95 * smoothstep(0.05, 0.7, inten);   // effects live in the lit mass
        emit = u_c3 * pow(inten, 3.0) * 0.16;                  // the core itself, gently
        soft = mixo(u_c2, u_c3, 0.5);
        g2 = 0.0; fil = 0.0; halo = 0.0; tr = 0.0;
        dawnFx = vec3(0.0);        // light-variant additions, as a tint amount per channel
        dawnInk = 0.0;
        if (wNebula > 0.0) nebulaGlow(wNebula);
        if (wLeak > 0.0) leakGlow(wLeak);
        if (wHolo > 0.0) holoGlow(wHolo);
        // never brighter than the highlight colour, however they stack
        emit = min(emit, u_c3 * 0.85 + 0.03);
        night = knee(night + emit * u_glow);

        // light: the same effects in pearl, low-contrast against the paper
        if (wantDawn) {
            float intenD = clamp(dot(abs(dawn - dawnBase), vec3(0.3333)) * 7.0, 0.0, 1.0);
            if (wNebula > 0.0) dawn = nebulaPearl(dawn, wNebula * intenD * 0.14 * u_glow);
            dawn = mix(dawn, vec3(1.0), clamp(dawnFx * (0.15 + 0.85 * intenD) * u_glow, 0.0, 0.6));
            dawn *= 1.0 - clamp(dawnInk, -0.2, 0.2) * u_signal;
        }
    } else {
        vec3 emitN;
        night = freshNight(freshLook(lookAll, dawn, emitN));
        night = freshGlow(night, emitN, 1.0);
    }

    // No baked raster. A 3-pixel scanline looked right at 1:1 and beat into
    // moire the moment GNOME scaled the wallpaper to the monitor (3840->1920,
    // 2560->1366); the lattice and the grain carry the texture instead.

    // the quiet corner (looks/shared.glsl): calmed toward the ground where
    // quick settings, notifications and the calendar open
    quietCorner(night, dawn);

    vec3 col = mix(night, dawn, theme);

    // grain: follows luminance, never absent -- this is also the dither that
    // keeps the long low-contrast gradients from banding in 8-bit
    vec2 nseed = gl_FragCoord.xy + floor(fract(u_time) * 60.0) * vec2(113.0, 71.0);
    float g = hashS(nseed) - 0.5;
    float brightness = dot(col, vec3(0.33));
    col += g * (0.012 + 0.050 * brightness) * mix(1.0, 0.5, theme) * u_grain;

    // ---- dither, last ------------------------------------------------------
    // The grain above is artistic and single-sample: in the darks it is only
    // about one 8-bit step, and lossy JPEG XL and a compositor's downscale
    // both thin it further, so long gradients banded again. A triangular
    // (two-sample) dither of +-1 step on top breaks the bands wherever the
    // image is quantised, and is too fine to read as texture.
        col += (hashS(nseed + 0.37) + hashS(nseed + 91.7) - 1.0) / 255.0;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
