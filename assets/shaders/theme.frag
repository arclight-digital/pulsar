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
uniform float u_signal;           // signal treatment: lit lattice, raster, edge aberration (0 = none)
uniform float u_grain;            // grain multiplier (it is also the 8-bit dither: never 0)

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
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
float starLayer(vec2 uv, float scale, float density, float size) {
    vec2 g = uv * scale;
    vec2 id = floor(g);
    vec2 pos = vec2(hash(id + vec2(3.1, 1.7)), hash(id + vec2(7.7, 9.2)));
    float d = length(fract(g) - pos);
    float lit = step(1.0 - density, hash(id));
    return lit * exp(-d * d * size) * (0.4 + 0.6 * hash(id + vec2(5.5, 2.2)));
}

// ---- OKLab mixing -------------------------------------------------------
vec3 toLin(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 toSrgb(vec3 c) { c = max(c, 0.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }
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
    return vec3(exp(-pow((y - c + o) / w, 2.0)), exp(-pow((y - c) / w, 2.0)), exp(-pow((y - c - o) / w, 2.0)));
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

    vec2 seed = uv + theme * vec2(31.7, 17.3) + u_seed;
    float starsNight = starLayer(seed, 110.0, 0.030, 600.0) + starLayer(seed, 28.0, 0.050, 260.0);
    float starsDawn  = starLayer(seed,  60.0, 0.018, 380.0) + starLayer(seed, 18.0, 0.040, 180.0);

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
    leak += u_c3 * exp(-pow((lq.y + 0.28) / 0.42, 2.0)) * smoothstep(0.50, -0.45, lq.x) * 0.10 * u_gain;
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
    float dV = exp(-pow((lq.y - 0.36) / 0.20, 2.0)) * lfade;
    float dP = exp(-pow((lq.y - 0.05) / 0.26, 2.0)) * lfade;
    float dC = exp(-pow((lq.y + 0.28) / 0.14, 2.0)) * smoothstep(0.50, -0.45, lq.x);
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

    // ---- luminescence + signal (both variants) -------------------------------
    // Light that glows from within: the look above is the ground-glow; on it
    // go emissive cores where the look is brightest, ion-trail filaments on
    // isolines of a second warped field with a halo falloff and a touch of
    // chromatic split, and a circuit lattice lit only by the glow around it.
    // All of it is emission (added), tonemapped through a soft knee so the
    // highlights bloom rather than clip.
    float g2 = fbm(uv * 2.7 + w * 1.8 + u_seed * 0.73 + 4.1);
    float inten = clamp(dot(night - mix(u_ga, u_gb, 0.5), vec3(0.3333)) * 2.6, 0.0, 1.0);
    float ca = 0.0022 * u_signal;
    vec3 fil = vec3(line(g2 - 0.52 - ca, 0.0042), line(g2 - 0.52, 0.0042), line(g2 - 0.52 + ca, 0.0042))
             + 0.55 * vec3(line(f - 0.63 - ca, 0.0036), line(f - 0.63, 0.0036), line(f - 0.63 + ca, 0.0036));
    float halo = line(g2 - 0.52, 0.040) + 0.5 * line(f - 0.63, 0.030);
    float carry = 0.07 + 0.93 * smoothstep(0.05, 0.7, inten);    // trails live in the lit mass
    float tr = lattice(uv, 26.0);
    vec3 emit = u_c3 * fil * 0.95 * carry
              + mixo(u_c2, u_c3, 0.5) * halo * 0.16 * carry
              + u_c3 * pow(inten, 3.0) * 0.30
              + mixo(u_c2, u_c3, 0.4) * tr * (0.015 + 0.30 * inten) * u_signal / max(u_glow, 0.001);
    night = knee(night + emit * u_glow);

    // light: luminous on paper reads as pearl -- a thin-film sheen where the
    // look has colour, white-hot filaments with a tinted halo, and the
    // lattice as the faintest ink, never glow
    float intenD = clamp(dot(abs(dawn - dawnBase), vec3(0.3333)) * 7.0, 0.0, 1.0);
    vec3 pearl = 0.5 + 0.5 * cos(6.2831 * (g2 * 2.2 + f * 0.8 + vec3(0.0, 0.33, 0.67)));
    pearl = mixo(pearl, l2, 0.75);
    dawn = mixo(dawn, pearl, intenD * 0.22 * u_glow);
    float carryD = 0.10 + 0.90 * intenD;
    dawn = mix(dawn, vec3(1.0), clamp(fil.g * 0.40 * carryD * u_glow, 0.0, 1.0));
    dawn = mixo(dawn, l3, clamp(halo * 0.10 * carryD * u_glow, 0.0, 1.0));
    dawn *= 1.0 - tr * 0.035 * u_signal;

    // raster: a 3-pixel scanline you feel more than see
    float scan = 0.5 + 0.5 * sin(gl_FragCoord.y * 2.0944);
    night *= 1.0 - 0.045 * u_signal * scan;
    dawn *= 1.0 - 0.012 * u_signal * scan;

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
    float g = hash(gl_FragCoord.xy + fract(u_time) * 17.0) - 0.5;
    float brightness = dot(col, vec3(0.33));
    col += g * (0.012 + 0.050 * brightness) * mix(1.0, 0.5, theme) * u_grain;
    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
