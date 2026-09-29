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
// The look: silk. A domain-warped noise field lit in the brand palette only
// (violet -> periwinkle -> cyan), folded like defocused light through fabric,
// over a near-black indigo ground with film grain everywhere and stars in the
// dark. Saturation is deliberately pulled toward luminance -- the reference
// boards all read soft, and pure hues read cheap.
//
//   u_theme 0.0 = night   1.0 = dawn (same field, high-key, ink-mark-friendly)
//
// LOCKED: the silk field is approved as-is -- do not retune its constants or
// math. Post-approval additions sit on top of it and leave it untouched: the
// downlight, and the per-look luminescence pass at the end of main() (silk's
// ion trails, leak's volumetric light, satin's fibre optics, holo's
// interference; approved 2026-09-26, kept subtle).
uniform vec2  u_resolution;
uniform float u_time;   // fixed per render for stills, live for WebGL
uniform float u_theme;  // 0 = dark variant, 1 = light variant
uniform float u_look;   // 0 = silk (shipped), 1 = leak, 2 = satin, 3 = holo
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
// site's hero sky (site/src/scripts/sky.ts), phones included. The extra field
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

// holo's column ramp: indigo | rose | periwinkle | teal | indigo. Split out
// so the technicolor pass can sample it three times at offset positions.
vec3 holoRamp(float hx) {
    vec3 c = INDIGO;
    c = pmix(c, ROSE,   smoothstep(-0.38, -0.16, hx));
    c = pmix(c, PERI,   smoothstep(-0.04,  0.12, hx));
    c = pmix(c, TEAL,   smoothstep( 0.16,  0.30, hx));
    c = pmix(c, INDIGO, smoothstep( 0.34,  0.52, hx));
    return c;
}

// one beam with prismatic dispersion: the R/G/B channels land at slightly
// offset heights, so the beam's edges split into color fringes
vec3 beamRGB(float y, float c, float w, float o) {
    return vec3(gauss((y - c + o) / w),
                gauss((y - c) / w),
                gauss((y - c - o) / w));
}

void main() {
    if (pal()) {
        CYAN = u_p_hi; PERI = u_p_mid; VIOLET = u_p_deep;
        ROSE = u_p_alt; TEAL = u_p_hi; INDIGO = mix(u_p_ga, u_p_deep, 0.35);
    }
    vec2 uv = (gl_FragCoord.xy - 0.5 * u_resolution) / u_resolution.y;
    float r = length(uv);
    float theme = clamp(u_theme, 0.0, 1.0);
    // Each look's weight in the final mix, known up front so a look that is
    // not showing is never computed: these are uniform branches (every pixel
    // takes the same path), so a hidden look costs nothing, and a still is
    // pixel-identical -- a skipped look was multiplied by zero anyway.
    float look = clamp(u_look, 0.0, 3.0);
    float wSilk = 1.0 - clamp(look, 0.0, 1.0);
    float wLeak = clamp(look, 0.0, 1.0) - clamp(look - 1.0, 0.0, 1.0);
    float wSatin = clamp(look - 1.0, 0.0, 1.0) - clamp(look - 2.0, 0.0, 1.0);
    float wHolo = clamp(look - 2.0, 0.0, 1.0);

    // ---- the silk: domain-warped fbm (iq's f(p + fbm(p + fbm(p))) trick) --
    // This is what replaces gaussian bands: the double warp folds the field
    // into creases and wisps, so the light has internal structure instead of
    // reading as airbrushed stripes.
    vec2 w = vec2(0.0);
    float f = 0.0;
    if (wSilk > 0.0) {
        vec2 p = uv * 2.2 + vec2(0.0, u_time * 0.01);
        vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
        w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2)),
                 fbm(p + 3.0 * q + vec2(8.3, 2.8)));
        f = fbm(p + 3.0 * w);
    }

    // light mass flows out of the lower-left; the upper-right goes dark.
    // the smoothstep remap is contrast, not gain: creases below 0.28 stay
    // black, folds above it glow -- raising overall gain instead of this is
    // what made an earlier cut read as uniform smoke
    float mask = smoothstep(1.05, -0.55, dot(uv, normalize(vec2(0.80, 0.60))));
    float lum = pow(smoothstep(0.28, 0.92, f), 1.6) * mask;

    // color from the fold depth, brand ramp only, then pulled toward grey --
    // full-sat hues are what made the earlier cuts read like test cards
    vec3 silk = pmix(VIOLET * 0.75, PERI, smoothstep(0.35, 0.75, f));
    silk = pmix(silk, CYAN, smoothstep(0.70, 0.95, f) * 0.8);
    silk = mix(silk, vec3(dot(silk, vec3(0.30, 0.55, 0.15))), 0.18);

    // each variant gets its own sky: a seed shift moves every star, and the
    // mixes differ -- night is dense fine dust, dawn is sparse larger glints
    // Two fields at fixed places, faded between by theme: the seed used to
    // move WITH theme, so the site's light/dark crossfade slid every star
    // across the sky. Dark and light stills are unchanged; the second field
    // is computed only mid-fade (uniform branch).
    vec2 seedD = uv, seedL = uv + vec2(31.7, 17.3);
    float starsNight, starsDawn;
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

    // ---- night -------------------------------------------------------------
    // kept LOW on purpose: this sits behind a desktop full of windows, and
    // the reference boards go to true black in the empty regions
    vec3 night = mix(pal() ? u_p_ga : vec3(0.005, 0.006, 0.016),      // upper-right, near black
                     pal() ? u_p_gb : vec3(0.016, 0.019, 0.048),      // lower-left, indigo cast
                     mask);
    night += silk * lum * 0.75;
    night += STAR * starsNight * clamp(1.0 - lum * 3.0, 0.0, 1.0) * 0.55;
    night *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r); // vignette
    // soft downlight from the top, same move as the tile icon's ambient glow:
    // widest at top center, gone by mid-frame, periwinkle so it stays cool
    night += PERI * 0.17 * pow(smoothstep(-0.25, 0.62, uv.y), 1.6)
           * (0.70 + 0.30 * exp(-uv.x * uv.x * 1.2));

    // ---- alternate looks (u_look 1-3) --------------------------------------
    // The warped-fbm "watercolor" texture is silk's signature, so none of
    // these touch the f field. Each look has its own effect instead; all keep
    // to the brand palette pulled toward grey, and stay dim -- these are dark
    // wallpapers, not posters.

    // 1: light-leak -- THE CLEAN ONE: buttery smooth beams, deliberately no
    // texture objects at all (a bokeh cut of this read as a Windows
    // screensaver and died for it). Its signature is photographic instead:
    // prismatic dispersion splits each beam edge into color fringes, and
    // film halation bleeds the brightest beam softly into the dark side.
    float lA = -0.35;
    vec2 lq = vec2(cos(lA) * uv.x + sin(lA) * uv.y,
                   -sin(lA) * uv.x + cos(lA) * uv.y);
    float lfade = smoothstep(0.85, -0.35, lq.x);
    vec3 leak = vec3(0.0);
    if (wLeak > 0.0) {
    leak = pal() ? mix(u_p_ga, u_p_gb * 0.85, lfade)
                 : mix(vec3(0.006, 0.007, 0.018), vec3(0.014, 0.016, 0.040), lfade);
    leak += VIOLET * beamRGB(lq.y, 0.36, 0.20, 0.050) * lfade * 0.55;
    leak += PERI   * beamRGB(lq.y, 0.05, 0.26, 0.055) * lfade * 0.45;
    leak += CYAN   * beamRGB(lq.y, -0.28, 0.14, 0.040)
          * smoothstep(0.50, -0.45, lq.x) * 0.50;
    // halation: an extra-wide faint copy of the cyan beam glowing outward
    leak += CYAN * gauss((lq.y + 0.28) / 0.42)
          * smoothstep(0.50, -0.45, lq.x) * 0.10;
    leak = mix(leak, vec3(dot(leak, vec3(0.33))), 0.15);
    leak += STAR * starsNight * (1.0 - lfade * 0.7) * 0.45;
    leak *= 1.0 - 0.35 * smoothstep(0.60, 1.10, r);
    }

    // 2: satin -- LOCKED composition: indigo field, one submerged cyan bloom.
    // Unique effect: directional thread sheen, fine noise stretched along the
    // diagonal like woven fabric; it scales with local brightness the way a
    // real weave only shows where the light hits it.
    float sdiag = dot(uv, normalize(vec2(-0.35, 1.0)));
    float su = dot(uv, normalize(vec2(1.0, 0.35)));       // along-thread coord
    vec2 sp = uv - vec2(0.42, -0.06);
    float sd = dot(sp, sp);
    vec3 satin = vec3(0.0);
    float fiber = 0.0, weft = 0.0;
    if (wSatin > 0.0) {
    satin = mix(pal() ? u_p_ga : vec3(0.006, 0.008, 0.020),
                     pal() ? mix(u_p_gb, u_p_deep, 0.25) : vec3(0.030, 0.045, 0.110),
                     smoothstep(-0.60, 0.70, sdiag));
    satin += CYAN * exp(-sd * 7.0) * 0.26;
    satin += PERI * exp(-sd * 2.5) * 0.09;
    // weave, not scratches: short fiber dashes along the thread direction
    // crossed by a weaker perpendicular weft. Long unbroken streaks read as
    // brushed metal, which satin is not; still scales with local brightness
    // so the weave only shows where the bloom hits it.
    fiber = vnoise(vec2(sdiag * 340.0, su * 36.0)) - 0.5;
    weft  = vnoise(vec2(su * 300.0, sdiag * 30.0)) - 0.5;
    satin += satin * (fiber + 0.6 * weft) * 0.38;
    satin = mix(satin, vec3(dot(satin, vec3(0.33))), 0.10);
    // no stars: this is cloth, not sky
    satin *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r);
    }

    // 3: holo -- iridescent foil, spectrum clipped to rose/peri/teal between
    // indigo flanks, luminous mid-height. Unique effect: thin-film
    // interference -- contour fringes from a smooth thickness field, hue
    // rotating across each fringe like an oil slick. Curved bands, so it
    // shares no DNA with satin's threads or leak's discs. The muddy version
    // of this look died of desaturation, so it keeps most of its chroma.
    float nx = gl_FragCoord.x / u_resolution.x - 0.5;
    float ab = 0.030;
    float fring = 0.0, hx = 0.0;
    vec3 holo = vec3(0.0);
    if (wHolo > 0.0) {
    float film = vnoise(uv * 2.4 + 3.0) + 0.5 * vnoise(uv * 4.8 + 7.0);
    fring = 0.5 + 0.5 * sin(film * 22.0);                  // interference fringes
    float sheen = 0.5 + 0.5 * sin(nx * 9.0 + sin(uv.y * 1.8) * 0.7);
    // fringes SHIMMER the columns, they must not replace them -- the 0.10
    // version of this hue shift turned the whole frame into an oil slick
    hx = nx * 1.25 + 0.06 * sin(uv.y * 2.2 + 1.0)
             + (fring - 0.5) * 0.035 + uv.y * 0.08;
    // technicolor mis-registration: each channel reads the column ramp at a
    // slightly different position, so every color boundary fringes
    holo = vec3(holoRamp(hx + ab).r, holoRamp(hx).g, holoRamp(hx - ab).b);
    float env = smoothstep(0.62, 0.10, abs(uv.y)) * 0.62 + 0.10;
    holo *= env * (0.72 + 0.28 * sheen) * (0.92 + 0.11 * fring);
    holo = mix(holo, vec3(dot(holo, vec3(0.33))), 0.04);   // nearly full chroma
    holo += STAR * starsNight * 0.20 * smoothstep(0.40, 0.62, abs(uv.y));
    holo *= 1.0 - 0.30 * smoothstep(0.65, 1.15, r);
    }

    night = mix(night, leak,  clamp(look, 0.0, 1.0));
    night = mix(night, satin, clamp(look - 1.0, 0.0, 1.0));
    night = mix(night, holo,  clamp(look - 2.0, 0.0, 1.0));

    // ---- dawn: every look gets a high-key counterpart ----------------------
    // No darkening pool behind the mark: the light cuts carry the authored
    // -light mark, which is designed to read on pale ground as-is.
    // ground sits a full step below white -- "too light" feedback killed the
    // near-white version; the tint does the work of making the marks pop
    // Dawn only when light mode shows (or mid-fade): theme is a uniform too.
    vec3 dawnBase = mix(pal() ? u_p_da : vec3(0.906, 0.916, 0.958),
                        pal() ? u_p_db : vec3(0.822, 0.842, 0.922),
                        smoothstep(-0.5, 0.5, uv.y));
    vec3 dawn = vec3(0.0);
    if (theme > 0.0) {

    // silk dawn: the field as watercolor, wetter than before
    dawn = dawnBase;
    if (wSilk > 0.0) {
    vec3 silkDawn = pmix(mix(PERI, vec3(1.0), 0.12), mix(CYAN, vec3(1.0), 0.20),
                        smoothstep(0.6, 0.9, f));
    dawn = mix(dawn, silkDawn, lum * 0.95);
    dawn = mix(dawn, mix(VIOLET, vec3(1.0), 0.60), starsDawn * 0.35); // pale glints
    }

    // leak dawn: the same beams as washes of pastel; dispersion would be
    // invisible at this key, so the light cut trades it for pure color
    vec3 dawnL = vec3(0.0);
    if (wLeak > 0.0) {
    dawnL = dawnBase;
    float dV = gauss((lq.y - 0.36) / 0.20) * lfade;
    float dP = gauss((lq.y - 0.05) / 0.26) * lfade;
    float dC = gauss((lq.y + 0.28) / 0.14) * smoothstep(0.50, -0.45, lq.x);
    dawnL = mix(dawnL, vec3(0.700, 0.650, 0.930), dV * 0.75);
    dawnL = mix(dawnL, vec3(0.700, 0.760, 0.970), dP * 0.68);
    dawnL = mix(dawnL, vec3(0.590, 0.840, 0.975), dC * 0.75);
    }

    // satin dawn: daylight on the same cloth -- the weave flips to reading
    // as darker threads on pale fabric, and the bloom becomes a soft sheen
    vec3 dawnS = vec3(0.0);
    if (wSatin > 0.0) {
    dawnS = mix(pal() ? u_p_db * 0.96 : vec3(0.800, 0.818, 0.900),
                     pal() ? u_p_da : vec3(0.862, 0.880, 0.940),
                     smoothstep(-0.60, 0.70, sdiag));
    dawnS += CYAN * exp(-sd * 7.0) * 0.18;
    dawnS *= 1.0 - clamp(fiber + 0.6 * weft, -1.0, 1.0) * 0.12;
    }

    // holo dawn: the foil ramp pushed to pastel over the pale ground
    vec3 dawnH = vec3(0.0);
    if (wHolo > 0.0) {
    dawnH = mix(dawnBase,
                     mix(vec3(holoRamp(hx + ab).r, holoRamp(hx).g, holoRamp(hx - ab).b),
                         vec3(1.0), 0.38),
                     smoothstep(0.62, 0.10, abs(uv.y)) * 0.78 + 0.16);
    dawnH *= 0.94 + 0.06 * fring;
    }

    dawn = mix(dawn, dawnL, clamp(look, 0.0, 1.0));
    dawn = mix(dawn, dawnS, clamp(look - 1.0, 0.0, 1.0));
    dawn = mix(dawn, dawnH, clamp(look - 2.0, 0.0, 1.0));
    }


    // ---- each look's own luminescence --------------------------------------
    // One signature effect per look, all quiet enough to be noticed on a
    // second look rather than the first; nothing outshines the look's own
    // core, nothing runs brighter than cyan. The top-right stays quiet.
    //   silk  -- ion trails on the field's isolines, with a halo, over a
    //            faint violet circuit lattice lit only by the glow near it
    //   leak  -- volumetric light: god-rays through the leak, drifting motes,
    //            an anamorphic streak with a little dispersion at the beam edge
    //   satin -- fibre optics: a few warp threads carry travelling pulses
    //            (they travel on the site's live sky), with glints at crossings
    //   holo  -- interference: thin-film fringes and a diffraction sheen,
    //            coloured by wavelength, and one faint hologram scan band
    // Only the active look's block runs (the branches are on uniforms), so
    // the live sky pays for one effect, not four. GLSL ES 1.0 throughout.
    float inten = clamp(dot(night - (pal() ? mix(u_p_ga, u_p_gb, 0.5) : vec3(0.012, 0.014, 0.034)), vec3(0.3333)) * 2.6, 0.0, 1.0);
    float carry = 0.05 + 0.95 * smoothstep(0.05, 0.7, inten);
    vec3 emit = CYAN * pow(inten, 3.0) * 0.16;
    float g2 = 0.0;
    vec3 dawnFx = vec3(0.0);
    float dawnInk = 0.0;
    if (wSilk > 0.0) {
        g2 = fbm3(uv * 2.7 + w * 1.8 + 4.1);
        float ca = 0.0020;
        vec3 f3 = vec3(glowLine(g2 - 0.52 - ca, 0.0060), glowLine(g2 - 0.52, 0.0060), glowLine(g2 - 0.52 + ca, 0.0060))
                + 0.5 * vec3(glowLine(f - 0.63 - ca, 0.0050), glowLine(f - 0.63, 0.0050), glowLine(f - 0.63 + ca, 0.0050));
        float halo = glowLine(g2 - 0.52, 0.050) + 0.5 * glowLine(f - 0.63, 0.040);
        float tr = lattice(uv, 26.0);
        emit += wSilk * (CYAN * f3 * 0.55 * carry + PERI * halo * 0.12 * carry
                         + mix(VIOLET, PERI, 0.5) * tr * (0.010 + 0.18 * inten));
        dawnFx += wSilk * vec3(f3.g * 0.28 * (0.1 + 0.9 * carry));
        dawnInk += wSilk * tr * 0.025;
    }
    if (wLeak > 0.0) {
        vec2 rel = lq - vec2(-1.25, -0.05);
        float ang = atan(rel.y, rel.x);
        float rays = vnoise(vec2(ang * 34.0, 1.7)) * 0.65 + vnoise(vec2(ang * 91.0, 4.2)) * 0.35;
        rays = smoothstep(0.35, 0.95, rays) * smoothstep(2.3, 0.4, length(rel));
        float motes = starLayer(uv, 46.0, 0.035, 140.0, 0.0) + starLayer(uv + 7.3, 19.0, 0.03, 60.0, 0.0);
        float edge = -0.14;
        vec3 streak = vec3(glowLine(lq.y - edge - 0.0035, 0.010), glowLine(lq.y - edge, 0.010),
                           glowLine(lq.y - edge + 0.0035, 0.010)) * smoothstep(0.55, -0.6, lq.x);
        emit += wLeak * (PERI * rays * inten * 0.06 + CYAN * motes * inten * 0.28 + CYAN * streak * 0.10);
        dawnFx += wLeak * vec3(rays * 0.05 + streak.g * 0.08);
        dawnInk -= wLeak * motes * 0.06;
    }
    if (wSatin > 0.0) {
        float tid = floor(sdiag * 48.0);
        float lit = step(0.80, hash(vec2(tid, 7.0)));
        float thread = glowLine(fract(sdiag * 48.0) - 0.5, 0.09) * lit;
        // The pulse travels along the threads -- but not on the live site,
        // where its fronts read as bands marching to the upper right across
        // the dark sky behind the hero text. Stills never moved anyway.
        float pt = u_time * 0.6 * (1.0 - clamp(u_live, 0.0, 1.0));
        float pulse = pow(0.5 + 0.5 * sin(su * 9.0 - pt + hash(vec2(tid, 3.0)) * 6.2831), 10.0);
        float weftLit = step(0.90, hash(vec2(floor(su * 30.0), 11.0)));
        float glint = thread * weftLit * glowLine(fract(su * 30.0) - 0.5, 0.10);
        float satinLit = exp(-sd * 2.2);
        emit += wSatin * (CYAN * thread * (0.10 + 0.35 * pulse) * satinLit
                          + mix(CYAN, vec3(1.0), 0.2) * glint * 0.30 * satinLit);
        dawnFx += wSatin * vec3(thread * (0.04 + 0.12 * pulse) * satinLit + glint * 0.12 * satinLit);
    }
    if (wHolo > 0.0) {
        g2 = fbm3(uv * 1.9 + 2.3);
        float thick = g2 * 2.4 + uv.x * 0.35 + 0.15 * sin(uv.y * 3.1);
        vec3 film = 0.5 + 0.5 * cos(6.2831 * (thick + vec3(0.0, 0.33, 0.67)));
        float gd = dot(uv, normalize(vec2(0.8, 0.45)));
        vec3 grating = (0.5 + 0.5 * cos(6.2831 * (gd * 3.0 + vec3(0.0, 0.33, 0.67))))
                     * gauss((gd - 0.05) / 0.22);
        float scanBand = glowLine(uv.y - 0.14, 0.035);
        emit += wHolo * (mix(film, CYAN, 0.45) * inten * 0.12 + grating * inten * 0.08
                         + PERI * scanBand * (0.02 + 0.08 * inten));
        dawnFx += wHolo * (film * 0.06 + grating * 0.05 + vec3(scanBand * 0.04));
    }
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
    // dawn: the same effects in pearl, low-contrast against the paper, with
    // "lit" measured against each look's own ground (satin's is its cloth)
    vec3 groundS = mix(pal() ? u_p_db * 0.96 : vec3(0.800, 0.818, 0.900),
                       pal() ? u_p_da : vec3(0.862, 0.880, 0.940), smoothstep(-0.60, 0.70, sdiag))
                 * (1.0 - clamp(fiber + 0.6 * weft, -1.0, 1.0) * 0.12);
    float intenD = clamp(dot(abs(dawn - mix(dawnBase, groundS, wSatin)), vec3(0.3333)) * 7.0, 0.0, 1.0);
    if (wSilk > 0.0) {
        vec3 pearl = mix(0.5 + 0.5 * cos(6.2831 * (g2 * 2.2 + f * 0.8 + vec3(0.0, 0.33, 0.67))),
                         mix(PERI, vec3(1.0), 0.3), 0.8);
        dawn = mix(dawn, pearl, wSilk * intenD * 0.14 * quiet);
    }
    dawn = mix(dawn, vec3(1.0), clamp(dawnFx * (0.15 + 0.85 * intenD) * quiet, 0.0, 0.6));
    dawn *= 1.0 - clamp(dawnInk, -0.2, 0.2);

    // No raster: a fine scanline beats into moire when GNOME scales a baked
    // wallpaper to the monitor, and shimmers in the live sky; the lattice and
    // the grain carry the texture.

    vec3 col = mix(night, dawn, theme);

    // ---- film grain, screen-space ------------------------------------------
    // Follows luminance the way real grain does: strongest in the lit silk,
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
