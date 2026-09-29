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
// The looks themselves -- silk / leak / satin / holo -- are Pulsar's, math
// untouched; that is what keeps a Catppuccin desktop recognisably Pulsar.
uniform vec2  u_resolution;
uniform float u_time;
uniform float u_theme;   // 0 = night, 1 = dawn
uniform float u_look;    // 0 silk, 1 leak, 2 satin, 3 holo

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
uniform float u_fold;             // silk field scale (brand: 2.2)
uniform vec2  u_seed;             // silk field offset: moves every fold
uniform vec2  u_dir;              // direction the light mass flows FROM (brand: lower-left)
uniform vec2  u_bloom;            // satin bloom centre
uniform float u_beam;             // leak beam angle (brand: -0.35)
uniform float u_quiet;            // how hard the top-right (quick settings) corner is calmed
uniform float u_glow;             // luminescence: emissive cores, filaments, halos (0 = the plain look)
uniform float u_signal;           // signal treatment: lit lattice, edge aberration (0 = none)
uniform float u_grain;            // grain multiplier (it is also the 8-bit dither: never 0)
uniform float u_web;              // filament + lattice density/brightness (silk 1; leak/holo 0.55, satin 0.45)

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
    float star = 1.3 * exp(-dp2 / (r * r)) + 0.32 * exp(-sqrt(dp2) / (r * 3.5));
    // the brightest few get a thin four-point diffraction cross
    float L = r * (7.0 + 9.0 * b);
    float cross = exp(-abs(v.x) / L * 2.5) * exp(-v.y * v.y / (r * r * 0.3))
                + exp(-abs(v.y) / L * 2.5) * exp(-v.x * v.x / (r * r * 0.3));
    // each cell draws only its own star, so a spike reaching the cell's
    // edge would be cut off there: fade it out before the edge
    vec2 fc = fract(g);
    float edge = min(min(fc.x, 1.0 - fc.x), min(fc.y, 1.0 - fc.y)) * ppc;
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

vec3 holoRamp(float hx) {
    vec3 flank = u_c1 * 0.32;
    vec3 c = flank;
    c = mixo(c, u_c4, smoothstep(-0.38, -0.16, hx));
    c = mixo(c, u_c2, smoothstep(-0.04,  0.12, hx));
    c = mixo(c, u_c3, smoothstep( 0.16,  0.30, hx));
    c = mixo(c, flank, smoothstep( 0.34,  0.52, hx));
    return c;
}
vec3 beamRGB(float y, float c, float w, float o) {
    return vec3(gauss((y - c + o) / w), gauss((y - c) / w), gauss((y - c - o) / w));
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * u_resolution) / u_resolution.y;
    float r = length(uv);
    float theme = clamp(u_theme, 0.0, 1.0);
    vec2 dir = normalize(-u_dir);   // mask falls off TOWARD this

    // ---- silk ----
    vec2 p = uv * u_fold + u_seed;
    vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
    vec2 w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2)), fbm(p + 3.0 * q + vec2(8.3, 2.8)));
    float f = fbm(p + 3.0 * w);
    float mask = smoothstep(1.05, -0.55, dot(uv, dir));
    float lum = pow(smoothstep(0.28, 0.92, f), 1.6) * mask;
    vec3 silk = mixo(u_c1 * 0.75, u_c2, smoothstep(0.35, 0.75, f));
    silk = mixo(silk, u_c3, smoothstep(0.70, 0.95, f) * 0.8);
    silk = grey(silk, u_desat);

    // two fields at fixed places, faded between by theme (see pulsar.frag)
    vec2 seedD = uv + u_seed, seedL = uv + vec2(31.7, 17.3) + u_seed;
    float starsNight = mix(starLayer(seedD, 110.0, 0.030, 600.0, 0.0) + starLayer(seedD, 28.0, 0.050, 260.0, 0.0),
                           starLayer(seedL, 110.0, 0.030, 600.0, 0.0) + starLayer(seedL, 28.0, 0.050, 260.0, 0.0), step(0.5, theme));
    float starsDawn  = mix(starLayer(seedD,  60.0, 0.018, 380.0, 0.0) + starLayer(seedD, 18.0, 0.040, 180.0, 0.0),
                           starLayer(seedL,  60.0, 0.018, 380.0, 0.0) + starLayer(seedL, 18.0, 0.040, 180.0, 0.0), step(0.5, theme));

    vec3 night = mix(u_ga, u_gb, mask);
    night += silk * lum * 0.75 * u_gain;
    night += u_star * starsNight * clamp(1.0 - lum * 3.0, 0.0, 1.0) * 0.55 * u_stars;
    night *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r);
    night += u_c2 * u_down * pow(smoothstep(-0.25, 0.62, uv.y), 1.6) * (0.70 + 0.30 * exp(-uv.x * uv.x * 1.2));

    // ---- leak ----
    float lA = u_beam;
    vec2 lq = vec2(cos(lA) * uv.x + sin(lA) * uv.y, -sin(lA) * uv.x + cos(lA) * uv.y);
    float lfade = smoothstep(0.85, -0.35, lq.x);
    vec3 leak = mix(u_ga, u_gb, lfade);
    leak += u_c1 * beamRGB(lq.y, 0.36, 0.20, 0.050) * lfade * 0.30 * u_gain;  // brand 0.55: violet is dim, theme c1 is not
    leak += u_c2 * beamRGB(lq.y, 0.05, 0.26, 0.055) * lfade * 0.45 * u_gain;
    leak += u_c3 * beamRGB(lq.y, -0.28, 0.14, 0.040) * smoothstep(0.50, -0.45, lq.x) * 0.50 * u_gain;
    leak += u_c3 * gauss((lq.y + 0.28) / 0.42) * smoothstep(0.50, -0.45, lq.x) * 0.10 * u_gain;
    leak = grey(leak, u_desat * 0.8);
    leak += u_star * starsNight * (1.0 - lfade * 0.7) * 0.45 * u_stars;
    leak *= 1.0 - 0.35 * smoothstep(0.60, 1.10, r);

    // ---- satin ----
    float sdiag = dot(uv, normalize(vec2(-0.35, 1.0)));
    vec3 satin = mix(u_ga, mixo(u_gb, u_c1, 0.25), smoothstep(-0.60, 0.70, sdiag));
    vec2 sp = uv - u_bloom;
    float sd = dot(sp, sp);
    satin += u_c3 * exp(-sd * 7.0) * 0.26 * u_gain;
    satin += u_c2 * exp(-sd * 2.5) * 0.09 * u_gain;
    float su = dot(uv, normalize(vec2(1.0, 0.35)));
    float fiber = vnoise(vec2(sdiag * 340.0, su * 36.0)) - 0.5;
    float weft  = vnoise(vec2(su * 300.0, sdiag * 30.0)) - 0.5;
    satin += satin * (fiber + 0.6 * weft) * 0.38;
    satin = grey(satin, u_desat * 0.55);
    satin *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r);

    // ---- holo ----
    float nx = gl_FragCoord.x / u_resolution.x - 0.5;
    float film = vnoise(uv * 2.4 + 3.0 + u_seed) + 0.5 * vnoise(uv * 4.8 + 7.0);
    float fring = 0.5 + 0.5 * sin(film * 22.0);
    float sheen = 0.5 + 0.5 * sin(nx * 9.0 + sin(uv.y * 1.8) * 0.7);
    float hx = nx * 1.25 + 0.06 * sin(uv.y * 2.2 + 1.0) + (fring - 0.5) * 0.035 + uv.y * 0.08;
    float ab = 0.030;
    vec3 holo = vec3(holoRamp(hx + ab).r, holoRamp(hx).g, holoRamp(hx - ab).b);
    float env = smoothstep(0.62, 0.10, abs(uv.y)) * 0.62 + 0.10;
    holo *= env * (0.72 + 0.28 * sheen) * (0.92 + 0.11 * fring) * u_gain;
    holo = max(holo, u_ga);
    holo += u_star * starsNight * 0.20 * smoothstep(0.40, 0.62, abs(uv.y)) * u_stars;
    holo *= 1.0 - 0.30 * smoothstep(0.65, 1.15, r);

    float look = clamp(u_look, 0.0, 3.0);
    night = mix(night, leak,  clamp(look, 0.0, 1.0));
    night = mix(night, satin, clamp(look - 1.0, 0.0, 1.0));
    night = mix(night, holo,  clamp(look - 2.0, 0.0, 1.0));

    // ---- dawn ----
    vec3 dawnBase = mix(u_da, u_db, smoothstep(-0.5, 0.5, uv.y));
    vec3 l1 = mixo(u_c1, vec3(1.0), u_wash), l2 = mixo(u_c2, vec3(1.0), u_wash),
         l3 = mixo(u_c3, vec3(1.0), u_wash * 0.9), l4 = mixo(u_c4, vec3(1.0), u_wash);

    vec3 dawn = dawnBase;
    vec3 silkDawn = mixo(mixo(l1, l2, smoothstep(0.35, 0.75, f)), l3, smoothstep(0.6, 0.9, f));
    dawn = mixo(dawn, silkDawn, lum * 0.95 * u_gain);
    dawn = mixo(dawn, mixo(u_c1, vec3(1.0), 0.45), starsDawn * 0.35 * u_stars);

    vec3 dawnL = dawnBase;
    float dV = gauss((lq.y - 0.36) / 0.20) * lfade;
    float dP = gauss((lq.y - 0.05) / 0.26) * lfade;
    float dC = gauss((lq.y + 0.28) / 0.14) * smoothstep(0.50, -0.45, lq.x);
    dawnL = mixo(dawnL, l1, dV * 0.45 * u_gain);
    dawnL = mixo(dawnL, l2, dP * 0.68 * u_gain);
    dawnL = mixo(dawnL, l3, dC * 0.75 * u_gain);

    vec3 dawnS = mix(u_db, u_da, smoothstep(-0.60, 0.70, sdiag));
    dawnS = mixo(dawnS, l3, exp(-sd * 7.0) * 0.55 * u_gain);
    dawnS = mixo(dawnS, l2, exp(-sd * 2.5) * 0.25 * u_gain);
    dawnS *= 1.0 - clamp(fiber + 0.6 * weft, -1.0, 1.0) * 0.10;

    vec3 hr = vec3(holoRamp(hx + ab).r, holoRamp(hx).g, holoRamp(hx - ab).b);
    vec3 dawnH = mixo(dawnBase, mixo(hr, vec3(1.0), u_wash * 0.8),
                      (smoothstep(0.62, 0.10, abs(uv.y)) * 0.78 + 0.16) * u_gain);
    dawnH *= 0.94 + 0.06 * fring;

    dawn = mix(dawn, dawnL, clamp(look, 0.0, 1.0));
    dawn = mix(dawn, dawnS, clamp(look - 1.0, 0.0, 1.0));
    dawn = mix(dawn, dawnH, clamp(look - 2.0, 0.0, 1.0));

    // ---- each look's own luminescence (both variants) ----------------------
    // One signature effect per look, all quiet enough to be noticed on a
    // second look rather than the first: soft peaks, wide falloffs, more of
    // the calm ground showing. Nothing outshines the look's own emissive
    // core, and no effect runs brighter than the theme's highlight colour.
    //   silk  -- ion trails: filaments on isolines of the field, with a halo
    //   leak  -- volumetric light: god-rays through the leak, drifting motes,
    //            an anamorphic streak with a little dispersion at the beam edge
    //   satin -- fibre optics: a few warp threads carry travelling pulses of
    //            light, with a glint where a lit weft crosses them
    //   holo  -- interference: thin-film fringes and a diffraction sheen,
    //            coloured by wavelength, and one faint hologram scan band
    // u_web scales them all (the phosphor themes ask for more); u_signal the
    // hacker-ish parts (lattice on silk, dispersion, the scan band).
    float wSilk = 1.0 - clamp(look, 0.0, 1.0);
    float wLeak = clamp(look, 0.0, 1.0) - clamp(look - 1.0, 0.0, 1.0);
    float wSatin = clamp(look - 1.0, 0.0, 1.0) - clamp(look - 2.0, 0.0, 1.0);
    float wHolo = clamp(look - 2.0, 0.0, 1.0);
    float inten = clamp(dot(night - mix(u_ga, u_gb, 0.5), vec3(0.3333)) * 2.6, 0.0, 1.0);
    float carry = 0.05 + 0.95 * smoothstep(0.05, 0.7, inten);   // effects live in the lit mass
    vec3 emit = u_c3 * pow(inten, 3.0) * 0.16;                  // the core itself, gently
    vec3 soft = mixo(u_c2, u_c3, 0.5);
    float g2 = 0.0, fil = 0.0, halo = 0.0, tr = 0.0;
    vec3 dawnFx = vec3(0.0);        // light-variant additions, as a tint amount per channel
    float dawnInk = 0.0;

    if (wSilk > 0.0) {
        g2 = fbm(uv * 2.7 + w * 1.8 + u_seed * 0.73 + 4.1);
        float ca = 0.0020 * u_signal;
        vec3 f3 = vec3(line(g2 - 0.52 - ca, 0.0060), line(g2 - 0.52, 0.0060), line(g2 - 0.52 + ca, 0.0060))
                + 0.5 * vec3(line(f - 0.63 - ca, 0.0050), line(f - 0.63, 0.0050), line(f - 0.63 + ca, 0.0050));
        halo = (line(g2 - 0.52, 0.050) + 0.5 * line(f - 0.63, 0.040)) * u_web;
        fil = f3.g * u_web;
        tr = lattice(uv, 26.0) * step(1.0 - u_web, hash(floor(uv * 26.0) + 41.0)) * u_web * u_signal;
        emit += wSilk * (u_c3 * f3 * u_web * 0.55 * carry + soft * halo * 0.12 * carry
                         + mixo(u_c2, u_c3, 0.4) * tr * (0.010 + 0.18 * inten));
        dawnFx += wSilk * vec3(fil * 0.28 * (0.1 + 0.9 * carry));
        dawnInk += wSilk * tr * 0.025;
    }
    if (wLeak > 0.0) {
        // rays fan out from a source beyond the left edge, along the beams
        vec2 rel = lq - vec2(-1.25, -0.05);
        float ang = atan(rel.y, rel.x);
        float rays = vnoise(vec2(ang * 34.0, 1.7)) * 0.65 + vnoise(vec2(ang * 91.0, 4.2)) * 0.35;
        rays = smoothstep(0.35, 0.95, rays) * smoothstep(2.3, 0.4, length(rel));
        float motes = starLayer(uv + u_seed, 46.0, 0.035, 140.0, 0.0) + starLayer(uv - u_seed, 19.0, 0.03, 60.0, 0.0);
        float edge = -0.28 + 0.14;              // the upper edge of the brightest beam
        float disp = 0.0035 * u_signal;
        vec3 streak = vec3(line(lq.y - edge - disp, 0.010), line(lq.y - edge, 0.010), line(lq.y - edge + disp, 0.010))
                    * smoothstep(0.55, -0.6, lq.x);
        emit += wLeak * u_web * (soft * rays * inten * 0.09 + u_c3 * motes * inten * 0.28
                                 + u_c3 * streak * 0.10);
        dawnFx += wLeak * u_web * vec3(rays * 0.05 + streak.g * 0.08);
        dawnInk -= wLeak * u_web * motes * 0.06;      // motes on paper: pale specks catching light
    }
    if (wSatin > 0.0) {
        // warp threads run along the weave; a sparse few are lit fibres
        float n = 48.0;
        float tid = floor(sdiag * n);
        float across = fract(sdiag * n) - 0.5;
        float lit = step(0.80, hash(vec2(tid, 7.0)));
        float thread = line(across, 0.09) * lit;
        float pulse = pow(0.5 + 0.5 * sin(su * 9.0 - u_time * 0.6 + hash(vec2(tid, 3.0)) * 6.2831), 10.0);
        // a lit weft thread crossing a lit warp thread: a small glint
        float wid = floor(su * 30.0);
        float weftLit = step(0.90, hash(vec2(wid, 11.0)));
        float glint = thread * weftLit * line(fract(su * 30.0) - 0.5, 0.10);
        float satinLit = exp(-sd * 2.2);           // the bloom is where the light runs
        emit += wSatin * u_web * (u_c3 * thread * (0.10 + 0.35 * pulse) * satinLit
                                  + mixo(u_c3, vec3(1.0), 0.2) * glint * 0.30 * satinLit);
        dawnFx += wSatin * u_web * vec3(thread * (0.04 + 0.12 * pulse) * satinLit + glint * 0.12 * satinLit);
    }
    if (wHolo > 0.0) {
        g2 = fbm(uv * 1.9 + u_seed * 0.51 + 2.3);
        // thin film: hue follows optical thickness, fringes drift across it
        float thick = g2 * 2.4 + uv.x * 0.35 + 0.15 * sin(uv.y * 3.1);
        vec3 film = 0.5 + 0.5 * cos(6.2831 * (thick + vec3(0.0, 0.33, 0.67)));
        // grating: a broad diagonal band whose colour runs with angle
        float gd = dot(uv, normalize(vec2(0.8, 0.45)));
        vec3 grating = (0.5 + 0.5 * cos(6.2831 * (gd * 3.0 + vec3(0.0, 0.33, 0.67))))
                     * gauss((gd - 0.05) / 0.22);
        float scanBand = line(uv.y - 0.14, 0.035) * u_signal;
        emit += wHolo * u_web * (mixo(film, u_c3, 0.45) * inten * 0.12 + grating * inten * 0.08
                                 + soft * scanBand * (0.02 + 0.08 * inten));
        dawnFx += wHolo * u_web * (film * 0.06 + grating * 0.05 + vec3(scanBand * 0.04));
    }
    // never brighter than the highlight colour, however they stack
    emit = min(emit, u_c3 * 0.85 + 0.03);
    night = knee(night + emit * u_glow);

    // light: the same effects in pearl, low-contrast against the paper.
    // "lit" is measured against each look's OWN ground: satin's cloth is its
    // own gradient and weave, and measured against dawnBase all of it read as
    // lit and took the effects over plain cloth.
    vec3 groundS = mix(u_db, u_da, smoothstep(-0.60, 0.70, sdiag)) * (1.0 - clamp(fiber + 0.6 * weft, -1.0, 1.0) * 0.10);
    float intenD = clamp(dot(abs(dawn - mix(dawnBase, groundS, wSatin)), vec3(0.3333)) * 7.0, 0.0, 1.0);
    if (wSilk > 0.0) {
        vec3 pearl = mixo(0.5 + 0.5 * cos(6.2831 * (g2 * 2.2 + f * 0.8 + vec3(0.0, 0.33, 0.67))), l2, 0.8);
        dawn = mixo(dawn, pearl, wSilk * intenD * 0.14 * u_glow);
    }
    dawn = mix(dawn, vec3(1.0), clamp(dawnFx * (0.15 + 0.85 * intenD) * u_glow, 0.0, 0.6));
    dawn *= 1.0 - clamp(dawnInk, -0.2, 0.2) * u_signal;

    // No baked raster. A 3-pixel scanline looked right at 1:1 and beat into
    // moire the moment GNOME scaled the wallpaper to the monitor (3840->1920,
    // 2560->1366); the lattice and the grain carry the texture instead.

    // ---- the quiet corner ----
    // Quick settings, notifications and the calendar all open from the top
    // edge, mostly top-right, and sit over the wallpaper as translucent-feeling
    // cards. A bright fold or beam there fights them, so every look is calmed
    // toward its own ground in that corner and, more gently, along the bar.
    float aspect = u_resolution.x / u_resolution.y;
    vec2 qc = (uv - vec2(0.5 * aspect, 0.5)) * vec2(0.8, 1.2);
    float quiet = exp(-dot(qc, qc) * 2.2) * u_quiet;
    float bar = smoothstep(0.30, 0.50, uv.y) * 0.35 * u_quiet;
    night = mix(night, u_ga, clamp(quiet * 0.85 + bar, 0.0, 1.0));
    dawn = mixo(dawn, mix(u_da, u_db, 0.5), clamp(quiet * 0.75 + bar * 0.7, 0.0, 1.0));

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
