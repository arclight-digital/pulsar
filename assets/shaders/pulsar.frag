// pulsar.frag -- the wallpaper background, rendered headless in CI.
//
// Pure fragment shader, no textures, no dependencies. scripts/render-wallpapers.py
// compiles it against a fullscreen triangle, writes PNGs, then composites the
// mark on top (full-color mark on dark, ink mark on light -- the logo is alpha
// art, so it is pasted after the render rather than reimplemented in GLSL).
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
// math. The only post-approval addition is the downlight, which sits on top.
uniform vec2  u_resolution;
uniform float u_time;   // fixed per render for stills, live for WebGL
uniform float u_theme;  // 0 = dark variant, 1 = light variant
uniform float u_look;   // 0 = silk (shipped), 1 = leak, 2 = satin, 3 = holo

// brand palette
const vec3 CYAN   = vec3(0.243, 0.796, 1.000); // #3ECBFF
const vec3 PERI   = vec3(0.561, 0.659, 1.000); // #8FA8FF
const vec3 VIOLET = vec3(0.294, 0.247, 0.831); // #4B3FD4
const vec3 STAR   = vec3(0.914, 0.929, 0.969); // #E9EDF7

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

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
float starLayer(vec2 uv, float scale, float density, float size) {
    vec2 g = uv * scale;
    vec2 id = floor(g);
    vec2 pos = vec2(hash(id + vec2(3.1, 1.7)), hash(id + vec2(7.7, 9.2)));
    float d = length(fract(g) - pos);
    float lit = step(1.0 - density, hash(id));
    return lit * exp(-d * d * size) * (0.4 + 0.6 * hash(id + vec2(5.5, 2.2)));
}

// holo's column ramp: indigo | rose | periwinkle | teal | indigo. Split out
// so the technicolor pass can sample it three times at offset positions.
vec3 holoRamp(float hx) {
    vec3 c = vec3(0.055, 0.075, 0.360);
    c = mix(c, vec3(0.980, 0.520, 0.760), smoothstep(-0.38, -0.16, hx));
    c = mix(c, PERI,                      smoothstep(-0.04,  0.12, hx));
    c = mix(c, vec3(0.290, 0.800, 0.840), smoothstep( 0.16,  0.30, hx));
    c = mix(c, vec3(0.055, 0.075, 0.360), smoothstep( 0.34,  0.52, hx));
    return c;
}

// one beam with prismatic dispersion: the R/G/B channels land at slightly
// offset heights, so the beam's edges split into color fringes
vec3 beamRGB(float y, float c, float w, float o) {
    return vec3(exp(-pow((y - c + o) / w, 2.0)),
                exp(-pow((y - c) / w, 2.0)),
                exp(-pow((y - c - o) / w, 2.0)));
}

void main() {
    vec2 uv = (gl_FragCoord.xy - 0.5 * u_resolution) / u_resolution.y;
    float r = length(uv);
    float theme = clamp(u_theme, 0.0, 1.0);

    // ---- the silk: domain-warped fbm (iq's f(p + fbm(p + fbm(p))) trick) --
    // This is what replaces gaussian bands: the double warp folds the field
    // into creases and wisps, so the light has internal structure instead of
    // reading as airbrushed stripes.
    vec2 p = uv * 2.2 + vec2(0.0, u_time * 0.01);
    vec2 q = vec2(fbm(p), fbm(p + vec2(5.2, 1.3)));
    vec2 w = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2)),
                  fbm(p + 3.0 * q + vec2(8.3, 2.8)));
    float f = fbm(p + 3.0 * w);

    // light mass flows out of the lower-left; the upper-right goes dark.
    // the smoothstep remap is contrast, not gain: creases below 0.28 stay
    // black, folds above it glow -- raising overall gain instead of this is
    // what made an earlier cut read as uniform smoke
    float mask = smoothstep(1.05, -0.55, dot(uv, normalize(vec2(0.80, 0.60))));
    float lum = pow(smoothstep(0.28, 0.92, f), 1.6) * mask;

    // color from the fold depth, brand ramp only, then pulled toward grey --
    // full-sat hues are what made the earlier cuts read like test cards
    vec3 silk = mix(VIOLET * 0.75, PERI, smoothstep(0.35, 0.75, f));
    silk = mix(silk, CYAN, smoothstep(0.70, 0.95, f) * 0.8);
    silk = mix(silk, vec3(dot(silk, vec3(0.30, 0.55, 0.15))), 0.18);

    // each variant gets its own sky: a seed shift moves every star, and the
    // mixes differ -- night is dense fine dust, dawn is sparse larger glints
    vec2 seed = uv + theme * vec2(31.7, 17.3);
    float starsNight = starLayer(seed, 110.0, 0.030, 600.0)
                     + starLayer(seed,  28.0, 0.050, 260.0);
    float starsDawn  = starLayer(seed,  60.0, 0.018, 380.0)
                     + starLayer(seed,  18.0, 0.040, 180.0);

    // ---- night -------------------------------------------------------------
    // kept LOW on purpose: this sits behind a desktop full of windows, and
    // the reference boards go to true black in the empty regions
    vec3 night = mix(vec3(0.005, 0.006, 0.016),      // upper-right, near black
                     vec3(0.016, 0.019, 0.048),      // lower-left, indigo cast
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
    vec3 leak = mix(vec3(0.006, 0.007, 0.018), vec3(0.014, 0.016, 0.040), lfade);
    leak += VIOLET * beamRGB(lq.y, 0.36, 0.20, 0.050) * lfade * 0.55;
    leak += PERI   * beamRGB(lq.y, 0.05, 0.26, 0.055) * lfade * 0.45;
    leak += CYAN   * beamRGB(lq.y, -0.28, 0.14, 0.040)
          * smoothstep(0.50, -0.45, lq.x) * 0.50;
    // halation: an extra-wide faint copy of the cyan beam glowing outward
    leak += CYAN * exp(-pow((lq.y + 0.28) / 0.42, 2.0))
          * smoothstep(0.50, -0.45, lq.x) * 0.10;
    leak = mix(leak, vec3(dot(leak, vec3(0.33))), 0.15);
    leak += STAR * starsNight * (1.0 - lfade * 0.7) * 0.45;
    leak *= 1.0 - 0.35 * smoothstep(0.60, 1.10, r);

    // 2: satin -- LOCKED composition: indigo field, one submerged cyan bloom.
    // Unique effect: directional thread sheen, fine noise stretched along the
    // diagonal like woven fabric; it scales with local brightness the way a
    // real weave only shows where the light hits it.
    float sdiag = dot(uv, normalize(vec2(-0.35, 1.0)));
    vec3 satin = mix(vec3(0.006, 0.008, 0.020),
                     vec3(0.030, 0.045, 0.110),
                     smoothstep(-0.60, 0.70, sdiag));
    vec2 sp = uv - vec2(0.42, -0.06);
    float sd = dot(sp, sp);
    satin += CYAN * exp(-sd * 7.0) * 0.26;
    satin += PERI * exp(-sd * 2.5) * 0.09;
    float su = dot(uv, normalize(vec2(1.0, 0.35)));       // along-thread coord
    // weave, not scratches: short fiber dashes along the thread direction
    // crossed by a weaker perpendicular weft. Long unbroken streaks read as
    // brushed metal, which satin is not; still scales with local brightness
    // so the weave only shows where the bloom hits it.
    float fiber = vnoise(vec2(sdiag * 340.0, su * 36.0)) - 0.5;
    float weft  = vnoise(vec2(su * 300.0, sdiag * 30.0)) - 0.5;
    satin += satin * (fiber + 0.6 * weft) * 0.38;
    satin = mix(satin, vec3(dot(satin, vec3(0.33))), 0.10);
    // no stars: this is cloth, not sky
    satin *= 1.0 - 0.40 * smoothstep(0.55, 1.10, r);

    // 3: holo -- iridescent foil, spectrum clipped to rose/peri/teal between
    // indigo flanks, luminous mid-height. Unique effect: thin-film
    // interference -- contour fringes from a smooth thickness field, hue
    // rotating across each fringe like an oil slick. Curved bands, so it
    // shares no DNA with satin's threads or leak's discs. The muddy version
    // of this look died of desaturation, so it keeps most of its chroma.
    float nx = gl_FragCoord.x / u_resolution.x - 0.5;
    float film = vnoise(uv * 2.4 + 3.0) + 0.5 * vnoise(uv * 4.8 + 7.0);
    float fring = 0.5 + 0.5 * sin(film * 22.0);            // interference fringes
    float sheen = 0.5 + 0.5 * sin(nx * 9.0 + sin(uv.y * 1.8) * 0.7);
    // fringes SHIMMER the columns, they must not replace them -- the 0.10
    // version of this hue shift turned the whole frame into an oil slick
    float hx = nx * 1.25 + 0.06 * sin(uv.y * 2.2 + 1.0)
             + (fring - 0.5) * 0.035 + uv.y * 0.08;
    // technicolor mis-registration: each channel reads the column ramp at a
    // slightly different position, so every color boundary fringes
    float ab = 0.030;
    vec3 holo = vec3(holoRamp(hx + ab).r, holoRamp(hx).g, holoRamp(hx - ab).b);
    float env = smoothstep(0.62, 0.10, abs(uv.y)) * 0.62 + 0.10;
    holo *= env * (0.72 + 0.28 * sheen) * (0.92 + 0.11 * fring);
    holo = mix(holo, vec3(dot(holo, vec3(0.33))), 0.04);   // nearly full chroma
    holo += STAR * starsNight * 0.20 * smoothstep(0.40, 0.62, abs(uv.y));
    holo *= 1.0 - 0.30 * smoothstep(0.65, 1.15, r);

    float look = clamp(u_look, 0.0, 3.0);
    night = mix(night, leak,  clamp(look, 0.0, 1.0));
    night = mix(night, satin, clamp(look - 1.0, 0.0, 1.0));
    night = mix(night, holo,  clamp(look - 2.0, 0.0, 1.0));

    // ---- dawn: every look gets a high-key counterpart ----------------------
    // No darkening pool behind the mark: the light cuts carry the INK mark
    // (pulsar-mark-ink), which is designed to read on pale ground as-is.
    // ground sits a full step below white -- "too light" feedback killed the
    // near-white version; the tint does the work of making the marks pop
    vec3 dawnBase = mix(vec3(0.906, 0.916, 0.958),
                        vec3(0.822, 0.842, 0.922),
                        smoothstep(-0.5, 0.5, uv.y));

    // silk dawn: the field as watercolor, wetter than before
    vec3 dawn = dawnBase;
    vec3 silkDawn = mix(mix(PERI, vec3(1.0), 0.12), mix(CYAN, vec3(1.0), 0.20),
                        smoothstep(0.6, 0.9, f));
    dawn = mix(dawn, silkDawn, lum * 0.95);
    dawn = mix(dawn, mix(VIOLET, vec3(1.0), 0.60), starsDawn * 0.35); // pale glints

    // leak dawn: the same beams as washes of pastel; dispersion would be
    // invisible at this key, so the light cut trades it for pure color
    vec3 dawnL = dawnBase;
    float dV = exp(-pow((lq.y - 0.36) / 0.20, 2.0)) * lfade;
    float dP = exp(-pow((lq.y - 0.05) / 0.26, 2.0)) * lfade;
    float dC = exp(-pow((lq.y + 0.28) / 0.14, 2.0)) * smoothstep(0.50, -0.45, lq.x);
    dawnL = mix(dawnL, vec3(0.700, 0.650, 0.930), dV * 0.75);
    dawnL = mix(dawnL, vec3(0.700, 0.760, 0.970), dP * 0.68);
    dawnL = mix(dawnL, vec3(0.590, 0.840, 0.975), dC * 0.75);

    // satin dawn: daylight on the same cloth -- the weave flips to reading
    // as darker threads on pale fabric, and the bloom becomes a soft sheen
    vec3 dawnS = mix(vec3(0.800, 0.818, 0.900),
                     vec3(0.862, 0.880, 0.940),
                     smoothstep(-0.60, 0.70, sdiag));
    dawnS += CYAN * exp(-sd * 7.0) * 0.18;
    dawnS *= 1.0 - clamp(fiber + 0.6 * weft, -1.0, 1.0) * 0.12;

    // holo dawn: the foil ramp pushed to pastel over the pale ground
    vec3 dawnH = mix(dawnBase,
                     mix(vec3(holoRamp(hx + ab).r, holoRamp(hx).g, holoRamp(hx - ab).b),
                         vec3(1.0), 0.38),
                     smoothstep(0.62, 0.10, abs(uv.y)) * 0.78 + 0.16);
    dawnH *= 0.94 + 0.06 * fring;

    dawn = mix(dawn, dawnL, clamp(look, 0.0, 1.0));
    dawn = mix(dawn, dawnS, clamp(look - 1.0, 0.0, 1.0));
    dawn = mix(dawn, dawnH, clamp(look - 2.0, 0.0, 1.0));

    vec3 col = mix(night, dawn, theme);

    // ---- film grain, screen-space ------------------------------------------
    // Follows luminance the way real grain does: strongest in the lit silk,
    // never absent even in the blacks. This also kills gradient banding.
    float g = hash(gl_FragCoord.xy + fract(u_time) * 17.0) - 0.5;
    float brightness = dot(col, vec3(0.33));
    col += g * (0.012 + 0.050 * brightness) * mix(1.0, 0.6, theme);

    gl_FragColor = vec4(clamp(col, 0.0, 1.0), 1.0);
}
