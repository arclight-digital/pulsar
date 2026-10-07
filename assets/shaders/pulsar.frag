// pulsar.frag -- the wallpaper background, rendered headless in CI.
//
// Pure fragment shader, no textures, no dependencies. scripts/render-wallpapers.py
// compiles it against a fullscreen triangle, writes PNGs, then composites the
// mark on top (the colour-on-dark mark on dark, the authored -light mark on
// light -- the logo is alpha art, pasted after the render, not reimplemented in GLSL).
// Nothing evaluates this at runtime on a real machine.
//
// Written for GLSL 120-style gl_FragColor. The harness injects a #version 330
// preamble that aliases it, so this stays readable as a glslViewer-compatible
// shader you can iterate on interactively:
//   glslViewer pulsar.frag -w 1920 -h 1080
//
// The look: nebula. A domain-warped noise field lit in the brand palette only
// (violet -> periwinkle -> cyan), folded like defocused light through fabric,
// over a near-black indigo ground with film grain everywhere and stars in the
// dark. Saturation is deliberately pulled toward luminance -- the reference
// boards all read soft, and pure hues read cheap.
//
//   u_theme 0.0 = night   1.0 = dawn (same field, high-key, ink-mark-friendly)
//
// LOCKED: the nebula field is approved as-is -- do not retune its constants or
// math. Post-approval additions sit on top of it and leave it untouched: the
// downlight, and the per-look luminescence pass at the end of main() (nebula's
// ion trails, leak's volumetric light, satin's fibre optics, holo's
// interference; approved 2026-09-26, kept subtle).
//
// The looks live in looks/, one file each, and are appended after this file
// (looks/looks.json gives the order; the renderers and the site's sky.ts
// assemble it the same way). This file is the brand contract -- the palette,
// the helpers -- and the dispatch in main(). #define BRAND selects each
// shared look file's brand half (Nebula, Leak and Holo keep their locked brand
// math apart from theme.frag's); the looks added since (Satin, Relief, Tide,
// Orbit, Beacon) are written once against theme.frag's contract, which the
// shim below maps onto the brand palette.
#define BRAND 1
uniform vec2  u_resolution;
uniform float u_time;   // fixed per render for stills, live for WebGL
uniform float u_theme;  // 0 = dark variant, 1 = light variant
uniform float u_look;   // 0 nebula (shipped) 1 leak 2 satin 3 holo 4 relief 5 tide 6 orbit 7 beacon
uniform float u_live;   // 1 on the site's live hero sky: the luminescence drops to a hint,
                        // so text over it stays readable; 0 (unset) for wallpapers

// brand palette. Not const: the site's live sky can hand in a picked
// theme's palette (u_palette_on = 1), which main() writes over these before
// anything reads them. Unset -- every wallpaper render -- they stay exactly
// the brand values, so the brand wallpapers are pixel-identical.
vec3 CYAN   = vec3(0.243, 0.796, 1.000); // #3ECBFF
vec3 PERI   = vec3(0.561, 0.659, 1.000); // #8FA8FF
vec3 VIOLET = vec3(0.294, 0.247, 0.831); // #4B3FD4
const vec3 STAR   = vec3(0.914, 0.929, 0.969); // #E9EDF7
vec3 ROSE   = vec3(0.980, 0.520, 0.760);         // holo's rose column
vec3 TEAL   = vec3(0.290, 0.800, 0.840);         // holo's teal column
vec3 INDIGO = vec3(0.055, 0.075, 0.360);         // holo's flanks

// The site's theme palette (sky.ts). Eight colours and a flag; no extra
// noise, a few mixes. Grounds are the theme's own deep/bg, lights its accent
// and two supporting hues, mixed in OKLab so distant hues never go muddy.
uniform float u_palette_on;
uniform vec3 u_p_hi, u_p_mid, u_p_deep, u_p_alt;   // accent, supporting, deep light, holo's contrast
uniform vec3 u_p_ga, u_p_gb;                       // night ground: far, near
uniform vec3 u_p_da, u_p_db;                       // dawn ground: bottom, top
bool pal() { return u_palette_on > 0.5; }

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
    return mix(mix(hash(i),                 hash(i + vec2(1.0, 0.0)), f.x),
               mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 5; i++) { s += a * vnoise(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return s;
}

// soft round stars on a jittered grid; d is in cell units so `size` controls
// the dot radius independent of resolution
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

// ---- luminescence helpers ------------------------------------------------
// Kept cheap on purpose: this file also runs live, per frame, in WebGL1 as the
// site's hero sky (pulsar-site's src/scripts/sky.ts), phones included. The extra field
// is a 3-octave fbm, the lattice is one hash lookup per cell, no loops beyond
// fbm's, GLSL ES 1.0 only.
float fbm3(vec2 p) {
    float a = 0.5, s = 0.0;
    for (int i = 0; i < 3; i++) { s += a * vnoise(p); p = p * 2.03 + 11.7; a *= 0.5; }
    return s / 0.875;
}
float glowLine(float d, float w) { return exp(-(d * d) / (w * w)); }
// circuit lattice: at most one trace segment (or a rare node) per cell
float lattice(vec2 uv, float scale) {
    vec2 g = uv * scale;
    vec2 id = floor(g), f = fract(g);
    float h = hash(id + 17.0);
    float lh = 1.0 - smoothstep(0.0225, 0.045, abs(f.y - 0.5));
    float lv = 1.0 - smoothstep(0.0225, 0.045, abs(f.x - 0.5));
    float seg = h < 0.30 ? lh : (h < 0.52 ? lv : 0.0);
    float node = step(0.94, hash(id + 3.1)) * (1.0 - smoothstep(0.07, 0.11, length(f - 0.5)));
    return max(seg * (0.55 + 0.45 * hash(id + 9.7)), node);
}
// soft-knee rolloff: identity below the knee (the grounds keep their exact
// values), an exponential shoulder above (cores bloom, never clip flat)
vec3 knee(vec3 x) {
    vec3 over = max(x - 0.62, 0.0);
    return min(x, vec3(0.62)) + 0.38 * (1.0 - exp(-over / 0.38));
}

// OKLab mixing, for theme palettes only: the brand ramp is analogous and
// keeps its sRGB mix (and its exact pixels).
vec3 toLinS(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 toSrgbS(vec3 c) { c = max(c, 0.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
// exp(-x^2) without pow(): GLSL leaves pow() undefined for a negative base,
// and some mobile GPUs return NaN there, which blacked out the whole frame
float gauss(float x) { return exp(-x * x); }
vec3 toLab(vec3 c) {
    c = toLinS(c);
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
    return toSrgbS(vec3( 4.0767416621 * lms.x - 3.3077115913 * lms.y + 0.2309699292 * lms.z,
                        -1.2684380046 * lms.x + 2.6097574011 * lms.y - 0.3413193965 * lms.z,
                        -0.0041960863 * lms.x - 0.7034186147 * lms.y + 1.7076147010 * lms.z));
}
vec3 pmix(vec3 a, vec3 b, float t) {
    if (pal()) return fromLab(mix(toLab(a), toLab(b), clamp(t, 0.0, 1.0)));
    return mix(a, b, t);
}

// ---- the contract the newer looks are written against --------------------
// theme.frag's uniform names, as plain globals here, set from the brand
// palette (or a site palette) at the top of main(). Colours mix in sRGB the
// way the brand's own looks do, unless a palette is on (pmix).
vec3 u_c1, u_c2, u_c3, u_c4, u_star, u_ga, u_gb, u_da, u_db;
float u_desat, u_gain, u_stars, u_down, u_wash, u_glow, u_quiet;
vec2 u_seed, u_dir;
vec3 mixo(vec3 a, vec3 b, float t) { return pmix(a, b, t); }
vec3 grey(vec3 c, float amt) { return mix(c, vec3(dot(c, vec3(0.30, 0.55, 0.15))), amt); }
void brandContract() {
    u_c1 = VIOLET; u_c2 = PERI; u_c3 = CYAN; u_c4 = ROSE; u_star = STAR;
    u_ga = pal() ? u_p_ga : vec3(0.005, 0.006, 0.016);
    u_gb = pal() ? u_p_gb : vec3(0.016, 0.019, 0.048);
    u_da = pal() ? u_p_da : vec3(0.906, 0.916, 0.958);
    u_db = pal() ? u_p_db : vec3(0.822, 0.842, 0.922);
    u_desat = 0.18; u_gain = 1.0; u_stars = 1.0; u_down = 0.17; u_wash = 0.35;
    u_glow = 1.0; u_quiet = 1.0;
    u_seed = vec2(0.0); u_dir = vec2(-0.8, -0.6);
}

// ---- per-pixel state the looks read and write ----------------------------
// Set by main() before any look runs; the looks' own functions (looks/*.glsl)
// read them, and the luminescence pass accumulates into emit/dawnFx/dawnInk.
vec2 uv;
float r, theme, starsNight, starsDawn;
bool wantDawn;          // light shows (theme > 0): the light cut is drawn at all
vec3 dawnBase;
float inten, carry, g2, dawnInk;
vec3 emit, dawnFx;

// the looks, defined in looks/*.glsl
void nebulaField(float wNebula);
vec3 nebulaNight();
vec3 nebulaDawn(vec3 dawn);
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
    if (pal()) {
        CYAN = u_p_hi; PERI = u_p_mid; VIOLET = u_p_deep;
        ROSE = u_p_alt; TEAL = u_p_hi; INDIGO = mix(u_p_ga, u_p_deep, 0.35);
    }
    uv = (gl_FragCoord.xy - 0.5 * u_resolution) / u_resolution.y;
    r = length(uv);
    theme = clamp(u_theme, 0.0, 1.0);
    wantDawn = theme > 0.0;
    brandContract();

    // each variant gets its own sky: a seed shift moves every star, and the
    // mixes differ -- night is dense fine dust, dawn is sparse larger glints
    // Two fields at fixed places, faded between by theme: the seed used to
    // move WITH theme, so the site's light/dark crossfade slid every star
    // across the sky. Dark and light stills are unchanged; the second field
    // is computed only mid-fade (uniform branch).
    // and each look its own sky: the field shifts with the look, so swapping
    // looks swaps the stars too (Nebula, look 0, keeps the field it shipped with)
    float lookN = floor(clamp(u_look, 0.0, 7.0) + 0.5);
    vec2 skySeed = vec2(lookN * 37.1, lookN * 11.9);
    vec2 seedD = uv + skySeed, seedL = uv + vec2(31.7, 17.3) + skySeed;
    if (theme <= 0.0) {
        starsNight = starLayer(seedD, 110.0, 0.030, 600.0, u_live) + starLayer(seedD, 28.0, 0.050, 260.0, u_live);
        starsDawn  = starLayer(seedD,  60.0, 0.018, 380.0, u_live) + starLayer(seedD, 18.0, 0.040, 180.0, u_live);
    } else if (theme >= 1.0) {
        starsNight = starLayer(seedL, 110.0, 0.030, 600.0, u_live) + starLayer(seedL, 28.0, 0.050, 260.0, u_live);
        starsDawn  = starLayer(seedL,  60.0, 0.018, 380.0, u_live) + starLayer(seedL, 18.0, 0.040, 180.0, u_live);
    } else {
        starsNight = mix(starLayer(seedD, 110.0, 0.030, 600.0, u_live) + starLayer(seedD, 28.0, 0.050, 260.0, u_live),
                         starLayer(seedL, 110.0, 0.030, 600.0, u_live) + starLayer(seedL, 28.0, 0.050, 260.0, u_live), theme);
        starsDawn  = mix(starLayer(seedD,  60.0, 0.018, 380.0, u_live) + starLayer(seedD, 18.0, 0.040, 180.0, u_live),
                         starLayer(seedL,  60.0, 0.018, 380.0, u_live) + starLayer(seedL, 18.0, 0.040, 180.0, u_live), theme);
    }

    // the dawn ground every light cut starts from. No darkening pool behind
    // the mark: the light cuts carry the authored -light mark, which is
    // designed to read on pale ground as-is; the ground sits a full step
    // below white ("too light" killed the near-white version)
    dawnBase = mix(pal() ? u_p_da : vec3(0.906, 0.916, 0.958),
                   pal() ? u_p_db : vec3(0.822, 0.842, 0.922),
                   smoothstep(-0.5, 0.5, uv.y));

    vec3 night;
    vec3 dawn = vec3(0.0);
    float lookAll = clamp(u_look, 0.0, 7.0);
    // Nebula, Leak and Holo keep their original data flow below, weights and
    // mix chain included, so their pixels are exactly what they were. Satin
    // and the looks since draw in the fresh path.
    if (lookAll < 3.5 && abs(lookAll - 2.0) > 0.5) {
        // Each look's weight in the final mix, known up front so a look that
        // is not showing is never computed: these are uniform branches (every
        // pixel takes the same path), so a hidden look costs nothing, and a
        // still is pixel-identical -- a skipped look was multiplied by zero.
        float look = clamp(u_look, 0.0, 3.0);
        float wNebula = 1.0 - clamp(look, 0.0, 1.0);
        float wLeak = clamp(look, 0.0, 1.0) - clamp(look - 1.0, 0.0, 1.0);
        float wHolo = clamp(look - 2.0, 0.0, 1.0);

        nebulaField(wNebula);
        night = nebulaNight();
        vec3 leak = vec3(0.0);
        if (wLeak > 0.0) leak = leakNight();
        // Satin's slot in the chain stays, as zero: it keeps the chain's
        // arithmetic exactly what it was when Satin sat here
        vec3 satinSlot = vec3(0.0);
        vec3 holo = vec3(0.0);
        if (wHolo > 0.0) holo = holoNight();
        night = mix(night, leak,  clamp(look, 0.0, 1.0));
        night = mix(night, satinSlot, clamp(look - 1.0, 0.0, 1.0));
        night = mix(night, holo,  clamp(look - 2.0, 0.0, 1.0));

        // dawn only when light mode shows (or mid-fade): theme is a uniform too
        if (theme > 0.0) {
            dawn = dawnBase;
            if (wNebula > 0.0) dawn = nebulaDawn(dawn);
            vec3 dawnL = vec3(0.0);
            if (wLeak > 0.0) dawnL = leakDawn();
            vec3 dawnS = vec3(0.0);
            vec3 dawnH = vec3(0.0);
            if (wHolo > 0.0) dawnH = holoDawn();
            dawn = mix(dawn, dawnL, clamp(look, 0.0, 1.0));
            dawn = mix(dawn, dawnS, clamp(look - 1.0, 0.0, 1.0));
            dawn = mix(dawn, dawnH, clamp(look - 2.0, 0.0, 1.0));
        }

        // ---- each look's own luminescence ----------------------------------
        // One signature effect per look (see each look's Glow), all quiet
        // enough to be noticed on a second look rather than the first;
        // nothing outshines the look's own core, nothing runs brighter than
        // cyan. Only the active look's block runs.
        inten = clamp(dot(night - (pal() ? mix(u_p_ga, u_p_gb, 0.5) : vec3(0.012, 0.014, 0.034)), vec3(0.3333)) * 2.6, 0.0, 1.0);
        carry = 0.05 + 0.95 * smoothstep(0.05, 0.7, inten);
        emit = CYAN * pow(inten, 3.0) * 0.16;
        g2 = 0.0;
        dawnFx = vec3(0.0);
        dawnInk = 0.0;
        if (wNebula > 0.0) nebulaGlow(wNebula);
        if (wLeak > 0.0) leakGlow(wLeak);
        if (wHolo > 0.0) holoGlow(wHolo);
        emit = min(emit, CYAN * 0.85 + 0.03);
        // the live sky sits behind the site's hero text: the calmest of all
        float fx = mix(1.0, 0.22, clamp(u_live, 0.0, 1.0));
        emit *= fx;
        dawnFx *= fx;
        dawnInk *= fx;
        float aspect = u_resolution.x / u_resolution.y;
        vec2 qc = (uv - vec2(0.5 * aspect, 0.5)) * vec2(0.8, 1.2);
        float quiet = 1.0 - exp(-dot(qc, qc) * 2.2) * 0.85;
        night = knee(night + emit * quiet);
        // dawn: the same effects in pearl, low-contrast against the paper
        float intenD = clamp(dot(abs(dawn - dawnBase), vec3(0.3333)) * 7.0, 0.0, 1.0);
        if (wNebula > 0.0) dawn = nebulaPearl(dawn, wNebula * intenD * 0.14 * quiet);
        dawn = mix(dawn, vec3(1.0), clamp(dawnFx * (0.15 + 0.85 * intenD) * quiet, 0.0, 0.6));
        dawn *= 1.0 - clamp(dawnInk, -0.2, 0.2);
    } else {
        vec3 emitN;
        night = freshNight(freshLook(lookAll, dawn, emitN));
        // live, the glow is calmed, but less than the first three's: their
        // filaments cross the hero text, while a newer look's light is its
        // subject (Beacon's star and halo all but vanished at 0.22)
        night = freshGlow(night, emitN, mix(1.0, 0.5, clamp(u_live, 0.0, 1.0)));
        quietCorner(night, dawn);
    }

    // No raster: a fine scanline beats into moire when GNOME scales a baked
    // wallpaper to the monitor, and shimmers in the live sky; the lattice and
    // the grain carry the texture.

    vec3 col = mix(night, dawn, theme);

    // ---- film grain, screen-space ------------------------------------------
    // Follows luminance the way real grain does: strongest in the lit nebula,
    // never absent even in the blacks. This also kills gradient banding.
    vec2 nseed = gl_FragCoord.xy + floor(fract(u_time) * 60.0) * vec2(113.0, 71.0);
    float g = hashS(nseed) - 0.5;
    float brightness = dot(col, vec3(0.33));
    col += g * (0.012 + 0.050 * brightness) * mix(1.0, 0.6, theme);

    // ---- dither, last ------------------------------------------------------
    // The grain above is artistic and single-sample: in the darks it is only
    // about one 8-bit step, and lossy JPEG XL and a compositor's downscale
    // both thin it further, so long gradients banded again. A triangular
    // (two-sample) dither of +-1 step on top breaks the bands wherever the
    // image is quantised, and is too fine to read as texture.
    // Live, the dither is +-3 steps: laptop panels are often 6-bit (+FRC),
    // where one visible step is four 8-bit ones, and +-1 vanishes under it --
    // the site's dark diagonal gradient banded on such a panel with the +-1
    // dither measurably present. Stills keep +-1 (their grain survives).
        float damp = mix(1.0, 3.0, clamp(u_live, 0.0, 1.0));
    col += (hashS(nseed + 0.37) + hashS(nseed + 91.7) - 1.0) * damp / 255.0;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
